# WP-005: Versioned API and event contracts

- Phase: 0 - Foundation
- Status: Implemented
- Owner: `contracts/`
- Dependencies: WP-001
- Requirements: INV-005, INV-007, INV-011, FR-API-001

## Objective

Define machine-validated public HTTP and cross-component event contracts before provider or API implementation begins.

## Decisions

- The public API uses OpenAPI 3.0.3 with a relative `/v1` server prefix.
- Mutating operations require the `Idempotency-Key` header.
- Long-running deployment, promotion, rollback, domain and scaling operations return HTTP 202 resources.
- Public resource identifiers remain opaque until the identifier ADR is approved; the contract does not expose sequential database IDs.
- Cross-component events use JSON Schema 2020-12 and the canonical v1 envelope.
- Every event carries organization, resource, correlation and idempotency identifiers. Additional top-level fields are rejected.

## Compatibility policy

Additive optional fields are allowed within v1. Removing a path or operation, removing a required response field, adding a required request field, narrowing accepted values or changing semantics requires a new version. The contract suite locks the minimum operation IDs and mutation idempotency requirement.

## Acceptance evidence

- `openapi3_parser` validates the complete OpenAPI document and all references.
- `json_schemer` validates the event schema against JSON Schema 2020-12.
- A versioned build-completed fixture is accepted.
- The same event without `organization_id` is rejected.
- Compatibility examples cover all twelve endpoints required by the implementation specification.
- The checks run as part of the control-plane RSpec and CI suites.

## Deferred decisions

The exact public identifier format, authentication scopes and administrative API surface require their own approved work packets. The current contracts deliberately avoid locking those choices.

## Rollback

Before any consumer ships, revert the contract files, validator dependencies, tests and read-only development mount together. After a consumer ships, published v1 files are immutable; corrections require an additive amendment or a new version rather than deleting or rewriting the consumed contract.