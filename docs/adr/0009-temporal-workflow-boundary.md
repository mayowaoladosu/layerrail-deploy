# ADR-0009: Temporal workflow boundary

- Status: Accepted
- Date: 2026-07-12
- Decision owners: Platform engineering
- Requirements: GOAL-002, GOAL-007, INV-005, INV-006, INV-008, INV-010, INV-011
- Applies to: Phase 2 isolated alpha

## Context

A Phase 2 deployment spans source resolution, sandboxed build, artifact publication, runtime/static reconciliation, readiness and callback processing. The locked architecture selects the official Temporal Ruby SDK in dedicated worker processes, but requires explicit approval of deployment and payload policy.

Rails remains authoritative for desired state and customer-visible status. Workflow replay must not deserialize Active Record objects, execute repository code or hide infrastructure truth in Temporal alone.

## Decision

Use `temporalio` Ruby SDK 1.5.0 in a standalone `services/orchestrator` process. Workflows and activities exchange versioned primitive DTOs containing opaque IDs, expected versions, operation IDs and contract versions. They never receive Active Record models, plaintext secrets, raw provider objects or credential-bearing URLs.

The workflow ID is deterministic: `deployment/<deployment-id>`. Starting the same logical workflow is idempotent. Temporal retries activities; receiving infrastructure services still deduplicate by operation/event ID because remote outcomes can be unknown.

Rails transactionally persists domain state and the `deployment.requested.v1` outbox event. A signed workflow bridge claims that event and starts or signals the deterministic Temporal workflow. Activities call signed internal Rails/build/runtime contracts; they do not connect to the Rails database. Provider callbacks remain expected-version/operation-bound and Rails alone advances Deployment, Build, Revision and Alias state.

Local/CI uses a pinned self-hosted Temporal service on an internal network. The GKE target uses the official Temporal Helm chart with a dedicated managed PostgreSQL database, private networking, TLS and workload identity. Temporal is treated like a database and is never publicly exposed.

Payloads are JSON with a strict allowlist and 64 KiB limit. Search attributes contain only bounded stable identifiers; secrets and arbitrary user strings are prohibited. Workflow history retention is 30 days for alpha. Build/runtime logs remain in the log plane, not workflow history.

## Consequences

Refresh, process restarts and duplicate outbox delivery resume one durable workflow. Temporal success is not treated as runtime readiness; signed callbacks and Rails state remain the acceptance source.

The orchestrator adds operational weight, but it establishes the locked long-running workflow boundary before cloud rollout. Local development may use Temporal's development server; production-shaped manifests use server services and PostgreSQL.

## Rollback

Stop the workflow bridge and worker, then route new Phase 2 commands to a forward-compatible replacement. Existing Rails outbox/domain records remain authoritative. Preserve workflow histories until their retention window expires; never delete Rails events to force a retry.
