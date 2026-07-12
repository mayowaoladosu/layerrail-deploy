from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import hmac
import json
from pathlib import Path
import re
import secrets
import sqlite3
import time
from typing import Iterator


class CredentialConflict(ValueError):
    pass


_EXACT_REPOSITORY = re.compile(
    r"^lrail/[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/"
    r"[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)


@dataclass(frozen=True)
class Credential:
    credential_id: str
    username: str
    repository_prefix: str
    actions: tuple[str, ...]
    expires_at: int


class CredentialStore:
    SCRYPT_N = 2**14
    SCRYPT_R = 8
    SCRYPT_P = 1

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

    def register(
        self,
        *,
        credential_id: str,
        username: str,
        password: str,
        repository_prefix: str,
        actions: list[str],
        expires_at: int,
        now: int | None = None,
    ) -> Credential:
        current = int(time.time()) if now is None else now
        normalized_actions = tuple(sorted(set(actions)))
        self._validate(
            username=username,
            password=password,
            repository_prefix=repository_prefix,
            actions=normalized_actions,
            expires_at=expires_at,
            now=current,
        )
        with self.transaction() as connection:
            existing = connection.execute(
                "SELECT * FROM credentials WHERE credential_id = ? OR username = ?",
                (credential_id, username),
            ).fetchone()
            if existing:
                if (
                    existing["credential_id"] != credential_id
                    or existing["username"] != username
                    or existing["repository_prefix"] != repository_prefix
                    or tuple(json.loads(existing["actions_json"])) != normalized_actions
                    or existing["expires_at"] != expires_at
                    or not self._verify_password(password, existing)
                ):
                    raise CredentialConflict("credential registration conflicts")
                return self._credential(existing)

            salt = secrets.token_bytes(16)
            digest = self._password_digest(password, salt)
            connection.execute(
                """
                INSERT INTO credentials (
                    credential_id, username, password_salt, password_digest,
                    repository_prefix, actions_json, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    credential_id,
                    username,
                    salt,
                    digest,
                    repository_prefix,
                    json.dumps(normalized_actions, separators=(",", ":")),
                    expires_at,
                ),
            )
            row = connection.execute(
                "SELECT * FROM credentials WHERE credential_id = ?", (credential_id,)
            ).fetchone()
            return self._credential(row)

    def authenticate(
        self, username: str, password: str, *, now: int | None = None
    ) -> Credential | None:
        current = int(time.time()) if now is None else now
        row = self._connection.execute(
            "SELECT * FROM credentials WHERE username = ?", (username,)
        ).fetchone()
        if (
            not row
            or row["revoked_at"] is not None
            or row["expires_at"] <= current
            or not self._verify_password(password, row)
        ):
            return None
        return self._credential(row)

    def revoke(self, credential_id: str, *, now: int | None = None) -> bool:
        current = int(time.time()) if now is None else now
        with self.transaction() as connection:
            cursor = connection.execute(
                """
                UPDATE credentials
                SET revoked_at = COALESCE(revoked_at, ?)
                WHERE credential_id = ?
                """,
                (current, credential_id),
            )
            return cursor.rowcount == 1

    def _migrate(self) -> None:
        with self.transaction() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS credentials (
                    credential_id TEXT PRIMARY KEY,
                    username TEXT NOT NULL UNIQUE,
                    password_salt BLOB NOT NULL,
                    password_digest BLOB NOT NULL,
                    repository_prefix TEXT NOT NULL,
                    actions_json TEXT NOT NULL,
                    expires_at INTEGER NOT NULL,
                    revoked_at INTEGER,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE INDEX IF NOT EXISTS index_credentials_on_expiry
                    ON credentials(expires_at);
                """
            )

    def _validate(
        self,
        *,
        username: str,
        password: str,
        repository_prefix: str,
        actions: tuple[str, ...],
        expires_at: int,
        now: int,
    ) -> None:
        if not username.startswith("lr_") or len(username) > 80:
            raise ValueError("registry username is invalid")
        if len(password) < 32 or len(password) > 256:
            raise ValueError("registry password is invalid")
        organization_prefix = (
            repository_prefix.startswith("lrail/")
            and repository_prefix.endswith("/")
            and ".." not in repository_prefix
        )
        if (
            not organization_prefix
            and not _EXACT_REPOSITORY.fullmatch(repository_prefix)
        ) or len(repository_prefix) > 240:
            raise ValueError("registry repository prefix is invalid")
        if not actions or any(action not in {"pull", "push"} for action in actions):
            raise ValueError("registry actions are invalid")
        if not now < expires_at <= now + 3600:
            raise ValueError("registry credential expiry is invalid")

    def _password_digest(self, password: str, salt: bytes) -> bytes:
        return hashlib.scrypt(
            password.encode(),
            salt=salt,
            n=self.SCRYPT_N,
            r=self.SCRYPT_R,
            p=self.SCRYPT_P,
            dklen=32,
        )

    def _verify_password(self, password: str, row: sqlite3.Row) -> bool:
        try:
            actual = self._password_digest(password, row["password_salt"])
        except (TypeError, ValueError):
            return False
        return hmac.compare_digest(actual, row["password_digest"])

    def _credential(self, row: sqlite3.Row) -> Credential:
        return Credential(
            credential_id=row["credential_id"],
            username=row["username"],
            repository_prefix=row["repository_prefix"],
            actions=tuple(json.loads(row["actions_json"])),
            expires_at=row["expires_at"],
        )
