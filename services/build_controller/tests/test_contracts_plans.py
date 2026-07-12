from __future__ import annotations

import base64
import hashlib
from io import BytesIO
from pathlib import Path
import tarfile
import tempfile
import unittest
from uuid import uuid4

from build_controller.contracts import (
    BuildCommand,
    CancelCommand,
    CloneCredentials,
    InvalidContract,
    WorkerResult,
)
from build_controller.plans import UnsupportedProject, detect_plan
from build_controller.store import OperationConflict, OperationStore


IDS = {
    "event": str(uuid4()),
    "operation": str(uuid4()),
    "organization": str(uuid4()),
    "deployment": str(uuid4()),
    "build": str(uuid4()),
    "revision": str(uuid4()),
    "service": str(uuid4()),
    "correlation": str(uuid4()),
}
COMMIT = "0123456789abcdef0123456789abcdef01234567"


def command_envelope() -> dict[str, object]:
    data = {
        "contract_version": 1,
        "command_type": "build.start",
        "operation_id": IDS["operation"],
        "organization_id": IDS["organization"],
        "deployment_id": IDS["deployment"],
        "build_id": IDS["build"],
        "revision_id": IDS["revision"],
        "service_id": IDS["service"],
        "expected_version": 3,
        "workload_type": "web",
        "repository": f"lrail/{IDS['organization']}/{IDS['service']}",
        "source_commit": COMMIT,
        "source_root": ".",
        "descriptor_digest": "sha256:" + "a" * 64,
    }
    return {
        "event_id": IDS["event"],
        "event_type": "build.requested.v1",
        "occurred_at": "2026-07-12T12:00:00Z",
        "organization_id": IDS["organization"],
        "resource_id": IDS["build"],
        "correlation_id": IDS["correlation"],
        "idempotency_key": f"build:{IDS['build']}:requested",
        "producer": "control-plane",
        "schema_version": 1,
        "data": data,
    }


def static_archive() -> bytes:
    target = BytesIO()
    with tarfile.open(fileobj=target, mode="w") as archive:
        body = b"<h1>static</h1>"
        info = tarfile.TarInfo("index.html")
        info.size = len(body)
        archive.addfile(info, BytesIO(body))
    return target.getvalue()


