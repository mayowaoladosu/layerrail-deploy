from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    state_path: Path
    signing_key_path: Path
    admin_secret_path: Path
    issuer: str
    service: str
    token_ttl_seconds: int
    port: int

    @classmethod
    def from_env(cls) -> "Settings":
        settings = cls(
            state_path=Path(
                os.environ.get(
                    "REGISTRY_AUTH_STATE_PATH",
                    "/var/lib/lrail-registry-auth/registry-auth.sqlite3",
                )
            ),
            signing_key_path=Path(
                os.environ.get(
                    "REGISTRY_AUTH_SIGNING_KEY_PATH",
                    "/run/lrail-registry-auth/tls.key",
                )
            ),
            admin_secret_path=Path(
                os.environ.get(
                    "REGISTRY_AUTH_ADMIN_SECRET_PATH",
                    "/run/lrail-registry-auth/admin-secret",
                )
            ),
            issuer=os.environ.get(
                "REGISTRY_AUTH_ISSUER", "lrail-alpha-registry-auth"
            ),
            service=os.environ.get(
                "REGISTRY_AUTH_SERVICE", "lrail-alpha-registry"
            ),
            token_ttl_seconds=int(
                os.environ.get("REGISTRY_AUTH_TOKEN_TTL_SECONDS", "300")
            ),
            port=int(os.environ.get("REGISTRY_AUTH_HTTP_PORT", "8080")),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        if not self.issuer or len(self.issuer) > 120:
            raise ValueError("registry auth issuer is invalid")
        if not self.service or len(self.service) > 120:
            raise ValueError("registry auth service is invalid")
        if not 60 <= self.token_ttl_seconds <= 900:
            raise ValueError("registry token TTL must be 60-900 seconds")
        if not 1 <= self.port <= 65535:
            raise ValueError("registry auth port is invalid")
