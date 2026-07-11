# ADR-004: Project-scoped environments

- Status: Accepted
- Date: 2026-07-11
- Requirements: GOAL-003, INV-002, FR-ENV-001, WP-004

## Context

Lrail projects can contain several related workloads, such as a web service and a worker, that move through production and staging together. An environment could belong to each service independently or belong to the project and be shared by its services.

Service-scoped environments make each workload self-contained, but they allow contradictory production and staging definitions inside one project and duplicate branch/configuration context. Project-scoped environments model the product release context once while deployments still identify the individual service being released.

The implementation specification defines an environment slug as unique within a project and describes projects as grouping related services and environments. The legacy application stored environments in a project-level JSON structure, but that storage format and its single-host deployment assumptions are not retained.

## Decision

1. An environment belongs to one project and can be used by every service in that project.
2. A service belongs to one project and represents one deployable workload.
3. A deployment will identify both its service and target environment; both must belong to the same project.
4. Environment slugs and branch mappings are unique within their project.
5. Each project has at most one production environment and at most one staging environment. Additional environments are custom contexts.
6. Environment-scoped configuration is shared project context. Future service-specific overrides must explicitly identify both service and environment rather than redefining environment ownership.

## Consequences

- Related services can be promoted through a consistent set of release contexts.
- Policies and queries scope environments through their project and organization.
- A service cannot carry an unrelated environment from another project.
- Deployment and configuration schemas must enforce service/project/environment compatibility.
- Migrating legacy project environment JSON remains possible without inventing one environment copy per service.