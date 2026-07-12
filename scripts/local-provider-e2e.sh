#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

init_script_logging "local-provider-e2e"

trap 'code=$?; if (( code != 0 )); then err "Command failed: ${BASH_COMMAND}"; [[ -f "$SCRIPT_ERR_LOG" ]] && cat "$SCRIPT_ERR_LOG" >&2; fi; exit "$code"' EXIT

assert_equal() {
  local actual="$1"
  local expected="$2"
  local description="$3"
  [[ "$actual" == "$expected" ]] || {
    printf 'Expected %s to be %q, got %q\n' "$description" "$expected" "$actual" >&2
    return 1
  }
}

verify_isolation() {
  local control_plane_id provider_id provider_uid control_plane_networks control_plane_mounts
  local runtime_network_internal build_status exec_status system_status
  local -a runtime_ids

  control_plane_id="$("${COMPOSE_BASE[@]}" ps -q control-plane)"
  provider_id="$("${COMPOSE_BASE[@]}" ps -q local-provider)"
  [[ -n "$control_plane_id" && -n "$provider_id" ]]

  provider_uid="$(docker exec "$provider_id" sh -c "awk '/^Uid:/ { print \$2; exit }' /proc/1/status")"
  [[ "$provider_uid" != "0" ]] || {
    printf 'Local-provider process must not run as root\n' >&2
    return 1
  }

  control_plane_networks="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$control_plane_id")"
  ! grep -Eq '^devpush_(docker_api|local_provider_docker|local_runtime)$' <<<"$control_plane_networks"
  control_plane_mounts="$(docker inspect --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' "$control_plane_id")"
  ! grep -Fq '/var/run/docker.sock' <<<"$control_plane_mounts"

  runtime_network_internal="$(docker network inspect devpush_local_runtime --format '{{.Internal}}')"
  assert_equal "$runtime_network_internal" "true" "local runtime network isolation"

  mapfile -t runtime_ids < <(docker ps -q --filter 'label=com.layerrail.managed=true')
  (( ${#runtime_ids[@]} > 0 )) || {
    printf 'No managed local runtime is available for security verification\n' >&2
    return 1
  }
  for runtime_id in "${runtime_ids[@]}"; do
    assert_equal "$(docker inspect --format '{{.Config.User}}' "$runtime_id")" "10001:10001" "runtime user"
    assert_equal "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$runtime_id")" "true" "read-only runtime root filesystem"
    assert_equal "$(docker inspect --format '{{json .HostConfig.CapDrop}}' "$runtime_id")" '["ALL"]' "runtime capability drop"
    assert_equal "$(docker inspect --format '{{json .HostConfig.SecurityOpt}}' "$runtime_id")" '["no-new-privileges:true"]' "runtime security options"
    assert_equal "$(docker inspect --format '{{.HostConfig.Memory}}' "$runtime_id")" "268435456" "runtime memory limit"
    assert_equal "$(docker inspect --format '{{.HostConfig.NanoCpus}}' "$runtime_id")" "500000000" "runtime CPU limit"
    assert_equal "$(docker inspect --format '{{.HostConfig.PidsLimit}}' "$runtime_id")" "128" "runtime PID limit"
    assert_equal "$(docker inspect --format '{{json .HostConfig.Tmpfs}}' "$runtime_id")" '{"/tmp":"rw,noexec,nosuid,size=16777216"}' "runtime temporary filesystem"
    assert_equal "$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$runtime_id")" "devpush_local_runtime" "runtime network"
    assert_equal "$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$runtime_id")" "devpush_local_runtime" "runtime network attachment"
  done
  assert_equal "$(docker inspect --format '{{.State.Health.Status}}' "${runtime_ids[0]}")" "healthy" "runtime readiness health"

  build_status="$(docker exec "$provider_id" curl -sS -o /dev/null -w '%{http_code}' -X POST http://local-docker-proxy:2375/build)"
  exec_status="$(docker exec "$provider_id" curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"Cmd":["id"]}' "http://local-docker-proxy:2375/containers/${runtime_ids[0]}/exec")"
  system_status="$(docker exec "$provider_id" curl -sS -o /dev/null -w '%{http_code}' http://local-docker-proxy:2375/system/df)"
  assert_equal "$build_status" "403" "Docker build API denial"
  assert_equal "$exec_status" "403" "Docker exec API denial"
  assert_equal "$system_status" "403" "Docker system API denial"
}

# Configure Compose
set_compose_base

# Build trusted sample
run_cmd "Building trusted local-provider sample..." \
  "${COMPOSE_BASE[@]}" --profile samples build local-provider-sample
image_digest="$(docker image inspect --format '{{.Id}}' lrail-local-sample:dev)"
[[ "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { err "Sample image digest is invalid"; exit 1; }

# Run complete deployment flow
run_cmd "Running local-provider deploy, promote, rollback, and cancellation E2E..." \
  "${COMPOSE_BASE[@]}" exec -T \
  -e "SAMPLE_IMAGE_DIGEST=$image_digest" \
  control-plane bundle exec rails runner script/local_provider_e2e.rb

# Verify provider isolation
run_cmd "Verifying local-provider isolation and runtime hardening..." verify_isolation

printf "${GRN}Local-provider E2E passed.${NC}\n"
