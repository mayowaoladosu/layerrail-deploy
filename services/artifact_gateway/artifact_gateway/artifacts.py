from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
from io import BytesIO
import json
from pathlib import PurePosixPath
import re
import tarfile
import threading
from uuid import UUID

from .storage import ObjectStore, ObjectValue


_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_EVIDENCE_NAME = re.compile(r"^[a-z][a-z0-9_-]{0,47}\.(?:json|txt|log)$")
_HASHED_ASSET = re.compile(r"(?:^|[._-])[0-9a-f]{8,64}(?:[._-]|$)")
_MEDIA_TYPES = {
    ".css": "text/css; charset=utf-8",
    ".gif": "image/gif",
    ".html": "text/html; charset=utf-8",
    ".ico": "image/x-icon",
    ".jpeg": "image/jpeg",
    ".jpg": "image/jpeg",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".map": "application/json; charset=utf-8",
    ".png": "image/png",
    ".svg": "image/svg+xml",
    ".txt": "text/plain; charset=utf-8",
    ".wasm": "application/wasm",
    ".webmanifest": "application/manifest+json",
    ".webp": "image/webp",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".xml": "application/xml; charset=utf-8",
}


class ArtifactFault(ValueError):
    def __init__(self, code: str, status: int):
        super().__init__(code)
        self.code = code
        self.status = status


@dataclass(frozen=True)
class ArtifactLimits:
    archive_bytes: int
    expanded_bytes: int
    file_bytes: int
    file_count: int
    evidence_bytes: int


@dataclass(frozen=True)
class StaticFile:
    path: str
    body: bytes
    digest: str
    media_type: str
    cache_control: str


