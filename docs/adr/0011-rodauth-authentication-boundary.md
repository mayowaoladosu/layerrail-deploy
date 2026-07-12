# ADR-0011: Rodauth authentication boundary

- Status: Accepted
- Date: 2026-07-12
- Decision owners: Product and platform engineering
- Requirements: GOAL-004, INV-007, INV-010, INV-011
- Supersedes: the custom authentication implementation described by WP-003A

## Context

The first Rails authentication slice implemented passwordless challenges, browser sessions and API tokens as application-specific models and services. That duplicated security-sensitive framework behavior and produced authentication pages that no longer matched the legacy FastAPI product during the side-by-side rebuild.

The control plane needs one authentication authority, revocable browser and API sessions, passwordless local development, optional provider login and explicit organization authorization. Product authorization remains separate from authentication.

## Decision

Rodauth Rails is the sole authentication framework for the Rails control plane. The enabled boundary consists of Rodauth login, logout, email authentication, active sessions, JWT, internal requests and path helpers. Rodauth OmniAuth owns configured GitHub and Google provider login. No application controller, model or middleware independently authenticates a credential.

Browser authentication uses the Rails encrypted cookie session plus Rodauth's PostgreSQL active-session whitelist. The cookie is HTTP-only, SameSite=Lax, secure in production and expires after the configured 30-day maximum lifetime. Logout deletes the active-session row, so replaying an old cookie fails closed.

API authentication uses a Rodauth JWT in the Bearer header. Tokens include fixed issuer and audience claims, issue and expiry times, and the Rodauth session payload. Every authenticated API request also checks the same PostgreSQL active-session whitelist, making logout and administrative revocation effective before JWT expiry. API controllers require a valid Bearer JWT and never fall back to the browser cookie.

Passwordless login uses Rodauth email-auth keys with a 15-minute deadline. A link GET moves the key into the session and redirects to a query-free confirmation page; only the CSRF-protected POST consumes it. A digest-only unique login claim prevents concurrent double consumption. PostgreSQL advisory locks elect exactly one initial organization owner. Unknown identities cannot self-register after bootstrap.

Application-owned request-attempt records are abuse-control evidence, not a second authentication system. They store only HMAC digests and enforce five requests per email and twenty per IP in 15 minutes under advisory locks. Pundit and organization memberships remain the authorization boundary.

All Rails authentication pages use the legacy FastAPI auth shell: the 65-pixel logo header, centered 320-pixel form stack, matching controls, responsive behavior and persisted light/dark preference. Authentication behavior and HTML routes are nevertheless served only by Rodauth.

The replaced authentication tables are renamed with a `legacy_` prefix for reversible pre-production migration evidence. Runtime code does not load their models or inspect their credentials.

## Consequences

Authentication lifecycle, CSRF integration, email login, provider callbacks, session cookies and JWT parsing use maintained Rodauth behavior. GitHub and Google buttons appear only when their credentials are configured; email login remains available without SaaS credentials.

The v1 authentication adapter preserves the published challenge, session, current-identity and logout response shapes. API credentials change from custom opaque values to Rodauth JWTs, which the contract already treats as opaque strings.

Browser and API sessions share revocation storage but remain context-separated. MFA can be added as a Rodauth feature without replacing the principal or organization policy seams.

## Rollback

Disable the Rodauth middleware only after restoring a safe authentication implementation and revoking every Rodauth active session. The forward migration can restore the archived table names before production use. Do not run both authentication engines or accept fallback credentials during rollback.
