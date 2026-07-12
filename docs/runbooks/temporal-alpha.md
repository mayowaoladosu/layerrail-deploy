# Alpha Temporal orchestration

- Owner: Platform engineering
- Scope: Phase 2 local/CI orchestration only
- Components: Rails workflow bridge, orchestrator bridge, orchestrator worker, Temporal 1.28.1, PostgreSQL 16
- Workflow retention: 30 days

## Authority and data policy

Rails is the only writer of Deployment, Build, Revision and Alias state. Temporal records orchestration intent and bounded observations; workflow completion is never readiness evidence. The worker has no Rails database configuration. Workflow payloads use `contracts/orchestrator/v1/workflow-message.schema.json` and contain only versioned IDs, enums, expected versions and SHA-256 digests. Do not add repository URLs, provider responses, environment values, customer labels, credentials or logs.

Workflow IDs are `deployment/<deployment-id>`. Activity IDs include the immutable operation ID. A repeated start uses the existing running execution, and every receiving adapter must deduplicate the same operation ID because an RPC outcome can be unknown.

## Health and inspection

Start the profile with `DEPLOYMENT_ORCHESTRATOR=temporal scripts/compose.sh --profile phase2 up -d`. The control plane, Temporal, worker and bridge must remain healthy/running. Temporal is private to the internal Compose network and persists in the dedicated `lrail_temporal` and `lrail_temporal_visibility` PostgreSQL databases.

Run `scripts/temporal-e2e.sh` after upgrades or recovery. It deliberately abandons one delivery after Temporal accepts it, redelivers the same Rails event, stops the worker while signals accumulate, injects a stale callback, restarts the worker and Temporal server, inspects history for forbidden payloads and proves Rails state did not advance.

Use the pinned Temporal CLI inside the Temporal container for administrative inspection. Never print full payloads in normal logs; use workflow ID, run ID, status and history length. Exported history is security-sensitive operational evidence even though the allowlist excludes secrets.

## Failure recovery

- Bridge unavailable: leave Rails outbox events pending/delivering. Expired leases are reclaimed; never delete an event to retry.
- Temporal unavailable or RPC outcome unknown: finalize the Rails claim as retryable. Reuse the same workflow/activity/operation ID.
- Worker unavailable: keep Temporal running. Signals and workflow history persist and replay when a compatible worker returns.
- Rails unavailable: activities retry bounded calls with the same operation ID. Workflow history cannot substitute for Rails state.
- Stale callback: acknowledge it as ignored and preserve the higher Rails/Temporal expected version.
- Invalid or conflicting DTO: fail closed with a bounded code; never place the rejected body in logs.

Before a worker deployment, replay retained histories against the new workflow implementation. Do not put incompatible workflow code on the existing task queue; use Temporal patching or a new versioned task queue.

## Backup and restore

Treat Temporal as a database. Back up both Temporal PostgreSQL databases with the same consistency and encryption controls as Rails, but never merge their schemas. Restore both databases to an isolated PostgreSQL instance, start the same pinned Temporal server, verify namespace `lrail-alpha` and 30-day retention, start the compatible worker, and run the durability E2E. Keep Rails outbox/domain backups from the same recovery point so command delivery can reconcile safely.

## Rollback

Stop the bridge first to pause new workflow starts/signals, then stop workers. Preserve Rails events and both Temporal databases. Existing histories may be resumed by the same worker, patched forward, or served by a replacement on a compatible task queue. Do not mark revisions ready from workflow results and do not delete histories or outbox events to force replay.
