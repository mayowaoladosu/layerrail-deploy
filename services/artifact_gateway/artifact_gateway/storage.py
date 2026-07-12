from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from io import BytesIO
from pathlib import Path
from typing import Protocol
from urllib.parse import urlsplit

from minio import Minio
from minio.error import S3Error


@dataclass(frozen=True)
class ObjectInfo:
    key: str
    size: int
    last_modified: datetime
    content_type: str


@dataclass(frozen=True)
class ObjectValue:
    body: bytes
    info: ObjectInfo


class ObjectStore(Protocol):
    def stat(self, bucket: str, key: str) -> ObjectInfo | None: ...

    def get(self, bucket: str, key: str) -> ObjectValue | None: ...

    def put(
        self,
        bucket: str,
        key: str,
        body: bytes,
        *,
        content_type: str,
        metadata: dict[str, str] | None = None,
    ) -> None: ...

    def list(self, bucket: str, prefix: str) -> tuple[ObjectInfo, ...]: ...

    def delete(self, bucket: str, keys: tuple[str, ...]) -> None: ...


class MinioObjectStore:
    def __init__(
        self,
        *,
        endpoint: str,
        access_key_path: Path,
        secret_key_path: Path,
    ) -> None:
        parsed = urlsplit(endpoint)
        self._client = Minio(
            parsed.netloc,
            access_key=access_key_path.read_text(encoding="utf-8").strip(),
            secret_key=secret_key_path.read_text(encoding="utf-8").strip(),
            secure=parsed.scheme == "https",
        )

    def stat(self, bucket: str, key: str) -> ObjectInfo | None:
        try:
            value = self._client.stat_object(bucket, key)
        except S3Error as error:
            if error.code in {"NoSuchKey", "NoSuchObject", "NoSuchBucket"}:
                return None
            raise
        return ObjectInfo(
            key=key,
            size=value.size,
            last_modified=value.last_modified,
            content_type=value.content_type or "application/octet-stream",
        )

    def get(self, bucket: str, key: str) -> ObjectValue | None:
        info = self.stat(bucket, key)
        if info is None:
            return None
        response = self._client.get_object(bucket, key)
        try:
            body = response.read()
        finally:
            response.close()
            response.release_conn()
        return ObjectValue(body=body, info=info)

    def put(
        self,
        bucket: str,
        key: str,
        body: bytes,
        *,
        content_type: str,
        metadata: dict[str, str] | None = None,
    ) -> None:
        self._client.put_object(
            bucket,
            key,
            BytesIO(body),
            len(body),
            content_type=content_type,
            metadata=metadata,
        )

    def list(self, bucket: str, prefix: str) -> tuple[ObjectInfo, ...]:
        return tuple(
            ObjectInfo(
                key=value.object_name,
                size=value.size or 0,
                last_modified=value.last_modified,
                content_type="application/octet-stream",
            )
            for value in self._client.list_objects(bucket, prefix=prefix, recursive=True)
        )

    def delete(self, bucket: str, keys: tuple[str, ...]) -> None:
        for key in keys:
            self._client.remove_object(bucket, key)
