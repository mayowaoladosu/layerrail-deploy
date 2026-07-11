# WP-008: Deployment, Build, Revision and Alias state

- Phase: 1 - Behavior parity
- Status: Implemented
- Owner: `apps/control_plane`
- Dependencies: WP-004, WP-005
- Requirements: FR-BLD-003, FR-DEP-001, FR-DEP-002, FR-DEP-003, INV-002, INV-003, INV-004, INV-005

## Objective

Persist immutable deployment inputs and artifacts, explicit retryable state transitions, readiness-gated revisions, and atomic current/previous alias pointers without executing customer code or performing infrastructure operations in Rails.

## Deployment state

Deployments progress through explicit created, queued, preparing, building, scanning, deploying, verifying, ready, promoted and superseded states. Cancellation and failure use separate terminal states and conclusions. Retryable build failure returns a deployment from building to preparing for a new numbered attempt.

Every transition is append-only and records sequence, actor or system cause, timestamp, structured safe error and the deployment correlation ID. Row locks and optimistic `lock_version` checks reject stale transitions. Superseded deployments remain eligible for promotion because rollback reuses an existing healthy Revision.

## Build lifecycle

A Build is an organization-owned, deployment-scoped attempt. Start commands are idempotent per deployment and serialize on the Deployment row. Attempts are monotonically numbered and move the deployment into building.

Completion writes one content-addressed OCI digest and bounded evidence object, creates one candidate Revision, and moves the deployment into scanning in the same transaction. Placement is supplied as provider-neutral region and cell data; core services contain no local-controller constants. Identical completion replays return the existing result, while changed digest, evidence or placement conflicts.

Retryable failure preserves structured evidence and permits a later attempt. Non-retryable failure terminates the deployment. Cancellation completion is accepted only after the deployment enters canceling and is replay-safe. Succeeded, failed and canceled Build outputs are immutable.

## Revision readiness

A Revision binds one Build artifact digest, frozen configuration snapshot, runtime policy, service, environment, region and cell. Composite PostgreSQL foreign keys ensure all referenced resources share the same organization, project, service, environment, deployment and artifact digest.

Only a candidate with passing scan evidence and a passing readiness result can become ready. The readiness transition and deployment progression through deploying, verifying and ready are transactional. Readiness evidence becomes immutable after success, and changed callback replays conflict.

## Alias promotion and rollback

An Alias has immutable organization/project/service/environment identity and mutable current/previous Revision pointers. Only owner or admin contexts may promote, and only a ready Revision from the selected organization and matching resources is accepted.

A transaction-scoped advisory lock serializes each service/type/name key. Promotion updates current/previous pointers and promoted/superseded deployment states atomically. Competing promotions preserve a consistent two-Revision history. Rollback requires the expected Alias version, rejects stale commands, swaps back to the previous ready Revision and creates no Build.

## Persistence and tenant scope

Build, Revision and Alias IDs are application-generated UUIDv7 values with no database defaults. Check constraints enforce allowed states, normalized keys and placement, terminal timestamp/digest consistency, JSON object shape, distinct alias pointers and candidate/ready timestamp consistency.

Composite foreign keys reject cross-organization Builds, cross-resource Revisions and cross-resource Alias pointers even when model validation is bypassed. The migration backfills transition correlation IDs, was replayed from an empty database, rolled back and reapplied in development and test, and produces a byte-stable schema dump.

## Acceptance evidence

- Immutable deployment source, build settings, runtime policy and configuration snapshots are covered by model and service tests.
- Build completion, failure, retry and cancellation are idempotent and persist one logical outcome.
- Only scan-passed, readiness-passed Revisions can become ready or receive an Alias.
- Promotion and rollback preserve atomic current/previous pointers and rollback creates no Build.
- Same-key Build starts and competing Alias promotions are tested with concurrent PostgreSQL connections.
- Direct SQL cross-tenant, cross-resource, inconsistent lifecycle and mismatched artifact writes fail database constraints.
- Transition correlation, append-only history, UUIDv7 generation, stale versions and immutable terminal evidence are tested.
- The complete control-plane CI passes with 165 examples, RuboCop, Zeitwerk, Bundler Audit, Importmap Audit and Brakeman.

## Deferred work

WP-009 attaches transactional outbox events and idempotent consumers to these state changes. WP-010 implements the local provider and actual sandbox/runtime routing behind provider contracts. WP-012 exposes deployment state, logs and promotion controls in the Rails UI. Artifact retention later moves unreferenced ready Revisions to retired; previous healthy Revisions remain available for rollback until then.

## Rollback

Before production artifacts exist, roll back the Build/Revision/Alias migration and remove the related services, policies and associations. Once deployment history exists, preserve immutable records and use forward expand/migrate/contract changes rather than deleting Build, Revision, Alias or transition history.
