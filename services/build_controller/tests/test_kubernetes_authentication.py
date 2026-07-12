from __future__ import annotations

import hashlib
import hmac
from pathlib import Path
import tempfile
import time
import unittest
from uuid import uuid4

from kubernetes_asyncio.client.exceptions import ApiException

from build_controller.authentication import CallbackAuthenticator, RequestAuthenticator
from build_controller.clients import RegistryCredential
from build_controller.contracts import BuildCommand, CloneCredentials
from build_controller.kubernetes import BuildJobs


class FakeBatch:
    def __init__(self):
        self.jobs: dict[str, dict] = {}

    async def read_namespaced_job_status(self, name, _namespace):
        if name not in self.jobs:
            raise ApiException(status=404)
        value = type("Job", (), {})()
        value.status = type(
            "Status",
            (),
            {"conditions": [], "active": 1},
        )()
        return value

    async def create_namespaced_job(self, _namespace, body):
        self.jobs[body["metadata"]["name"]] = body

    async def delete_namespaced_job(self, name, _namespace, **_kwargs):
        if self.jobs.pop(name, None) is None:
            raise ApiException(status=404)


class FakeCore:
    def __init__(self):
        self.secrets: dict[str, dict] = {}

    async def create_namespaced_secret(self, _namespace, body):
        self.secrets[body["metadata"]["name"]] = body

    async def delete_namespaced_secret(self, name, _namespace, **_kwargs):
        if self.secrets.pop(name, None) is None:
            raise ApiException(status=404)


def command() -> BuildCommand:
    organization_id = str(uuid4())
    build_id = str(uuid4())
    service_id = str(uuid4())
    event = {
        "event_id": str(uuid4()),
        "event_type": "build.requested.v1",
        "occurred_at": "2026-07-12T12:00:00Z",
        "organization_id": organization_id,
        "resource_id": build_id,
        "correlation_id": str(uuid4()),
        "idempotency_key": f"build:{build_id}:requested",
        "producer": "control-plane",
        "schema_version": 1,
        "data": {
            "contract_version": 1,
            "command_type": "build.start",
            "operation_id": str(uuid4()),
            "organization_id": organization_id,
            "deployment_id": str(uuid4()),
            "build_id": build_id,
            "revision_id": str(uuid4()),
            "service_id": service_id,
            "expected_version": 3,
            "workload_type": "web",
            "repository": f"lrail/{organization_id}/{service_id}",
            "source_commit": "a" * 40,
            "source_root": ".",
            "descriptor_digest": "sha256:" + "b" * 64,
        },
    }
    return BuildCommand.parse(event)


class KubernetesTests(unittest.IsolatedAsyncioTestCase):
    async def test_job_is_one_disposable_gvisor_sandbox_with_secret_references_only(self):
        batch = FakeBatch()
        core = FakeCore()
        jobs = BuildJobs(
            namespace="lrail-builds",
            worker_image="lrail-build-worker:dev",
            callback_url="http://build-controller.lrail-system.svc.cluster.local:8080",
            registry_endpoint="registry.lrail-system.svc.cluster.local:5000",
            batch_api=batch,
            core_api=core,
        )
        value = command()
        clone = CloneCredentials(
            build_id=value.build_id,
            clone_url="https://git.example.test/layerrail/sample.git",
            username="x-access-token",
            secret="clone-secret-value",
            expires_at="2026-07-12T12:15:00Z",
        )
        registry = RegistryCredential(
            credential_id=str(uuid4()),
            username="lr_registry_user",
            password="registry-secret-value",
            repository=value.repository,
            expires_at=int(time.time()) + 600,
        )

        created = await jobs.dispatch(
            value,
            clone=clone,
            registry=registry,
            callback_secret=b"callback-secret-value",
            active_deadline_seconds=600,
        )

        self.assertTrue(created)
        job = batch.jobs[value.job_name]
        pod = job["spec"]["template"]["spec"]
        container = pod["containers"][0]
        self.assertEqual(pod["runtimeClassName"], "gvisor")
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertFalse(container["securityContext"]["privileged"])
        self.assertFalse(container["securityContext"]["allowPrivilegeEscalation"])
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertEqual(container["securityContext"]["capabilities"]["drop"], ["ALL"])
        self.assertIn("SYS_ADMIN", container["securityContext"]["capabilities"]["add"])
        self.assertEqual(job["spec"]["activeDeadlineSeconds"], 600)
        self.assertEqual(job["spec"]["backoffLimit"], 1)
        credential_mount = next(
            mount for mount in container["volumeMounts"] if mount["name"] == "credentials"
        )
        self.assertTrue(credential_mount["readOnly"])
        self.assertNotIn("clone-secret-value", str(job))
        self.assertNotIn("registry-secret-value", str(job))
        secret = core.secrets[value.secret_name]["stringData"]
        self.assertEqual(secret["git-password"], "clone-secret-value")
        self.assertEqual(secret["registry-password"], "registry-secret-value")
        self.assertEqual(
            secret["registry-endpoint"],
            "registry.lrail-system.svc.cluster.local:5000",
        )


class AuthenticationTests(unittest.TestCase):
    def test_callback_secret_is_per_build_and_replay_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secret"
            path.write_bytes(b"controller-shared-secret-at-least-32-bytes")
            root = RequestAuthenticator(path)
            auth = CallbackAuthenticator(root)
            build_id = str(uuid4())
            other_build_id = str(uuid4())
            request_id = str(uuid4())
            timestamp = int(time.time())
            body = b'{"status":"completed"}'
            path_value = f"/v1/builds/{build_id}/result"
            message = b"\n".join(
                [
                    str(timestamp).encode(),
                    request_id.encode(),
                    b"PUT",
                    path_value.encode(),
                    body,
                ]
            )
            signature = "sha256=" + hmac.new(
                root.callback_secret(build_id), message, hashlib.sha256
            ).hexdigest()
            headers = {
                "X-Lrail-Timestamp": str(timestamp),
                "X-Lrail-Request-Id": request_id,
                "X-Lrail-Signature": signature,
            }

            self.assertTrue(
                auth.valid(
                    build_id=build_id,
                    method="PUT",
                    path=path_value,
                    body=body,
                    headers=headers,
                    now=timestamp,
                )
            )
            self.assertFalse(
                auth.valid(
                    build_id=build_id,
                    method="PUT",
                    path=path_value,
                    body=body,
                    headers=headers,
                    now=timestamp,
                )
            )
            self.assertFalse(
                auth.valid(
                    build_id=other_build_id,
                    method="PUT",
                    path=path_value,
                    body=body,
                    headers=headers,
                    now=timestamp,
                )
            )


if __name__ == "__main__":
    unittest.main()
