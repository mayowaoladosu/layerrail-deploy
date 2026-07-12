from __future__ import annotations

import base64
from dataclasses import dataclass
import hashlib
import json
from pathlib import PurePosixPath
import re
from typing import Any
from urllib.parse import urlsplit
from uuid import UUID


class InvalidContract(ValueError):
    pass


_UUID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
_COMMIT = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
_CODE = re.compile(r"^[a-z][a-z0-9_]{0,63}$")
_REPOSITORY = re.compile(
    r"^lrail/[0-9a-f-]{36}/[0-9a-f-]{36}$"
)
_ENVELOPE_KEYS = {
    "event_id",
    "event_type",
    "occurred_at",
    "organization_id",
    "resource_id",
    "correlation_id",
    "idempotency_key",
    "producer",
    "schema_version",
    "data",
}
_BUILD_KEYS = {
    "contract_version",
    "command_type",
    "operation_id",
    "organization_id",
    "deployment_id",
    "build_id",
    "revision_id",
    "service_id",
    "expected_version",
    "workload_type",
    "repository",
    "source_commit",
    "source_root",
    "descriptor_digest",
}
_CANCEL_KEYS = {
    "contract_version",
    "command_type",
    "operation_id",
    "organization_id",
    "deployment_id",
    "build_id",
    "expected_version",
}


def _uuid(value: object) -> str:
    value = str(value)
    if not _UUID.fullmatch(value):
        raise InvalidContract("identity is invalid")
    return value


def _version(value: object) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 2_147_483_647:
        raise InvalidContract("version is invalid")
    return value


def _digest(value: object) -> str:
    value = str(value)
    if not _DIGEST.fullmatch(value):
        raise InvalidContract("digest is invalid")
    return value


def _source_root(value: object) -> str:
    value = str(value)
    if value == ".":
        return value
    if (
        not value
        or len(value.encode()) > 1024
        or value.startswith(("/", "\\"))
        or "\\" in value
        or ":" in value
    ):
        raise InvalidContract("source root is invalid")
    path = PurePosixPath(value)
    if str(path) != value or any(part in {"", ".", ".."} for part in value.split("/")):
        raise InvalidContract("source root is invalid")
    return value


def canonical_json(value: object) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode()


@dataclass(frozen=True)
class BuildCommand:
    event_id: str
    operation_id: str
    organization_id: str
    deployment_id: str
    build_id: str
    revision_id: str
    service_id: str
    expected_version: int
    workload_type: str
    repository: str
    source_commit: str
    source_root: str
    descriptor_digest: str
    correlation_id: str

    @classmethod
    def parse(cls, envelope: object) -> "BuildCommand":
        if not isinstance(envelope, dict) or set(envelope) != _ENVELOPE_KEYS:
            raise InvalidContract("build envelope is invalid")
        if (
            envelope.get("event_type") != "build.requested.v1"
            or envelope.get("producer") != "control-plane"
            or envelope.get("schema_version") != 1
        ):
            raise InvalidContract("build envelope is invalid")
        data = envelope.get("data")
        if not isinstance(data, dict) or set(data) != _BUILD_KEYS:
            raise InvalidContract("build command is invalid")
        if data.get("contract_version") != 1 or data.get("command_type") != "build.start":
            raise InvalidContract("build command is invalid")
        build_id = _uuid(data.get("build_id"))
        organization_id = _uuid(data.get("organization_id"))
        service_id = _uuid(data.get("service_id"))
        if build_id != _uuid(envelope.get("resource_id")):
            raise InvalidContract("build resource is invalid")
        if organization_id != _uuid(envelope.get("organization_id")):
            raise InvalidContract("build owner is invalid")
        workload_type = str(data.get("workload_type"))
        if workload_type not in {"web", "static"}:
            raise InvalidContract("workload type is invalid")
        repository = str(data.get("repository"))
        if (
            not _REPOSITORY.fullmatch(repository)
            or repository != f"lrail/{organization_id}/{service_id}"
        ):
            raise InvalidContract("repository is invalid")
        source_commit = str(data.get("source_commit"))
        if not _COMMIT.fullmatch(source_commit):
            raise InvalidContract("source commit is invalid")
        return cls(
            event_id=_uuid(envelope.get("event_id")),
            operation_id=_uuid(data.get("operation_id")),
            organization_id=organization_id,
            deployment_id=_uuid(data.get("deployment_id")),
            build_id=build_id,
            revision_id=_uuid(data.get("revision_id")),
            service_id=service_id,
            expected_version=_version(data.get("expected_version")),
            workload_type=workload_type,
            repository=repository,
            source_commit=source_commit,
            source_root=_source_root(data.get("source_root")),
            descriptor_digest=_digest(data.get("descriptor_digest")),
            correlation_id=_uuid(envelope.get("correlation_id")),
        )

    @property
    def job_name(self) -> str:
        return "build-" + self.build_id.replace("-", "")[:24]

    @property
    def secret_name(self) -> str:
        return "build-credentials-" + self.build_id.replace("-", "")[:16]

    def command_value(self) -> dict[str, object]:
        return {
            "contract_version": 1,
            "command_type": "build.start",
            "operation_id": self.operation_id,
            "organization_id": self.organization_id,
            "deployment_id": self.deployment_id,
            "build_id": self.build_id,
            "revision_id": self.revision_id,
            "service_id": self.service_id,
            "expected_version": self.expected_version,
            "workload_type": self.workload_type,
            "repository": self.repository,
            "source_commit": self.source_commit,
            "source_root": self.source_root,
            "descriptor_digest": self.descriptor_digest,
        }

    @property
    def request_digest(self) -> str:
        return "sha256:" + hashlib.sha256(canonical_json(self.command_value())).hexdigest()


