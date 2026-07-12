# WP-010: Local development provider

- Phase: 1 - Behavior parity
- Status: Implemented
- Owner: `apps/control_plane`, `apps/local_provider`, `compose`, `contracts/events`
- Dependencies: WP-008, WP-009
- Requirements: FR-BLD-003, FR-DEP-001, FR-DEP-002, FR-DEP-003, INV-003, INV-004, INV-005, INV-006, INV-007, INV-008, INV-010, INV-011

## Objective

Implement a local development provider behind versioned control-plane contracts so the repository-owned sample application can deploy, become ready, receive immutable and environment routes, promote, roll back without a rebuild, and cancel without infrastructure-controller implementation leaking into Rails.

## Component boundary

Rails remains authoritative for desired state, organization ownership, immutable artifacts, Deployment transitions, readiness, and Alias pointers. It publishes commands transactionally and exposes HMAC-authenticated internal claim, finalize, and callback endpoints. Rails does not import provider code, access Docker, execute a workload, or read the provider's SQLite state.

The separate Python 3.13 provider polls only `deployment.requested.v1`, `deployment.cancellation.requested.v1`, and `alias.routing.requested.v1`. The process uses a locked `uv` dependency graph and communicates with Rails only over canonical signed JSON. It has no PostgreSQL credentials.

## Durable command transport

Provider claims use `FOR UPDATE SKIP LOCKED`, a request ID, claim token, attempt count, and bounded lease. Repeating the same request ID returns the active claim. Expired claims can be reclaimed, while stale finalization tokens fail closed. Published and dead outcomes are terminal and idempotent; retryable outcomes use bounded exponential backoff.

Every provider request signs timestamp, request ID, method, path, and raw body with HMAC-SHA256. Rails accepts only bounded clock skew, canonical request identifiers, and constant-time signature comparison. Callback envelopes retain organization, resource, correlation, operation, expected-version, and artifact bindings. Durable `EventReceipt` rows deduplicate callbacks and reject changed replays.

The provider records command payload digests and completed results in SQLite before finalization. A replay returns the same callback identity. Revision/container and Alias mappings survive process restarts, so an unknown callback/finalization outcome can be retried safely.

## Runtime and routing behavior

WP-010 deliberately accepts only the repository-owned `lrail-local-sample:dev` web image with the exact locally built SHA-256 image ID. Git sources, arbitrary OCI references, configuration injection, and non-web workloads fail safely without runtime execution.

A successful deployment creates one hardened runtime on `devpush_local_runtime`, waits for HTTP readiness, and sends `deployment.runtime.ready.v1`. Rails creates the Build and ready Revision from the callback's pinned digest and readiness evidence. The runtime's Docker labels expose its immutable Deployment hostname.

Promotion and rollback publish versioned Alias routing commands. The provider validates that the target Revision is known locally, persists the Alias target, and atomically replaces one Traefik file. Rollback changes only the Alias target and creates no Build. Cancellation is rejected while a Deployment serves an Alias; after rollback, cancellation removes the non-serving runtime and its local routing state before `deployment.runtime.canceled.v1` completes the Rails transition.

## Isolation and least privilege

The provider runs non-root after privileged volume initialization. Rails is attached only to the normal application networks and has neither a Docker socket mount nor a Docker API network. The provider reaches Docker through a dedicated internal proxy network; an explicit HAProxy policy allows only the image inspect/pull and container inspect/create/start/delete endpoints its reconciler uses. Docker build, exec, system, archive, logs, and unrestricted endpoint families are denied.

Customer runtimes use a separate internal network shared with Traefik and the provider. They run as UID/GID 10001 with a read-only root filesystem, `no-new-privileges`, all Linux capabilities dropped, and bounded CPU, memory, PIDs, and no-exec temporary storage. Runtime identity labels bind an existing container to its Deployment, organization, and source digest before reuse or deletion.

This remains a trusted local behavior-parity provider. Docker container creation is a privileged host capability, and ordinary runc is not an approved public multi-tenant boundary. Arbitrary customer code and production execution remain disabled until the later sandbox/runtime work packets satisfy the threat model.

## Acceptance evidence

- The real E2E creates two Deployments and two Builds from the pinned sample image.
- Both immutable hostnames pass readiness through Traefik.
- Docker health gates immutable routing, and a readiness failure removes the candidate before the failure callback.
- The environment Alias moves from the first Revision to the second and rolls back to the first.
- Rollback preserves the original Build count.
- The now non-serving second Deployment cancels, its command reaches `published`, its immutable route disappears, and the rolled-back Alias remains healthy.
- Provider restart/replay recovers the same command without duplicating runtime or callback identity.
- The E2E asserts provider PID 1 is non-root, Rails has no Docker access, the runtime network is internal, and every managed runtime retains the required user, filesystem, capability, privilege, CPU, memory, PID, and network restrictions.
- Live proxy probes confirm Docker build, exec, and system APIs return HTTP 403 while the full lifecycle still succeeds.
- Ten provider unit tests cover contracts, HMAC body binding, durable replay/conflict detection, allowlisting, safe Git/readiness failure, runtime hardening, Alias routing, and cancellation.
- The provider-focused Rails suite passes 31 examples covering signed transport, claims/finalization, callbacks, stale versions, API cancellation, outbox data, tenant-unique hostnames, and Alias routing events.
- The complete control-plane CI passes 249 examples, RuboCop, Zeitwerk, Bundler Audit, Importmap Audit, and Brakeman.
- Migration `20260711217000` rolls down/up in both development and test; test preparation preserves the byte-identical schema dump.

## Deferred work

WP-011 adds isolated BuildKit proof for Git/Dockerfile builds and the mandatory metadata, control-plane, and cross-build isolation tests. WP-012 adds refresh-safe Deployment status/log UI and user actions. Arbitrary OCI execution, configuration injection, production registry credentials, gVisor/Kata runtime cells, default-deny workload egress, telemetry, and public multi-tenant operation remain unavailable.

## Rollback

Stop the local provider before reverting its transport. Remove only containers labeled `com.layerrail.managed=true`, remove the generated `lrail-local-provider.yml` route file, and remove the provider/proxy services and dedicated networks. The additive claim migration can be reversed after no command is actively leased; preserve existing Deployment, Build, Revision, Alias, transition, outbox, and receipt history. Once external provider history is relied upon, prefer a forward migration over deleting durable events or receipts.
