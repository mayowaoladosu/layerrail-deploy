# ADR-0008: Phase 2 cell, cloud target and sandbox

- Status: Accepted
- Date: 2026-07-12
- Decision owners: Platform engineering
- Requirements: GOAL-001, GOAL-004, GOAL-007, FR-DEP-001, FR-DEP-002, FR-DEP-003, INV-001, INV-003, INV-005, INV-006, INV-007, INV-010, INV-012
- Applies to: Phase 2 isolated alpha

## Context

Phase 2 requires one Kubernetes cell, web/static revisions, health-gated URLs and rollback. The implementation specification leaves the initial cloud and runtime sandbox as explicit approval gates. The user delegated those choices after reviewing the Phase 2 prompt.

The cell must run malicious customer workloads without exposing Rails, PostgreSQL, cloud metadata, another tenant, node APIs or broad cluster credentials. Ordinary namespace separation and runc alone are prohibited as the public multi-tenant boundary.

## Decision

The first cloud target is a private **GKE Standard regional cluster in `us-central1`**. GKE is selected because GKE Sandbox provides a supported gVisor RuntimeClass without custom node-image maintenance. Cloud resources are declared with OpenTofu and GitOps; no billable resource is created without credentials and an explicit apply.

The executable local/CI cell is a separate minikube profile named `lrail-alpha` with Kubernetes 1.34, containerd, Cilium and the minikube gVisor addon. It is disposable validation infrastructure, not the cloud production topology.

All untrusted build and public web Pods use `runtimeClassName: gvisor`. Platform controllers and gateways use ordinary runtime classes only when they execute no customer code. Namespaces enforce Pod Security admission and default-deny NetworkPolicies. Customer Pods run non-root, disable privilege escalation, drop all capabilities, use a read-only root filesystem, bounded tmpfs/ephemeral storage, seccomp, resource limits and no service-account token.

The initial supported workloads are:

1. Dockerfile web services that listen on the platform `PORT`;
2. detected Node web services with a lockfile and explicit `start` script; and
3. plain or generated static sites published to object storage with no per-revision runtime Pod.

Workers, cron, jobs, private services, custom domains, persistent disks, arbitrary buildpacks and functions remain outside Phase 2.

## Consequences

GKE Sandbox and local minikube both expose the `gvisor` RuntimeClass, keeping workload manifests provider-neutral. GKE networking, identity, load balancing and artifact vendors remain behind cell/provider contracts.

The local cell can prove isolation and product behavior without cloud credentials. A successful local E2E does not claim GKE has been applied. Cloud completion requires an OpenTofu plan in an authenticated environment and a separate operational review.

Build workers are ephemeral and single-tenant. If Kubernetes forces BuildKit's no-process-sandbox mode, the entire worker Pod remains one short-lived tenant sandbox with only expiring repository/registry credentials; no controller process, cross-tenant cache or control-plane credential may share that Pod.

## Rejected alternatives

- AWS EKS is the specification reference but needs custom gVisor node/runtime maintenance.
- Linode LKE aligns with an existing LayerRail provider but does not expose sufficient managed-node runtime control for the locked gVisor default.
- Kata-by-default increases startup and operational cost beyond the first alpha.
- A local-only decision would leave the cloud architecture gate unresolved.

## Rollback

Delete the `lrail-alpha` profile and remove the Phase 2 GitOps/OpenTofu modules. This does not modify Rails domain history. Superseding the cloud or sandbox requires a new ADR; do not rewrite this accepted record.
