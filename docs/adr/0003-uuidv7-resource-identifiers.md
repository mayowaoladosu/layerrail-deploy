# ADR-003: UUIDv7 resource identifiers

- Status: Accepted
- Date: 2026-07-11
- Requirements: INV-001, INV-005, INV-007, WP-003

## Context

Every customer-owned resource needs an opaque, globally unique, non-sequential identifier that can cross PostgreSQL, HTTP and event boundaries. The identifier should preserve useful insertion locality without coupling consumers to one database sequence or requiring an additional runtime library.

The implementation specification requires UUIDv7, ULID or another sortable globally unique format to be selected in an ADR before domain tables are created. Autonomous technical decision authority was granted after that required choice was surfaced.

## Decision

1. Use UUIDv7 for public and customer-owned resource primary keys.
2. Store primary and foreign keys in PostgreSQL's native `uuid` type.
3. Generate identifiers in application code with Ruby 3.4's `SecureRandom.uuid_v7`; do not depend on a PostgreSQL extension or sequential fallback.
4. Assign the identifier before insert so domain events and idempotency records can reference a resource before persistence completes.
5. Treat identifiers as opaque strings in public contracts. Clients must not infer creation time, ordering or tenancy from their representation.
6. Infrastructure services that create contract resources must use a standards-conforming UUIDv7 implementation and compatibility fixtures.

## Consequences

- Inserts retain better index locality than random UUIDv4 identifiers while preserving global uniqueness.
- PostgreSQL can enforce UUID types for primary and foreign keys without extra extensions.
- Every write path must generate an identifier; bulk import and migration tools need explicit UUIDv7 handling.
- UUID timestamps are metadata, not authorization or billing evidence, and must never replace recorded timestamps.
- Migrating legacy identifiers requires a separate mapping and cutover work packet.