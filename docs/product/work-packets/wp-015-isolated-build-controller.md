# WP-015: Isolated build controller

- Phase: 2 - Isolated alpha
- Status: Approved
- Owner: `services/build_controller`, `infrastructure/kubernetes`, `contracts/provider`
- Dependencies: WP-013, WP-014, ADR-008
- Requirements: GOAL-001, GOAL-004, GOAL-005, FR-BLD-001, FR-BLD-002, INV-001, INV-002, INV-005, INV-006, INV-007, INV-010, INV-011

## Objective

Turn a pinned Git source into an immutable OCI image or static bundle in one disposable gVisor build sandbox, then return redacted logs and bounded supply-chain evidence without executing code in Rails.

## Scope

- Resolve installation-scoped short-lived clone credentials through the existing Git provider seam.
- Support Dockerfile web, detected Node web and plain/generated static plans; reject unsupported ambiguity.
- Create one gVisor Kubernetes Job per Build with no service-account token, default-deny networking, resource/time/process/disk limits and expiring mounted credentials.
- Publish immutable OCI/static artifacts, SBOM, provenance and scan/policy result.
- Capture timestamped redacted phases and cancellation/failure evidence.

## Acceptance

- Supported public/fake-private samples build from exact commit and publish by digest.
- Malicious metadata/control-plane/cross-tenant/cache/secret probes stay blocked.
- Clone/registry credentials expire and cannot be recovered from image, logs, Pod spec or retained state.
- Build timeout/cancel removes the sandbox and creates no ready Revision.
- Duplicate requests reuse one logical Build; process/node loss resumes or safely retries.
- Critical scan-policy failure blocks runtime reconciliation.

## Rollback

Stop new Jobs, revoke credentials, delete disposable build Pods, and preserve Build evidence/logs and published referenced artifacts.
