# ADR-001: Ruby, Rails and repository baseline

- Status: Accepted
- Date: 2026-07-11
- Requirements: GOAL-002, GOAL-007, INV-006, WP-001

## Context

Lrail is replacing the current FastAPI control plane with a new Ruby on Rails control plane. The existing implementation is valuable as a behavioral reference, but a file-by-file translation would preserve single-host assumptions and couple product behavior to the old runtime.

The rebuild needs a reproducible toolchain and component boundaries before application code is generated. It must also preserve the running product while behavior is reproduced and verified incrementally.

## Decision

1. Pin Ruby 3.4.10 and Rails 8.1.3. Ruby 3.4.10 is the exact patch release exposed by the official `ruby:3.4-slim` image at project kickoff.
2. Place the Rails application in `apps/control_plane/`. It owns product behavior, public APIs and desired state.
3. Keep the existing root `app/` FastAPI application operational as a behavioral reference until explicit parity and cutover gates pass. New Rails code must not import Python implementation code.
4. Use the specification's top-level boundaries: `apps/`, `services/`, `contracts/`, `infrastructure/`, `docs/` and `samples/`.
5. Place durable workflow workers and infrastructure controllers in `services/`, behind versioned contracts owned by the control plane. User code never executes in Rails web, job, console or database contexts.
6. Use a separate Rails database in local development and test environments on the existing PostgreSQL server. Rails migrations must not claim or mutate the legacy application's tables. Any future data migration requires an explicit, reversible work packet.
7. Update exact patch versions through a superseding ADR or an amendment that records compatibility and security validation.

## Consequences

- The repository temporarily contains two control-plane implementations, which costs additional build and review time but enables behavior comparison and rollback.
- Shared implementation imports are prohibited; parity is established through contracts and tests.
- Infrastructure can evolve independently behind stable provider contracts.
- CI can reproduce the exact Ruby and Rails baseline before a full Rails application exists.