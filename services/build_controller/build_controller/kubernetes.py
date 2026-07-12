from __future__ import annotations

from dataclasses import dataclass
import json
from typing import Any

from kubernetes_asyncio import client, config
from kubernetes_asyncio.client.exceptions import ApiException

from .clients import RegistryCredential
from .contracts import BuildCommand, CloneCredentials


class KubernetesError(RuntimeError):
    pass


@dataclass(frozen=True)
class JobState:
    exists: bool
    active: bool
    complete: bool
    failed: bool
    reason: str | None


class BuildJobs:
    OUTER_CAPABILITIES = [
        "CHOWN",
        "DAC_OVERRIDE",
        "FOWNER",
        "FSETID",
        "KILL",
        "MKNOD",
        "NET_BIND_SERVICE",
        "SETFCAP",
        "SETGID",
        "SETPCAP",
        "SETUID",
        "SYS_ADMIN",
        "SYS_CHROOT",
    ]

    def __init__(
        self,
        *,
        namespace: str,
        worker_image: str,
        callback_url: str,
        registry_endpoint: str,
        batch_api: Any | None = None,
        core_api: Any | None = None,
    ):
        self._namespace = namespace
        self._worker_image = worker_image
        self._callback_url = callback_url.rstrip("/")
        self._registry_endpoint = registry_endpoint
        self._batch = batch_api
        self._core = core_api
        self._api_client: Any | None = None

    async def start(self) -> None:
        if self._batch is not None and self._core is not None:
            return
        config.load_incluster_config()
        self._api_client = client.ApiClient()
        self._batch = client.BatchV1Api(self._api_client)
        self._core = client.CoreV1Api(self._api_client)

    async def close(self) -> None:
        if self._api_client is not None:
            await self._api_client.close()

    async def dispatch(
        self,
        command: BuildCommand,
        *,
        clone: CloneCredentials,
        registry: RegistryCredential,
        callback_secret: bytes,
        active_deadline_seconds: int,
    ) -> bool:
        await self.start()
        if (await self.status(command.job_name)).exists:
            return False
        await self._delete_secret(command.secret_name)
        await self._create_secret(
            command,
            clone=clone,
            registry=registry,
            callback_secret=callback_secret,
        )
        body = self._job(command, active_deadline_seconds=active_deadline_seconds)
        try:
            await self._batch.create_namespaced_job(self._namespace, body)
        except ApiException as error:
            if error.status == 409:
                return False
            await self._delete_secret(command.secret_name)
            raise KubernetesError("build job creation failed") from error
        return True

    async def status(self, job_name: str) -> JobState:
        await self.start()
        try:
            job = await self._batch.read_namespaced_job_status(job_name, self._namespace)
        except ApiException as error:
            if error.status == 404:
                return JobState(False, False, False, False, None)
            raise KubernetesError("build job status failed") from error
        status = job.status
        conditions = status.conditions or []
        complete = any(
            condition.type == "Complete" and condition.status == "True"
            for condition in conditions
        )
        failed = any(
            condition.type == "Failed" and condition.status == "True"
            for condition in conditions
        )
        reason = next(
            (
                condition.reason
                for condition in conditions
                if condition.status == "True" and condition.reason
            ),
            None,
        )
        return JobState(
            exists=True,
            active=bool(status.active),
            complete=complete,
            failed=failed,
            reason=reason,
        )

    async def logs(self, job_name: str, *, limit_bytes: int = 65536) -> str:
        await self.start()
        pods = await self._core.list_namespaced_pod(
            self._namespace,
            label_selector=f"job-name={job_name}",
            limit=2,
        )
        if not pods.items:
            return ""
        try:
            value = await self._core.read_namespaced_pod_log(
                pods.items[0].metadata.name,
                self._namespace,
                container="worker",
                timestamps=True,
                tail_lines=200,
            )
        except ApiException:
            return ""
        return str(value).encode(errors="replace")[-limit_bytes:].decode(errors="replace")

    async def delete(self, job_name: str, secret_name: str) -> None:
        await self.start()
        try:
            await self._batch.delete_namespaced_job(
                job_name,
                self._namespace,
                propagation_policy="Background",
                grace_period_seconds=0,
            )
        except ApiException as error:
            if error.status != 404:
                raise KubernetesError("build job deletion failed") from error
        await self._delete_secret(secret_name)

    async def _create_secret(
        self,
        command: BuildCommand,
        *,
        clone: CloneCredentials,
        registry: RegistryCredential,
        callback_secret: bytes,
    ) -> None:
        body = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": command.secret_name,
                "namespace": self._namespace,
                "labels": self._labels(command),
            },
            "type": "Opaque",
            "stringData": {
                "command.json": json.dumps(
                    command.command_value(), separators=(",", ":"), sort_keys=True
                ),
                "clone-url": clone.clone_url,
                "git-username": clone.username,
                "git-password": clone.secret,
                "git-expires-at": clone.expires_at,
                "registry-username": registry.username,
                "registry-password": registry.password,
                "registry-endpoint": self._registry_endpoint,
                "callback-secret": callback_secret.decode(),
            },
        }
        try:
            await self._core.create_namespaced_secret(self._namespace, body)
        except ApiException as error:
            raise KubernetesError("build credential mount failed") from error

    async def _delete_secret(self, secret_name: str) -> None:
        try:
            await self._core.delete_namespaced_secret(
                secret_name,
                self._namespace,
                grace_period_seconds=0,
            )
        except ApiException as error:
            if error.status != 404:
                raise KubernetesError("build credential cleanup failed") from error

    def _job(self, command: BuildCommand, *, active_deadline_seconds: int) -> dict[str, Any]:
        labels = self._labels(command)
        return {
            "apiVersion": "batch/v1",
            "kind": "Job",
            "metadata": {
                "name": command.job_name,
                "namespace": self._namespace,
                "labels": labels,
            },
            "spec": {
                "activeDeadlineSeconds": active_deadline_seconds,
                "backoffLimit": 1,
                "ttlSecondsAfterFinished": 300,
                "template": {
                    "metadata": {"labels": labels},
                    "spec": {
                        "runtimeClassName": "gvisor",
                        "restartPolicy": "Never",
                        "automountServiceAccountToken": False,
                        "enableServiceLinks": False,
                        "terminationGracePeriodSeconds": 5,
                        "securityContext": {
                            "runAsUser": 0,
                            "runAsGroup": 0,
                            "seccompProfile": {"type": "RuntimeDefault"},
                        },
                        "containers": [
                            {
                                "name": "worker",
                                "image": self._worker_image,
                                "imagePullPolicy": "Never",
                                "env": [
                                    {
                                        "name": "BUILD_CONTROLLER_URL",
                                        "value": self._callback_url,
                                    },
                                    {
                                        "name": "BUILD_CREDENTIALS_DIR",
                                        "value": "/run/lrail-build",
                                    },
                                    {
                                        "name": "BUILDKIT_HOST",
                                        "value": "unix:///run/buildkit/buildkitd.sock",
                                    },
                                ],
                                "securityContext": {
                                    "privileged": False,
                                    "allowPrivilegeEscalation": False,
                                    "readOnlyRootFilesystem": True,
                                    "capabilities": {
                                        "drop": ["ALL"],
                                        "add": self.OUTER_CAPABILITIES,
                                    },
                                },
                                "resources": {
                                    "requests": {
                                        "cpu": "250m",
                                        "memory": "512Mi",
                                        "ephemeral-storage": "1Gi",
                                    },
                                    "limits": {
                                        "cpu": "2",
                                        "memory": "4Gi",
                                        "ephemeral-storage": "8Gi",
                                    },
                                },
                                "volumeMounts": [
                                    {
                                        "name": "credentials",
                                        "mountPath": "/run/lrail-build",
                                        "readOnly": True,
                                    },
                                    {"name": "state", "mountPath": "/state"},
                                    {"name": "run", "mountPath": "/run/buildkit"},
                                    {"name": "docker", "mountPath": "/root/.docker"},
                                    {"name": "work", "mountPath": "/work"},
                                    {"name": "tmp", "mountPath": "/tmp"},
                                ],
                            }
                        ],
                        "volumes": [
                            {
                                "name": "credentials",
                                "secret": {
                                    "secretName": command.secret_name,
                                    "defaultMode": 0o400,
                                },
                            },
                            {"name": "state", "emptyDir": {"sizeLimit": "4Gi"}},
                            {
                                "name": "run",
                                "emptyDir": {"medium": "Memory", "sizeLimit": "64Mi"},
                            },
                            {
                                "name": "docker",
                                "emptyDir": {"medium": "Memory", "sizeLimit": "16Mi"},
                            },
                            {"name": "work", "emptyDir": {"sizeLimit": "4Gi"}},
                            {
                                "name": "tmp",
                                "emptyDir": {"medium": "Memory", "sizeLimit": "256Mi"},
                            },
                        ],
                    },
                },
            },
        }

    def _labels(self, command: BuildCommand) -> dict[str, str]:
        return {
            "app.kubernetes.io/name": "build-worker",
            "app.kubernetes.io/part-of": "lrail-alpha-build",
            "layerrail.com/build-id": command.build_id,
            "layerrail.com/organization-id": command.organization_id,
            "layerrail.com/deployment-id": command.deployment_id,
        }
