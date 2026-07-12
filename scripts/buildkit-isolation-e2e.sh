#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

init_script_logging "buildkit-isolation-e2e"

proof_dir=""
owner_log="$LOG_DIR/buildkit-secret-owner.log"
attacker_log="$LOG_DIR/buildkit-secret-attacker.log"
canary=""
python_bin=""

cleanup() {
  local code=$?
  trap - EXIT
  if declare -p COMPOSE_BASE >/dev/null 2>&1; then
    if ((code != 0)); then
      "${COMPOSE_BASE[@]}" --profile buildkit-poc logs --tail 200 \
        buildkitd buildkit-control-plane-canary >&2 || true
    fi
    "${COMPOSE_BASE[@]}" --profile buildkit-poc run --rm -T --no-deps \
      --entrypoint //bin/rm buildkit-client -f //proof/canary >/dev/null 2>&1 || true
    "${COMPOSE_BASE[@]}" --profile buildkit-poc stop \
      buildkitd buildkit-control-plane-canary >/dev/null 2>&1 || true
    "${COMPOSE_BASE[@]}" --profile buildkit-poc rm -f \
      buildkit-volume-init >/dev/null 2>&1 || true
  fi
  canary=""
  if ((code != 0)); then
    err "Command failed: ${BASH_COMMAND}"
    [[ -f "$SCRIPT_ERR_LOG" ]] && cat "$SCRIPT_ERR_LOG" >&2
  fi
  exit "$code"
}
trap cleanup EXIT

client() {
  "${COMPOSE_BASE[@]}" --profile buildkit-poc run --rm -T --no-deps \
    buildkit-client "$@"
}

client_shell() {
  "${COMPOSE_BASE[@]}" --profile buildkit-poc run --rm -T --no-deps \
    --entrypoint //bin/sh buildkit-client -ec "$1"
}

write_canary() {
  printf '%s' "$canary" | \
    "${COMPOSE_BASE[@]}" --profile buildkit-poc run --rm -T --no-deps \
      --entrypoint //bin/sh buildkit-client -ec \
      'umask 077; cat > /proof/canary; test -s /proof/canary'
}

resolve_python() {
  if command -v python3 >/dev/null 2>&1; then
    python_bin="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    python_bin="$(command -v python)"
  else
    err "Python 3 is required for the BuildKit isolation proof"
    return 1
  fi
}

verify_daemon_boundary() {
  local buildkit_id canary_id control_plane_id networks mounts routes workers socket
  buildkit_id="$("${COMPOSE_BASE[@]}" --profile buildkit-poc ps -q buildkitd)"
  canary_id="$("${COMPOSE_BASE[@]}" --profile buildkit-poc ps -q buildkit-control-plane-canary)"
  control_plane_id="$("${COMPOSE_BASE[@]}" ps -q control-plane)"
  [[ -n "$buildkit_id" && -n "$canary_id" ]]

  [[ "$(docker exec "$buildkit_id" sh -c "awk '/^Uid:/ { print \$2; exit }' /proc/1/status")" == "1000" ]]
  [[ "$(docker inspect --format '{{.Config.User}}' "$buildkit_id")" == "1000:1000" ]]
  [[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$buildkit_id")" == "true" ]]
  [[ "$(docker inspect --format '{{.HostConfig.Memory}}' "$buildkit_id")" == "1073741824" ]]
  [[ "$(docker inspect --format '{{.HostConfig.NanoCpus}}' "$buildkit_id")" == "1000000000" ]]
  [[ "$(docker inspect --format '{{.HostConfig.PidsLimit}}' "$buildkit_id")" == "512" ]]

  networks="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$buildkit_id")"
  [[ "$networks" == "devpush_buildkit_sandbox" ]]
  [[ "$(docker network inspect devpush_buildkit_sandbox --format '{{.Internal}}')" == "true" ]]
  routes="$(docker exec "$buildkit_id" ip route)"
  ! grep -Eq '^default([[:space:]]|$)' <<<"$routes"

  mounts="$(docker inspect --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' "$buildkit_id")"
  ! grep -Fq '/var/run/docker.sock' <<<"$mounts"
  socket="$(MSYS_NO_PATHCONV=1 docker exec "$buildkit_id" stat -c '%a %u %g' /run/user/1000/buildkit/buildkitd.sock)"
  [[ "$socket" == "660 1000 1000" ]]
  ! docker exec "$buildkit_id" nc -z -w 1 127.0.0.1 1234

  workers="$(client debug workers -v)"
  grep -Eq 'org\.mobyproject\.buildkit\.worker\.executor:[[:space:]]+oci' <<<"$workers"
  grep -Eq 'org\.mobyproject\.buildkit\.worker\.oci\.process-mode:[[:space:]]+sandbox' <<<"$workers"
  grep -Eq 'org\.mobyproject\.buildkit\.worker\.snapshotter:[[:space:]]+native' <<<"$workers"

  if [[ -n "$control_plane_id" ]]; then
    networks="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$control_plane_id")"
    ! grep -Fq 'devpush_buildkit_sandbox' <<<"$networks"
  fi
  networks="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$canary_id")"
  ! grep -Fq 'devpush_buildkit_sandbox' <<<"$networks"
}

