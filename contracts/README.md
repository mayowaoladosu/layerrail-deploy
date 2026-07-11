# Contracts

Versioned public and internal interfaces live here:

- `openapi/` for HTTP APIs.
- `events/` for JSON Schema event contracts.
- `protobuf/` only after an ADR approves gRPC.

Every cross-component request or event requires a versioned schema and compatibility test. Rails owns the customer-facing contract.

## Versioning rules

- Public HTTP routes use the `/v1` server prefix. Mutations require `Idempotency-Key` and return a correlation identifier.
- Event types end in `.v<schema version>` and use the canonical envelope in `events/v1/`.
- Additive, optional fields may be introduced within a version. Removing operations or required fields, narrowing accepted values, or changing semantics requires a new version.
- Contract examples are executable fixtures. CI validates the documents and locks the minimum v1 operation surface.