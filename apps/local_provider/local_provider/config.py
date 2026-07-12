from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    control_plane_url: str
    control_plane_host: str
    docker_host: str
    allowed_image_reference: str
    deploy_domain: str
    runtime_network: str
    state_dir: Path
    routes_dir: Path
    shared_secret_file: Path
    poll_interval_seconds: float
    health_port: int
    container_port: int = 8000

    @classmethod
    def from_env(cls) -> "Settings":
        settings = cls(
            control_plane_url=os.environ.get(
                "CONTROL_PLANE_URL", "http://control-plane:3000"
            ).rstrip("/"),
            control_plane_host=os.environ.get(
                "CONTROL_PLANE_HTTP_HOST", "control.localhost"
            ),
            docker_host=os.environ.get(
                "DOCKER_HOST", "tcp://local-docker-proxy:2375"
            ),
            allowed_image_reference=os.environ.get(
                "LOCAL_PROVIDER_ALLOWED_IMAGE_REFERENCE",
                "lrail-local-sample:dev",
            ),
            deploy_domain=os.environ.get("DEPLOY_DOMAIN", "localhost").lower(),
            runtime_network=os.environ.get("RUNTIME_NETWORK", "devpush_runner"),
            state_dir=Path(
                os.environ.get("LOCAL_PROVIDER_STATE_DIR", "/var/lib/lrail-provider")
            ),
            routes_dir=Path(
                os.environ.get("LOCAL_PROVIDER_ROUTES_DIR", "/var/lib/lrail-routes")
            ),
            shared_secret_file=Path(
                os.environ.get(
                    "LOCAL_PROVIDER_SHARED_SECRET_FILE",
                    "/run/lrail-provider-auth/secret",
                )
            ),
            poll_interval_seconds=float(
                os.environ.get("LOCAL_PROVIDER_POLL_INTERVAL_SECONDS", "1")
            ),
            health_port=int(os.environ.get("LOCAL_PROVIDER_HEALTH_PORT", "9000")),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        if not self.control_plane_url.startswith(("http://", "https://")):
            raise ValueError("CONTROL_PLANE_URL must be HTTP(S)")
        if not self.control_plane_host or any(
            character.isspace() for character in self.control_plane_host
        ):
            raise ValueError("CONTROL_PLANE_HTTP_HOST is invalid")
        if not self.docker_host.startswith(("http://", "https://", "tcp://", "unix://")):
            raise ValueError("DOCKER_HOST must use a supported scheme")
        if self.allowed_image_reference != "lrail-local-sample:dev":
            raise ValueError("only the repository-owned local sample is allowed")
        if not self.deploy_domain or any(
            character not in "abcdefghijklmnopqrstuvwxyz0123456789.-"
            for character in self.deploy_domain
        ):
            raise ValueError("DEPLOY_DOMAIN is invalid")
        if self.poll_interval_seconds <= 0 or self.poll_interval_seconds > 60:
            raise ValueError("poll interval is invalid")
        if not 1 <= self.health_port <= 65535:
            raise ValueError("health port is invalid")
