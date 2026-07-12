from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import sqlite3
from typing import Any, Iterator

from .contracts import canonical_json


class EventConflict(ValueError):
    pass


class StateStore:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._connection = sqlite3.connect(path)
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("PRAGMA journal_mode=WAL")
        self._connection.execute("PRAGMA synchronous=FULL")
        self._migrate()

    def close(self) -> None:
        self._connection.close()

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        self._connection.execute("BEGIN IMMEDIATE")
        try:
            yield self._connection
            self._connection.commit()
        except BaseException:
            self._connection.rollback()
            raise

    def _migrate(self) -> None:
        with self.transaction() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS events (
                    event_id TEXT PRIMARY KEY,
                    payload_digest TEXT NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('processing', 'completed')),
                    result_json TEXT,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS revisions (
                    revision_id TEXT PRIMARY KEY,
                    deployment_id TEXT NOT NULL UNIQUE,
                    container_id TEXT NOT NULL,
                    container_name TEXT NOT NULL,
                    container_port INTEGER NOT NULL,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS aliases (
                    alias_id TEXT PRIMARY KEY,
                    hostname TEXT NOT NULL UNIQUE,
                    revision_id TEXT NOT NULL,
                    deployment_id TEXT NOT NULL,
                    container_name TEXT NOT NULL,
                    container_port INTEGER NOT NULL,
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS runtime_logs (
                    deployment_id TEXT PRIMARY KEY,
                    organization_id TEXT NOT NULL,
                    entries_json TEXT NOT NULL,
                    truncated INTEGER NOT NULL CHECK (truncated IN (0, 1)),
                    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                """
            )

    def receive(self, event_id: str, envelope: dict[str, Any]) -> tuple[str, Any]:
        digest = hashlib.sha256(canonical_json(envelope)).hexdigest()
        with self.transaction() as connection:
            row = connection.execute(
                "SELECT payload_digest, status, result_json FROM events WHERE event_id = ?",
                (event_id,),
            ).fetchone()
            if row:
                if row["payload_digest"] != digest:
                    raise EventConflict("event payload conflicts with its receipt")
                result = json.loads(row["result_json"]) if row["result_json"] else None
                return row["status"], result
            connection.execute(
                "INSERT INTO events (event_id, payload_digest, status) VALUES (?, ?, 'processing')",
                (event_id, digest),
            )
        return "processing", None

    def complete(self, event_id: str, result: dict[str, Any]) -> None:
        payload = canonical_json(result).decode()
        with self.transaction() as connection:
            connection.execute(
                """
                UPDATE events
                SET status = 'completed', result_json = ?, updated_at = CURRENT_TIMESTAMP
                WHERE event_id = ?
                """,
                (payload, event_id),
            )

    def save_revision(
        self,
        *,
        revision_id: str,
        deployment_id: str,
        container_id: str,
        container_name: str,
        container_port: int,
    ) -> None:
        with self.transaction() as connection:
            connection.execute(
                """
                INSERT INTO revisions (
                    revision_id, deployment_id, container_id, container_name, container_port
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(deployment_id) DO UPDATE SET
                    revision_id = excluded.revision_id,
                    container_id = excluded.container_id,
                    container_name = excluded.container_name,
                    container_port = excluded.container_port,
                    updated_at = CURRENT_TIMESTAMP
                """,
                (
                    revision_id,
                    deployment_id,
                    container_id,
                    container_name,
                    container_port,
                ),
            )

    def revision_for_deployment(self, deployment_id: str) -> dict[str, Any] | None:
        row = self._connection.execute(
            "SELECT * FROM revisions WHERE deployment_id = ?", (deployment_id,)
        ).fetchone()
        return dict(row) if row else None

    def save_alias(
        self,
        *,
        alias_id: str,
        hostname: str,
        revision_id: str,
        deployment_id: str,
        container_name: str,
        container_port: int,
    ) -> None:
        with self.transaction() as connection:
            connection.execute(
                """
                INSERT INTO aliases (
                    alias_id, hostname, revision_id, deployment_id, container_name, container_port
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(alias_id) DO UPDATE SET
                    hostname = excluded.hostname,
                    revision_id = excluded.revision_id,
                    deployment_id = excluded.deployment_id,
                    container_name = excluded.container_name,
                    container_port = excluded.container_port,
                    updated_at = CURRENT_TIMESTAMP
                """,
                (
                    alias_id,
                    hostname,
                    revision_id,
                    deployment_id,
                    container_name,
                    container_port,
                ),
            )

    def aliases(self) -> list[dict[str, Any]]:
        rows = self._connection.execute(
            "SELECT * FROM aliases ORDER BY alias_id"
        ).fetchall()
        return [dict(row) for row in rows]

    def save_runtime_logs(
        self,
        *,
        deployment_id: str,
        organization_id: str,
        entries: list[dict[str, str]],
        truncated: bool,
    ) -> None:
        payload = canonical_json(entries).decode()
        if len(entries) > 200 or len(payload.encode()) > 1024 * 1024:
            raise ValueError("runtime log snapshot is too large")
        with self.transaction() as connection:
            existing = connection.execute(
                "SELECT organization_id FROM runtime_logs WHERE deployment_id = ?",
                (deployment_id,),
            ).fetchone()
            if existing and existing["organization_id"] != organization_id:
                raise EventConflict("runtime log tenant identity conflicts")
            connection.execute(
                """
                INSERT INTO runtime_logs (
                    deployment_id, organization_id, entries_json, truncated
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(deployment_id) DO UPDATE SET
                    entries_json = excluded.entries_json,
                    truncated = excluded.truncated,
                    updated_at = CURRENT_TIMESTAMP
                """,
                (deployment_id, organization_id, payload, int(truncated)),
            )

    def runtime_logs(
        self, *, deployment_id: str, organization_id: str
    ) -> dict[str, Any] | None:
        row = self._connection.execute(
            """
            SELECT entries_json, truncated
            FROM runtime_logs
            WHERE deployment_id = ? AND organization_id = ?
            """,
            (deployment_id, organization_id),
        ).fetchone()
        if not row:
            return None
        return {
            "entries": json.loads(row["entries_json"]),
            "truncated": bool(row["truncated"]),
        }

    def remove_deployment(self, deployment_id: str) -> None:
        with self.transaction() as connection:
            connection.execute(
                "DELETE FROM aliases WHERE deployment_id = ?", (deployment_id,)
            )
            connection.execute(
                "DELETE FROM revisions WHERE deployment_id = ?", (deployment_id,)
            )
