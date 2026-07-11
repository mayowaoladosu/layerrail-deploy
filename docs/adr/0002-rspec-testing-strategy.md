# ADR-002: RSpec testing strategy

- Status: Accepted
- Date: 2026-07-11
- Requirements: GOAL-002, GOAL-004, INV-005, INV-007, WP-001

## Context

The specification permits RSpec or Minitest but requires one consistent framework. The control plane needs readable behavior specifications for authorization, tenant isolation, state transitions, idempotency and provider contracts.

## Decision

1. Use RSpec Rails 8.0.4 as the sole Rails test framework.
2. Generate Rails without Minitest files and configure generators to create RSpec examples.
3. Organize tests by boundary: model/domain, request, policy, service, provider contract, job/workflow and system.
4. Every organization-owned resource receives positive ownership coverage and cross-organization fail-closed coverage.
5. Every remote or event-driven operation receives retry, duplicate-delivery, stale-callback and partial-failure coverage where applicable.
6. Prefer real PostgreSQL integration tests for constraints, transactions, inbox/outbox behavior and locking. Use fakes only at explicit provider boundaries.
7. Run focused examples during implementation, then the full RSpec suite and applicable security/contract gates before completing a work packet.

## Consequences

- Rails-generated Minitest files are disabled to avoid two competing conventions.
- RSpec is a required development and test dependency and is version-pinned with the application.
- Tests intentionally carry more tenant and failure-path cases than a conventional CRUD application.
- Provider adapters need deterministic contract suites that can be shared by fake and real implementations.