# ADR-0012: Legacy Devpush dashboard presentation contract

- Status: Accepted
- Date: 2026-07-12
- Decision owners: Product and platform engineering
- Requirements: GOAL-001, GOAL-002, GOAL-007, FR-DEP-001, FR-DEP-002, FR-DEP-003, FR-OBS-001

## Context

The Rails rebuild initially introduced a separate control-plane dashboard with new layouts, component names and product vocabulary. Although its backend behavior was valid, it changed the product instead of translating the existing Devpush application from Python to Ruby. The rebuild must preserve the dashboard users already know while allowing Rails to own new durable behavior.

The FastAPI application has a complete Jinja2, HTMX, Alpine and Basecoat presentation under `app/templates` with compiled assets under `app/assets`. Rails uses different server-side and live-update primitives, but those implementation details do not require a different product interface.

## Decision

The existing Devpush dashboard is the presentation contract for the Rails control plane. Rails ports that interface to ERB and Rails controllers rather than designing a parallel dashboard.

Rails pages use the original compiled `styles.css`, Basecoat, Alpine, HTMX support files and icon set. The canonical team, project and Deployment hierarchy remains `/:team_slug`, `/:team_slug/projects/:project_name` and nested Deployment routes. Breadcrumbs, switchers, tabs, filters, empty states, dialogs, menus, status language, spacing and responsive behavior follow their corresponding Jinja templates.

New Rails behavior is added through existing Devpush components and visual vocabulary. Durable status, artifact evidence, route pointers, structured failures, redacted logs, actions and future Phase 2 state appear inside the legacy dashboard rather than in a second control-plane interface. A backend work packet may extend the dashboard when its behavior has no legacy equivalent, but it must compose that extension from the same assets and patterns. A visual redesign requires explicit product approval and a superseding decision.

Rails may use Turbo Streams and Stimulus behind the interface where they provide equivalent or stronger refresh-safe behavior. It does not import or execute Python modules, share the FastAPI database, or make Jinja a runtime dependency. The Jinja templates remain the behavioral and visual reference during the side-by-side rebuild.

Regression coverage checks the original asset bytes, canonical route hierarchy, representative shell/classes and the absence of the discarded parallel-dashboard vocabulary. Behavior specs separately retain routing, authorization, live refresh, structured failure, log filtering/download, retained output, promotion, rollback, redeploy and cancellation requirements.

## Consequences

The Ruby rebuild can replace implementation technology without surprising users with a simultaneous product redesign. Backend phases remain independently testable, while every user-visible capability accumulates in one familiar dashboard.

Rails keeps a read-only development/image mount of the canonical asset and icon directories until cutover. Changes to those shared files affect both implementations and must be verified in both applications. Rails-specific custom CSS is not used to recreate or override the product design.

Pages not yet owned by Rails continue to be ported from their matching Jinja pages as the required domain behavior ships. Missing behavior is not replaced by invented navigation, placeholder products or a separate SPA.

## Rollback

Before cutover, the Rails presentation slice can be removed without changing durable Deployment, Build, Revision, Alias, event, receipt or provider state; FastAPI remains available as the reference application. Do not restore the discarded parallel dashboard as a fallback. After Rails cutover, presentation corrections must be forward ports that preserve canonical routes and user workflows.
