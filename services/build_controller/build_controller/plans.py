from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path


class UnsupportedProject(ValueError):
    pass


NODE_IMAGE = "node@sha256:a0b9bf06e4e6193cf7a0f58816cc935ff8c2a908f81e6f1a95432d679c54fbfd"


@dataclass(frozen=True)
class Plan:
    type: str
    artifact_kind: str
    dockerfile: str | None
    package_manager: str | None


def detect_plan(root: Path, workload_type: str) -> Plan:
    if workload_type not in {"web", "static"}:
        raise UnsupportedProject("unsupported workload type")
    dockerfile = root / "Dockerfile"
    package_path = root / "package.json"
    if dockerfile.is_file():
        if workload_type != "web":
            raise UnsupportedProject("Dockerfile static output is ambiguous")
        return Plan(
            type="dockerfile_web",
            artifact_kind="oci",
            dockerfile=None,
            package_manager=None,
        )

    package = _package(package_path) if package_path.is_file() else None
    if package is not None:
        manager = _package_manager(root, package)
        scripts = package.get("scripts")
        scripts = scripts if isinstance(scripts, dict) else {}
        if workload_type == "web":
            if not isinstance(scripts.get("start"), str) or not scripts["start"].strip():
                raise UnsupportedProject("Node web service requires an explicit start script")
            return Plan(
                type="node_web",
                artifact_kind="oci",
                dockerfile=_node_web_dockerfile(manager),
                package_manager=manager,
            )
        if isinstance(scripts.get("build"), str) and scripts["build"].strip():
            return Plan(
                type="node_static",
                artifact_kind="static",
                dockerfile=_node_static_dockerfile(manager),
                package_manager=manager,
            )

    if workload_type == "static" and (root / "index.html").is_file():
        return Plan(
            type="plain_static",
            artifact_kind="static",
            dockerfile="FROM scratch\nCOPY . /\n",
            package_manager=None,
        )
    raise UnsupportedProject("No supported build plan was detected")


def _package(path: Path) -> dict[str, object]:
    if path.stat().st_size > 1 << 20:
        raise UnsupportedProject("package.json is too large")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise UnsupportedProject("package.json is invalid") from error
    if not isinstance(value, dict):
        raise UnsupportedProject("package.json is invalid")
    return value


def _package_manager(root: Path, package: dict[str, object]) -> str:
    lockfiles = {
        "npm": root / "package-lock.json",
        "pnpm": root / "pnpm-lock.yaml",
        "yarn": root / "yarn.lock",
    }
    present = [name for name, path in lockfiles.items() if path.is_file()]
    declared = str(package.get("packageManager", "")).split("@", 1)[0]
    if declared:
        if declared not in lockfiles or not lockfiles[declared].is_file():
            raise UnsupportedProject("declared package manager lockfile is missing")
        return declared
    if len(present) != 1:
        raise UnsupportedProject("Node project must have exactly one lockfile")
    return present[0]


def _install_command(manager: str) -> str:
    return {
        "npm": "npm ci",
        "pnpm": "corepack enable && pnpm install --frozen-lockfile",
        "yarn": "corepack enable && yarn install --immutable",
    }[manager]


def _run_command(manager: str, script: str) -> str:
    return {
        "npm": f"npm run {script}",
        "pnpm": f"pnpm run {script}",
        "yarn": f"yarn {script}",
    }[manager]


def _node_web_dockerfile(manager: str) -> str:
    return f"""FROM {NODE_IMAGE}
WORKDIR /app
COPY . .
RUN {_install_command(manager)}
ENV NODE_ENV=production PORT=8000
USER node
EXPOSE 8000
CMD [\"{manager}\", \"{('start' if manager != 'yarn' else 'start')}\"]
"""


def _node_static_dockerfile(manager: str) -> str:
    return f"""FROM {NODE_IMAGE} AS build
WORKDIR /app
COPY . .
RUN {_install_command(manager)}
RUN {_run_command(manager, 'build')}
RUN set -eu; mkdir /site; for output in dist build out public; do if [ -f \"$output/index.html\" ]; then cp -a \"$output/.\" /site/; exit 0; fi; done; echo 'static output missing index.html' >&2; exit 1
FROM scratch
COPY --from=build /site /
"""