@dataclass(frozen=True)
class CancelCommand:
    event_id: str
    operation_id: str
    organization_id: str
    deployment_id: str
    build_id: str
    expected_version: int

    @classmethod
    def parse(cls, envelope: object) -> "CancelCommand":
        if not isinstance(envelope, dict) or set(envelope) != _ENVELOPE_KEYS:
            raise InvalidContract("cancellation envelope is invalid")
        if (
            envelope.get("event_type") != "build.cancellation.requested.v1"
            or envelope.get("producer") != "control-plane"
            or envelope.get("schema_version") != 1
        ):
            raise InvalidContract("cancellation envelope is invalid")
        data = envelope.get("data")
        if not isinstance(data, dict) or set(data) != _CANCEL_KEYS:
            raise InvalidContract("cancellation command is invalid")
        if data.get("contract_version") != 1 or data.get("command_type") != "build.cancel":
            raise InvalidContract("cancellation command is invalid")
        build_id = _uuid(data.get("build_id"))
        organization_id = _uuid(data.get("organization_id"))
        if build_id != _uuid(envelope.get("resource_id")):
            raise InvalidContract("cancellation resource is invalid")
        if organization_id != _uuid(envelope.get("organization_id")):
            raise InvalidContract("cancellation owner is invalid")
        return cls(
            event_id=_uuid(envelope.get("event_id")),
            operation_id=_uuid(data.get("operation_id")),
            organization_id=organization_id,
            deployment_id=_uuid(data.get("deployment_id")),
            build_id=build_id,
            expected_version=_version(data.get("expected_version")),
        )


@dataclass(frozen=True, repr=False)
class CloneCredentials:
    build_id: str
    clone_url: str
    username: str
    secret: str
    expires_at: str

    @classmethod
    def parse(cls, value: object, *, build_id: str) -> "CloneCredentials":
        keys = {
            "contract_version",
            "build_id",
            "clone_url",
            "username",
            "secret",
            "expires_at",
        }
        if not isinstance(value, dict) or set(value) != keys or value.get("contract_version") != 1:
            raise InvalidContract("clone credentials are invalid")
        if _uuid(value.get("build_id")) != _uuid(build_id):
            raise InvalidContract("clone credential owner is invalid")
        parsed = urlsplit(str(value.get("clone_url")))
        local_fixture = (
            parsed.scheme == "http"
            and parsed.hostname == "git-fixture.lrail-system.svc.cluster.local"
            and parsed.port == 8080
        )
        if (
            (parsed.scheme != "https" and not local_fixture)
            or not parsed.hostname
            or parsed.username
            or parsed.password
        ):
            raise InvalidContract("clone URL is invalid")
        username = str(value.get("username"))
        secret = str(value.get("secret"))
        expires_at = str(value.get("expires_at"))
        if not 1 <= len(username) <= 255 or not 1 <= len(secret) <= 4096:
            raise InvalidContract("clone credentials are invalid")
        return cls(
            build_id=build_id,
            clone_url=parsed.geturl(),
            username=username,
            secret=secret,
            expires_at=expires_at,
        )

    def __repr__(self) -> str:
        return (
            f"CloneCredentials(build_id={self.build_id!r}, clone_url={self.clone_url!r}, "
            f"username={self.username!r}, secret=[REDACTED], expires_at={self.expires_at!r})"
        )


@dataclass(frozen=True)
class Failure:
    phase: str
    code: str
    message: str


