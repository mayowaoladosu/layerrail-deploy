from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import sqlite3
import threading
import time
from typing import Any

from .contracts import BuildCommand, WorkerResult, canonical_json


class OperationConflict(ValueError):
    pass


@dataclass(frozen=True)
class Operation:
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
    request_digest: str
    status: str
    job_name: str
    secret_name: str
    registry_credential_id: str | None
    completion_observed_at: int | None
    result: dict[str, Any]
    created_at: int
    updated_at: int


class OperationStore:
    STATUSES = {
        "preparing",
        "running",
        "result_pending",
        "completed",
        "failed",
        "canceling",
        "canceled",
    }

    def __init__(self, state_dir: Path):
        state_dir.mkdir(parents=True, exist_ok=True)
        self._state_dir = state_dir
        self._result_dir = state_dir / "results"
        self._result_dir.mkdir(mode=0o700, exist_ok=True)
        self._connection = sqlite3.connect(
            state_dir / "build-controller.sqlite3", check_same_thread=False
        )
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("PRAGMA journal_mode=WAL")
        self._connection.execute("PRAGMA synchronous=FULL")
        self._lock = threading.RLock()
        self._migrate()

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def register(
        self, command: BuildCommand, *, now: int | None = None
    ) -> tuple[Operation, bool]:
        current = int(time.time()) if now is None else now
        with self._lock, self._connection:
            row = self._connection.execute(
                "SELECT * FROM operations WHERE build_id = ?", (command.build_id,)
            ).fetchone()
            if row:
                operation = self._row(row)
                if operation.request_digest != command.request_digest:
                    raise OperationConflict("build command conflicts with existing state")
                return operation, False
            self._connection.execute(
                """
                INSERT INTO operations (
                  event_id, operation_id, organization_id, deployment_id,
                  build_id, revision_id, service_id, expected_version,
                  workload_type, repository, source_commit, source_root,
                  descriptor_digest, correlation_id, request_digest, status,
                  job_name, secret_name, registry_credential_id, result_json,
                  created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, '{}', ?, ?)
                """,
                (
                    command.event_id,
                    command.operation_id,
                    command.organization_id,
                    command.deployment_id,
                    command.build_id,
                    command.revision_id,
                    command.service_id,
                    command.expected_version,
                    command.workload_type,
                    command.repository,
                    command.source_commit,
                    command.source_root,
                    command.descriptor_digest,
                    command.correlation_id,
                    command.request_digest,
                    "preparing",
                    command.job_name,
                    command.secret_name,
                    current,
                    current,
                ),
            )
        return self.get(command.build_id), True

    def get(self, build_id: str) -> Operation:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM operations WHERE build_id = ?", (build_id,)
            ).fetchone()
        if row is None:
            raise KeyError(build_id)
        return self._row(row)

    def find_by_deployment(self, deployment_id: str) -> Operation | None:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT * FROM operations
                WHERE deployment_id = ?
                ORDER BY created_at DESC, build_id DESC
                LIMIT 1
                """,
                (deployment_id,),
            ).fetchone()
        return self._row(row) if row else None

    def set_running(
        self,
        build_id: str,
        *,
        registry_credential_id: str,
        now: int | None = None,
    ) -> Operation:
        return self._transition(
            build_id,
            from_statuses={"preparing", "running"},
            status="running",
            registry_credential_id=registry_credential_id,
            now=now,
        )

    def save_result(
        self, result: WorkerResult, *, now: int | None = None
    ) -> tuple[Operation, bool]:
        operation = self.get(result.build_id)
        if (
            operation.operation_id != result.operation_id
            or operation.source_commit != result.source_commit
        ):
            raise OperationConflict("worker result conflicts with build command")
        safe = result.safe_value()
        digest = "sha256:" + __import__("hashlib").sha256(canonical_json(safe)).hexdigest()
        existing_digest = operation.result.get("result_digest")
        if operation.status in {"result_pending", "completed", "failed"}:
            if existing_digest != digest:
                raise OperationConflict("worker result conflicts with existing result")
            return operation, False

        if result.static_archive is not None:
            target = self._archive_path(result.build_id)
            temporary = target.with_suffix(".tmp")
            temporary.write_bytes(result.static_archive)
            os.chmod(temporary, 0o600)
            os.replace(temporary, target)
        safe["result_digest"] = digest
        safe["static_archive_present"] = result.static_archive is not None
        current = int(time.time()) if now is None else now
        safe["result_received_at"] = current
        with self._lock, self._connection:
            cursor = self._connection.execute(
                """
                UPDATE operations
                SET status = 'result_pending', result_json = ?, updated_at = ?
                WHERE build_id = ? AND status = 'running'
                """,
                (json.dumps(safe, separators=(",", ":"), sort_keys=True), current, result.build_id),
            )
            if cursor.rowcount != 1:
                raise OperationConflict("worker result arrived in an invalid state")
        return self.get(result.build_id), True

    def load_archive(self, build_id: str) -> bytes | None:
        path = self._archive_path(build_id)
        return path.read_bytes() if path.is_file() else None

    def observe_completion(
        self, build_id: str, *, now: int | None = None
    ) -> Operation:
        current = int(time.time()) if now is None else now
        with self._lock, self._connection:
            self._connection.execute(
                """
                UPDATE operations
                SET completion_observed_at = COALESCE(completion_observed_at, ?)
                WHERE build_id = ? AND status = 'running'
                """,
                (current, build_id),
            )
        return self.get(build_id)

    def merge_result(
        self, build_id: str, values: dict[str, Any]
    ) -> Operation:
        canonical = json.loads(json.dumps(values, separators=(",", ":"), sort_keys=True))
        with self._lock, self._connection:
            operation = self.get(build_id)
            if operation.status != "result_pending":
                raise OperationConflict("result checkpoint arrived in an invalid state")
            result = operation.result | canonical
            self._connection.execute(
                """
                UPDATE operations
                SET result_json = ?
                WHERE build_id = ? AND status = 'result_pending'
                """,
                (json.dumps(result, separators=(",", ":"), sort_keys=True), build_id),
            )
        return self.get(build_id)

    def mark(
        self,
        build_id: str,
        status: str,
        *,
        result: dict[str, Any] | None = None,
        now: int | None = None,
    ) -> Operation:
        if status not in self.STATUSES:
            raise ValueError("operation status is invalid")
        current = int(time.time()) if now is None else now
        with self._lock, self._connection:
            existing = self.get(build_id)
            value = existing.result if result is None else result
            self._connection.execute(
                """
                UPDATE operations
                SET status = ?, result_json = ?, updated_at = ?
                WHERE build_id = ?
                """,
                (
                    status,
                    json.dumps(value, separators=(",", ":"), sort_keys=True),
                    current,
                    build_id,
                ),
            )
        if status in {"completed", "failed", "canceled"}:
            self._archive_path(build_id).unlink(missing_ok=True)
        return self.get(build_id)

    def pending(self) -> tuple[Operation, ...]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT * FROM operations
                WHERE status IN ('running', 'result_pending', 'canceling')
                ORDER BY created_at, build_id
                """
            ).fetchall()
        return tuple(self._row(row) for row in rows)

    def _transition(
        self,
        build_id: str,
        *,
        from_statuses: set[str],
        status: str,
        registry_credential_id: str | None = None,
        now: int | None = None,
    ) -> Operation:
        current = int(time.time()) if now is None else now
        with self._lock, self._connection:
            operation = self.get(build_id)
            if operation.status not in from_statuses:
                raise OperationConflict("operation transition is invalid")
            self._connection.execute(
                """
                UPDATE operations
                SET status = ?, registry_credential_id = COALESCE(?, registry_credential_id),
                    completion_observed_at = NULL, updated_at = ?
                WHERE build_id = ?
                """,
                (status, registry_credential_id, current, build_id),
            )
        return self.get(build_id)

    def _archive_path(self, build_id: str) -> Path:
        return self._result_dir / f"{build_id}.tar"

    def _migrate(self) -> None:
        with self._connection:
            self._connection.execute(
                """
                CREATE TABLE IF NOT EXISTS operations (
                  event_id TEXT NOT NULL,
                  operation_id TEXT NOT NULL,
                  organization_id TEXT NOT NULL,
                  deployment_id TEXT NOT NULL,
                  build_id TEXT PRIMARY KEY,
                  revision_id TEXT NOT NULL,
                  service_id TEXT NOT NULL,
                  expected_version INTEGER NOT NULL,
                  workload_type TEXT NOT NULL,
                  repository TEXT NOT NULL,
                  source_commit TEXT NOT NULL,
                  source_root TEXT NOT NULL,
                  descriptor_digest TEXT NOT NULL,
                  correlation_id TEXT NOT NULL,
                  request_digest TEXT NOT NULL,
                  status TEXT NOT NULL,
                  job_name TEXT NOT NULL,
                  secret_name TEXT NOT NULL,
                  registry_credential_id TEXT,
                  completion_observed_at INTEGER,
                  result_json TEXT NOT NULL,
                  created_at INTEGER NOT NULL,
                  updated_at INTEGER NOT NULL
                )
                """
            )
            columns = {
                row["name"]
                for row in self._connection.execute("PRAGMA table_info(operations)")
            }
            if "completion_observed_at" not in columns:
                self._connection.execute(
                    "ALTER TABLE operations ADD COLUMN completion_observed_at INTEGER"
                )
            self._connection.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS operations_operation_id ON operations(operation_id)"
            )
            self._connection.execute(
                "CREATE INDEX IF NOT EXISTS operations_deployment_id ON operations(deployment_id, created_at)"
            )

    def _row(self, row: sqlite3.Row) -> Operation:
        result = json.loads(row["result_json"])
        if not isinstance(result, dict):
            raise OperationConflict("stored result is invalid")
        return Operation(
            event_id=row["event_id"],
            operation_id=row["operation_id"],
            organization_id=row["organization_id"],
            deployment_id=row["deployment_id"],
            build_id=row["build_id"],
            revision_id=row["revision_id"],
            service_id=row["service_id"],
            expected_version=int(row["expected_version"]),
            workload_type=row["workload_type"],
            repository=row["repository"],
            source_commit=row["source_commit"],
            source_root=row["source_root"],
            descriptor_digest=row["descriptor_digest"],
            correlation_id=row["correlation_id"],
            request_digest=row["request_digest"],
            status=row["status"],
            job_name=row["job_name"],
            secret_name=row["secret_name"],
            registry_credential_id=row["registry_credential_id"],
            completion_observed_at=(
                int(row["completion_observed_at"])
                if row["completion_observed_at"] is not None
                else None
            ),
            result=result,
            created_at=int(row["created_at"]),
            updated_at=int(row["updated_at"]),
        )
