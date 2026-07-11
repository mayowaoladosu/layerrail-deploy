# WP-004: Project, Service and Environment domain

- Phase: 0 - Foundation
- Status: Implemented
- Owner: `apps/control_plane`
- Dependencies: WP-003, WP-005, ADR-003, ADR-004
- Requirements: GOAL-005, INV-001, INV-005, INV-007, FR-ENV-001

## Objective

Create organization-owned projects, deployable services and project-scoped environments with database-backed invariants, fail-closed authorization and an idempotent v1 project mutation.

## Domain invariants

- A Project belongs to exactly one organization and has a case-insensitively unique name and unique slug within that organization.
- Project creation atomically creates canonical production and staging environments.
- An Environment belongs to one project. Its slug and non-null branch mapping are unique within that project.
- Each project has at most one production and one staging environment. Additional environments are custom.
- Environment kind is immutable. Canonical production and staging environments cannot be independently deletion-requested.
- A Service belongs to one project and derives its organization through that project.
- A Service has one workload type, one Git or OCI source reference, one bounded runtime policy and one lifecycle state.
- Service names are case-insensitively unique within their project.
- Runtime policy accepts only readiness path, liveness path and bounded graceful-shutdown settings; arbitrary provider or privilege input is rejected.
- All new primary keys are application-generated UUIDv7 values with no database fallback.

## Authorization boundary

Project, Service and Environment policies verify the selected organization through `AuthorizationContext`. Owners can request deletion, admins can create/update, and members are read-only. Policy scopes join through the project where necessary and return no foreign-organization records.

The API organization selector returns the same not-found response for inaccessible and nonexistent organizations so resource existence is not disclosed across tenants.

## Idempotent API mutation

`POST /v1/projects` implements the published OpenAPI request and response contract. It requires an organization-scoped `Idempotency-Key`, canonicalizes the request payload, stores a SHA-256 fingerprint and safe response body, and serializes concurrent execution with a PostgreSQL transaction-scoped advisory lock.

Replaying the same request returns the original resource with `Idempotency-Replayed: true`. Reusing a key for different input returns a conflict. Validation, authorization or unknown execution failures roll back both domain state and the idempotency record, so safe retry remains possible.

Authentication is deliberately an upstream boundary. Until an approved authentication work packet sets `lrail.authenticated_principal`, the API fails closed with HTTP 401.

## Acceptance evidence

- Project creation, canonical environments, normalization and rollback are covered.
- Project/service/environment uniqueness is enforced in Rails and PostgreSQL.
- Workload/source values and JSON runtime policy are constrained.
- Owner/admin/member behavior and cross-organization scopes are covered.
- Project API success and error payloads validate against OpenAPI components.
- Missing, invalid, replayed and conflicting idempotency keys are covered.
- A failed mutation does not consume its key or leave partial project/environment state.
- Two concurrent executions use separate database connections and produce one logical side effect.
- All three migrations were applied, rolled back and rebuilt from an empty test database with byte-stable `schema.rb` output.

## Deferred work

Repository connections, configuration snapshots, asynchronous deletion orchestration, service/environment REST endpoints, deployments and audit/outbox events belong to their approved work packets. Production/staging branch defaults remain unset until Git provider behavior is defined.

## Rollback

Before production data exists, roll back the idempotency, service and project/environment migrations in reverse order, remove their models/services/policies/controllers and restore the previous schema and OpenAPI file. Once customer data exists, use expand/migrate/contract changes; do not destructively roll these resources back.