class Artifacts:
    def __init__(
        self,
        store: ObjectStore,
        *,
        static_bucket: str,
        evidence_bucket: str,
        limits: ArtifactLimits,
    ) -> None:
        self._store = store
        self._static_bucket = static_bucket
        self._evidence_bucket = evidence_bucket
        self._limits = limits
        self._lock = threading.RLock()

    def publish_static(
        self,
        *,
        organization_id: str,
        revision_id: str,
        archive: bytes,
        expected_digest: str,
        now: datetime | None = None,
    ) -> tuple[dict[str, object], bool]:
        organization_id = self._uuid(organization_id)
        revision_id = self._uuid(revision_id)
        digest = self._digest(archive)
        if not _DIGEST.fullmatch(expected_digest) or digest != expected_digest:
            raise ArtifactFault("artifact_digest_mismatch", 422)
        if not archive or len(archive) > self._limits.archive_bytes:
            raise ArtifactFault("archive_size_invalid", 413)
        files = self._extract(archive)
        created_at = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
        prefix = self._revision_prefix(organization_id, revision_id)
        manifest_key = prefix + "manifest.json"

        with self._lock:
            existing = self._store.get(self._static_bucket, manifest_key)
            if existing is not None:
                manifest = self._parse_json(existing)
                if manifest.get("archive", {}).get("digest") != digest:
                    raise ArtifactFault("revision_artifact_conflict", 409)
                return manifest, False

            manifest: dict[str, object] = {
                "schema_version": 1,
                "organization_id": organization_id,
                "revision_id": revision_id,
                "created_at": created_at.isoformat(timespec="seconds").replace(
                    "+00:00", "Z"
                ),
                "archive": {
                    "digest": digest,
                    "media_type": "application/x-tar",
                    "size": len(archive),
                },
                "files": [
                    {
                        "path": file.path,
                        "digest": file.digest,
                        "media_type": file.media_type,
                        "size": len(file.body),
                        "cache_control": file.cache_control,
                    }
                    for file in files
                ],
            }
            for file in files:
                self._put_immutable(
                    self._static_bucket,
                    prefix + "files/" + file.path,
                    file.body,
                    content_type=file.media_type,
                )
            manifest_body = self._canonical_json(manifest)
            self._put_immutable(
                self._static_bucket,
                manifest_key,
                manifest_body,
                content_type="application/json",
            )
            return manifest, True

    def static_manifest(
        self, *, organization_id: str, revision_id: str
    ) -> dict[str, object]:
        organization_id = self._uuid(organization_id)
        revision_id = self._uuid(revision_id)
        value = self._store.get(
            self._static_bucket,
            self._revision_prefix(organization_id, revision_id) + "manifest.json",
        )
        if value is None:
            raise ArtifactFault("artifact_not_found", 404)
        return self._parse_json(value)

    def static_file(
        self, *, organization_id: str, revision_id: str, path: str
    ) -> StaticFile:
        organization_id = self._uuid(organization_id)
        revision_id = self._uuid(revision_id)
        path = self._path(path)
        value = self._store.get(
            self._static_bucket,
            self._revision_prefix(organization_id, revision_id) + "files/" + path,
        )
        if value is None:
            raise ArtifactFault("artifact_not_found", 404)
        return StaticFile(
            path=path,
            body=value.body,
            digest=self._digest(value.body),
            media_type=self._media_type(path),
            cache_control=self._cache_control(path),
        )

    def put_evidence(
        self,
        *,
        organization_id: str,
        build_id: str,
        name: str,
        body: bytes,
        expected_digest: str,
    ) -> tuple[dict[str, object], bool]:
        organization_id = self._uuid(organization_id)
        build_id = self._uuid(build_id)
        if not _EVIDENCE_NAME.fullmatch(name):
            raise ArtifactFault("evidence_name_invalid", 422)
        if not body or len(body) > self._limits.evidence_bytes:
            raise ArtifactFault("evidence_size_invalid", 413)
        if name.endswith(".json"):
            try:
                json.loads(body)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise ArtifactFault("evidence_json_invalid", 422) from error
        digest = self._digest(body)
        if not _DIGEST.fullmatch(expected_digest) or digest != expected_digest:
            raise ArtifactFault("artifact_digest_mismatch", 422)
        key = f"organizations/{organization_id}/builds/{build_id}/{name}"
        with self._lock:
            created = self._put_immutable(
                self._evidence_bucket,
                key,
                body,
                content_type=self._media_type(name),
            )
        return {
            "schema_version": 1,
            "organization_id": organization_id,
            "build_id": build_id,
            "name": name,
            "digest": digest,
            "size": len(body),
        }, created

    def evidence(
        self, *, organization_id: str, build_id: str, name: str
    ) -> ObjectValue:
        organization_id = self._uuid(organization_id)
        build_id = self._uuid(build_id)
        if not _EVIDENCE_NAME.fullmatch(name):
            raise ArtifactFault("evidence_name_invalid", 422)
        value = self._store.get(
            self._evidence_bucket,
            f"organizations/{organization_id}/builds/{build_id}/{name}",
        )
        if value is None:
            raise ArtifactFault("artifact_not_found", 404)
        return value

    def reconcile(
        self,
        *,
        reconciliation_id: str,
        organization_id: str,
        retain_revision_ids: list[str],
        delete_candidate_revision_ids: list[str],
        delete_before: datetime,
        now: datetime | None = None,
    ) -> tuple[dict[str, object], bool]:
        reconciliation_id = self._uuid(reconciliation_id)
        organization_id = self._uuid(organization_id)
        retained = {self._uuid(value) for value in retain_revision_ids}
        candidates = {self._uuid(value) for value in delete_candidate_revision_ids}
        if len(retained) > 1000 or len(candidates) > 1000 or retained & candidates:
            raise ArtifactFault("retention_set_invalid", 422)
        if delete_before.tzinfo is None:
            raise ArtifactFault("retention_cutoff_invalid", 422)
        cutoff = delete_before.astimezone(timezone.utc)
        current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
        if cutoff > current:
            raise ArtifactFault("retention_cutoff_invalid", 422)

        request_value = {
            "reconciliation_id": reconciliation_id,
            "organization_id": organization_id,
            "retain_revision_ids": sorted(retained),
            "delete_candidate_revision_ids": sorted(candidates),
            "delete_before": cutoff.isoformat(timespec="seconds").replace(
                "+00:00", "Z"
            ),
        }
        request_digest = self._digest(self._canonical_json(request_value))
        evidence_key = (
            f"organizations/{organization_id}/retention/{reconciliation_id}.json"
        )

        with self._lock:
            existing = self._store.get(self._evidence_bucket, evidence_key)
            if existing is not None:
                result = self._parse_json(existing)
                if result.get("request_digest") != request_digest:
                    raise ArtifactFault("retention_reconciliation_conflict", 409)
                return result, False

            prefix = f"organizations/{organization_id}/revisions/"
            grouped: dict[str, list] = {}
            for value in self._store.list(self._static_bucket, prefix):
                remainder = value.key.removeprefix(prefix)
                revision_id = remainder.split("/", 1)[0]
                if revision_id in candidates:
                    grouped.setdefault(revision_id, []).append(value)

            deleted: list[str] = []
            for revision_id, values in sorted(grouped.items()):
                if revision_id in retained:
                    continue
                if max(value.last_modified for value in values) >= cutoff:
                    continue
                self._store.delete(
                    self._static_bucket,
                    tuple(value.key for value in values),
                )
                deleted.append(revision_id)

            result: dict[str, object] = request_value | {
                "schema_version": 1,
                "request_digest": request_digest,
                "reconciled_at": current.isoformat(timespec="seconds").replace(
                    "+00:00", "Z"
                ),
                "deleted_revision_ids": deleted,
            }
            self._put_immutable(
                self._evidence_bucket,
                evidence_key,
                self._canonical_json(result),
                content_type="application/json",
            )
            return result, True

    def _extract(self, archive: bytes) -> tuple[StaticFile, ...]:
        try:
            value = tarfile.open(fileobj=BytesIO(archive), mode="r:")
        except tarfile.TarError as error:
            raise ArtifactFault("archive_invalid", 422) from error
        files: list[StaticFile] = []
        paths: set[str] = set()
        expanded = 0
        try:
            for member in value:
                if member.isdir():
                    self._path(member.name, directory=True)
                    continue
                path = self._path(member.name)
                if not member.isfile():
                    raise ArtifactFault("archive_entry_type_invalid", 422)
                if path in paths:
                    raise ArtifactFault("archive_path_duplicate", 422)
                if member.size < 0 or member.size > self._limits.file_bytes:
                    raise ArtifactFault("archive_file_size_invalid", 413)
                paths.add(path)
                expanded += member.size
                if (
                    len(paths) > self._limits.file_count
                    or expanded > self._limits.expanded_bytes
                ):
                    raise ArtifactFault("archive_expansion_invalid", 413)
                source = value.extractfile(member)
                if source is None:
                    raise ArtifactFault("archive_invalid", 422)
                body = source.read(member.size + 1)
                if len(body) != member.size:
                    raise ArtifactFault("archive_size_mismatch", 422)
                files.append(
                    StaticFile(
                        path=path,
                        body=body,
                        digest=self._digest(body),
                        media_type=self._media_type(path),
                        cache_control=self._cache_control(path),
                    )
                )
        finally:
            value.close()
        if "index.html" not in paths:
            raise ArtifactFault("archive_index_missing", 422)
        return tuple(sorted(files, key=lambda file: file.path))

    def _path(self, value: str, *, directory: bool = False) -> str:
        if (
            not value
            or "\\" in value
            or "\0" in value
            or any(ord(character) < 32 or ord(character) == 127 for character in value)
        ):
            raise ArtifactFault("artifact_path_invalid", 422)
        while value.startswith("./"):
            value = value[2:]
        if directory:
            value = value.rstrip("/")
        path = PurePosixPath(value)
        if (
            not value
            or value.startswith("/")
            or value.endswith("/")
            or any(part in {"", ".", ".."} for part in value.split("/"))
            or str(path) != value
            or len(value.encode()) > 512
        ):
            raise ArtifactFault("artifact_path_invalid", 422)
        return value

    def _uuid(self, value: str) -> str:
        try:
            normalized = str(UUID(value))
        except (TypeError, ValueError) as error:
            raise ArtifactFault("artifact_identity_invalid", 422) from error
        if normalized != value:
            raise ArtifactFault("artifact_identity_invalid", 422)
        return normalized

    def _put_immutable(
        self,
        bucket: str,
        key: str,
        body: bytes,
        *,
        content_type: str,
    ) -> bool:
        existing = self._store.get(bucket, key)
        if existing is not None:
            if existing.body != body:
                raise ArtifactFault("artifact_immutable_conflict", 409)
            return False
        self._store.put(
            bucket,
            key,
            body,
            content_type=content_type,
            metadata={"sha256": hashlib.sha256(body).hexdigest()},
        )
        return True

    def _parse_json(self, value: ObjectValue) -> dict[str, object]:
        try:
            parsed = json.loads(value.body)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ArtifactFault("artifact_state_invalid", 500) from error
        if not isinstance(parsed, dict):
            raise ArtifactFault("artifact_state_invalid", 500)
        return parsed

    def _revision_prefix(self, organization_id: str, revision_id: str) -> str:
        return f"organizations/{organization_id}/revisions/{revision_id}/"

    def _digest(self, body: bytes) -> str:
        return "sha256:" + hashlib.sha256(body).hexdigest()

    def _canonical_json(self, value: dict[str, object]) -> bytes:
        return json.dumps(value, separators=(",", ":"), sort_keys=True).encode()

    def _media_type(self, path: str) -> str:
        return _MEDIA_TYPES.get(
            PurePosixPath(path).suffix.lower(), "application/octet-stream"
        )

    def _cache_control(self, path: str) -> str:
        if path == "index.html" or path.endswith("/index.html"):
            return "no-cache, must-revalidate"
        if _HASHED_ASSET.search(PurePosixPath(path).name):
            return "public, max-age=31536000, immutable"
        return "public, max-age=300"
