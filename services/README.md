# Infrastructure services

Purpose-built workflow, build, runtime and usage components live here. They authenticate with workload identity, use least privilege and communicate through versioned contracts.

Rails remains the product source of truth. Infrastructure services reconcile desired state and return explicit, idempotent operation results without exposing provider-specific objects to customers.