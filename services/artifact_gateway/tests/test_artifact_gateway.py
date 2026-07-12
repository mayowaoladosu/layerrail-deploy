from __future__ import annotations

from datetime import datetime, timedelta, timezone
import hashlib
import hmac
from io import BytesIO
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from uuid import uuid4

from aiohttp.test_utils import TestClient, TestServer

from artifact_gateway.application import Application
from artifact_gateway.artifacts import ArtifactFault, ArtifactLimits, Artifacts
from artifact_gateway.config import Settings
from artifact_gateway.storage import ObjectInfo, ObjectValue


class MemoryStore:
    def __init__(self, now: datetime | None = None):
        self.now = now or datetime.now(timezone.utc)
        self.values: dict[tuple[str, str], ObjectValue] = {}

    def stat(self, bucket: str, key: str) -> ObjectInfo | None:
        value = self.values.get((bucket, key))
        return value.info if value else None

    def get(self, bucket: str, key: str) -> ObjectValue | None:
        return self.values.get((bucket, key))

    def put(
        self,
        bucket: str,
        key: str,
        body: bytes,
        *,
        content_type: str,
        metadata: dict[str, str] | None = None,
    ) -> None:
        del metadata
        self.values[(bucket, key)] = ObjectValue(
            body=body,
            info=ObjectInfo(
                key=key,
                size=len(body),
                last_modified=self.now,
                content_type=content_type,
            ),
        )

    def list(self, bucket: str, prefix: str) -> tuple[ObjectInfo, ...]:
        return tuple(
            value.info
            for (stored_bucket, key), value in self.values.items()
            if stored_bucket == bucket and key.startswith(prefix)
        )

    def delete(self, bucket: str, keys: tuple[str, ...]) -> None:
        for key in keys:
            self.values.pop((bucket, key), None)


def tar_archive(
    files: dict[str, bytes],
    *,
    symlink: tuple[str, str] | None = None,
    directories: tuple[str, ...] = (),
) -> bytes:
    target = BytesIO()
    with tarfile.open(fileobj=target, mode="w") as archive:
        for path in directories:
            value = tarfile.TarInfo(path)
            value.type = tarfile.DIRTYPE
            archive.addfile(value)
        for path, body in files.items():
            value = tarfile.TarInfo(path)
            value.size = len(body)
            value.mtime = 0
            archive.addfile(value, BytesIO(body))
        if symlink:
            value = tarfile.TarInfo(symlink[0])
            value.type = tarfile.SYMTYPE
            value.linkname = symlink[1]
            archive.addfile(value)
    return target.getvalue()


def digest(body: bytes) -> str:
    return "sha256:" + hashlib.sha256(body).hexdigest()


