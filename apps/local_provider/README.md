# Lrail local development provider

This Python service is the development-only infrastructure provider behind the Rails control-plane contract. It polls signed commands, reconciles trusted sample runtimes through a constrained Docker API proxy, writes local Traefik routes, and sends signed callbacks. It does not import Rails code or access either Rails database.

## Supported scope

- Repository-owned `lrail-local-sample:dev` OCI image, pinned to the exact local image digest.
- Web workload on port 8000 with an HTTP readiness path.
- Immutable deployment hostnames, environment Alias routing, rollback, and cancellation.
- Durable command receipts, Revision/container mappings, and Alias mappings in SQLite.

Git builds, arbitrary OCI images, configuration injection, and production multi-tenant execution are intentionally unavailable. Git commands return a safe failure until WP-011 supplies the isolated BuildKit proof of concept.

## Development

`scripts/start.sh` starts the provider with the rest of the development stack. Health is exposed inside Compose at `/health`; readiness at `/ready` checks both Rails transport and the constrained Docker API.

Run the provider unit suite through its development container:

```text
scripts/compose.sh exec -T local-provider python -m unittest discover -s tests -v
```

Run the complete deploy, route, promote, rollback, cancellation, and security proof:

```text
scripts/local-provider-e2e.sh
```

The E2E check also verifies that Rails has no Docker access, the provider process is non-root, the runtime network is internal, runtime containers are bounded and hardened, and Docker build/exec/system endpoints are denied.

## Security boundary

The provider and its Docker proxy share a dedicated internal network. Customer runtimes use a separate internal network shared only with the provider and Traefik. Runtime containers run as UID/GID 10001 with a read-only root filesystem, all capabilities dropped, `no-new-privileges`, and CPU, memory, PID, and temporary-filesystem limits.

The proxy exposes only the image inspection/pull and container inspect/create/start/delete endpoints required by the provider. This is a local behavior-parity harness, not the production sandbox described by the platform threat model; the production build/runtime boundary remains deferred to later work packets.
