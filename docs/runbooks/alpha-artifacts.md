# Alpha artifact services

- Owner: Platform engineering
- Scope: Disposable Phase 2 local/CI cell only
- Components: Distribution 3, MinIO, registry-auth, artifact-gateway
- Recovery objective: Reconcile within 15 minutes; no production durability claim

## Health

Run `scripts/phase2-cell.sh status`. The `minio`, `registry`, `registry-auth` and `artifact-gateway` Pods must be Ready, the bucket-init Job must be Complete, and both PVCs must be Bound. Run `scripts/phase2-artifacts-e2e.sh` after bootstrap, credential rotation, storage recovery or policy changes.

The artifact gateway readiness check performs a bounded bucket listing. Registry probes are TCP because an unauthenticated `/v2/` correctly returns an authentication challenge. Inspect logs by label; never enable HTTP header or request-body logging.

## Backup and verification

The local alpha is disposable, but a retained evidence capture can be made before destructive testing:

1. Stop build/runtime publication and wait for active Jobs to finish.
2. Submit a retention reconciliation containing every current and previous Alias Revision and only explicitly expired candidates.
3. Use the pinned MinIO client in a temporary restricted Pod, mounting `lrail-artifact-credentials` from the `lrail-system` namespace, to mirror `lrail-static`, `lrail-evidence`, `lrail-sources` and `lrail-registry` to an encrypted operator-controlled target.
4. Record bucket object counts and SHA-256 hashes outside the cell. Do not export Kubernetes Secret objects with the backup.
5. Restore into empty buckets, verify counts and hashes, then run the artifact E2E before resuming publication.

A Kubernetes volume snapshot alone is not an accepted backup because the alpha storage class and MinIO filesystem layout are implementation details. Google deployments use GCS versioning/retention and Artifact Registry policies through workload identity.

## Retention and registry garbage collection

The artifact gateway deletes only Revision IDs explicitly nominated by the trusted reconciler, only when their newest object predates the supplied cutoff, and never when an ID also appears in the retained set. Reconciliation IDs are immutable and their result is evidence in `lrail-evidence`. Retry the same ID and body after a timeout; a changed body is rejected.

Use a seven-day cutoff for failed or unreferenced alpha Revisions. Always retain current and previous ready Alias targets. OCI manifest deletion follows the same reconciled retain/delete plan. Stop registry writes before running Distribution garbage collection; never run blob garbage collection directly against MinIO or before manifest reconciliation. The safest full cleanup for a disposable cell is `scripts/phase2-cell.sh delete --yes` after confirming no retained evidence is required.

## Credential rotation

Generated credentials live only in Kubernetes Secrets in `lrail-system`.

1. Drain publication and preserve the registry-auth PVC.
2. Create replacement MinIO users/policies and update `lrail-artifact-credentials` without printing values.
3. Restart `registry` and `artifact-gateway`, verify readiness and run the artifact E2E, then remove old MinIO users.
4. Rotate `lrail-registry-auth-admin` and `lrail-artifact-gateway-admin`, restart their consumers, and verify signed requests.
5. Rotate the registry signing certificate only after its maximum five-minute token lifetime; restart registry-auth and registry together, then revoke old build credentials.

If any secret appears in output, stop publication, rotate it immediately, preserve redacted incident evidence and remove the affected logs from normal retention.

## Failure and rollback

On MinIO or registry failure, stop new publication but retain PVCs. Restore storage, restart MinIO first, then registry-auth, artifact-gateway and registry. A published manifest is immutable; never repair it in place. Publish a new Revision after a verification failure.

To roll back this slice, drain publication, preserve all reconciled current/previous digests, scale artifact clients to zero, and remove only disposable unreferenced alpha data. Cloud migration copies and verifies immutable digests before switching the provider mapping.

## Provider mapping

The credential-free mappings in `contracts/provider/v1/examples/artifact-provider-local.json` and `artifact-provider-google.json` map Distribution/MinIO to GAR/GCS. Rails stores only organization IDs, Revision/Build IDs and immutable digests; it never receives registry, MinIO, GAR or GCS credentials.
