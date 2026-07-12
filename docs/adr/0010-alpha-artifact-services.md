# ADR-0010: Alpha artifact services and immutable publication

- Status: Accepted
- Date: 2026-07-12
- Decision owners: Platform engineering
- Requirements: GOAL-003, GOAL-004, GOAL-007, FR-BLD-001, FR-BLD-002, INV-001, INV-002, INV-005, INV-007, INV-011, INV-012
- Applies to: Phase 2 isolated alpha

## Context

Phase 2 requires an OCI registry for web artifacts and object storage for static outputs, logs/evidence and source bundles. The implementation specification requires content-addressed artifacts, scoped credentials, deletion strategy and provider portability. Managed vendors remain an approval-sensitive decision.

## Decision

The disposable local/CI alpha uses digest-pinned CNCF Distribution 3 and MinIO. Distribution stores registry blobs in MinIO through the S3-compatible driver; static artifacts and build evidence use separate buckets and prefixes. The cloud target maps the same provider contracts to Google Artifact Registry and Google Cloud Storage.

Artifact identities are tenant-scoped:

- OCI repository: `lrail/<organization-id>/<service-id>`;
- immutable image reference: repository plus returned `sha256` manifest digest;
- static prefix: `organizations/<organization-id>/revisions/<revision-id>/`;
- build evidence prefix: `organizations/<organization-id>/builds/<build-id>/`.

Mutable tags are transport conveniences only. Rails records and deploys the immutable digest returned by the registry. Static manifests contain content digests, media types, sizes and cache policy; path traversal, symlinks and unbounded archives are rejected.

Build workers receive expiring single-build credentials through secret mounts. Runtime pull credentials are scoped to one organization repository. Customer build steps and runtime processes do not receive MinIO administrative credentials. The local alpha's registry is reachable only from build/runtime infrastructure networks and never from Rails or customer runtime egress.

Each Build records bounded evidence for source commit, detected plan, cache result, SBOM reference, provenance reference, scan status/policy and artifact reference. Alpha scanning uses pinned tools and blocks critical policy failures; signatures/attestations bind the immutable digest.

Retention preserves every current or previous ready Alias target. Failed/unreferenced alpha artifacts expire after seven days; deletion is idempotent and emits evidence. Registry garbage collection runs only after Rails/provider retention reconciliation.

## Consequences

Local E2E can build, publish, pull and roll back without cloud credentials. GKE production manifests use workload identity and managed artifact services without changing Rails contracts.

Distribution and MinIO are development/alpha dependencies, not promises to self-host production storage. Their root/admin credentials stay in generated Kubernetes Secrets and are excluded from source, events and logs.

## Rollback

Stop artifact services and delete only the disposable alpha buckets/registry volume after removing the local cell. Never remove blobs referenced by current/previous ready Revisions. Cloud migration copies and verifies immutable digests before switching provider configuration.
