# WP-018: Isolated alpha operations and launch evidence

- Phase: 2 - Isolated alpha
- Status: Approved
- Owner: `infrastructure`, `docs/runbooks`, all Phase 2 services
- Dependencies: WP-013 through WP-017
- Requirements: GOAL-001, GOAL-004, GOAL-006, GOAL-007, INV-001 through INV-012

## Objective

Prove the Phase 2 cell is reproducible, observable, recoverable and free of known critical/high isolation findings before declaring isolated alpha complete.

## Scope

- OpenTofu validation for private GKE, workload identity, GKE Sandbox, Artifact Registry/GCS, private Temporal and controlled egress.
- GitOps manifests and policy validation for the disposable cell.
- Component health, SLO/alert placeholders, backup/restore, cleanup, credential rotation and incident runbooks.
- Fault injection for duplicate events, lost callbacks, controller/build/runtime loss, registry timeout and stale routes.
- Full sample and adversarial E2E in local/CI.

## Acceptance

- Fresh cell bootstrap and teardown are idempotent and leave no unlabeled resources.
- Web/static samples deploy with no control-plane code execution; logs/readiness/URLs/rollback pass.
- Metadata, cluster API, control-plane, cross-tenant network/cache/log/secret/artifact attempts are blocked.
- Build/controller/Pod/registry faults recover or produce visible bounded failures without orphan routes.
- Secret/IaC/dependency/image scans and policy checks pass.
- Independent Standards and Spec reviews report no unresolved critical/high finding.
- Remote CI and documented local commands pass from a clean checkout.

## Rollback

Follow component runbooks in reverse dependency order: stop new workflows, drain routes, retain referenced artifacts/history, revoke credentials, remove workloads, then delete the disposable cell.
