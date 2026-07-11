# WP-003: Identity, organizations, memberships and policy boundary

- Phase: 0 - Foundation
- Status: Implemented
- Owner: `apps/control_plane`
- Dependencies: WP-002, ADR-003
- Requirements: GOAL-004, INV-001, INV-007, FR-ORG-001

## Objective

Create the tenancy foundation with UUIDv7 identities, organizations, memberships and an authorization boundary that fails closed across organizations.

## Domain invariants

- Rails generates every primary key with `SecureRandom.uuid_v7` before validation.
- PostgreSQL stores primary and foreign keys as native UUIDs and has no UUIDv4 fallback default.
- Email addresses are normalized and uniquely indexed case-insensitively.
- A user can have only one membership in an organization.
- Membership roles are limited to owner, admin and member by both Rails and PostgreSQL.
- Organization creation and its initial owner membership commit in one transaction.
- Generic membership actions cannot change or remove an owner; ownership transfer requires a dedicated future workflow.

## Authorization boundary

`AuthorizationContext` always carries an explicit principal and selected organization and resolves membership from PostgreSQL. Pundit policies default to denial. Organization and membership policies verify both selected-organization ownership and role before authorizing behavior or returning scoped records.

The controller integration returns an empty context until authentication and organization selection are implemented, so an unconfigured action fails closed rather than accidentally authorizing a request.

## Acceptance evidence

- UUIDv7 format and absence of database defaults are tested.
- PostgreSQL uniqueness and role constraints are exercised directly.
- Invalid organization creation and unpersisted principals leave no partial tenant state.
- Owner, admin and member capabilities are covered.
- A principal from another organization cannot view, update, destroy or scope foreign records.
- The migration was applied, rolled back and reapplied against PostgreSQL.
- CI recreates the test database from migrations and rejects a stale `schema.rb`.

## Deferred work

Sessions, MFA, invitations, role-change audit events, ownership transfer and customer-facing organization routes belong to later approved work packets. Their absence must not be bypassed with controller-local authorization.

## Rollback

Before production data exists, run the migration rollback against the isolated Rails database, remove the models/services/policies and restore the previous schema file. The migration has been exercised in both directions. Once customer identity data exists, use an expand/migrate/contract change instead of rolling this table set back destructively.