class ContractTests(unittest.TestCase):
    def test_clone_credentials_allow_only_https_or_the_exact_local_fixture(self):
        value = {
            "contract_version": 1,
            "build_id": IDS["build"],
            "clone_url": "http://git-fixture.lrail-system.svc.cluster.local:8080/sample.git",
            "username": "fixture-user",
            "secret": "fixture-secret",
            "expires_at": "2026-07-12T12:15:00Z",
        }
        credentials = CloneCredentials.parse(value, build_id=IDS["build"])
        self.assertEqual(credentials.clone_url, value["clone_url"])

        value["clone_url"] = "http://attacker.example:8080/sample.git"
        with self.assertRaises(InvalidContract):
            CloneCredentials.parse(value, build_id=IDS["build"])

    def test_build_and_cancel_commands_are_tenant_bound(self):
        command = BuildCommand.parse(command_envelope())
        self.assertEqual(command.build_id, IDS["build"])
        self.assertEqual(command.repository, f"lrail/{IDS['organization']}/{IDS['service']}")

        cancel = command_envelope()
        cancel["event_type"] = "build.cancellation.requested.v1"
        cancel["data"] = {
            "contract_version": 1,
            "command_type": "build.cancel",
            "operation_id": str(uuid4()),
            "organization_id": IDS["organization"],
            "deployment_id": IDS["deployment"],
            "build_id": IDS["build"],
            "expected_version": 4,
        }
        value = CancelCommand.parse(cancel)
        self.assertEqual(value.build_id, IDS["build"])

        altered = command_envelope()
        altered["data"]["organization_id"] = str(uuid4())
        with self.assertRaises(InvalidContract):
            BuildCommand.parse(altered)

        altered = command_envelope()
        altered["data"]["repository"] = f"lrail/{IDS['organization']}/{uuid4()}"
        with self.assertRaises(InvalidContract):
            BuildCommand.parse(altered)

    def test_worker_results_bind_artifact_content_and_shape(self):
        archive = static_archive()
        digest = "sha256:" + hashlib.sha256(archive).hexdigest()
        result = WorkerResult.parse(
            {
                "contract_version": 1,
                "operation_id": IDS["operation"],
                "build_id": IDS["build"],
                "source_commit": COMMIT,
                "status": "completed",
                "plan_type": "plain_static",
                "artifact_kind": "static",
                "artifact_digest": digest,
                "static_archive": base64.b64encode(archive).decode(),
                "log_lines": ["2026-07-12T12:00:00Z build static"],
            },
            build_id=IDS["build"],
            max_static_archive_bytes=1 << 20,
            max_log_lines=100,
        )
        self.assertEqual(result.static_archive, archive)
        self.assertNotIn("static_archive", result.safe_value())

        changed = bytearray(archive)
        changed[-1] ^= 1
        with self.assertRaises(InvalidContract):
            WorkerResult.parse(
                {
                    "contract_version": 1,
                    "operation_id": IDS["operation"],
                    "build_id": IDS["build"],
                    "source_commit": COMMIT,
                    "status": "completed",
                    "plan_type": "plain_static",
                    "artifact_kind": "static",
                    "artifact_digest": digest,
                    "static_archive": base64.b64encode(changed).decode(),
                    "log_lines": [],
                },
                build_id=IDS["build"],
                max_static_archive_bytes=1 << 20,
                max_log_lines=100,
            )

        with self.assertRaises(InvalidContract):
            WorkerResult.parse(
                {
                    "contract_version": 1,
                    "operation_id": IDS["operation"],
                    "build_id": IDS["build"],
                    "source_commit": COMMIT,
                    "status": "completed",
                    "plan_type": "plain_static",
                    "artifact_kind": "oci",
                    "artifact_digest": "sha256:" + "b" * 64,
                    "image_reference": "registry.test/repository@sha256:" + "b" * 64,
                    "log_lines": [],
                },
                build_id=IDS["build"],
                max_static_archive_bytes=1 << 20,
                max_log_lines=100,
            )

    def test_store_deduplicates_commands_and_never_persists_static_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            store = OperationStore(Path(directory))
            command = BuildCommand.parse(command_envelope())
            first, created = store.register(command)
            second, replayed = store.register(command)
            self.assertTrue(created)
            self.assertFalse(replayed)
            self.assertEqual(first, second)
            store.set_running(command.build_id, registry_credential_id=str(uuid4()))
            archive = static_archive()
            result = WorkerResult.parse(
                {
                    "contract_version": 1,
                    "operation_id": IDS["operation"],
                    "build_id": IDS["build"],
                    "source_commit": COMMIT,
                    "status": "completed",
                    "plan_type": "plain_static",
                    "artifact_kind": "static",
                    "artifact_digest": "sha256:" + hashlib.sha256(archive).hexdigest(),
                    "static_archive": base64.b64encode(archive).decode(),
                    "log_lines": [],
                },
                build_id=IDS["build"],
                max_static_archive_bytes=1 << 20,
                max_log_lines=100,
            )
            stored, created = store.save_result(result)
            self.assertTrue(created)
            self.assertTrue(stored.result["static_archive_present"])
            self.assertNotIn("static_archive", stored.result)
            self.assertEqual(store.load_archive(command.build_id), archive)
            changed = command_envelope()
            changed["data"]["source_commit"] = "f" * 40
            with self.assertRaises(OperationConflict):
                store.register(BuildCommand.parse(changed))
            store.close()


class PlanTests(unittest.TestCase):
    def test_dockerfile_has_explicit_priority_for_web(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            (root / "package.json").write_text(
                '{"scripts":{"start":"node server.js"}}', encoding="utf-8"
            )
            (root / "package-lock.json").write_text("{}", encoding="utf-8")
            plan = detect_plan(root, "web")
            self.assertEqual(plan.type, "dockerfile_web")
            self.assertEqual(plan.artifact_kind, "oci")

    def test_node_web_requires_one_lockfile_and_explicit_start(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "package.json").write_text(
                '{"scripts":{"start":"node server.js"}}', encoding="utf-8"
            )
            (root / "package-lock.json").write_text("{}", encoding="utf-8")
            plan = detect_plan(root, "web")
            self.assertEqual(plan.type, "node_web")
            self.assertIn("npm ci", plan.dockerfile)
            self.assertIn("USER node", plan.dockerfile)

            (root / "yarn.lock").write_text("", encoding="utf-8")
            with self.assertRaises(UnsupportedProject):
                detect_plan(root, "web")

    def test_generated_and_plain_static_plans_are_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "package.json").write_text(
                '{"scripts":{"build":"node build.js"}}', encoding="utf-8"
            )
            (root / "pnpm-lock.yaml").write_text("lockfileVersion: '9'", encoding="utf-8")
            generated = detect_plan(root, "static")
            self.assertEqual(generated.type, "node_static")
            self.assertIn("pnpm run build", generated.dockerfile)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "index.html").write_text("<h1>plain</h1>", encoding="utf-8")
            plain = detect_plan(root, "static")
            self.assertEqual(plain.type, "plain_static")
            self.assertEqual(plain.artifact_kind, "static")

    def test_unsupported_projects_fail_without_guessing_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "app.py").write_text("print('no Dockerfile')", encoding="utf-8")
            with self.assertRaisesRegex(UnsupportedProject, "No supported"):
                detect_plan(root, "web")


if __name__ == "__main__":
    unittest.main()
