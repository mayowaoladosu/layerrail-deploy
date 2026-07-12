#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

init_script_logging "phase2-cell"

PROFILE="${LRAIL_ALPHA_PROFILE:-lrail-alpha}"
KUBERNETES_VERSION="${LRAIL_ALPHA_KUBERNETES_VERSION:-v1.34.0}"
ACTION="${1:-start}"
CONFIRM_DELETE="${2:-}"
KUBECTL=(kubectl --context "$PROFILE")
CELL_TEMP_DIR=""
WORKER_IMAGE=""
WORKER_IMAGE_PLACEHOLDER="docker.io/library/lrail-build-worker@sha256:0000000000000000000000000000000000000000000000000000000000000000"

trap 'code=$?; [[ -n "${CELL_TEMP_DIR:-}" ]] && rm -rf "$CELL_TEMP_DIR"; if (( code != 0 )); then err "Command failed: ${BASH_COMMAND}"; [[ -f "$SCRIPT_ERR_LOG" ]] && cat "$SCRIPT_ERR_LOG" >&2; fi; exit "$code"' EXIT

usage() {
  cat <<EOF
Usage: $(basename "$0") <start|status|stop|delete> [--yes]

Commands:
  start          Create or reconcile the disposable Phase 2 cell
  status         Show node, sandbox and artifact-service status
  stop           Stop the cell without deleting state
  delete --yes   Delete the disposable cell and all alpha artifacts
EOF
}

python_bin() {
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
  elif command -v python >/dev/null 2>&1; then
    command -v python
  else
    err "Python 3 is required"
    return 1
  fi
}

openssl_bin() {
  if command -v openssl >/dev/null 2>&1; then
    command -v openssl
  elif [[ -x "/c/Program Files/Git/usr/bin/openssl.exe" ]]; then
    printf '%s\n' "/c/Program Files/Git/usr/bin/openssl.exe"
  else
    err "OpenSSL is required"
    return 1
  fi
}

ensure_cluster() {
  local state
  state="$(minikube status -p "$PROFILE" --format='{{.Host}}' 2>/dev/null || true)"
  if [[ "$state" != "Running" ]]; then
    minikube start -p "$PROFILE" \
      --driver=docker \
      --container-runtime=containerd \
      --docker-opt containerd=/var/run/containerd/containerd.sock \
      --cni=cilium \
      --kubernetes-version="$KUBERNETES_VERSION" \
      --cpus=4 \
      --memory=6144 \
      --disk-size=30g \
      --insecure-registry=10.0.0.0/8 \
      --insecure-registry=192.168.0.0/16 \
      --keep-context=false
  fi
  minikube addons enable gvisor -p "$PROFILE"
  minikube addons enable metrics-server -p "$PROFILE"
  "${KUBECTL[@]}" wait --for=condition=Ready pod/gvisor -n kube-system --timeout=180s
  "${KUBECTL[@]}" get runtimeclass gvisor >/dev/null
}

build_platform_images() {
  docker build -f "$APP_DIR/docker/Dockerfile.registry-auth" -t lrail-registry-auth:dev "$APP_DIR"
  docker build -f "$APP_DIR/docker/Dockerfile.artifact-gateway" -t lrail-artifact-gateway:dev "$APP_DIR"
  docker build -f "$APP_DIR/docker/Dockerfile.buildkit-gvisor" -t lrail-buildkit-gvisor:dev "$APP_DIR"
  docker build -f "$APP_DIR/docker/Dockerfile.build-worker" -t lrail-build-worker:dev "$APP_DIR"
  docker build -f "$APP_DIR/docker/Dockerfile.build-controller" -t lrail-build-controller:dev "$APP_DIR"
  minikube image load --overwrite=true -p "$PROFILE" lrail-registry-auth:dev
  minikube image load --overwrite=true -p "$PROFILE" lrail-artifact-gateway:dev
  minikube image load --overwrite=true -p "$PROFILE" lrail-build-worker:dev
  minikube image load --overwrite=true -p "$PROFILE" lrail-build-controller:dev

  local listing digest
  listing="$(minikube ssh -p "$PROFILE" -- "sudo ctr -n k8s.io images list")"
  digest="$(printf '%s\n' "$listing" | awk '
    $1 == "docker.io/library/lrail-build-worker:dev" {
      for (index = 1; index <= NF; index += 1) {
        if ($index ~ /^sha256:[0-9a-f]{64}$/) { print $index; exit }
      }
    }
  ')"
  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    err "Could not resolve the loaded build-worker image digest"
    return 1
  fi
  WORKER_IMAGE="docker.io/library/lrail-build-worker@$digest"
  minikube ssh -p "$PROFILE" -- \
    "sudo ctr -n k8s.io images tag --force docker.io/library/lrail-build-worker:dev '$WORKER_IMAGE'" \
    >/dev/null
}

