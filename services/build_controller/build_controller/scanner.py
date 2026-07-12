from __future__ import annotations

import asyncio
from dataclasses import dataclass
from io import BytesIO
import json
import os
from pathlib import Path, PurePosixPath
import tarfile
import tempfile
from typing import Any

from .clients import RegistryCredential


class ScanError(RuntimeError):
    pass


@dataclass(frozen=True)
class ScanResult:
    sbom: dict[str, Any]
    report: dict[str, Any]
    summary: dict[str, int]
    passed: bool


class TrivyScanner:
    MAX_DOCUMENT_BYTES = 4 << 20
    MAX_EXPANDED_BYTES = 64 << 20
    MAX_FILE_BYTES = 16 << 20
    MAX_FILE_COUNT = 2_000

    def __init__(
        self,
        *,
        executable: Path,
        cache_dir: Path,
        max_critical: int,
    ):
        self._executable = executable
        self._cache_dir = cache_dir
        self._cache_dir.mkdir(parents=True, exist_ok=True)
        self._max_critical = max_critical

    async def scan_image(
        self,
        image_reference: str,
        credential: RegistryCredential,
    ) -> ScanResult:
        env = os.environ.copy()
        env.update(
            TRIVY_USERNAME=credential.username,
            TRIVY_PASSWORD=credential.password,
        )
        with tempfile.TemporaryDirectory(dir=self._cache_dir.parent) as directory:
            root = Path(directory)
            sbom_path = root / "sbom.json"
            report_path = root / "scan.json"
            await self._run(
                [
                    "image",
                    "--insecure",
                    "--format",
                    "cyclonedx",
                    "--output",
                    str(sbom_path),
                    image_reference,
                ],
                env=env,
            )
            await self._run(
                [
                    "image",
                    "--insecure",
                    "--format",
                    "json",
                    "--output",
                    str(report_path),
                    image_reference,
                ],
                env=env,
            )
            return self._result(sbom_path, report_path)

    async def scan_static(self, archive: bytes) -> ScanResult:
        with tempfile.TemporaryDirectory(dir=self._cache_dir.parent) as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            self._extract(archive, source)
            sbom_path = root / "sbom.json"
            report_path = root / "scan.json"
            await self._run(
                [
                    "fs",
                    "--format",
                    "cyclonedx",
                    "--output",
                    str(sbom_path),
                    str(source),
                ]
            )
            await self._run(
                [
                    "fs",
                    "--format",
                    "json",
                    "--output",
                    str(report_path),
                    str(source),
                ]
            )
            return self._result(sbom_path, report_path)

    async def _run(self, arguments: list[str], *, env: dict[str, str] | None = None) -> None:
        if not self._executable.is_file():
            raise ScanError("scanner_unavailable")
        process = await asyncio.create_subprocess_exec(
            str(self._executable),
            "--cache-dir",
            str(self._cache_dir),
            "--quiet",
            *arguments,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        try:
            _stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=300)
        except TimeoutError as error:
            process.kill()
            await process.wait()
            raise ScanError("scan_timeout") from error
        if process.returncode != 0:
            message = stderr.decode(errors="replace")[:500]
            raise ScanError("scan_failed:" + message.replace("\n", " "))

    def _result(self, sbom_path: Path, report_path: Path) -> ScanResult:
        try:
            if (
                sbom_path.stat().st_size > self.MAX_DOCUMENT_BYTES
                or report_path.stat().st_size > self.MAX_DOCUMENT_BYTES
            ):
                raise ScanError("scan_output_too_large")
            sbom = json.loads(sbom_path.read_bytes())
            report = json.loads(report_path.read_bytes())
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ScanError("scan_output_invalid") from error
        if not isinstance(sbom, dict) or not isinstance(report, dict):
            raise ScanError("scan_output_invalid")
        counts = {"critical": 0, "high": 0, "medium": 0, "low": 0, "unknown": 0}
        for result in report.get("Results") or []:
            if not isinstance(result, dict):
                continue
            for vulnerability in result.get("Vulnerabilities") or []:
                if not isinstance(vulnerability, dict):
                    continue
                severity = str(vulnerability.get("Severity", "UNKNOWN")).lower()
                counts[severity if severity in counts else "unknown"] += 1
        return ScanResult(
            sbom=sbom,
            report=report,
            summary=counts,
            passed=counts["critical"] <= self._max_critical,
        )

    def _extract(self, archive: bytes, destination: Path) -> None:
        try:
            value = tarfile.open(fileobj=BytesIO(archive), mode="r:")
        except tarfile.TarError as error:
            raise ScanError("static_archive_invalid") from error
        try:
            paths: set[str] = set()
            expanded = 0
            for member in value:
                path = PurePosixPath(member.name)
                if (
                    not member.name
                    or member.name.startswith("/")
                    or "\\" in member.name
                    or any(part in {"", ".", ".."} for part in member.name.split("/"))
                    or str(path) != member.name.rstrip("/")
                    or len(member.name.rstrip("/").encode()) > 512
                ):
                    raise ScanError("static_archive_invalid")
                target = destination.joinpath(*path.parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                if not member.isfile():
                    raise ScanError("static_archive_invalid")
                if member.name in paths or not 0 <= member.size <= self.MAX_FILE_BYTES:
                    raise ScanError("static_archive_invalid")
                paths.add(member.name)
                expanded += member.size
                if (
                    len(paths) > self.MAX_FILE_COUNT
                    or expanded > self.MAX_EXPANDED_BYTES
                ):
                    raise ScanError("static_archive_invalid")
                target.parent.mkdir(parents=True, exist_ok=True)
                source = value.extractfile(member)
                if source is None:
                    raise ScanError("static_archive_invalid")
                target.write_bytes(source.read())
        finally:
            value.close()
