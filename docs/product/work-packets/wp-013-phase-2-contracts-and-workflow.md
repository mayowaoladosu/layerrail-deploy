# WP-013: Phase 2 contracts and durable workflow

- Phase: 2 - Isolated alpha
- Status: Approved
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

## Rollback

Stop bridge/worker and preserve Rails events plus Temporal history. New work may be paused or forward-migrated; never delete outbox events to retry.