ensure_secrets() {
  local py openssl
  py="$(python_bin)"
  openssl="$(openssl_bin)"
  CELL_TEMP_DIR="$(mktemp -d)"
  chmod 0700 "$CELL_TEMP_DIR"

  set_compose_base
  local compose_phase2
  compose_phase2=("${COMPOSE_BASE[@]}" --profile phase2)
  if ! "${compose_phase2[@]}" exec -T control-plane \
    cat /run/lrail-orchestrator-auth/secret \
    >"$CELL_TEMP_DIR/shared-secret"; then
    err "The Temporal control plane must be running before the build cell"
    return 1
  fi
  chmod 0600 "$CELL_TEMP_DIR/shared-secret"
  "$py" - "$CELL_TEMP_DIR/shared-secret" <<'PY'
from pathlib import Path
import sys

value = Path(sys.argv[1]).read_bytes().strip()
if not 32 <= len(value) <= 4096:
    raise SystemExit("orchestrator shared secret is invalid")
PY
  "${KUBECTL[@]}" create secret generic lrail-build-controller-auth \
    -n lrail-system \
    --from-file=shared-secret="$CELL_TEMP_DIR/shared-secret" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f - >/dev/null

  if ! "${KUBECTL[@]}" get secret lrail-build-controller-signing \
    -n lrail-system >/dev/null 2>&1; then
    "$openssl" genpkey -algorithm ED25519 \
      -out "$CELL_TEMP_DIR/signing-key.pem"
    "$openssl" pkey -in "$CELL_TEMP_DIR/signing-key.pem" \
      -check -noout >/dev/null
    chmod 0600 "$CELL_TEMP_DIR/signing-key.pem"
    "${KUBECTL[@]}" create secret generic lrail-build-controller-signing \
      -n lrail-system \
      --from-file=signing-key.pem="$CELL_TEMP_DIR/signing-key.pem"
  fi

  if ! "${KUBECTL[@]}" get secret lrail-artifact-credentials -n lrail-system >/dev/null 2>&1; then
    local minio_user minio_password registry_access registry_secret artifact_access artifact_secret
    minio_user="lrroot$($py -c 'import secrets; print(secrets.token_hex(6))')"
    minio_password="$($py -c 'import secrets; print(secrets.token_urlsafe(48))')"
    registry_access="lrregistry$($py -c 'import secrets; print(secrets.token_hex(6))')"
    registry_secret="$($py -c 'import secrets; print(secrets.token_urlsafe(48))')"
    artifact_access="lrartifact$($py -c 'import secrets; print(secrets.token_hex(6))')"
    artifact_secret="$($py -c 'import secrets; print(secrets.token_urlsafe(48))')"
    "${KUBECTL[@]}" create secret generic lrail-artifact-credentials \
      -n lrail-system \
      --from-literal=minio-root-user="$minio_user" \
      --from-literal=minio-root-password="$minio_password" \
      --from-literal=registry-access-key="$registry_access" \
      --from-literal=registry-secret-key="$registry_secret" \
      --from-literal=artifact-access-key="$artifact_access" \
      --from-literal=artifact-secret-key="$artifact_secret"
  fi

  if ! "${KUBECTL[@]}" get secret lrail-registry-auth-admin -n lrail-system >/dev/null 2>&1; then
    local admin_secret
    admin_secret="$($py -c 'import secrets; print(secrets.token_urlsafe(48))')"
    "${KUBECTL[@]}" create secret generic lrail-registry-auth-admin \
      -n lrail-system \
      --from-literal=admin-secret="$admin_secret"
  fi

  if ! "${KUBECTL[@]}" get secret lrail-registry-http -n lrail-system >/dev/null 2>&1; then
    local registry_http_secret
    registry_http_secret="$($py -c 'import secrets; print(secrets.token_urlsafe(48))')"
    "${KUBECTL[@]}" create secret generic lrail-registry-http \
      -n lrail-system \
      --from-literal=http-secret="$registry_http_secret"
  fi

  if ! "${KUBECTL[@]}" get secret lrail-artifact-gateway-admin -n lrail-system >/dev/null 2>&1; then
    local artifact_admin_secret
    artifact_admin_secret="$($py -c 'import secrets; print(secrets.token_urlsafe(48))')"
    "${KUBECTL[@]}" create secret generic lrail-artifact-gateway-admin \
      -n lrail-system \
      --from-literal=admin-secret="$artifact_admin_secret"
  fi

  if ! "${KUBECTL[@]}" get secret lrail-registry-auth-tls -n lrail-system >/dev/null 2>&1; then
    umask 077
    MSYS2_ARG_CONV_EXCL='/CN=' "$openssl" req -newkey rsa:3072 -nodes \
      -keyout "$CELL_TEMP_DIR/tls.key" \
      -x509 -sha256 -days 365 \
      -out "$CELL_TEMP_DIR/tls.crt" \
      -subj "/CN=lrail-alpha-registry-auth" \
      -addext "keyUsage=digitalSignature" \
      -addext "extendedKeyUsage=codeSigning"
    "${KUBECTL[@]}" create secret tls lrail-registry-auth-tls \
      -n lrail-system \
      --key="$CELL_TEMP_DIR/tls.key" \
      --cert="$CELL_TEMP_DIR/tls.crt"
  fi
  rm -rf "$CELL_TEMP_DIR"
  CELL_TEMP_DIR=""
}

