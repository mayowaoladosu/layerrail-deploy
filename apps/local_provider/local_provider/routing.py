from __future__ import annotations

import os
from pathlib import Path
import re
import tempfile
from typing import Any

import yaml

from .state import StateStore


_HOSTNAME = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"
)


class InvalidRoute(ValueError):
    pass


class RouteWriter:
    def __init__(self, *, store: StateStore, routes_dir: Path, deploy_domain: str):
        self._store = store
        self._routes_dir = routes_dir
        self._deploy_domain = deploy_domain
        self._routes_dir.mkdir(parents=True, exist_ok=True)

    def apply(self, data: dict[str, Any]) -> dict[str, Any]:
        required = {
            "alias_id",
            "hostname",
            "current_revision_id",
            "current_deployment_id",
            "container_port",
        }
        if not required.issubset(data):
            raise InvalidRoute("routing command is incomplete")
        hostname = str(data["hostname"]).lower()
        if not _HOSTNAME.fullmatch(hostname) or not hostname.endswith(
            f".{self._deploy_domain}"
        ):
            raise InvalidRoute("routing hostname is invalid")
        port = int(data["container_port"])
        if not 1 <= port <= 65535:
            raise InvalidRoute("routing port is invalid")

        revision = self._store.revision_for_deployment(
            str(data["current_deployment_id"])
        )
        if not revision or revision["revision_id"] != data["current_revision_id"]:
            raise InvalidRoute("routing target is not ready locally")

        self._store.save_alias(
            alias_id=str(data["alias_id"]),
            hostname=hostname,
            revision_id=str(data["current_revision_id"]),
            deployment_id=str(data["current_deployment_id"]),
            container_name=str(revision["container_name"]),
            container_port=port,
        )
        self._write_all()
        return {
            "alias_id": str(data["alias_id"]),
            "hostname": hostname,
            "revision_id": str(data["current_revision_id"]),
        }

    def remove_deployment(self, deployment_id: str) -> None:
        self._store.remove_deployment(deployment_id)
        self._write_all()

    def _write_all(self) -> None:
        routers: dict[str, Any] = {}
        services: dict[str, Any] = {}
        for route in self._store.aliases():
            identifier = route["alias_id"].replace("-", "")
            service_name = f"lrail-alias-{identifier}"
            routers[service_name] = {
                "rule": f"Host(`{route['hostname']}`)",
                "entryPoints": ["web"],
                "service": service_name,
            }
            services[service_name] = {
                "loadBalancer": {
                    "servers": [
                        {
                            "url": (
                                f"http://{route['container_name']}:"
                                f"{route['container_port']}"
                            )
                        }
                    ]
                }
            }
        content = yaml.safe_dump(
            {"http": {"routers": routers, "services": services}},
            sort_keys=True,
        )
        destination = self._routes_dir / "lrail-local-provider.yml"
        descriptor, temporary = tempfile.mkstemp(
            prefix=".lrail-local-provider-", suffix=".yml", dir=self._routes_dir
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, destination)
        finally:
            if os.path.exists(temporary):
                os.remove(temporary)
