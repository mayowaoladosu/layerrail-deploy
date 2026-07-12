# ADR-0013: gVisor BuildKit outer-root boundary

- Status: Accepted
- Date: 2026-07-12
- Decision owners: Platform engineering
- Supersedes: ADR-0008 for Phase 2 build Pods only
- Requirements: GOAL-001, GOAL-004, FR-BLD-001, FR-BLD-002, INV-001, INV-002, INV-005, INV-006, INV-007, INV-010, INV-011
- Applies to: WP-015 disposable build sandboxes

## Context

ADR-0008 requires customer Pods to be non-root and capability-free. That remains the runtime workload rule, but the actual minikube gVisor RuntimeClass cannot nest the user namespaces required by rootless BuildKit. The rootless daemon fails before executing a Dockerfile because `newuidmap` and the required subordinate-ID namespace operations are unavailable inside this sandbox. Disabling BuildKit's process sandbox would also collapse isolation between the daemon and build steps.

A focused executable spike proved a narrower alternative. BuildKit 0.26.2 can use the native snapshotter and normal OCI process sandbox inside the outer gVisor sandbox when its outer process runs as UID 0 with a reviewed capability set. A wrapper around BuildKit's pinned `runc` rewrites each nested OCI process specification immediately before `run`, atomically replacing every nested capability set with an empty list. The proof executed real Dockerfile `RUN` instructions and verified that the nested process had no capabilities.

Kubernetes Pod Security `baseline` rejects the outer `SYS_ADMIN` capability. Merely weakening namespace admission without a replacement policy would permit unrelated privileged shapes and is not acceptable.

## Decision

Each Build runs in one disposable, single-tenant gVisor Pod. The outer worker is not privileged, cannot escalate privileges, has a read-only root filesystem, joins no host namespace, mounts no host path or container socket, receives no service-account token and uses only bounded `emptyDir` storage. It receives expiring clone, registry and callback credentials through one read-only Secret volume. No BuildKit state or cache is shared across Builds.

The outer worker runs as UID/GID 0 inside gVisor with only `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `FSETID`, `KILL`, `MKNOD`, `NET_BIND_SERVICE`, `SETFCAP`, `SETGID`, `SETPCAP`, `SETUID`, `SYS_ADMIN` and `SYS_CHROOT`. `privileged` and `allowPrivilegeEscalation` remain false. The digest-pinned BuildKit image invokes the versioned `capless-runc` wrapper, which empties bounding, effective, inheritable, permitted and ambient capabilities for every nested `runc run`. Customer Dockerfile processes therefore do not inherit the outer daemon's capabilities.

The `lrail-builds` namespace uses the Pod Security `privileged` enforcement level only because the standard profiles cannot express this exact gVisor exception. Restricted policy remains in audit and warn mode. Fail-closed `ValidatingAdmissionPolicy` rules replace the broad profile for this namespace and require:

1. the `gvisor` RuntimeClass and approved worker image;
2. exactly one container with the reviewed outer-root security context and capability allowlist;
3. no init, ephemeral or privileged containers, host namespaces, host ports, host paths, propagated mounts or service-account token;
4. only Secret and `emptyDir` volumes, with credentials excluded from environment variables;
5. CPU, memory, disk and active-deadline limits, at most one retry and prompt Job collection.

The alpha kubelet enforces a per-Pod PID limit of 512. NetworkPolicy denies ingress and egress by default, blocks cloud metadata and private control-plane ranges from build steps, and permits only public package traffic plus authenticated registry and signed callback endpoints. Those endpoints disclose nothing without per-Build credentials that are unavailable to nested build processes. The selected local Cilium CNI uses a namespaced `CiliumNetworkPolicy` `kube-apiserver` entity rule for the trusted controller because ordinary CIDR rules do not match Cilium's remote-node API identity; this exception does not select Build Pods.

The build controller is a separate non-root trusted Pod. Its namespaced Role can create, inspect and delete only Jobs and credential Secrets in `lrail-builds`, and can list bounded worker logs. Rails remains the sole product-state writer; the controller has no database credentials, unrestricted cluster role or customer-code execution path.

This exception does not apply to public runtime Pods, which remain non-root, capability-free and restricted by ADR-0008. GKE admission, gVisor behavior and PID controls must pass the same executable probes before cloud apply.

## Consequences

Phase 2 can execute Dockerfile and detected builds in the selected local sandbox without privileged Pods, host mounts, Docker sockets or a shared multi-tenant daemon. A BuildKit exploit remains contained by the outer gVisor boundary and disposable tenant Pod rather than by rootless BuildKit.

`capless-runc`, the BuildKit digest, the capability allowlist, admission expressions and gVisor version are security-critical release inputs. Changes require rerunning capability, metadata, control-plane, cross-tenant, cache, credential, cancellation and process-limit probes. Restricted audit warnings for build Pods are expected and must not be silenced by changing runtime workload policy.

## Rejected alternatives

- Rootless BuildKit inside the chosen gVisor RuntimeClass is not executable because nested user-namespace mapping is unavailable.
- Privileged BuildKit, host Docker sockets, host mounts and unrestricted capabilities violate the tenant boundary.
- `--oci-worker-no-process-sandbox` weakens the proven daemon/build-step separation and is unnecessary.
- A shared BuildKit daemon reintroduces cross-Build cache, process and credential exposure.
- Replacing the approved BuildKit path with an unproven builder would defer rather than resolve the isolation gate.

## Rollback

Stop new command claims, cancel and delete disposable Build Jobs, revoke their credentials, remove the controller Deployment and admission bindings, then restore `lrail-builds` to Pod Security `baseline`. Preserve Rails Build history and immutable evidence. Do not fall back to privileged, socket-mounted or shared-daemon builds.