apply_pinned_build_manifests() {
  if [[ ! "$WORKER_IMAGE" =~ ^docker\.io/library/lrail-build-worker@sha256:[0-9a-f]{64}$ ]]; then
    err "The immutable build-worker image was not resolved"
    return 1
  fi

  local py render_dir
  py="$(python_bin)"
  render_dir="$(mktemp -d)"
  CELL_TEMP_DIR="$render_dir"
  WORKER_IMAGE="$WORKER_IMAGE" \
    WORKER_IMAGE_PLACEHOLDER="$WORKER_IMAGE_PLACEHOLDER" \
    "$py" - "$APP_DIR/infrastructure/kubernetes/alpha" "$render_dir" <<'PY'
from pathlib import Path
import os
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
placeholder = os.environ["WORKER_IMAGE_PLACEHOLDER"]
worker = os.environ["WORKER_IMAGE"]
for name in ("build-controller.yaml", "build-sandbox-policy.yaml"):
    value = (source / name).read_text(encoding="utf-8")
    if placeholder not in value:
        raise SystemExit(f"worker image placeholder is missing from {name}")
    value = value.replace(placeholder, worker)
    if placeholder in value:
        raise SystemExit(f"worker image placeholder remained in {name}")
    (target / name).write_text(value, encoding="utf-8", newline="\n")
PY
  "${KUBECTL[@]}" apply -f "$render_dir/build-sandbox-policy.yaml"
  "${KUBECTL[@]}" apply -f "$render_dir/build-controller.yaml"
  rm -rf "$render_dir"
  CELL_TEMP_DIR=""
}

verify_admission_guard() {
  local probe output
  probe="$(mktemp)"
  CELL_TEMP_DIR="$probe"
  cat >"$probe" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: lrail-admission-readiness-probe
  namespace: lrail-builds
spec:
  runtimeClassName: gvisor
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: busybox:1.36
      securityContext:
        privileged: false
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        limits:
          cpu: 100m
          memory: 32Mi
          ephemeral-storage: 16Mi
YAML
  for _attempt in $(seq 1 60); do
    if output="$("${KUBECTL[@]}" apply --dry-run=server -f "$probe" 2>&1)"; then
      sleep 0.5
      continue
    fi
    if grep -q "lrail-build-pod-boundary" <<<"$output"; then
      rm -f "$probe"
      CELL_TEMP_DIR=""
      return 0
    fi
    sleep 0.5
  done
  rm -f "$probe"
  CELL_TEMP_DIR=""
  err "The fail-closed build admission policy did not become active"
  return 1
}

