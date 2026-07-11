# ADR-006: Ephemeral GitHub installation tokens

- Status: Accepted
- Date: 2026-07-11
- Requirements: INV-006, INV-011, FR-GIT-001, WP-007

## Context

GitHub App installation access tokens are short-lived credentials used to read repositories and issue clone access. Lrail could cache each token encrypted in PostgreSQL until expiry or mint a token from the GitHub App identity whenever an installation session opens.

Persisting tokens reduces GitHub token-creation calls but increases the number of reusable credentials in backups, database access paths and incident scope. Minting on demand requires GitHub availability at session creation but removes token-at-rest storage and simplifies revocation behavior.

## Decision

1. Do not persist GitHub installation access tokens in the control-plane database.
2. Store only provider-neutral installation metadata and repository selections in PostgreSQL.
3. Use the GitHub App private key to issue a short-lived RS256 app JWT and request an installation token when a session opens.
4. Keep the installation token only in the in-memory session and refresh it before expiry.
5. Keep clone URLs free of embedded credentials. Pass the token separately to the isolated build boundary.
6. Load the app private key and webhook secret from the runtime secret environment. Never serialize or log either value.
7. Any future provider credential that must be persisted requires KMS-backed encryption, rotation metadata and a superseding ADR.

## Consequences

- Database backups contain no GitHub installation or clone tokens.
- Opening a new GitHub session depends on the GitHub token endpoint.
- Provider outages surface as explicit retryable failures rather than stale-token fallback.
- Session objects must redact tokens from inspection and serialization.
- Installation revocation takes effect when the provider rejects future token issuance or when a verified lifecycle webhook marks the installation inactive.