# WP-011: Isolated BuildKit proof of concept

- Phase: 1 - Behavior parity
- Status: Implemented
- Owner: `compose`, `samples/buildkit-isolation`, `scripts`
- Dependencies: Platform threat model
- Requirements: INV-005, INV-006, INV-007, INV-011

## Objective

Demonstrate that an untrusted BuildKit `RUN` step can execute outside Rails while direct cloud-metadata, control-plane, daemon-control, daemon-cache, and concurrent-build-secret access remain blocked. This is a falsifiable isolation spike, not the Phase 2 build service.

## Proof boundary

The opt-in `buildkit-poc` Compose profile pins `moby/buildkit:v0.26.2-rootless` by registry digest. The daemon runs as UID/GID 1000 in RootlessKit with the OCI worker, native snapshotter, and the normal process sandbox. The outer daemon has a read-only root filesystem, a persistent BuildKit state volume, narrow runtime tmpfs mounts, and one CPU, 1 GiB memory, and 512 PID limits.

BuildKit's documented rootless container mode needs unconfined seccomp, AppArmor, and system paths for user namespaces, mounts, and per-exec `/proc`. The proof keeps those exceptions on the non-root BuildKit daemon only. It deliberately does not use `--privileged` or `--oci-worker-no-process-sandbox`; the latter would expose daemon processes to build steps.

Daemon control is a mode-0660 Unix socket in a dedicated volume. A networkless, non-root `buildctl` client mounts that socket read-only. The daemon has no TCP listener, Docker socket, Rails network, or control-plane credentials. Build execution inherits the daemon container's network as required by rootless BuildKit, so the daemon is attached to only `devpush_buildkit_sandbox`, a Docker-internal network with no default route.

A control-plane canary listens on `devpush_internal` and is never attached to the build network. Its direct IP is passed to the malicious fixture so the test does not rely on DNS failure. Rails is independently asserted not to share the build network.

## Executable probes

A trusted fixture helper copies BusyBox and its musl loader from the already pinned BuildKit image into a scratch build context. The final artifacts copy files produced by the probe stages; BuildKit therefore cannot optimize away the malicious `RUN` instructions.

The network probe fails if it can open either `169.254.169.254:80` or the control-plane canary's direct IP and port. The harness also verifies that the daemon's network has no default route.

The cross-build probe streams a random canary to `buildctl` over stdin and mounts it with BuildKit's secret session. It never places the plaintext in Compose environment, build arguments, Dockerfile history, or the build context. While the owner build holds the secret mount open, an attacker build on the same daemon checks its own secret path and every visible `/proc/<pid>/root` for:

- the owner's secret mount;
- the BuildKit control socket; and
- the daemon cache directory.

Both builds must produce artifacts, the plaintext must be absent from both progress logs, and a post-build scan must not find it in persistent BuildKit state.

## Acceptance evidence

- Rootless PID 1 and image identity are UID/GID 1000.
- The outer daemon root filesystem is read-only and resource bounded.
- The daemon is attached only to the internal build network and has no default route or Docker socket.
- The worker reports OCI execution, native snapshots, and process mode `sandbox`.
- The control socket is owned by 1000:1000, mode 0660, and no TCP control port is open.
- A scratch BuildKit stage runs and cannot connect to cloud metadata or the direct control-plane canary IP.
- Concurrent owner/attacker builds complete while the attacker cannot traverse to the owner's secret, daemon socket, or daemon cache.
- Secret plaintext is absent from build logs and persistent daemon state.
- `scripts/buildkit-isolation-e2e.sh` passes on Docker Desktop and in the dedicated GitHub Actions isolation job.
- Failed CI proofs print the bounded BuildKit/canary logs before cleanup; Ubuntu 24.04 enables the upstream-documented unprivileged-userns prerequisite on its ephemeral runner.

## Deliberate limitations

The build network has no egress, so this proof does not pull arbitrary base images, clone repositories, publish OCI artifacts, or exercise cache/registry credentials. It does not connect to the WP-010 provider or turn Git Deployments into runnable Revisions. Those are build-service responsibilities for Phase 2 after credential issuance, registry, sandbox runtime, egress policy, cancellation, logs, quotas, and artifact evidence have approved contracts.

Rootless BuildKit in an ordinary Docker container is not the production multi-tenant boundary. The production design still requires ephemeral workers on isolated capacity, gVisor/Kata or stronger controls, default-deny policy, blocked metadata/control-plane routes, and independent security review.

## Rollback

Stop the `buildkit-poc` profile, remove its exited initializer/canary containers, and remove `devpush_buildkit_state`, `devpush_buildkit_socket`, and `data/buildkit-proof` if cached proof state is no longer needed. No Rails migration, domain state, event, or provider state is changed by this proof.
