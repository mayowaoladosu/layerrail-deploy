#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

init_script_logging "temporal-e2e"

export DEPLOYMENT_ORCHESTRATOR=temporal
set_compose_base
COMPOSE_PHASE2=("${COMPOSE_BASE[@]}" --profile phase2)
RUN_ID="$("$(command -v python3 || command -v python)" -c 'import secrets; print(secrets.token_hex(6))')"
STATE_PATH="tmp/orchestrator-e2e-${RUN_ID}.json"
FIXTURE_PATH=""

cleanup() {
  rm -f "${FIXTURE_PATH:-}" 2>/dev/null || true
}
trap cleanup EXIT

rails_action() {
  "${COMPOSE_PHASE2[@]}" exec -T \
    -e ORCHESTRATOR_E2E_RUN_ID="$RUN_ID" \
    -e ORCHESTRATOR_E2E_STATE_PATH="$STATE_PATH" \
    control-plane \
    bundle exec rails runner script/orchestrator_e2e.rb "$1"
}

capture_fixture() {
  "${COMPOSE_PHASE2[@]}" exec -T control-plane cat "$STATE_PATH" >"$FIXTURE_PATH"
}

abandon_delivery() {
  "${COMPOSE_PHASE2[@]}" run --rm --no-deps orchestrator-bridge \
    bundle exec ruby exe/abandon_delivery
}

drain_workflow_commands() {
  "${COMPOSE_PHASE2[@]}" run --rm --no-deps orchestrator-bridge \
    bundle exec ruby exe/drain
}

state_value() {
  local key="$1"
  "$(command -v python3 || command -v python)" -c \
    'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])' \
    "$FIXTURE_PATH" "$key"
}

# Start durable dependencies
run_cmd "Starting PostgreSQL-backed Temporal..." \
  "${COMPOSE_PHASE2[@]}" up -d --build \
  control-plane orchestrator-auth-init temporal orchestrator-worker orchestrator-bridge
run_cmd "Pausing the Phase 1 command consumer..." \
  "${COMPOSE_BASE[@]}" stop local-provider
run_cmd "Stopping the bridge for duplicate-delivery injection..." \
  "${COMPOSE_PHASE2[@]}" stop orchestrator-bridge
run_cmd "Recovering interrupted E2E command leases..." rails_action recover-prior-leases
run_cmd "Draining prior workflow commands..." drain_workflow_commands

# Start once without finalizing
run_cmd "Creating a fresh workflow-backed deployment..." rails_action create
run_cmd "Starting then abandoning one claimed delivery..." abandon_delivery
FIXTURE_PATH="$(mktemp)"
run_cmd "Capturing workflow fixture identifiers..." capture_fixture
DEPLOYMENT_ID="$(state_value deployment_id)"

# Redeliver the same durable event
run_cmd "Expiring the abandoned command lease..." rails_action expire-request-lease
run_cmd "Restarting the normal workflow bridge..." \
  "${COMPOSE_PHASE2[@]}" start orchestrator-bridge
run_cmd "Proving one deterministic workflow execution..." \
  "${COMPOSE_PHASE2[@]}" run --rm --no-deps orchestrator-worker \
  bundle exec ruby exe/inspect_workflow "$DEPLOYMENT_ID" state

# Queue signals while no worker can execute them
run_cmd "Stopping the Temporal worker mid-workflow..." \
  "${COMPOSE_PHASE2[@]}" stop orchestrator-worker
run_cmd "Publishing the versioned build result..." rails_action publish-build
run_cmd "Publishing a stale readiness callback..." rails_action publish-stale-release
run_cmd "Publishing the current readiness callback..." rails_action publish-release
run_cmd "Restarting the Temporal worker..." \
  "${COMPOSE_PHASE2[@]}" start orchestrator-worker
run_cmd "Waiting for replayed workflow completion..." \
  "${COMPOSE_PHASE2[@]}" run --rm --no-deps orchestrator-worker \
  bundle exec ruby exe/inspect_workflow "$DEPLOYMENT_ID" result ready_observed
run_cmd "Verifying Rails remained authoritative..." rails_action verify-authority

# Prove history survives the workflow server process
run_cmd "Restarting the Temporal server..." \
  "${COMPOSE_PHASE2[@]}" restart temporal
run_cmd "Waiting for Temporal health after restart..." \
  "${COMPOSE_PHASE2[@]}" up -d --wait temporal
run_cmd "Re-reading persisted workflow history..." \
  "${COMPOSE_PHASE2[@]}" run --rm --no-deps orchestrator-worker \
  bundle exec ruby exe/inspect_workflow "$DEPLOYMENT_ID" result ready_observed

# Prove cancellation is an observation, not a Rails state write
RUN_ID="${RUN_ID}c"
STATE_PATH="tmp/orchestrator-e2e-${RUN_ID}.json"
cleanup
FIXTURE_PATH="$(mktemp)"
run_cmd "Creating a cancellation workflow..." rails_action create
run_cmd "Publishing a cancellation signal..." rails_action publish-cancellation
run_cmd "Capturing cancellation fixture identifiers..." capture_fixture
CANCELED_DEPLOYMENT_ID="$(state_value deployment_id)"
run_cmd "Waiting for cancellation observation..." \
  "${COMPOSE_PHASE2[@]}" run --rm --no-deps orchestrator-worker \
  bundle exec ruby exe/inspect_workflow "$CANCELED_DEPLOYMENT_ID" result canceled_observed
run_cmd "Verifying cancellation left Rails authoritative..." \
  rails_action verify-cancellation-authority

printf "${GRN}Temporal durability E2E passed for deployment %s.${NC}\n" "$DEPLOYMENT_ID"
