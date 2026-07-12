# Applications

Customer-facing and control-plane applications live here.

- `control_plane/` is the authoritative Ruby on Rails product and control plane.
- `local_provider/` is the development-only infrastructure provider that reconciles the trusted sample behind signed contracts; it has no Rails imports or database access.
- The existing root `app/` FastAPI application remains a read-only behavioral reference during the phased rebuild and continues to serve the current product until a verified cutover.

Applications must communicate with infrastructure services through versioned contracts. They must not import service implementation code or execute customer workloads.