def limits(**overrides: int) -> ArtifactLimits:
    values = {
        "archive_bytes": 1 << 20,
        "expanded_bytes": 1 << 20,
        "file_bytes": 1 << 19,
        "file_count": 100,
        "evidence_bytes": 1 << 18,
    }
    values.update(overrides)
    return ArtifactLimits(**values)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 7, 1, tzinfo=timezone.utc)
        self.store = MemoryStore(self.now)
        self.artifacts = Artifacts(
            self.store,
            static_bucket="static",
            evidence_bucket="evidence",
            limits=limits(),
        )
        self.organization_id = str(uuid4())
        self.revision_id = str(uuid4())

    def publish(
        self,
        archive: bytes | None = None,
        revision_id: str | None = None,
    ) -> tuple[dict[str, object], bool]:
        value = archive or tar_archive(
            {
                "index.html": b"<h1>alpha</h1>",
                "assets/app.1234abcd.js": b"console.log('alpha')",
            },
            directories=("assets/",),
        )
        return self.artifacts.publish_static(
            organization_id=self.organization_id,
            revision_id=revision_id or self.revision_id,
            archive=value,
            expected_digest=digest(value),
            now=self.now,
        )

    def test_static_publication_is_immutable_and_readable(self):
        manifest, created = self.publish()
        self.assertTrue(created)
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(
            [value["path"] for value in manifest["files"]],
            ["assets/app.1234abcd.js", "index.html"],
        )
        self.assertEqual(
            manifest["files"][0]["cache_control"],
            "public, max-age=31536000, immutable",
        )
        file = self.artifacts.static_file(
            organization_id=self.organization_id,
            revision_id=self.revision_id,
            path="index.html",
        )
        self.assertEqual(file.body, b"<h1>alpha</h1>")

        same, created = self.publish()
        self.assertFalse(created)
        self.assertEqual(same, manifest)

        changed = tar_archive({"index.html": b"changed"})
        with self.assertRaisesRegex(ArtifactFault, "revision_artifact_conflict"):
            self.publish(changed)

    def test_traversal_symlink_duplicate_and_missing_index_fail_closed(self):
        fixtures = [
            tar_archive({"../index.html": b"bad"}),
            tar_archive({"index.html": b"ok", "bad\nname.txt": b"bad"}),
            tar_archive({"index.html": b"ok"}, symlink=("escape", "../secret")),
            tar_archive({"asset.txt": b"missing"}),
        ]
        duplicate = BytesIO()
        with tarfile.open(fileobj=duplicate, mode="w") as archive:
            for body in (b"first", b"second"):
                value = tarfile.TarInfo("index.html")
                value.size = len(body)
                archive.addfile(value, BytesIO(body))
        fixtures.append(duplicate.getvalue())

        for archive in fixtures:
            with self.subTest(size=len(archive)):
                with self.assertRaises(ArtifactFault):
                    self.publish(archive)
        self.assertEqual(self.store.values, {})

    def test_size_and_digest_bounds_fail_before_storage(self):
        archive = tar_archive({"index.html": b"too-large"})
        bounded = Artifacts(
            self.store,
            static_bucket="static",
            evidence_bucket="evidence",
            limits=limits(file_bytes=3),
        )
        with self.assertRaisesRegex(ArtifactFault, "archive_file_size_invalid"):
            bounded.publish_static(
                organization_id=self.organization_id,
                revision_id=self.revision_id,
                archive=archive,
                expected_digest=digest(archive),
            )
        with self.assertRaisesRegex(ArtifactFault, "artifact_digest_mismatch"):
            self.artifacts.publish_static(
                organization_id=self.organization_id,
                revision_id=self.revision_id,
                archive=archive,
                expected_digest="sha256:" + "0" * 64,
            )
        self.assertEqual(self.store.values, {})

    def test_evidence_is_bounded_and_immutable(self):
        build_id = str(uuid4())
        body = b'{"status":"passed"}'
        value, created = self.artifacts.put_evidence(
            organization_id=self.organization_id,
            build_id=build_id,
            name="scan.json",
            body=body,
            expected_digest=digest(body),
        )
        self.assertTrue(created)
        self.assertEqual(value["digest"], digest(body))
        _value, created = self.artifacts.put_evidence(
            organization_id=self.organization_id,
            build_id=build_id,
            name="scan.json",
            body=body,
            expected_digest=digest(body),
        )
        self.assertFalse(created)
        with self.assertRaisesRegex(ArtifactFault, "artifact_immutable_conflict"):
            changed = b'{"status":"failed"}'
            self.artifacts.put_evidence(
                organization_id=self.organization_id,
                build_id=build_id,
                name="scan.json",
                body=changed,
                expected_digest=digest(changed),
            )
        invalid = b"not-json"
        with self.assertRaisesRegex(ArtifactFault, "evidence_json_invalid"):
            self.artifacts.put_evidence(
                organization_id=self.organization_id,
                build_id=str(uuid4()),
                name="scan.json",
                body=invalid,
                expected_digest=digest(invalid),
            )

    def test_retention_preserves_alias_targets_and_is_idempotent(self):
        current = str(uuid4())
        previous = str(uuid4())
        failed = str(uuid4())
        for revision_id in (current, previous, failed):
            self.publish(revision_id=revision_id)
        self.store.now = self.now + timedelta(days=8)
        reconciliation_id = str(uuid4())
        arguments = {
            "reconciliation_id": reconciliation_id,
            "organization_id": self.organization_id,
            "retain_revision_ids": [current, previous],
            "delete_candidate_revision_ids": [failed],
            "delete_before": self.now + timedelta(days=7),
            "now": self.store.now,
        }
        result, created = self.artifacts.reconcile(**arguments)
        self.assertTrue(created)
        self.assertEqual(result["deleted_revision_ids"], [failed])
        for revision_id in (current, previous):
            self.assertEqual(
                self.artifacts.static_manifest(
                    organization_id=self.organization_id,
                    revision_id=revision_id,
                )["revision_id"],
                revision_id,
            )
        with self.assertRaisesRegex(ArtifactFault, "artifact_not_found"):
            self.artifacts.static_manifest(
                organization_id=self.organization_id,
                revision_id=failed,
            )

        second, created = self.artifacts.reconcile(**arguments)
        self.assertFalse(created)
        self.assertEqual(second, result)
        with self.assertRaisesRegex(
            ArtifactFault, "retention_reconciliation_conflict"
        ):
            self.artifacts.reconcile(
                **(arguments | {"delete_candidate_revision_ids": []})
            )


class ApplicationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.secret = b"artifact-admin-secret-with-at-least-32-bytes"
        for name, value in {
            "admin": self.secret,
            "access": b"test-access-key",
            "secret": b"test-secret-key",
        }.items():
            (root / name).write_bytes(value)
        self.settings = Settings(
            endpoint="http://minio:9000",
            access_key_path=root / "access",
            secret_key_path=root / "secret",
            admin_secret_path=root / "admin",
            static_bucket="static",
            evidence_bucket="evidence",
            port=8080,
            max_archive_bytes=1 << 20,
            max_expanded_bytes=1 << 20,
            max_file_bytes=1 << 19,
            max_file_count=100,
            max_evidence_bytes=1 << 18,
        )
        self.store = MemoryStore()
        self.application = Application(self.settings, self.store)
        self.client = TestClient(TestServer(self.application.web_application()))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        self.directory.cleanup()

    def headers(
        self,
        *,
        method: str,
        path: str,
        body: bytes,
        request_id: str | None = None,
    ) -> dict[str, str]:
        timestamp = str(int(datetime.now(timezone.utc).timestamp()))
        request_id = request_id or str(uuid4())
        value = b"\n".join(
            [timestamp.encode(), request_id.encode(), method.encode(), path.encode(), body]
        )
        signature = hmac.new(self.secret, value, hashlib.sha256).hexdigest()
        return {
            "X-Lrail-Timestamp": timestamp,
            "X-Lrail-Request-Id": request_id,
            "X-Lrail-Signature": f"sha256={signature}",
        }

    async def test_publish_and_serve_static_file(self):
        organization_id = str(uuid4())
        revision_id = str(uuid4())
        archive = tar_archive({"index.html": b"<h1>served</h1>"})
        path = f"/v1/static/{organization_id}/{revision_id}"
        headers = self.headers(method="PUT", path=path, body=archive) | {
            "Content-Type": "application/x-tar",
            "X-Lrail-Artifact-Digest": digest(archive),
        }
        response = await self.client.put(path, data=archive, headers=headers)
        self.assertEqual(response.status, 201, await response.text())

        response = await self.client.get(path + "/files/index.html")
        self.assertEqual(response.status, 200)
        self.assertEqual(await response.read(), b"<h1>served</h1>")
        self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(response.headers["Cache-Control"], "no-cache, must-revalidate")

    async def test_unsigned_and_replayed_mutation_fail(self):
        organization_id = str(uuid4())
        build_id = str(uuid4())
        path = f"/v1/evidence/{organization_id}/{build_id}/scan.json"
        body = json.dumps({"status": "passed"}).encode()
        response = await self.client.put(path, data=body)
        self.assertEqual(response.status, 401)

        headers = self.headers(
            method="PUT", path=path, body=body, request_id=str(uuid4())
        ) | {"X-Lrail-Artifact-Digest": digest(body)}
        response = await self.client.put(path, data=body, headers=headers)
        self.assertEqual(response.status, 201, await response.text())
        replay = await self.client.put(path, data=body, headers=headers)
        self.assertEqual(replay.status, 401)


if __name__ == "__main__":
    unittest.main()
