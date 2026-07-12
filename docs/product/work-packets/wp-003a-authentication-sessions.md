# WP-003A: Authentication sessions

- Phase: 1 - Behavior parity
- Status: Implemented
- Owner: `apps/control_plane`, `contracts/openapi`
- Dependencies: WP-003, WP-005
- Requirements: GOAL-004, INV-007, INV-010, INV-011

## Objective

Replace the test-only principal seam with Rails-owned passwordless browser sessions and API bearer sessions while preserving explicit organization authorization. Authentication works locally without OAuth/SaaS credentials, remains revocable in PostgreSQL and is ready for a later MFA policy.

## Session design

Authentication uses opaque random credentials rather than stateless JWTs. `AuthenticationSession` persists only a SHA-256 token digest, immutable kind (`web` or `api`), immutable assurance level (`single_factor` or `multi_factor`), issue/expiry times, optional HMAC-digested request context and revocation state. Raw session tokens are returned once and never stored.

Web and API credentials have distinct prefixes and cannot cross contexts. Browser controllers accept only an HTTP-only, SameSite=Lax web cookie. Versioned API controllers accept only `Authorization: Bearer` API sessions and deliberately reject web-cookie fallback, preventing cookie-authenticated API CSRF. Sessions expire after the configured `AUTH_TOKEN_TTL_DAYS`; revocation is durable and irreversible.

The Rack middleware resolves credentials before controllers and provides the authenticated `User`, `AuthenticationSession` and method through a private request environment seam. Existing request injection remains only as an internal test seam and cannot be supplied through HTTP headers.

## One-time email challenges

`LoginChallenge` stores normalized email, purpose, token digest, request-IP HMAC, expiry and delivery/consumption state. The raw challenge token is encrypted with Active Record Encryption for email delivery and is cleared atomically on use. It is never included in API responses or default inspection.

Challenges expire after `MAGIC_LINK_TTL_SECONDS`, work once and are serialized by PostgreSQL advisory locks. Rate limits allow five requests per email and twenty per IP in 15 minutes; separate sorted email/IP locks keep those limits correct under concurrency. Responses are generic for valid addresses and silently accept a rate-limited request to avoid account enumeration.

The first verified identity atomically bootstraps the initial organization and owner membership. After an organization exists, unknown emails cannot self-register; later users must be pre-provisioned by the invitation workflow. Existing users without a membership may authenticate but receive no organization until invited.

## Browser flow

- `GET /auth/login` renders the responsive LayerRail passwordless login.
- `POST /auth/login` issues and emails a challenge under Rails CSRF protection.
- `GET /auth/verify` validates without consumption, moves the token into a temporary encrypted HTTP-only cookie and redirects to a query-free confirmation page.
- `POST /auth/verify` consumes the challenge under CSRF protection, creates a web session and sets the secure production cookie.
- `POST /auth/logout` revokes the current session, clears the cookie and redirects to login.
- `/` requires a web session and presents the authenticated identity/organization landing page.

Development uses durable file mail under `tmp/mails` when SMTP is absent and shows a development-only shortcut after challenge creation. Production requires SMTP and `CONTROL_PLANE_HOST`; mail failures are not silently treated as successful delivery.

## API flow

The additive v1 contract includes:

- `POST /v1/auth/challenges` (public generic challenge request);
- `POST /v1/auth/sessions` (public one-time exchange);
- `GET /v1/auth/me` (bearer-protected identity and organization list); and
- `DELETE /v1/auth/session` (bearer session revocation).

Successful exchange returns the opaque API token once with expiry, user and nullable organization. All protected product API endpoints now work with live bearer credentials; invalid, expired, revoked and wrong-kind credentials produce the existing 401 contract.

## Security and persistence

Authentication IDs are application-generated UUIDv7 values with no database defaults. PostgreSQL enforces user ownership, token-digest uniqueness/format, session kind/assurance, issue-before-expiry, revocation consistency, normalized email, one supported challenge purpose and challenge consumption state. Models are append-only; revoked sessions and consumed challenges cannot be restored or deleted.

Email, token, authorization and cookie parameters are filtered from Rails logs. Model inspection redacts token and email-sensitive challenge data. IP and user-agent metadata are stored only as keyed HMAC digests. The same existing encryption root derives Active Record Encryption and context HMAC keys; no new plaintext secret is introduced.

## Acceptance evidence

- Raw API/web session tokens never enter PostgreSQL; challenge tokens are encrypted and cleared on use.
- API and web session kinds cannot cross authentication contexts.
- Invalid, expired and revoked credentials fail closed.
- Challenge replay fails and concurrent exchange creates one user/session.
- Concurrent first identities create exactly one initial organization/owner.
- Concurrent challenge requests cannot exceed the per-email budget.
- Unknown identities cannot self-register after bootstrap and receive no existence signal at challenge request time.
- API challenge/session/current-identity responses pass OpenAPI schemas.
- Browser login is CSRF-protected, responsive and verified live through challenge consumption, authenticated home and logout.
- Direct SQL rejects inconsistent revocation/consumption state and unknown-user sessions.
- The final migration was reset, rolled back and reapplied in development/test with byte-stable schema output.
- The complete control-plane CI passes with 231 examples, RuboCop, Zeitwerk, Bundler Audit, Importmap Audit and Brakeman.

## Deferred work

The invitation/member-management flow provisions later identities and records security audit events. A future MFA work packet can issue `multi_factor` sessions and require that assurance level for sensitive policies without changing token shape. GitHub/Google OAuth may become additional challenge issuers, but GitHub App installation credentials remain separate from user authentication. Broader distributed edge rate limiting and abuse controls are required before public self-service.

## Rollback

Before sessions are used in production, roll back the authentication migration and remove middleware/routes/controllers. Once live sessions exist, revoke them and use a forward migration; do not drop token history while credentials could remain active. Removing browser authentication must also restore a safe root route rather than exposing authenticated content.
