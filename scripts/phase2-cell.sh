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
  minikube image load -p "$PROFILE" lrail-registry-auth:dev
}

ensure_secrets() {
  local py openssl
  py="$(python_bin)"
  openssl="$(openssl_bin)"
  CELL_TEMP_DIR="$(mktemp -d)"
  chmod 0700 "$CELL_TEMP_DIR"

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

configure_cell() {
  local cell_ip realm
  cell_ip="$(minikube ip -p "$PROFILE")"
  realm="http://$cell_ip:30501/token"
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
  "${KUBECTL[@]}" rollout restart deployment/registry-auth -n lrail-system
  "${KUBECTL[@]}" rollout status deployment/minio -n lrail-system --timeout=240s
  "${KUBECTL[@]}" wait --for=condition=Complete job/artifact-bucket-init -n lrail-system --timeout=240s
  "${KUBECTL[@]}" rollout status deployment/registry-auth -n lrail-system --timeout=240s
  "${KUBECTL[@]}" rollout status deployment/registry -n lrail-system --timeout=240s
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
