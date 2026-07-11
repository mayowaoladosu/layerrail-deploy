# ADR-005: Installation-scoped Git provider seam

- Status: Accepted
- Date: 2026-07-11
- Requirements: INV-005, INV-007, INV-011, FR-GIT-001, WP-006

## Context

Lrail must support GitHub first and GitLab or Bitbucket later without leaking provider response objects, credentials or exception semantics into product behavior. Repository, branch, commit and clone operations are all authorized by one provider installation.

Three interface shapes were evaluated. A generic action dispatcher minimized method count but moved validation into action-specific hashes and made misuse easy. A flat capability interface was explicit but repeated installation identifiers on every operation and made accidental cross-installation calls possible. A provider-specific repository object graph hid pagination but coupled callers to lazy network behavior and provider vocabulary.

## Decision

1. Use a typed provider interface that opens an installation-scoped session.
2. Keep installation setup, installation lookup, disconnection, user mapping and verified webhook normalization on the provider adapter.
3. Keep authorized repository, branch, commit and clone-credential operations on the scoped session. Callers do not repeat installation identifiers within the session.
4. Verify webhook signatures and normalize payloads in one operation. Unverified payloads never become Lrail events.
5. Return immutable provider-neutral DTOs inside explicit success or failure results. Operational provider exceptions and raw response hashes do not cross the seam.
6. Use fixed safe error codes/messages. Provider diagnostics remain internal and must be redacted.
7. Return clone URLs separately from short-lived secrets. Credential inspection and serialization redact or omit the secret.
8. Require every adapter to pass the shared deterministic contract suite. The fake adapter uses injected fixtures, clock and signing seeds and performs no network I/O.

## Consequences

- Installation authorization is selected once, reducing repeated scope checks and cross-installation misuse.
- Callers learn two small interfaces instead of one large provider object.
- Provider adapters own pagination translation, credential refresh and event normalization complexity.
- GitHub-specific fields require deliberate additions to provider-neutral DTOs or internal adapter handling.
- A real adapter can be tested against the same behavioral contract while retaining provider-specific integration tests.