@dataclass(frozen=True)
class WorkerResult:
    operation_id: str
    build_id: str
    source_commit: str
    status: str
    plan_type: str | None
    artifact_kind: str | None
    artifact_digest: str | None
    image_reference: str | None
    static_archive: bytes | None
    log_lines: tuple[str, ...]
    failure: Failure | None

    @classmethod
    def parse(
        cls,
        value: object,
        *,
        build_id: str,
        max_static_archive_bytes: int,
        max_log_lines: int,
    ) -> "WorkerResult":
        if not isinstance(value, dict):
            raise InvalidContract("worker result is invalid")
        common = {
            "contract_version",
            "operation_id",
            "build_id",
            "source_commit",
            "status",
            "log_lines",
        }
        status = str(value.get("status"))
        completed = common | {
            "plan_type",
            "artifact_kind",
            "artifact_digest",
        }
        if status == "completed":
            artifact_kind = str(value.get("artifact_kind"))
            completed.add("image_reference" if artifact_kind == "oci" else "static_archive")
            if set(value) != completed:
                raise InvalidContract("completed result is invalid")
        elif status == "failed":
            if set(value) != common | {"failure"}:
                raise InvalidContract("failed result is invalid")
        else:
            raise InvalidContract("worker status is invalid")
        if value.get("contract_version") != 1 or _uuid(value.get("build_id")) != _uuid(build_id):
            raise InvalidContract("worker identity is invalid")
        source_commit = str(value.get("source_commit"))
        if not _COMMIT.fullmatch(source_commit):
            raise InvalidContract("worker commit is invalid")
        lines = value.get("log_lines")
        if (
            not isinstance(lines, list)
            or len(lines) > max_log_lines
            or any(not isinstance(line, str) or not 1 <= len(line.encode()) <= 4096 for line in lines)
        ):
            raise InvalidContract("worker logs are invalid")

        if status == "failed":
            raw_failure = value.get("failure")
            if not isinstance(raw_failure, dict) or set(raw_failure) != {"phase", "code", "message"}:
                raise InvalidContract("worker failure is invalid")
            phase = str(raw_failure.get("phase"))
            code = str(raw_failure.get("code"))
            message = str(raw_failure.get("message"))
            if not _CODE.fullmatch(phase) or not _CODE.fullmatch(code) or not 1 <= len(message.encode()) <= 500:
                raise InvalidContract("worker failure is invalid")
            return cls(
                operation_id=_uuid(value.get("operation_id")),
                build_id=build_id,
                source_commit=source_commit,
                status=status,
                plan_type=None,
                artifact_kind=None,
                artifact_digest=None,
                image_reference=None,
                static_archive=None,
                log_lines=tuple(lines),
                failure=Failure(phase=phase, code=code, message=message),
            )

        plan_type = str(value.get("plan_type"))
        artifact_kind = str(value.get("artifact_kind"))
        plan_artifacts = {
            "dockerfile_web": "oci",
            "node_web": "oci",
            "plain_static": "static",
            "node_static": "static",
        }
        if plan_type not in plan_artifacts:
            raise InvalidContract("build plan is invalid")
        if artifact_kind != plan_artifacts[plan_type]:
            raise InvalidContract("artifact kind is invalid")
        artifact_digest = _digest(value.get("artifact_digest"))
        image_reference: str | None = None
        static_archive: bytes | None = None
        if artifact_kind == "oci":
            image_reference = str(value.get("image_reference"))
            if (
                not image_reference.endswith("@" + artifact_digest)
                or "@sha256:" not in image_reference
                or len(image_reference) > 512
            ):
                raise InvalidContract("image reference is invalid")
        else:
            encoded = str(value.get("static_archive"))
            try:
                static_archive = base64.b64decode(encoded, validate=True)
            except ValueError as error:
                raise InvalidContract("static archive is invalid") from error
            if not static_archive or len(static_archive) > max_static_archive_bytes:
                raise InvalidContract("static archive is invalid")
            if "sha256:" + hashlib.sha256(static_archive).hexdigest() != artifact_digest:
                raise InvalidContract("static archive digest is invalid")
        return cls(
            operation_id=_uuid(value.get("operation_id")),
            build_id=build_id,
            source_commit=source_commit,
            status=status,
            plan_type=plan_type,
            artifact_kind=artifact_kind,
            artifact_digest=artifact_digest,
            image_reference=image_reference,
            static_archive=static_archive,
            log_lines=tuple(lines),
            failure=None,
        )

    def safe_value(self) -> dict[str, Any]:
        value: dict[str, Any] = {
            "operation_id": self.operation_id,
            "build_id": self.build_id,
            "source_commit": self.source_commit,
            "status": self.status,
            "log_lines": list(self.log_lines),
        }
        if self.failure:
            value["failure"] = {
                "phase": self.failure.phase,
                "code": self.failure.code,
                "message": self.failure.message,
            }
        else:
            value.update(
                plan_type=self.plan_type,
                artifact_kind=self.artifact_kind,
                artifact_digest=self.artifact_digest,
                image_reference=self.image_reference,
            )
        return value
