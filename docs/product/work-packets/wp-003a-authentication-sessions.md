# WP-003A: Rodauth authentication sessions

- Phase: 1 - Behavior parity
- Status: Implemented; revised by ADR-011
- Owner: `apps/control_plane`, `contracts/openapi`
- Dependencies: WP-003, WP-005
- Requirements: GOAL-004, INV-007, INV-010, INV-011

## Objective

Provide Rails-owned passwordless browser authentication and API Bearer sessions through Rodauth while preserving explicit organization authorization, local operation without SaaS credentials and the published v1 authentication contract.

## Authentication boundary

Rodauth Rails is the only authentication engine. It owns login, logout, email authentication, active sessions, JWT handling, CSRF integration and configured GitHub/Google OmniAuth callbacks. Application controllers read the Rodauth principal; they do not parse or authenticate credentials independently.

Pundit and `Membership` remain separate authorization concerns. A successful authentication does not imply access to any organization.

## Browser flow

- `GET /auth/login` renders the legacy-matched LayerRail sign-in page.
- `POST /auth/login` asks Rodauth to issue a passwordless email link.
- `GET /auth/verify?key=...` stores the key in the encrypted session and redirects to query-free `GET /auth/verify`.
- `POST /auth/verify` is CSRF-protected, atomically claims the one-time key and creates the Rodauth browser session.
- `POST /auth/logout` removes the current PostgreSQL active-session row, clears login state and redirects to login.
- `/` and organization UI routes require a live Rodauth browser session.

The Rails cookie is encrypted, HTTP-only, SameSite=Lax, secure in production and bounded by `AUTH_TOKEN_TTL_DAYS`. Rodauth checks the active-session whitelist on every request; a copied cookie cannot be reused after logout.

Development writes mail to `tmp/mails` when SMTP is absent and exposes a development-only link from the check-email page. Production requires the configured SMTP and control-plane host.

## Provider flow

Rodauth OmniAuth exposes GitHub when `GITHUB_APP_CLIENT_ID` and `GITHUB_APP_CLIENT_SECRET` are configured and Google when `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` are configured. Provider identities are persisted separately from GitHub App installation credentials. Unknown provider identities cannot create accounts after the initial organization exists.

Every auth view uses the legacy FastAPI visual shell: logo header, centered 320-pixel form stack, matching input/buttons/separator, responsive sizing, accessible labels/loading states and persisted light/dark preference.

## API flow

The unchanged v1 adapter exposes:

- `POST /v1/auth/challenges` for a generic link request;
- `POST /v1/auth/sessions` for one-time key exchange;
- `GET /v1/auth/me` for the authenticated identity and organizations; and
- `DELETE /v1/auth/session` for current-session revocation.

Exchange returns a Rodauth JWT once with `Bearer`, expiry, user and nullable organization. JWTs carry fixed issuer/audience and expiry claims plus the Rodauth session. Every request checks the corresponding PostgreSQL active-session row. Invalid, expired or revoked JWTs return HTTP 401. API controllers require Bearer authentication and deliberately reject browser-cookie fallback.

## Bootstrap and abuse controls

Before an initial organization exists, a normalized email may be staged as a bootstrap candidate. Passwordless verification elects one owner under a PostgreSQL advisory lock, creates one organization/membership and activates that identity. Concurrent losers are blocked. After bootstrap, only provisioned users may authenticate; challenge responses remain generic.

A unique digest-only claim makes a Rodauth email key single-use even under concurrent POSTs. Request-attempt rows store HMAC digests rather than email/IP plaintext and enforce five requests per email and twenty per IP in 15 minutes under sorted advisory locks. Rodauth also keeps one current email-auth key per account and suppresses immediate resends.

## Persistence and migration

Rodauth uses `user_email_auth_keys`, `user_active_session_keys` and `user_identities`. Session identifiers are HMAC-protected in PostgreSQL. One-time claims and request evidence use application-generated UUIDv7 records with digest constraints.

The prior custom `authentication_sessions` and `login_challenges` tables are archived as `legacy_authentication_sessions` and `legacy_login_challenges`. No runtime model or middleware loads them. This preserves reversible migration evidence without running two auth systems.

## Acceptance evidence

- Rodauth is the only middleware that authenticates browser or API credentials.
- Browser login, query-free confirmation, authenticated home and logout pass request and live-browser tests.
- Legacy and Rails login screenshots share the same layout, dimensions and controls.
- GitHub request phase is routed through Rodauth; Google is registered conditionally.
- API challenge/exchange/me/logout responses pass OpenAPI schemas.
- Browser cookies cannot authenticate API routes.
- JWTs fail closed when malformed, expired or absent from the active-session whitelist.
- A one-time key produces one session under concurrent exchange.
- Concurrent first identities produce one organization owner.
- Concurrent requests cannot exceed the email/IP budgets.
- Raw one-time keys, JWTs, emails and IP addresses are absent from security evidence rows and filtered from logs.
- Fresh migration, rollback/reapply, RSpec, RuboCop, Zeitwerk, Bundler Audit and Brakeman checks pass.

## Deferred work

Invitation/member management will provision later identities and record security audit events. MFA can be added through Rodauth features and policy assurance checks. Distributed edge abuse controls remain required before public self-service.

## Rollback

Revoke all Rodauth active sessions before disabling Rodauth. Restore archived table names only as part of an explicit forward or reversible migration, and restore a safe login boundary before removing the middleware. Never accept Rodauth and legacy credentials simultaneously.
