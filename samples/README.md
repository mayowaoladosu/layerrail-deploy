# Contract test applications

Disposable sample applications exercise build, runtime, networking and failure contracts. Samples are untrusted workload fixtures and must never execute in the Rails control plane.

- `local-provider-web/` is the trusted WP-010 OCI runtime fixture.
- `buildkit-isolation/` contains scratch-based malicious WP-011 build fixtures for metadata, control-plane and concurrent cross-build access probes.