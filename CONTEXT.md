# Lrail Domain Language

## Identity and tenancy

- **User**: A human identity that can authenticate to Lrail.
- **Organization**: The customer tenancy, authorization, and billing boundary. Every customer-owned resource belongs to exactly one organization.
- **Membership**: A user's role within one organization.
- **Principal**: The authenticated user acting on a request or command.

## Projects and workloads

- **Project**: A group of related services and environments that are operated and released together.
- **Service**: One deployable workload with a workload type, source, and runtime policy.
- **Workload type**: The execution behavior of a service, such as a web service, worker, cron task, job, private service, or static site.
- **Source**: The Git repository or OCI image configuration from which a service creates deployments.
- **Runtime policy**: The bounded operational settings that apply when a service revision runs.
- **Environment**: A named release context within a project, such as production or staging. An environment can apply across multiple services in the same project.
- **Branch mapping**: The optional association between one Git branch and one environment in a project.

## Git providers

- **Git provider**: An external source-control system connected to Lrail through an installation and a provider-neutral interface.
- **Installation**: A provider authorization grant for one external account and its selected repositories.
- **Repository**: A provider-owned source repository visible through an installation.
- **Provider user**: An external source-control identity that can be mapped to a Lrail user or recorded as a source actor.
- **Clone credential**: A short-lived secret that authorizes one build plane operation to fetch an approved repository revision.
- **Webhook delivery**: One signed provider notification with a provider delivery identifier.
- **Normalized Git event**: A verified provider notification expressed in Lrail's provider-neutral vocabulary.

## Deployments and routing

- **Deployment**: One attempt to turn a source snapshot into a runnable candidate.
- **Build**: One execution attempt that produces an immutable artifact for a deployment.
- **Revision**: An immutable runnable artifact combined with a frozen configuration and runtime policy.
- **Alias**: An atomic hostname or environment pointer to a ready revision.
- **Promotion**: Moving an alias to a ready revision without mutating or rebuilding that revision.
- **Rollback**: Moving an alias back to an existing healthy revision without rebuilding it.