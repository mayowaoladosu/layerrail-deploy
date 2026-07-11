# WP-009: Transactional outbox and idempotent consumers

- Phase: 1 - Behavior parity
- Status: Implemented
- Owner: `apps/control_plane`, `contracts/events`
- Dependencies: WP-005, WP-007, WP-008
- Requirements: FR-GIT-002, FR-DEP-001, FR-DEP-003, INV-005, INV-006, INV-007, INV-008, INV-011

## Objective

Persist desired-state changes and versioned events in one PostgreSQL transaction, deliver those events at least once without holding database transactions open across remote calls, and provide an idempotent consumer harness that produces one logical database side effect after crashes, retries and concurrent delivery.

## Canonical event envelope

`Events::Envelope` parses and builds the version 1 contract with exactly these fields: event ID, event type, occurrence time, organization/resource/correlation IDs, idempotency key, producer, schema version and bounded object data. It canonicalizes nested JSON before hashing and rejects unknown fields, invalid IDs/types/producers, unsupported values and oversized data.

`OutboxEvents::Publish` serializes one `(organization, producer, idempotency key)` with a PostgreSQL advisory lock. Identical calls replay the immutable event; changed resource, type, correlation or data conflicts. IDs are application-generated UUIDv7 values. Payload data and consumer results are redacted from default object inspection.

The versioned examples now include:

- `deployment.requested.v1`: provider-neutral durable workflow command;
- `deployment.transitioned.v1`: append-only status history projection;
- `alias.routing.requested.v1`: atomic desired routing command; and
- the existing `deployment.build.completed.v1` provider callback example.

Every example passes the shared JSON Schema 2020-12 contract.

## Transactional domain emission

Deployment creation writes the immutable Deployment, initial transition, `deployment.transitioned.v1` and `deployment.requested.v1` records in one transaction. Replaying creation repairs/replays the same request event rather than creating another logical command. Request data includes only IDs, source digest, expected version and trigger; encrypted configuration values and credentials never enter the event.

Every later Deployment transition appends its transition event inside the row-locked state transaction. Alias promotion and rollback append a version-specific `alias.routing.requested.v1` command in the same transaction as current/previous pointer and promoted/superseded state changes.

## Outbox delivery

`OutboxEvents::Dispatch` claims eligible rows using `FOR UPDATE SKIP LOCKED`, a UUID claim token and a bounded lease. The publisher call occurs after the claim transaction commits. A current claim may mark the event published, schedule deterministic exponential retry, or mark a rejected/exhausted event dead. Expired leases can be reclaimed. Published/dead rows are immutable and all rows are append-only.

Publisher adapters return `OutboxEvents::DeliveryResult`; arbitrary provider exceptions are converted to a generic safe retry without persistence of exception messages. Retry delays are 5, 10, 20 and 40 seconds, followed by a dead fifth attempt. WP-010 supplies the real local-provider adapter and process loop.

## Durable consumer receipt

`EventConsumers::Process` first commits an immutable `(consumer, event ID)` receipt, then locks it while applying database side effects and completing the receipt in a second transaction. A crash rolls back side effects but leaves a durable `processing` receipt for retry. Identical concurrent/repeated deliveries return the completed result; altered envelopes conflict.

The harness guarantees one logical transactional database side effect. Any future remote side effect must additionally use the event ID as the provider operation/idempotency key because transport remains at least once and unknown remote outcomes can be retried.

## Webhook-to-deployment flow

`GitWebhooks::Consume` row-locks a pending normalized inbox message. It resolves only an active repository connection within the message organization, then:

- maps a configured/default-branch push to its explicit or production environment;
- maps opened, reopened and synchronized pull requests to an explicit branch environment or staging preview;
- acknowledges non-configured branches and closed/non-deployable pull-request actions without scheduling work; and
- fails closed with a bounded safe error when the repository is disconnected.

Accepted messages create an immutable Deployment, configuration snapshot, initial transition and command events, then attach the Deployment and mark the webhook processed in one transaction. A narrow `AuthorizationContext.system` permits only Deployment/configuration creation in its selected organization; it does not grant membership, project creation or Alias promotion. Automated configuration snapshots retain no fabricated user attribution.

Webhook outcomes are append-only. Composite PostgreSQL foreign keys prevent a message from referencing another organization's Deployment. The provider request still returns immediately after verified inbox persistence; no build or remote operation runs in the request.

## Persistence and tenant scope

PostgreSQL enforces organization ownership, UUID foreign keys, normalized event/consumer/idempotency formats, JSON object shape, bounded safe errors, allowed status values, attempt counts and lifecycle-consistent leases/timestamps. `OutboxEvent`, `EventReceipt` and all event data have no database UUID defaults.

The migration is additive except for allowing system-created configuration snapshots to omit `created_by_id`. Existing user-created attribution remains intact. Before production automation data exists it can be rolled back; after null-attributed snapshots/events exist, use forward migrations rather than reverting the column contract.

## Acceptance evidence

- Domain state and outbox records roll back together.
- Concurrent identical publishes produce one event; altered reuse conflicts.
- Consumer receipts commit before side effects, survive simulated crashes and produce one database side effect under concurrent retry.
- Unknown publish outcomes retry the same event ID; the receiving harness deduplicates the side effect.
- Dispatcher claims serialize across workers, stale claims cannot finalize, retry backoff is bounded and the fifth failure becomes dead.
- Push and pull-request inbox consumption is replay-safe and concurrent consumption creates one Deployment/request event.
- Unconfigured branches/actions are durably acknowledged; disconnected repositories fail closed.
- Direct SQL rejects inconsistent delivery state, unknown receipt organizations and cross-organization webhook/Deployment outcomes.
- Event and receipt payloads are absent from default inspection; command events contain no plaintext configuration or credentials.
- Every versioned event example passes the canonical envelope schema.
- The complete control-plane CI passes with 193 examples, RuboCop, Zeitwerk, Bundler Audit, Importmap Audit and Brakeman.

## Deferred work

WP-010 implements the local provider in a separate process, consumes `deployment.requested.v1` and `alias.routing.requested.v1`, supplies provider callbacks with expected versions/operation IDs, and drives the dispatcher loop. WP-012 presents event-backed live deployment status and logs. Real build/runtime work, Git credential issuance, customer code and infrastructure privilege remain outside Rails.

## Rollback

Before automated snapshots or event history exist, roll back the WP-009 migration and remove event/consumer integration. Once events or system-attributed snapshots exist, preserve append-only history and use forward expand/migrate/contract changes. Never delete published commands or completed receipts to retry an operation; retry with the same event ID and idempotency key.
