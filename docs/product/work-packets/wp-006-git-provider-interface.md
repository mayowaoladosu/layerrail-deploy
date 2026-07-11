# WP-006: Git provider interface and fake adapter

- Phase: 0 - Foundation
- Status: Implemented
- Owner: `apps/control_plane/app/providers/git_providers`
- Dependencies: WP-004, WP-005, ADR-005
- Requirements: INV-005, INV-007, INV-011, FR-GIT-001

## Objective

Define a provider-neutral Git seam and deterministic fake adapter that cover installation lifecycle, authorized repository discovery, source metadata, short-lived clone access, user mapping and verified webhook normalization.

## Interface

The provider adapter creates installation setup URLs, resolves and disconnects installations, opens scoped sessions, maps provider users and verifies/normalizes webhook deliveries. An installation session lists repositories, branches and commits and issues credentials only for an authorized repository revision.

Every operation returns `GitProviders::Result` with either an immutable DTO or a fixed safe `GitProviders::Error`. Active Record objects, provider response hashes and provider exceptions do not cross the seam.

## Fake adapter guarantees

- Fixtures, clock, webhook secret and credential seed are injected.
- Repository, branch and commit ordering and pagination are deterministic.
- Pagination cursors are signed and bound to one operation/scope.
- Sessions reject repositories outside their installation with a not-found failure.
- Clone credentials expire after fifteen minutes, keep the secret out of `inspect` and `to_h`, and require a known revision.
- Webhook HMAC is verified before JSON parsing and normalization.
- Normalized events never contain the raw request body or signing secret.
- Disconnection is idempotent and invalidates sessions opened earlier.
- No network I/O or customer code execution occurs.

## Acceptance evidence

The reusable provider contract runs eighteen examples against a fresh fake adapter and covers:

- setup and installation metadata;
- explicit safe failures;
- authorized-only repository pagination and cursor rejection;
- branches, commits and revision validation;
- credential expiration and redaction;
- provider user mapping;
- valid, invalid, malformed and unsupported webhook deliveries;
- normalized installation disconnection;
- idempotent disconnect and stale-session rejection; and
- deterministic output for identical fixture and clock input.

The complete control-plane suite passes with seventy-eight examples, Zeitwerk eager loading, RuboCop, dependency audits and Brakeman.

## Deferred work

WP-007 implements the real GitHub App adapter, encrypted installation persistence, signature configuration and webhook inbox. Durable outbox delivery, project repository connections and build-plane credential transport remain in their approved packets.

## Rollback

Remove the provider/fake classes, shared contract loader and WP-006 documentation. No database migration, external installation or provider credential is created by this work packet.