run_network_probe() {
  local canary_id canary_ip nonce
  canary_id="$("${COMPOSE_BASE[@]}" --profile buildkit-poc ps -q buildkit-control-plane-canary)"
  canary_ip="$(docker inspect --format '{{(index .NetworkSettings.Networks "devpush_internal").IPAddress}}' "$canary_id")"
  nonce="$("$python_bin" -c 'import uuid; print(uuid.uuid4())')"
  [[ -n "$canary_ip" ]]

  client build \
    --progress plain \
    --no-cache \
    --frontend dockerfile.v0 \
    --local context=//proof/context \
    --local dockerfile=//proof/context \
    --opt filename=Dockerfile.network \
    --opt "build-arg:CONTROL_PLANE_IP=$canary_ip" \
    --opt "build-arg:PROBE_NONCE=$nonce" \
    --output type=local,dest=//proof/output-network

  client_shell 'test "$(cat /proof/output-network/proof/result.txt)" = network-isolation-passed'
}

run_cross_build_probe() {
  local digest nonce owner_pid marker=0 buildkit_id
  digest="$(printf '%s' "$canary" | sha256sum | awk '{print $1}')"
  nonce="$("$python_bin" -c 'import uuid; print(uuid.uuid4())')"
  : >"$owner_log"
  : >"$attacker_log"

  client build \
    --progress plain \
    --no-cache \
    --frontend dockerfile.v0 \
    --local context=//proof/context \
    --local dockerfile=//proof/context \
    --opt filename=Dockerfile.secret-owner \
    --opt "build-arg:CANARY_SHA256=$digest" \
    --opt "build-arg:PROBE_NONCE=$nonce-owner" \
    --secret id=canary,src=//proof/canary \
    --output type=local,dest=//proof/output-owner >"$owner_log" 2>&1 &
  owner_pid=$!

  for _attempt in $(seq 1 200); do
    if grep -Fq 'owner-secret-mounted' "$owner_log"; then
      marker=1
      break
    fi
    if ! kill -0 "$owner_pid" 2>/dev/null; then
      wait "$owner_pid"
      return 1
    fi
    sleep 0.1
  done
  ((marker == 1))

  client build \
    --progress plain \
    --no-cache \
    --frontend dockerfile.v0 \
    --local context=//proof/context \
    --local dockerfile=//proof/context \
    --opt filename=Dockerfile.secret-attacker \
    --opt "build-arg:PROBE_NONCE=$nonce-attacker" \
    --output type=local,dest=//proof/output-attacker >"$attacker_log" 2>&1
  kill -0 "$owner_pid" 2>/dev/null
  wait "$owner_pid"

  grep -Fq 'attacker-isolated' "$attacker_log"
  client_shell 'test "$(cat /proof/output-owner/proof/result.txt)" = secret-owner-passed'
  client_shell 'test "$(cat /proof/output-attacker/proof/result.txt)" = cross-build-isolation-passed'
  ! grep -Fq "$canary" "$owner_log" "$attacker_log"

  buildkit_id="$("${COMPOSE_BASE[@]}" --profile buildkit-poc ps -q buildkitd)"
  ! printf '%s\n' "$canary" | \
    MSYS_NO_PATHCONV=1 docker exec -i "$buildkit_id" \
      /bin/busybox grep -R -F -q -f - /home/user/.local/share/buildkit
}

# Configure Compose
set_compose_base
resolve_python
proof_dir="$DATA_DIR/buildkit-proof"

# Prepare proof workspace
run_cmd "Creating BuildKit proof workspace..." mkdir -p "$proof_dir"
run_cmd "Starting rootless BuildKit isolation proof..." \
  "${COMPOSE_BASE[@]}" --profile buildkit-poc up -d --wait \
  buildkitd buildkit-control-plane-canary
run_cmd "Preparing scratch-based malicious build fixtures..." \
  "${COMPOSE_BASE[@]}" --profile buildkit-poc run --rm -T --no-deps \
  buildkit-proof-fixture

# Verify daemon isolation
run_cmd "Verifying rootless BuildKit control boundary..." verify_daemon_boundary

# Verify build network isolation
run_cmd "Blocking metadata and control-plane access from build steps..." run_network_probe

# Verify concurrent build isolation
canary="$("$python_bin" -c 'import secrets; print(secrets.token_hex(32), end="")')"
run_cmd "Mounting a private build secret without environment exposure..." write_canary
run_cmd "Blocking concurrent cross-build secret access..." run_cross_build_probe

# Stop proof services
run_cmd "Stopping BuildKit isolation proof services..." \
  "${COMPOSE_BASE[@]}" --profile buildkit-poc stop \
  buildkitd buildkit-control-plane-canary

printf "${GRN}BuildKit isolation E2E passed.${NC}\n"
