# Contracts

Versioned public and internal interfaces live here:

- `openapi/` for HTTP APIs.
- `events/` for JSON Schema event contracts.
- `protobuf/` only after an ADR approves gRPC.

Every cross-component request or event requires a versioned schema and compatibility test. Rails owns the customer-facing contract.