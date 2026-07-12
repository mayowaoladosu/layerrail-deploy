from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import secrets

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
import jwt

from .store import Credential


class ScopeDenied(ValueError):
    pass


_REPOSITORY = re.compile(
    r"^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+$"
)


class TokenIssuer:
    def __init__(
        self,
        *,
        signing_key_path: Path,
        issuer: str,
        service: str,
        ttl_seconds: int,
    ):
        self._signing_key = signing_key_path.read_text(encoding="utf-8")
        private_key = serialization.load_pem_private_key(
            self._signing_key.encode(), password=None
        )
        if not isinstance(private_key, rsa.RSAPrivateKey):
            raise ValueError("registry signing key must be RSA")
        self._key_id = self._jwk_thumbprint(private_key.public_key())
        self._issuer = issuer
        self._service = service
        self._ttl_seconds = ttl_seconds

    def issue(
        self,
        *,
        credential: Credential,
        service: str,
        scopes: list[str],
        now: int | None = None,
    ) -> dict[str, object]:
        if service != self._service:
            raise ScopeDenied("registry service is invalid")
        current = int(datetime.now(timezone.utc).timestamp()) if now is None else now
        expires_at = min(current + self._ttl_seconds, credential.expires_at)
        if expires_at <= current:
            raise ScopeDenied("registry credential expired")

        access = [self._authorize_scope(scope, credential) for scope in scopes]
        payload = {
            "iss": self._issuer,
            "sub": credential.username,
            "aud": self._service,
            "exp": expires_at,
            "nbf": current - 5,
            "iat": current,
            "jti": secrets.token_hex(16),
            "access": access,
        }
        token = jwt.encode(
            payload,
            self._signing_key,
            algorithm="RS256",
            headers={"kid": self._key_id},
        )
        return {
            "token": token,
            "access_token": token,
            "expires_in": expires_at - current,
            "issued_at": datetime.fromtimestamp(
                current, timezone.utc
            ).isoformat(timespec="seconds").replace("+00:00", "Z"),
        }

    def _authorize_scope(
        self, scope: str, credential: Credential
    ) -> dict[str, object]:
        parts = scope.split(":", 2)
        if len(parts) != 3 or parts[0] != "repository":
            raise ScopeDenied("registry scope is invalid")
        repository = parts[1]
        actions = sorted(set(filter(None, parts[2].split(","))))
        if (
            not _REPOSITORY.fullmatch(repository)
            or not repository.startswith(credential.repository_prefix)
            or not actions
            or any(action not in credential.actions for action in actions)
        ):
            raise ScopeDenied("registry scope is denied")
        return {"type": "repository", "name": repository, "actions": actions}

    def _jwk_thumbprint(self, public_key: rsa.RSAPublicKey) -> str:
        numbers = public_key.public_numbers()
        value = json.dumps(
            {
                "e": self._base64url_uint(numbers.e),
                "kty": "RSA",
                "n": self._base64url_uint(numbers.n),
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode()
        return base64.urlsafe_b64encode(hashlib.sha256(value).digest()).rstrip(b"=").decode()

    def _base64url_uint(self, value: int) -> str:
        encoded = value.to_bytes((value.bit_length() + 7) // 8, "big")
        return base64.urlsafe_b64encode(encoded).rstrip(b"=").decode()
