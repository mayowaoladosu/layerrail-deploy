# WP-016: Kubernetes runtime cell

- Phase: 2 - Isolated alpha
- Status: Approved
- Owner: `services/runtime_controller`, `infrastructure/kubernetes`, `contracts/provider`
- Dependencies: WP-013, WP-014, WP-015, ADR-008
- Requirements: GOAL-003, GOAL-004, GOAL-007, FR-DEP-001, FR-DEP-002, FR-DEP-003, INV-001, INV-003, INV-004, INV-005, INV-006, INV-007, INV-010, INV-011, INV-012

## Objective

Reconcile immutable web Revisions into one gVisor Kubernetes cell, gate traffic on readiness, update aliases atomically and recover safely after controller or Pod loss.

## Scope

- Bootstrap the disposable `lrail-alpha` minikube cell and declarative GKE target.
- Install namespaces, RBAC, Pod Security, Cilium default-deny policy and gateway resources.
- Reconcile validated provider-neutral DTOs into Deployments, Services and routes; never accept raw customer Kubernetes objects.
- Observe Pod readiness/liveness and return operation/version-bound callbacks.
- Implement immutable, environment and rollback route bindings plus cancellation cleanup.

## Acceptance

- Web sample runs under `runtimeClassName: gvisor`, non-root/read-only/no-capabilities with bounded resources and no service-account token.
- Pod cannot reach metadata, Kubernetes API, Rails/data networks or another tenant.
- Immutable URL serves only after readiness; failed readiness receives no route.
- Environment promotion and rollback switch one route without rebuilding.
- Controller restart and Pod replacement preserve desired state; stale observations cannot regress Rails.
- Cancellation removes a non-serving runtime and retains bounded logs/evidence.

## Rollback

Remove route bindings before workloads, then delete only resources labeled for the target organization/revision. Preserve Rails state and referenced artifacts.
