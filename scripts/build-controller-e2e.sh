#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

init_script_logging "build-controller-e2e"

PROFILE="${LRAIL_ALPHA_PROFILE:-lrail-alpha}"
export DEPLOYMENT_ORCHESTRATOR=temporal
set_compose_base
COMPOSE_PHASE2=("${COMPOSE_BASE[@]}" --profile phase2)

cleanup() {
  local code=$?
  trap - EXIT
  if ((code != 0)); then
    err "Command failed: ${BASH_COMMAND}"
    [[ -f "$SCRIPT_ERR_LOG" ]] && cat "$SCRIPT_ERR_LOG" >&2
  fi
  exit "$code"
}
trap cleanup EXIT

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

# Start the authoritative control plane and durable orchestrator.
run_cmd "Starting the Temporal control plane..." \
  "${COMPOSE_PHASE2[@]}" up -d --build \
  control-plane orchestrator-auth-init temporal orchestrator-worker orchestrator-bridge
run_cmd "Pausing the legacy deployment consumer..." \
  "${COMPOSE_BASE[@]}" stop local-provider

# Reconcile the complete cell.
run_cmd "Reconciling the isolated build cell..." \
  bash "$SCRIPT_DIR/phase2-cell.sh" start

# Execute controller and sandbox acceptance probes.
py="$(python_bin)"
run_cmd "Running isolated build-controller E2E probes..." \
  "$py" "$APP_DIR/services/build_controller/tests/build_controller_e2e.py" \
  --profile "$PROFILE"

# Re-run shared artifact tenant and persistence probes.
run_cmd "Running cross-tenant artifact probes..." \
  bash "$SCRIPT_DIR/phase2-artifacts-e2e.sh"

printf "${GRN}Build controller E2E passed.${NC}\n"
