# WP-013: Phase 2 contracts and durable workflow

- Phase: 2 - Isolated alpha
- Status: Complete
- Owner: `apps/control_plane`, `services/orchestrator`, `contracts`
- Dependencies: WP-009, WP-012, ADR-009
- Requirements: GOAL-001, GOAL-002, GOAL-007, INV-002, INV-005, INV-006, INV-008, INV-010, INV-011

## Objective

Route each accepted Git Deployment into one deterministic Temporal workflow without giving the workflow database access, Active Record payloads, customer code or plaintext credentials.

## Scope

- Version signed internal DTOs for workflow claim/start, build preparation/completion/failure, runtime/static reconciliation, readiness and promotion.
- Add a dedicated Ruby Temporal worker and signed Rails workflow bridge.
- Use deterministic workflow/activity IDs and expected versions for duplicate, crash and stale-callback safety.
- Keep Rails as the only writer of Deployment, Build, Revision and Alias state.
- Support cancellation signals and bounded safe failures.

## Acceptance

- Duplicate outbox delivery starts one workflow.
- Worker/process restart resumes from persisted Temporal and Rails state.
- Workflow payload inspection contains only bounded IDs/enums/digests, never secrets or raw URLs.
- Unknown activity outcomes safely retry the same operation ID.
- Stale callbacks are acknowledged without regressing state.
- Workflow success alone cannot mark a Revision ready.

## Evidence

- `services/orchestrator` pins the official `temporalio` Ruby SDK 1.5.0 and runs bridge and worker as separate non-root processes without Rails imports or database configuration.
- `contracts/orchestrator/v1/workflow-message.schema.json` strictly allowlists versioned primitive workflow inputs, operations, results, build/release signals and cancellation messages under 64 KiB.
- The signed Rails bridge leases/finalizes append-only outbox events and exposes only a read-only expected-version observation; Temporal never writes product state.
- Deterministic `deployment/<deployment-id>` workflow IDs use `USE_EXISTING`, and activity IDs bind the immutable operation ID for unknown-outcome retry safety.
- Seven standalone orchestrator examples and Rails request/contract specs cover payload reduction, invalid data, deterministic duplicate starts, HMAC transport, stale reads and operation-ID reuse.
- `scripts/temporal-e2e.sh` proves real duplicate outbox redelivery creates one execution, worker restart replays persisted state, a stale readiness callback is ignored, no credential-bearing source reaches history, Rails remains `created` with zero Revisions after workflow success, and history survives a Temporal process restart on PostgreSQL.
- `docs/runbooks/temporal-alpha.md` documents authority, inspection, backup/restore, replay-safe upgrades, failure recovery and rollback.

## Rollback

Stop bridge/worker and preserve Rails events plus Temporal history. New work may be paused or forward-migrated; never delete outbox events to retry.
