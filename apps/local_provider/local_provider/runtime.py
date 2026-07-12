from __future__ import annotations

import asyncio
from dataclasses import dataclass
import logging
from typing import Any

import aiodocker
from aiodocker.exceptions import DockerError
import httpx


logger = logging.getLogger(__name__)


class RuntimeConflict(RuntimeError):
    pass


class RuntimeUnavailable(RuntimeError):
    pass


class ReadinessFailed(RuntimeError):
    pass


@dataclass(frozen=True)
class RuntimeInstance:
    container_id: str
    container_name: str
    container_port: int


class DockerRuntime:
    MEMORY_BYTES = 256 * 1024 * 1024
    NANO_CPUS = 500_000_000
    PIDS_LIMIT = 128

    def __init__(
        self,
        *,
        docker: aiodocker.Docker,
        runtime_network: str,
        container_port: int,
    ):
        self._docker = docker
        self._runtime_network = runtime_network
        self._container_port = container_port

    async def ensure(
        self,
        *,
        deployment_id: str,
        organization_id: str,
        source: dict[str, Any],
        source_digest: str,
        immutable_hostname: str,
        readiness_path: str,
    ) -> RuntimeInstance:
        name = f"lrail-runtime-{deployment_id}"
        container = await self._find_container(name)
        if container:
            info = await container.show()
            self._verify_existing(
                info,
                deployment_id=deployment_id,
                organization_id=organization_id,
                source_digest=source_digest,
            )
        else:
            image = await self._ensure_image(source=source, expected_digest=source_digest)
            container = await self._docker.containers.create(
                self._container_config(
                    image=image,
                    name=name,
                    deployment_id=deployment_id,
                    organization_id=organization_id,
                    source_digest=source_digest,
                    immutable_hostname=immutable_hostname,
                    readiness_path=readiness_path,
                ),
                name=name,
            )
            info = await container.show()

        if not info.get("State", {}).get("Running"):
            await container.start()
            info = await container.show()

        await self._wait_ready(name=name, path=readiness_path)
        return RuntimeInstance(
            container_id=str(info["Id"]),
            container_name=name,
            container_port=self._container_port,
        )

    async def remove(self, *, deployment_id: str, organization_id: str) -> None:
        name = f"lrail-runtime-{deployment_id}"
        container = await self._find_container(name)
        if not container:
            return
        info = await container.show()
        self._verify_identity(
            info,
            deployment_id=deployment_id,
            organization_id=organization_id,
        )
        try:
            await container.delete(force=True)
        except DockerError as error:
            if error.status != 404:
                raise RuntimeUnavailable("Docker container removal failed") from error

    def resource_profile(self) -> dict[str, int]:
        return {
            "cpu_millicores": self.NANO_CPUS // 1_000_000,
            "memory_bytes": self.MEMORY_BYTES,
        }

    async def logs(
        self, *, deployment_id: str, organization_id: str, limit: int = 200
    ) -> list[str]:
        container = await self._find_container(f"lrail-runtime-{deployment_id}")
        if not container:
            raise RuntimeConflict("Managed runtime was not found")
        info = await container.show()
        self._verify_identity(
            info,
            deployment_id=deployment_id,
            organization_id=organization_id,
        )
        try:
            lines = await container.log(
                stdout=True,
                stderr=True,
                timestamps=True,
                tail=max(1, min(limit, 1000)),
            )
        except DockerError as error:
            if error.status == 404:
                raise RuntimeConflict("Managed runtime was not found") from error
            raise RuntimeUnavailable("Docker log read failed") from error
        return [str(line) for line in lines]

    async def _find_container(self, name: str):
        try:
            return await self._docker.containers.get(name)
        except DockerError as error:
            if error.status == 404:
                return None
            raise RuntimeUnavailable("Docker container lookup failed") from error

    async def _ensure_image(
        self, *, source: dict[str, Any], expected_digest: str
    ) -> str:
        reference = str(source["reference"])
        image = await self._inspect_image(reference)
        if not image or not self._image_matches(image, expected_digest):
            pinned_reference = f"{reference}@{expected_digest}"
            try:
                await self._docker.images.pull(pinned_reference)
            except DockerError as error:
                raise RuntimeUnavailable("Pinned OCI image pull failed") from error
            image = await self._inspect_image(pinned_reference)
        if not image or not self._image_matches(image, expected_digest):
            raise RuntimeConflict("OCI image digest does not match the command")
        return reference

    async def _inspect_image(self, reference: str) -> dict[str, Any] | None:
        try:
            return await self._docker.images.inspect(reference)
        except DockerError as error:
            if error.status == 404:
                return None
            raise RuntimeUnavailable("Docker image inspection failed") from error

    def _image_matches(self, image: dict[str, Any], expected_digest: str) -> bool:
        if image.get("Id") == expected_digest:
            return True
        return any(
            str(repo_digest).endswith(f"@{expected_digest}")
            for repo_digest in image.get("RepoDigests") or []
        )

    def _container_config(
        self,
        *,
        image: str,
        name: str,
        deployment_id: str,
        organization_id: str,
        source_digest: str,
        immutable_hostname: str,
        readiness_path: str,
    ) -> dict[str, Any]:
        service = f"lrail-{deployment_id}"
        labels = {
            "com.layerrail.managed": "true",
            "com.layerrail.deployment-id": deployment_id,
            "com.layerrail.organization-id": organization_id,
            "com.layerrail.source-digest": source_digest,
            "traefik.enable": "true",
            "traefik.docker.network": self._runtime_network,
            f"traefik.http.routers.{service}.rule": f"Host(`{immutable_hostname}`)",
            f"traefik.http.routers.{service}.entrypoints": "web",
            f"traefik.http.routers.{service}.service": service,
            f"traefik.http.services.{service}.loadbalancer.server.port": str(
                self._container_port
            ),
        }
        return {
            "Image": image,
            "Hostname": name,
            "User": "10001:10001",
            "Env": [
                f"PORT={self._container_port}",
                f"LRAIL_DEPLOYMENT_ID={deployment_id}",
            ],
            "Healthcheck": {
                "Test": [
                    "CMD",
                    "python",
                    "-c",
                    (
                        "import sys; from urllib.request import urlopen; "
                        f"response = urlopen('http://127.0.0.1:{self._container_port}' + sys.argv[1], timeout=2); "
                        "raise SystemExit(0 if 200 <= response.status < 400 else 1)"
                    ),
                    readiness_path,
                ],
                "Interval": 5_000_000_000,
                "Timeout": 2_000_000_000,
                "Retries": 30,
                "StartPeriod": 1_000_000_000,
            },
            "Labels": labels,
            "HostConfig": {
                "AutoRemove": False,
                "ReadonlyRootfs": True,
                "CapDrop": ["ALL"],
                "SecurityOpt": ["no-new-privileges:true"],
                "Memory": self.MEMORY_BYTES,
                "NanoCpus": self.NANO_CPUS,
                "PidsLimit": self.PIDS_LIMIT,
                "Tmpfs": {"/tmp": "rw,noexec,nosuid,size=16777216"},
                "NetworkMode": self._runtime_network,
                "RestartPolicy": {"Name": "unless-stopped"},
            },
            "NetworkingConfig": {
                "EndpointsConfig": {
                    self._runtime_network: {"Aliases": [name]}
                }
            },
        }

    def _verify_existing(
        self,
        info: dict[str, Any],
        *,
        deployment_id: str,
        organization_id: str,
        source_digest: str,
    ) -> None:
        labels = info.get("Config", {}).get("Labels") or {}
        expected = {
            "com.layerrail.managed": "true",
            "com.layerrail.deployment-id": deployment_id,
            "com.layerrail.organization-id": organization_id,
            "com.layerrail.source-digest": source_digest,
        }
        if any(labels.get(key) != value for key, value in expected.items()):
            raise RuntimeConflict("Existing runtime identity does not match")

    def _verify_identity(
        self,
        info: dict[str, Any],
        *,
        deployment_id: str,
        organization_id: str,
    ) -> None:
        labels = info.get("Config", {}).get("Labels") or {}
        if (
            labels.get("com.layerrail.managed") != "true"
            or labels.get("com.layerrail.deployment-id") != deployment_id
            or labels.get("com.layerrail.organization-id") != organization_id
        ):
            raise RuntimeConflict("Existing runtime identity does not match")

    async def _wait_ready(self, *, name: str, path: str) -> None:
        url = f"http://{name}:{self._container_port}{path}"
        async with httpx.AsyncClient(timeout=2.0, trust_env=False) as client:
            for _attempt in range(60):
                try:
                    response = await client.get(url)
                    if 200 <= response.status_code < 400:
                        return
                except httpx.HTTPError:
                    pass
                await asyncio.sleep(0.5)
        raise ReadinessFailed("Runtime readiness check failed")
