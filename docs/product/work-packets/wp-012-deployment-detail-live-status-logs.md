# WP-012: Deployment detail and live status/log UI

- Phase: 1 - Behavior parity
- Status: Implemented
- Owner: `apps/control_plane`, `apps/local_provider`, `contracts/provider`, `contracts/openapi`
- Dependencies: WP-008, WP-010
- Requirements: FR-DEP-001, FR-DEP-002, FR-DEP-003, FR-OBS-001, INV-003, INV-004, INV-005, INV-007, INV-008, INV-011

## Objective

Provide an organization-scoped Deployment history and detail experience whose status survives refresh, whose live region updates from durable state, whose build/runtime output remains bounded and redacted, and whose cancel, redeploy, promote, and rollback controls match authorization and state.

## Browser experience

Authenticated users enter the canonical Devpush team dashboard, filter a project's Deployment history by environment, status, date and branch, and inspect one Deployment through the existing team/project/Deployment route hierarchy. The detail view uses the original Devpush header, menus, status language, metadata rows, route popover, action menu and 500-pixel log panel. It presents status, environment, service, source reference/digest, initiating actor, timestamps, execution duration, trigger, local resource size, immutable and environment URLs, current/previous Alias pointers, structured failure context, Build/runtime/system logs, and the complete persisted transition timeline.

Semantic landmarks, headings, lists, definition lists, `<time>` elements, labels, focus-visible styles, a skip link, reduced-motion behavior, and status/error live regions form the accessibility baseline. Desktop and narrow mobile layouts are responsive. Loading, empty, partial, error, success, terminal, active, and retained-log states are explicit.

A Stimulus controller polls a Turbo Stream endpoint without cache. The endpoint re-queries PostgreSQL and the provider on every request. A digest of Deployment/Alias/log state returns HTTP 304 when nothing changed; otherwise Turbo replaces the legacy Deployment header, structured failure, log panel and persisted history. The saved state remains useful when JavaScript, the provider, or the network is unavailable.

## Logs

Rails implements the existing `GET /v1/deployments/:deployment_id/logs` contract. It merges append-only Deployment transitions, Build lifecycle timestamps, and provider runtime output into bounded timestamp order. An opaque cursor supports tailing new entries. Runtime unavailability returns persisted history with `X-Lrail-Logs-Partial: true` rather than failing the whole request.

The provider exposes a versioned HMAC-authenticated log response bound to organization and Deployment IDs. It verifies managed-container identity before reading Docker. The constrained proxy permits only the exact container log endpoint in addition to the WP-010 lifecycle allowlist. Messages are timestamped, capped at 4096 characters, and redact authorization, token, password, secret, and API-key patterns before crossing the provider boundary. Internal health probes are suppressed.

Before cancellation deletes a container, the provider stores at most 200 redacted entries in its durable SQLite state. Terminal detail pages can therefore display and download the latest retained runtime output alongside permanent Build and transition history. Raw unredacted logs are never persisted by Rails or the provider.

## Actions and safety

Members can view and download logs but cannot mutate Deployments or Aliases. Owners/admins receive only actions valid for the current state:

- cancel only a non-terminal, non-serving Deployment;
- redeploy only after a stable ready/terminal/superseded outcome, reusing immutable source while resolving current configuration;
- promote only an active ready or superseded Deployment with a ready Revision; and
- roll back only the currently serving Deployment to the Alias's exact previous ready Revision and expected lock version.

Every destructive or routing action requires an explicit impact confirmation. Controllers re-check policy, state, tenant, readiness, and optimistic version independently of visibility. Canceled runtimes cannot be promoted, immutable URLs become non-clickable after removal, rollback creates no Build, and repeated redeploy form submission with one operation ID creates one Deployment.

## Acceptance evidence

- Browser request specs cover web-session enforcement, member/owner behavior, cross-organization 404s, semantic accessibility markers, live Turbo 304/replace behavior, retained logs, downloads, all four actions, stale/state restrictions, rollback Build count, and redeploy deduplication.
- A dedicated presentation contract verifies the original compiled asset bytes, canonical team/project/Deployment URLs and representative Devpush classes while rejecting the removed parallel-dashboard vocabulary. Behavior assertions continue to cover every WP-012 field and action independently.
- Service/API specs cover outbound signing, strict provider parsing, bounded redacted provider schema, persisted/runtime merge, opaque cursors, partial history, invalid pagination, and tenant fail-closed behavior.
- Provider tests cover inbound HMAC verification, redaction, internal-probe suppression, Docker identity binding, bounded tails, retained snapshots, and cross-tenant conflicts.
- The real provider E2E proves active signed runtime-log reads and retained output after cancellation while preserving deploy, promote, rollback, cancellation, and Docker isolation checks.
- Browser QA verifies real authenticated history/detail pages, live and retained log states, client-side search/stream filtering, responsive narrow layout, generated links, release pointers, and action presentation.
- Canceled previous revisions remain visible as history but cannot be promoted or offered as rollback targets; the provider reports the actual local CPU/memory limits in readiness evidence.
- Twelve provider tests and 24 focused WP-012 contract/service/request examples pass, with additional Alias routing regressions in the complete suite.
- The complete control-plane CI passes 288 examples, RuboCop, Zeitwerk, Bundler Audit, Importmap Audit, and Brakeman.
- Migration `20260711218000` normalizes two lifecycle constraints to cross-platform-stable SQL, rolls down/up in development and test, and preserves a byte-identical schema dump.

## Deliberate limits

WP-011 is an isolation proof rather than a Git build service, so repository BuildKit progress output does not yet exist. The Build stream is generated from authoritative Build lifecycle records; runtime lines come from the trusted WP-010 sample. Search and stream filters operate over the bounded visible tail; provider-level indexed search, arbitrary retention windows, and telemetry export remain later observability work.

Resource size reflects the fixed WP-010 local runtime policy. General per-service size configuration and metering remain later phases. The default customer view intentionally avoids Docker, container, BuildKit, pod, and provider-controller terminology.

## Rollback

Remove the organization-scoped UI/controllers/Stimulus files, public log route, provider log route, and additive provider response schema. Revert the exact Docker `/containers/:id/logs` proxy allowlist entry. Provider SQLite's additive `runtime_logs` table may remain harmlessly until a forward cleanup; do not delete Deployment transitions, Builds, Revisions, Aliases, events, or receipts. Existing public `/v1/deployments/:id/logs` clients require a compatible forward response rather than silent removal once released.
