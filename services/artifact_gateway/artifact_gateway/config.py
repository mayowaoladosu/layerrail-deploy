from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
from urllib.parse import urlsplit


@dataclass(frozen=True)
class Settings:
    endpoint: str
    access_key_path: Path
    secret_key_path: Path
    admin_secret_path: Path
    static_bucket: str
    evidence_bucket: str
    port: int
    max_archive_bytes: int
    max_expanded_bytes: int
    max_file_bytes: int
    max_file_count: int
    max_evidence_bytes: int

    @classmethod
    def from_env(cls) -> "Settings":
        settings = cls(
            endpoint=os.environ.get(
                "ARTIFACT_GATEWAY_S3_ENDPOINT",
                "http://minio.lrail-system.svc.cluster.local:9000",
            ),
            access_key_path=Path(
                os.environ.get(
                    "ARTIFACT_GATEWAY_S3_ACCESS_KEY_PATH",
                    "/run/lrail-artifacts/access-key",
                )
            ),
            secret_key_path=Path(
                os.environ.get(
                    "ARTIFACT_GATEWAY_S3_SECRET_KEY_PATH",
                    "/run/lrail-artifacts/secret-key",
                )
            ),
            admin_secret_path=Path(
                os.environ.get(
                    "ARTIFACT_GATEWAY_ADMIN_SECRET_PATH",
                    "/run/lrail-artifacts/admin-secret",
                )
            ),
            static_bucket=os.environ.get(
                "ARTIFACT_GATEWAY_STATIC_BUCKET", "lrail-static"
            ),
            evidence_bucket=os.environ.get(
                "ARTIFACT_GATEWAY_EVIDENCE_BUCKET", "lrail-evidence"
            ),
            port=int(os.environ.get("ARTIFACT_GATEWAY_HTTP_PORT", "8080")),
            max_archive_bytes=int(
                os.environ.get("ARTIFACT_GATEWAY_MAX_ARCHIVE_BYTES", str(32 << 20))
            ),
            max_expanded_bytes=int(
                os.environ.get("ARTIFACT_GATEWAY_MAX_EXPANDED_BYTES", str(64 << 20))
            ),
            max_file_bytes=int(
                os.environ.get("ARTIFACT_GATEWAY_MAX_FILE_BYTES", str(16 << 20))
            ),
            max_file_count=int(
                os.environ.get("ARTIFACT_GATEWAY_MAX_FILE_COUNT", "2000")
            ),
            max_evidence_bytes=int(
                os.environ.get("ARTIFACT_GATEWAY_MAX_EVIDENCE_BYTES", str(4 << 20))
            ),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        endpoint = urlsplit(self.endpoint)
        if endpoint.scheme not in {"http", "https"} or not endpoint.netloc:
            raise ValueError("artifact endpoint is invalid")
        for value in (
            self.access_key_path,
            self.secret_key_path,
            self.admin_secret_path,
        ):
            if not value.is_absolute():
                raise ValueError("artifact secret paths must be absolute")
        for bucket in (self.static_bucket, self.evidence_bucket):
            if not bucket or len(bucket) > 63:
                raise ValueError("artifact bucket is invalid")
        if not 1 <= self.port <= 65535:
            raise ValueError("artifact gateway port is invalid")
        if not 1024 <= self.max_archive_bytes <= 128 << 20:
            raise ValueError("archive size bound is invalid")
        if not self.max_archive_bytes <= self.max_expanded_bytes <= 256 << 20:
            raise ValueError("expanded size bound is invalid")
        if not 1 <= self.max_file_bytes <= self.max_expanded_bytes:
            raise ValueError("file size bound is invalid")
        if not 1 <= self.max_file_count <= 10000:
            raise ValueError("file count bound is invalid")
        if not 1024 <= self.max_evidence_bytes <= 16 << 20:
            raise ValueError("evidence size bound is invalid")
