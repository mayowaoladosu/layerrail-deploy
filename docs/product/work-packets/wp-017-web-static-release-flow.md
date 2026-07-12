# WP-017: Web and static release flow

- Phase: 2 - Isolated alpha
- Status: Approved
- Owner: `apps/control_plane`, `services/orchestrator`, `services/runtime_controller`, `services/artifact_gateway`
- Dependencies: WP-013 through WP-016
- Requirements: GOAL-001, GOAL-003, GOAL-005, FR-BLD-001, FR-BLD-002, FR-DEP-001, FR-DEP-002, FR-DEP-003, INV-002, INV-003, INV-004, INV-005, INV-008

## Objective

Complete push-to-deploy for supported web and static samples, including automatic readiness-gated environment promotion, immutable URLs, logs and no-rebuild rollback.

## Scope

- Dockerfile web, detected Node web and static artifact plans.
- Runtime configuration injected after build, never baked into artifacts.
- Shared static gateway serves immutable prefixes from object storage with safe path and cache policy.
- Workflow marks ready only after runtime/static verification and promotes the intended environment Alias.
- Existing Deployment UI displays real build/runtime logs, artifact evidence and route state.

## Acceptance

- Git push/fake-provider event reaches Ready without operator intervention.
- Dockerfile and detected Node samples serve health-gated immutable/environment URLs.
- Static sample has no per-revision customer Pod, supports deep paths safely and uses immutable cache headers for digested assets.
- A failed build/readiness/static verification produces structured actionable failure with no traffic.
- Second release promotes without downtime; rollback restores the first artifact without a Build.
- Refreshing/closing UI does not lose progress or logs.

## Rollback

Pause new workflows, preserve current routes/artifacts and move aliases only to existing healthy Revisions. Remove static prefixes after retention reconciliation.
