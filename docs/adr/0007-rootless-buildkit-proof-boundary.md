# ADR-0007: Rootless BuildKit proof boundary

- Status: Accepted
- Date: 2026-07-12
- Decision owners: Platform engineering
- Applies to: WP-011 development proof only

## Context

The platform specification prohibits repository commands in Rails and requires the first BuildKit spike to prove that metadata, control-plane, and cross-build access are blocked. A Docker Desktop proof must still distinguish a useful security hypothesis from a production sandbox claim.

Rootless BuildKit's OCI worker provides user-namespace execution and a per-exec process sandbox. Its official container guidance requires relaxed seccomp, AppArmor, and system-path policies for namespace and mount operations. Rootless workers also use host networking relative to their outer container. Listening on TCP from that container would expose daemon control to its own build steps.

## Decision

Use the digest-pinned `moby/buildkit:v0.26.2-rootless` image for WP-011 with these constraints:

1. Keep the normal OCI process sandbox and native snapshotter. Do not use privileged mode or `--oci-worker-no-process-sandbox`.
2. Run PID 1 as UID/GID 1000, make the outer root filesystem read-only, persist only BuildKit state, and bound CPU, memory, and PIDs.
3. Apply the rootless image's required unconfined seccomp, AppArmor, and system-path exceptions only to this non-root daemon.
4. Expose daemon control only through a Unix socket owned by 1000:1000 and mounted read-only into a networkless `buildctl` client. Do not open a TCP listener.
5. Attach the daemon only to a dedicated Docker-internal network with no default route. Never attach Rails, PostgreSQL, Redis, provider services, or the control-plane canary to that network.
6. Use scratch-based fixtures and a direct-IP canary to prove blocked metadata/control-plane access without external pulls.
7. Mount build secrets through the BuildKit session and test concurrent process/root isolation plus post-build non-persistence.

## Consequences

The proof can execute malicious fixture commands and produce exported artifacts while giving deterministic negative evidence for the named access paths. It is self-contained, repeatable, and suitable for CI.

The no-egress network intentionally prevents ordinary Dockerfile builds that need registries or package repositories. The relaxed outer security options and ordinary Docker/runc host remain unsuitable as a public multi-tenant boundary. Phase 2 must replace this proof topology with ephemeral isolated workers, controlled egress, short-lived credentials, registry publication, stronger runtime isolation, quotas, cancellation, evidence, and operational ownership.

## References

- [BuildKit rootless mode](https://github.com/moby/buildkit/blob/master/docs/rootless.md)
- [BuildKit overview](https://docs.docker.com/build/buildkit/)
- [Lrail implementation specification](../../Lrail_Ruby_Rebuild_AI_IDE_Implementation_Specification.docx)
