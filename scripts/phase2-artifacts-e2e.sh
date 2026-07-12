#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

init_script_logging "phase2-artifacts-e2e"

PROFILE="${LRAIL_ALPHA_PROFILE:-lrail-alpha}"

# Resolve Python
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python)"
else
  err "Python 3 is required"
  exit 1
fi

# Validate cell
if [[ "$(minikube status -p "$PROFILE" --format='{{.Host}}' 2>/dev/null || true)" != "Running" ]]; then
  err "Phase 2 cell is not running; run scripts/phase2-cell.sh start first"
  exit 1
fi

# Prove artifact isolation
run_cmd "Proving scoped OCI publication and persistence..." \
  "$PYTHON_BIN" "$APP_DIR/services/registry_auth/tests/registry_e2e.py" --profile "$PROFILE"

printf "${GRN}Phase 2 artifact E2E passed.${NC}\n"
