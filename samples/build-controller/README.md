# Build controller fixtures

These deterministic repositories exercise WP-015 through the authenticated E2E Git service. The E2E also pins a public GitHub Node sample. Together they cover explicit Dockerfiles, detected Node services, plain/generated static output, controller and Pod loss, cancellation, timeout, nested sandbox isolation and critical vulnerability policy failure.

All base images are digest-pinned. The legacy Alpine image is intentionally vulnerable and must only be used by the `scan-fail-web` policy test; its artifact must never produce a Revision.
