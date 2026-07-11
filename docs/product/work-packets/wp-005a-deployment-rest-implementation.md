# WP-005A: Deployment REST implementation

- Phase: 1 - Behavior parity
- Status: Implemented
- Owner: `apps/control_plane`, `contracts/openapi`
- Dependencies: WP-003, WP-005, WP-008, WP-009
- Requirements: FR-API-001, FR-DEP-001, FR-DEP-002, FR-DEP-003, INV-002, INV-004, INV-005, INV-007, INV-011

## Objective

Implement the versioned Deployment, cancellation, promotion and rollback operations already published in WP-005, using the immutable WP-008 domain and WP-009 transactional command events. This is a contract-implementation slice; the specification's WP-010 remains the separate local-provider process.

## Endpoint surface

The Rails control plane now serves:

- `POST /v1/services/:service_id/deployments`;
- `GET /v1/deployments/:deployment_id`;
- `POST /v1/deployments/:deployment_id/cancel`;
- `POST /v1/environments/:environment_id/promotions`; and
- `POST /v1/environments/:environment_id/rollbacks`.

Long-running mutations return HTTP 202. Deployment creation returns the accepted Deployment. Cancellation returns the `deployment.transitioned.v1` outbox event as an Operation. Promotion and rollback return their `alias.routing.requested.v1` outbox event as an Operation. Operation status reflects the durable event's pending, delivering, published or dead state.

Deployment logs remain deferred to WP-012 because their contract requires the local provider and log source.

## Organization selection and authorization

Authentication still enters through the existing request environment seam pending the dedicated authentication slice. The base API controller authenticates first. Nested resource controllers then derive the selected organization from the opaque service, Deployment or environment identifier, verify membership, and re-query the resource inside that organization.

Cross-organization and unknown nested identifiers both fail closed with HTTP 404. Owners/admins can create/cancel/promote/rollback. Members can read Deployments but cannot mutate them. Domain services authorize before revealing readiness or Alias history; a member cannot infer whether a Revision is ready.

## Idempotency and concurrency

Every mutation runs through `Api::Idempotency::Execute` with operation-specific canonical payloads. The first transaction includes domain state, transitions, command events and the stored response. Identical retries return the original body and `Idempotency-Replayed: true`; changed payload reuse conflicts. A creation retry remains stable after workflow state has advanced.

Cancellation uses the current Deployment lock version and transitions only a non-terminal state to canceling. Promotion uses Alias advisory/row locking and only accepts a ready Revision in the path environment. Rollback requires the caller to identify the Alias's exact current previous ready Revision and supplies the expected Alias lock version. Rollback creates no Build.

## Representations and validation

Deployment responses include opaque IDs, organization/service ownership, current status, immutable source, nullable preview URL and timestamps. Operation responses include event ID, organization/resource/correlation IDs, delivery status and creation time. Every success response passes the named OpenAPI schema.

The OpenAPI contract now distinguishes an immutable `DeploymentSourceSnapshot` from general Service source configuration:

- Git deployments require repository ID and a 40-64 character commit SHA.
- OCI deployments require a SHA-256 digest.
- Relative root directories are bounded and reject absolute, empty, dot and parent traversal segments.

Missing request fields and invalid source/reason values return schema-valid 422 errors. Missing/invalid/reused idempotency keys retain the stable 400/409 codes. Invalid/stale state operations use stable 409 codes without provider details.

## Acceptance evidence

- Create defaults to production or accepts only an environment in the Service project.
- Create/show responses pass the Deployment schema; all asynchronous responses pass Operation.
- Create replays after workflow progress without changing the original command.
- Cancel replays one operation, rejects changed key reuse, validates reason bounds and rejects terminal state.
- Promotion accepts only ready same-environment Revisions and authorizes before readiness disclosure.
- Rollback requires the explicit previous Revision, swaps current/previous pointers and creates no Build.
- Unauthenticated, member, cross-tenant and cross-project cases fail closed without consuming unauthorized state.
- The OpenAPI document and all versioned event examples remain machine-valid.
- The complete control-plane suite passes with 204 examples; RuboCop is clean.

## Deferred work

The dedicated authentication slice replaces the request-environment principal seam with real session/token authentication. WP-010 consumes the returned durable Operations through the local-provider process. WP-012 implements logs and the refresh-safe Deployment UI. Remaining organization/project/service/domain/scale contract operations are outside this focused Deployment slice.

## Rollback

The slice adds no database migration. Before clients depend on it, remove the routes/controllers and revert additive source contract fields. Once a v1 client consumes these operations, retain their paths and response shapes; make only additive compatible changes or publish a new API version.
