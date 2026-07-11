# Lrail Control Plane

The Ruby on Rails product and control plane for Lrail. It is being built beside the current FastAPI application until behavior-parity and cutover gates pass.

## Toolchain

- Ruby 3.4.10
- Rails 8.1.3
- RSpec Rails 8.0.4
- PostgreSQL 16 in local development

## Development

From the repository root, `scripts/start.sh` starts the current application and this control plane in development mode. The Rails service is available directly at `http://localhost:3001` and through Traefik at `http://control.localhost`.

Use `scripts/compose.sh logs -f control-plane` for logs. The development entrypoint waits for PostgreSQL and applies pending Rails migrations before Puma starts.

## Tests

Run the control-plane test suite through the development image:

```text
scripts/compose.sh run --rm -e RAILS_ENV=test control-plane bundle exec rspec
```

Rails uses its own development and test databases on the shared local PostgreSQL server. It never migrates or imports the legacy application's schema.
