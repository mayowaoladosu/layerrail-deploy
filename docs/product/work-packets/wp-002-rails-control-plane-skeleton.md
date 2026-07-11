# WP-002: Rails control-plane skeleton

- Phase: 0 - Foundation
- Status: Implemented
- Owner: `apps/control_plane`
- Dependencies: WP-001
- Requirements: GOAL-002, GOAL-007, INV-006

## Objective

Create a Rails 8.1.3 control-plane skeleton that boots with PostgreSQL, exposes a readiness endpoint and has executable request, lint, boot and security checks.

## Boundary

The Rails application runs beside the current FastAPI application during the rebuild. It has separate development and test databases on the local PostgreSQL server and does not import Python code, migrate legacy tables or execute customer workloads.

The current application remains available at `http://localhost`. The Rails development service is available at `http://localhost:3001` and `http://control.localhost`.

## Readiness contract

- `GET /up` is Rails process liveness.
- `GET /health` checks PostgreSQL with `SELECT 1`.
- A ready process returns HTTP 200 and `{"status":"ok"}`.
- A known Active Record failure returns HTTP 503 and `{"status":"unavailable"}` without database details.

## Acceptance evidence

- Ruby 3.4.10, Rails 8.1.3 and RSpec Rails 8.0.4 are pinned and printed in CI.
- The development container runs as a non-root user.
- Rails creates and prepares only `lrail_control_plane_development` and `lrail_control_plane_test`.
- Request specs cover ready and database-unavailable responses.
- CI runs database preparation, Zeitwerk eager loading, RSpec, RuboCop, Bundler Audit, Importmap Audit and Brakeman.
- The legacy application health endpoint remains green while Rails runs.

## Rollback

Remove `compose/control-plane.dev.yml` from the development Compose list in `scripts/lib.sh`, then stop and remove the `control-plane` service. The Rails databases and Docker volumes can be deleted independently because no legacy schema or customer data is referenced. Reverting this work packet does not require an Alembic rollback or changes to the current application.