# WP-014: Alpha registry and object storage

- Phase: 2 - Isolated alpha
- Status: Complete
- Owner: `infrastructure/kubernetes`, `services/artifact_gateway`, `contracts/provider`
- Dependencies: ADR-010
- Requirements: GOAL-003, GOAL-007, FR-BLD-001, FR-BLD-002, INV-001, INV-002, INV-005, INV-007, INV-011, INV-012

## Objective

Provide tenant-scoped immutable OCI and static artifact storage for the disposable alpha cell, with cloud-portable contracts and no credentials in Rails or customer workloads.

## Scope

- Deploy digest-pinned Distribution 3 backed by MinIO plus separate static/evidence buckets.
- Generate credentials at install time and mount them only into platform components.
- Validate artifact paths, manifests, digest/size bounds and immutable publication.
- Implement static artifact upload/read contracts and retention reconciliation.
- Map cloud configuration to Artifact Registry and Cloud Storage without applying credentials in source.

## Acceptance

- A built image pushes and pulls by manifest digest.
- Another organization cannot list, pull or overwrite the repository.
- Static traversal/symlink/oversize fixtures fail closed.
- Current and previous Alias artifacts survive cleanup; failed unreferenced artifacts expire idempotently.
- Credentials and auth headers are absent from logs, events and normal serialization.
- Registry/MinIO health and backup/cleanup procedures are documented.

## Evidence

- `scripts/phase2-cell.sh start` idempotently reconciles the gVisor alpha cell, generated Secrets, quotas, default-deny policies, Distribution, MinIO, registry-auth and artifact-gateway.
- `scripts/phase2-artifacts-e2e.sh` publishes and pulls an OCI manifest by digest, denies a foreign organization list/pull/overwrite scope, verifies revocation and persistence, rejects traversal/symlink/conflicting static archives, and proves current/previous Alias retention across a MinIO restart.
- Registry-auth has four isolated tests for scoped RS256 tokens, expiry, revocation, HMAC replay denial, conflict handling and plaintext absence.
- Artifact-gateway has seven isolated tests for bounded extraction, immutable publication/evidence, cache policy, signed mutation requests and idempotent retention.
- `contracts/provider/v1/static-artifact-manifest.schema.json` bounds the publication contract; `artifact-provider.schema.json` maps credential-free local Distribution/MinIO and cloud GAR/GCS configuration.
- `docs/runbooks/alpha-artifacts.md` documents health, backup/restore verification, retention, offline registry garbage collection, credential rotation and rollback.

## Rollback

Drain new publication, retain referenced digests, and remove only disposable unreferenced alpha data after reconciliation.
