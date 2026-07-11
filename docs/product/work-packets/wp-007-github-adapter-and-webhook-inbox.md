# WP-007: GitHub App adapter and webhook inbox

- Phase: 1 - Behavior parity
- Status: Implemented
- Owner: `apps/control_plane`
- Dependencies: WP-006, ADR-005, ADR-006
- Requirements: FR-GIT-001, FR-GIT-002, INV-005, INV-007, INV-011

## Objective

Implement the real GitHub App adapter, organization-scoped installation/repository persistence and a verified, replay-safe webhook inbox without exposing provider credentials or raw provider objects.

## GitHub adapter

- Issues short-lived RS256 app JWTs and verifies their signatures in tests.
- Maps GitHub installation, repository, branch, commit and user responses into provider-neutral immutable DTOs.
- Requests installation tokens on demand, refreshes before expiry and never persists them.
- Lists only installation-authorized repositories and validates a repository before clone credential issuance.
- Keeps clone secrets out of URLs, `inspect` and `to_h`.
- Translates provider HTTP failures into fixed safe retryable/non-retryable results.
- Passes the same shared provider contract as the deterministic fake adapter.

## Persistence and tenant scope

`GitInstallation` stores organization-owned provider/account metadata and permissions. `RepositoryConnection` links one service to one installation-authorized repository. No table includes token, access-token, secret or raw-payload columns.

Composite PostgreSQL foreign keys enforce:

- installation and repository connection organization ownership;
- project and organization ownership; and
- service and project ownership.

Provider installation identifiers are globally unique per provider. Advisory locks serialize repeated installation callbacks, and service row locks serialize repeated repository selections.

## Webhook inbox

The GitHub endpoint verifies HMAC-SHA256 before parsing. The verifier normalizes push, pull-request, installation, repository-selection and repository-lifecycle events. Unknown installations are acknowledged without persistence.

Known deliveries are organization-owned and store only normalized data plus a SHA-256 payload digest. `(provider, delivery_id)` is unique. Transaction-scoped advisory locks make concurrent retries produce one message. Identical retries replay the existing message; changed payloads with the same delivery ID conflict and cannot overwrite history.

Installation and repository metadata events apply in the same transaction as inbox creation. Push and pull-request events remain pending for WP-009 processing.

## Acceptance evidence

- Fake and GitHub adapters pass the shared provider contract.
- App JWT signature, lifetime and issuer are tested.
- Installation tokens, private keys, webhook secrets and cursor seeds are redacted.
- Installation and repository connect operations are tenant-scoped, idempotent and concurrency-tested.
- Direct SQL cross-tenant installation/service combinations fail composite foreign keys.
- Valid, invalid, malformed, unsupported and lifecycle webhook payloads are tested.
- Raw webhook bodies are absent from the schema and persisted attributes.
- Identical, altered and concurrent webhook retries are tested.
- Both migrations were applied, rolled back and rebuilt from an empty database with byte-stable schema output.
- The complete control-plane suite passes with 124 examples and all security gates.

## Deferred work

WP-009 consumes pending inbox messages transactionally with deployment state and outbox events. User OAuth/session persistence belongs to the approved authentication flow. GitHub sandbox-account tests require configured credentials and remain separate from deterministic CI.

## Rollback

Before production data exists, roll back the webhook inbox migration followed by installation/repository persistence, then remove the adapter/controller/services and restore the previous schema. Once provider connections exist, use forward state transitions and expand/migrate/contract changes rather than deleting installation history.