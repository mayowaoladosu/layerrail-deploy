from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
from urllib.parse import urlsplit


@dataclass(frozen=True)
class Settings:
    state_dir: Path
    shared_secret_path: Path
    registry_admin_secret_path: Path
    artifact_admin_secret_path: Path
    signing_key_path: Path
    control_plane_url: str
    control_plane_host: str | None
    registry_auth_url: str
    registry_service: str
    registry_endpoint: str
    artifact_gateway_url: str
    namespace: str
    worker_image: str
    trivy_path: Path
    port: int
    reconcile_interval: float
    build_timeout_seconds: int
    result_grace_seconds: int
    max_result_bytes: int
    max_static_archive_bytes: int
    max_log_lines: int
    max_critical_vulnerabilities: int

    @classmethod
    def from_env(cls) -> "Settings":
        value = cls(
            state_dir=Path(
                os.environ.get(
                    "BUILD_CONTROLLER_STATE_DIR", "/var/lib/lrail-build-controller"
                )
            ),
            shared_secret_path=Path(
                os.environ.get(
                    "BUILD_CONTROLLER_SHARED_SECRET_PATH",
                    "/run/lrail-build-controller/shared-secret",
                )
            ),
            registry_admin_secret_path=Path(
                os.environ.get(
                    "BUILD_CONTROLLER_REGISTRY_ADMIN_SECRET_PATH",
                    "/run/lrail-build-controller/registry-admin-secret",
                )
            ),
            artifact_admin_secret_path=Path(
                os.environ.get(
                    "BUILD_CONTROLLER_ARTIFACT_ADMIN_SECRET_PATH",
                    "/run/lrail-build-controller/artifact-admin-secret",
                )
            ),
            signing_key_path=Path(
                os.environ.get(
                    "BUILD_CONTROLLER_SIGNING_KEY_PATH",
                    "/run/lrail-build-controller/signing-key.pem",
                )
            ),
            control_plane_url=os.environ.get(
                "BUILD_CONTROLLER_CONTROL_PLANE_URL",
                "http://host.minikube.internal:3001",
            ),
            control_plane_host=os.environ.get(
                "BUILD_CONTROLLER_CONTROL_PLANE_HOST", "control.localhost"
            ),
            registry_auth_url=os.environ.get(
                "BUILD_CONTROLLER_REGISTRY_AUTH_URL",
                "http://registry-auth.lrail-system.svc.cluster.local:8080",
            ),
            registry_service=os.environ.get(
                "BUILD_CONTROLLER_REGISTRY_SERVICE", "lrail-alpha-registry"
            ),
            registry_endpoint=os.environ.get(
                "BUILD_CONTROLLER_REGISTRY_ENDPOINT",
                "registry.lrail-system.svc.cluster.local:5000",
            ),
            artifact_gateway_url=os.environ.get(
                "BUILD_CONTROLLER_ARTIFACT_GATEWAY_URL",
                "http://artifact-gateway.lrail-system.svc.cluster.local:8080",
            ),
            namespace=os.environ.get("BUILD_CONTROLLER_NAMESPACE", "lrail-builds"),
            worker_image=os.environ.get(
                "BUILD_CONTROLLER_WORKER_IMAGE", "lrail-build-worker:dev"
            ),
            trivy_path=Path(os.environ.get("BUILD_CONTROLLER_TRIVY_PATH", "/usr/local/bin/trivy")),
            port=int(os.environ.get("BUILD_CONTROLLER_HTTP_PORT", "8080")),
            reconcile_interval=float(
                os.environ.get("BUILD_CONTROLLER_RECONCILE_INTERVAL", "0.5")
            ),
            build_timeout_seconds=int(
                os.environ.get("BUILD_CONTROLLER_BUILD_TIMEOUT_SECONDS", "900")
            ),
            result_grace_seconds=int(
                os.environ.get("BUILD_CONTROLLER_RESULT_GRACE_SECONDS", "15")
            ),
            max_result_bytes=int(
                os.environ.get("BUILD_CONTROLLER_MAX_RESULT_BYTES", "48000000")
            ),
            max_static_archive_bytes=int(
                os.environ.get("BUILD_CONTROLLER_MAX_STATIC_ARCHIVE_BYTES", "33554432")
            ),
            max_log_lines=int(
                os.environ.get("BUILD_CONTROLLER_MAX_LOG_LINES", "1000")
            ),
            max_critical_vulnerabilities=int(
                os.environ.get("BUILD_CONTROLLER_MAX_CRITICAL", "0")
            ),
        )
        value.validate()
        return value

    def validate(self) -> None:
        for path in (
            self.shared_secret_path,
            self.registry_admin_secret_path,
            self.artifact_admin_secret_path,
            self.signing_key_path,
        ):
            if not path.is_absolute():
                raise ValueError("build controller secret paths must be absolute")
        for value in (
            self.control_plane_url,
            self.registry_auth_url,
            self.artifact_gateway_url,
        ):
            parsed = urlsplit(value)
            if (
                parsed.scheme not in {"http", "https"}
                or not parsed.hostname
                or parsed.username
                or parsed.password
                or parsed.query
                or parsed.fragment
            ):
                raise ValueError("build controller URL is invalid")
        if not self.namespace or len(self.namespace) > 63:
            raise ValueError("build namespace is invalid")
        if not self.worker_image or len(self.worker_image) > 512:
            raise ValueError("build worker image is invalid")
        if not 1 <= self.port <= 65535:
            raise ValueError("build controller port is invalid")
        if not 0.05 <= self.reconcile_interval <= 30:
            raise ValueError("reconcile interval is invalid")
        if not 60 <= self.build_timeout_seconds <= 3600:
            raise ValueError("build timeout is invalid")
        if not 1 <= self.result_grace_seconds <= 300:
            raise ValueError("result grace is invalid")
        if not 1 << 20 <= self.max_result_bytes <= 64 << 20:
            raise ValueError("result size limit is invalid")
        if not 1 << 20 <= self.max_static_archive_bytes <= 48 << 20:
            raise ValueError("static archive size limit is invalid")
        if not 1 <= self.max_log_lines <= 2000:
            raise ValueError("log line limit is invalid")
        if not 0 <= self.max_critical_vulnerabilities <= 1000:
            raise ValueError("critical policy limit is invalid")
