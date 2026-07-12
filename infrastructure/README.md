# Infrastructure

Production infrastructure is declared through OpenTofu/Terraform and GitOps after the initial cloud, region, isolation boundary and managed vendors are approved.

No infrastructure resource may exist solely through a human console action. This directory must not contain customer-provided Kubernetes objects or credentials.

The WP-011 rootless BuildKit profile is a local/CI isolation proof declared in `compose/control-plane.dev.yml`; it is not production infrastructure. ADR-0007 records its boundary and the stronger controls still required for a managed build plane.