configure_cell() {
  local cell_ip realm
  cell_ip="$(minikube ip -p "$PROFILE")"
  realm="http://registry-auth.lrail-system.svc.cluster.local:8080/token"
  "${KUBECTL[@]}" create configmap alpha-cell-config \
    -n lrail-system \
    --from-literal=registry-endpoint="$cell_ip:30500" \
    --from-literal=registry-auth-realm="$realm" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

  local remote
  remote="sudo mkdir -p /etc/containerd/certs.d/$cell_ip:30500 && "
  remote+="printf '%s\\n' 'server = \"http://$cell_ip:30500\"' '[host.\"http://$cell_ip:30500\"]' '  capabilities = [\"pull\", \"resolve\", \"push\"]' '  skip_verify = true' | "
  remote+="sudo tee /etc/containerd/certs.d/$cell_ip:30500/hosts.toml >/dev/null && sudo systemctl restart containerd"
  minikube ssh -p "$PROFILE" -- "$remote"
}

apply_cell() {
  "${KUBECTL[@]}" apply -f "$APP_DIR/infrastructure/kubernetes/alpha/namespaces.yaml"
  ensure_secrets
  configure_cell
  "${KUBECTL[@]}" delete job artifact-bucket-init -n lrail-system --ignore-not-found >/dev/null
  "${KUBECTL[@]}" apply -k "$APP_DIR/infrastructure/kubernetes/alpha"
  apply_pinned_build_manifests
  verify_admission_guard
  "${KUBECTL[@]}" label namespace lrail-builds \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/enforce-version=latest \
    --overwrite >/dev/null
  "${KUBECTL[@]}" rollout restart deployment/registry -n lrail-system
  "${KUBECTL[@]}" rollout restart deployment/registry-auth -n lrail-system
  "${KUBECTL[@]}" rollout restart deployment/artifact-gateway -n lrail-system
  "${KUBECTL[@]}" rollout restart deployment/build-controller -n lrail-system
  "${KUBECTL[@]}" rollout status deployment/minio -n lrail-system --timeout=240s
  "${KUBECTL[@]}" wait --for=condition=Complete job/artifact-bucket-init -n lrail-system --timeout=240s
  "${KUBECTL[@]}" rollout status deployment/registry-auth -n lrail-system --timeout=240s
  "${KUBECTL[@]}" rollout status deployment/artifact-gateway -n lrail-system --timeout=240s
  "${KUBECTL[@]}" rollout status deployment/registry -n lrail-system --timeout=240s
  "${KUBECTL[@]}" rollout status deployment/build-controller -n lrail-system --timeout=360s
}

show_status() {
  "${KUBECTL[@]}" get nodes
  "${KUBECTL[@]}" get runtimeclass gvisor
  "${KUBECTL[@]}" get pods,services,persistentvolumeclaims -n lrail-system
  "${KUBECTL[@]}" get resourcequota,limitrange -n lrail-builds
  "${KUBECTL[@]}" get resourcequota,limitrange -n lrail-runtime
}

case "$ACTION" in
  start)
    run_cmd "Starting the disposable Phase 2 Kubernetes cell..." ensure_cluster
    run_cmd "Building alpha platform images..." build_platform_images
    run_cmd "Reconciling alpha artifact services and policies..." apply_cell
    printf '\n'
    show_status
    printf "${GRN}Phase 2 cell is ready.${NC}\n"
    ;;
  status)
    show_status
    ;;
  stop)
    run_cmd "Stopping the disposable Phase 2 cell..." minikube stop -p "$PROFILE"
    ;;
  delete)
    if [[ "$CONFIRM_DELETE" != "--yes" ]]; then
      usage
      exit 1
    fi
    run_cmd "Deleting the disposable Phase 2 cell..." minikube delete -p "$PROFILE"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
