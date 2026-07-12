from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import json
from pathlib import Path
import tempfile
import unittest
from uuid import uuid4

from aiohttp.test_utils import TestClient, TestServer
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
import jwt

from registry_auth.application import Application
from registry_auth.config import Settings
from registry_auth.store import CredentialConflict, CredentialStore
from registry_auth.tokens import ScopeDenied, TokenIssuer


class RegistryAuthTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.secret = b"registry-admin-secret-with-at-least-32-bytes"
        self.secret_path = root / "admin-secret"
        self.secret_path.write_bytes(self.secret)
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.private_path = root / "tls.key"
        self.private_path.write_bytes(
            key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )
        self.public_key = key.public_key().public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        self.settings = Settings(
            state_path=root / "state.sqlite3",
            signing_key_path=self.private_path,
            admin_secret_path=self.secret_path,
            issuer="lrail-alpha-registry-auth",
            service="lrail-alpha-registry",
            token_ttl_seconds=300,
            port=8080,
        )
        self.application = Application(self.settings)
        self.client = TestClient(TestServer(self.application.web_application()))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        self.directory.cleanup()

    def admin_headers(self, *, method: str, path: str, body: bytes) -> dict[str, str]:
        timestamp = int(datetime.now(timezone.utc).timestamp())
        request_id = str(uuid4())
        message = b"\n".join(
            [
                str(timestamp).encode(),
                request_id.encode(),
                method.encode(),
                path.encode(),
                body,
            ]
        )
        signature = hmac.new(self.secret, message, hashlib.sha256).hexdigest()
        return {
            "Content-Type": "application/json",
            "X-Lrail-Timestamp": str(timestamp),
            "X-Lrail-Request-Id": request_id,
            "X-Lrail-Signature": f"sha256={signature}",
        }

    async def register(
        self,
        *,
        prefix: str = "lrail/organization-a/",
        actions: list[str] | None = None,
    ) -> tuple[dict, str]:
        password = "registry-password-" + "x" * 32
        body = json.dumps(
            {
                "credential_id": str(uuid4()),
                "username": "lr_" + uuid4().hex,
                "password": password,
                "repository_prefix": prefix,
                "actions": actions or ["pull", "push"],
                "expires_at": int(
                    (datetime.now(timezone.utc) + timedelta(minutes=10)).timestamp()
                ),
            },
            separators=(",", ":"),
        ).encode()
        response = await self.client.post(
            "/v1/credentials",
            data=body,
            headers=self.admin_headers(
                method="POST", path="/v1/credentials", body=body
            ),
        )
        self.assertEqual(response.status, 201, await response.text())
        return await response.json(), password

    async def test_scoped_token_and_cross_tenant_denial(self):
        credential, password = await self.register()
        basic = base64.b64encode(
            f"{credential['username']}:{password}".encode()
        ).decode()
        headers = {"Authorization": f"Basic {basic}"}

        response = await self.client.get(
            "/token",
            params={
                "service": "lrail-alpha-registry",
                "scope": "repository:lrail/organization-a/service-a:pull,push",
            },
            headers=headers,
        )
        self.assertEqual(response.status, 200)
        value = await response.json()
        payload = jwt.decode(
            value["token"],
            self.public_key,
            algorithms=["RS256"],
            audience="lrail-alpha-registry",
            issuer="lrail-alpha-registry-auth",
        )
        self.assertEqual(
            payload["access"],
            [
                {
                    "type": "repository",
                    "name": "lrail/organization-a/service-a",
                    "actions": ["pull", "push"],
                }
            ],
        )
        self.assertRegex(jwt.get_unverified_header(value["token"])["kid"], r"^[\w-]{43}$")
        self.assertNotIn(password, json.dumps(value))
        self.assertEqual(response.headers["Cache-Control"], "no-store")

        denied = await self.client.get(
            "/token",
            params={
                "service": "lrail-alpha-registry",
                "scope": "repository:lrail/organization-b/service-a:pull",
            },
            headers=headers,
        )
        self.assertEqual(denied.status, 403)

    async def test_admin_signature_replay_and_revocation(self):
        replay_body = json.dumps(
            {
                "credential_id": str(uuid4()),
                "username": "lr_" + uuid4().hex,
                "password": "replay-password-" + "x" * 32,
                "repository_prefix": "lrail/organization-a/",
                "actions": ["pull"],
                "expires_at": int(
                    (datetime.now(timezone.utc) + timedelta(minutes=10)).timestamp()
                ),
            },
            separators=(",", ":"),
        ).encode()
        replay_headers = self.admin_headers(
            method="POST", path="/v1/credentials", body=replay_body
        )
        first = await self.client.post(
            "/v1/credentials", data=replay_body, headers=replay_headers
        )
        self.assertEqual(first.status, 201)
        replay = await self.client.post(
            "/v1/credentials", data=replay_body, headers=replay_headers
        )
        self.assertEqual(replay.status, 401)

        credential, password = await self.register(actions=["pull"])
        path = f"/v1/credentials/{credential['credential_id']}"
        response = await self.client.delete(
            path,
            headers=self.admin_headers(method="DELETE", path=path, body=b""),
        )
        self.assertEqual(response.status, 200)

        basic = base64.b64encode(
            f"{credential['username']}:{password}".encode()
        ).decode()
        denied = await self.client.get(
            "/token",
            params={
                "service": "lrail-alpha-registry",
                "scope": "repository:lrail/organization-a/service-a:pull",
            },
            headers={"Authorization": f"Basic {basic}"},
        )
        self.assertEqual(denied.status, 401)

        unsigned = await self.client.post("/v1/credentials", json={})
        self.assertEqual(unsigned.status, 401)


class CredentialStoreTests(unittest.TestCase):
    def test_idempotency_conflict_expiry_and_plaintext_absence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "store.sqlite3"
            store = CredentialStore(path)
            now = 1000
            values = {
                "credential_id": str(uuid4()),
                "username": "lr_" + uuid4().hex,
                "password": "secret-password-" + "x" * 32,
                "repository_prefix": "lrail/org-a/",
                "actions": ["pull"],
                "expires_at": now + 300,
            }
            first = store.register(**values, now=now)
            second = store.register(**values, now=now)
            self.assertEqual(first, second)
            self.assertIsNotNone(
                store.authenticate(values["username"], values["password"], now=now)
            )
            self.assertIsNone(
                store.authenticate(
                    values["username"], values["password"], now=values["expires_at"]
                )
            )
            with self.assertRaises(CredentialConflict):
                store.register(**(values | {"repository_prefix": "lrail/org-b/"}), now=now)
            store.close()
            database_bytes = path.read_bytes()
            self.assertNotIn(values["password"].encode(), database_bytes)

    def test_scope_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            key_path = root / "key.pem"
            key_path.write_bytes(
                key.private_bytes(
                    serialization.Encoding.PEM,
                    serialization.PrivateFormat.PKCS8,
                    serialization.NoEncryption(),
                )
            )
            issuer = TokenIssuer(
                signing_key_path=key_path,
                issuer="issuer",
                service="service",
                ttl_seconds=300,
            )
            store = CredentialStore(root / "state.sqlite3")
            credential = store.register(
                credential_id=str(uuid4()),
                username="lr_" + uuid4().hex,
                password="password-" + "x" * 32,
                repository_prefix="lrail/org-a/",
                actions=["pull"],
                expires_at=1300,
                now=1000,
            )
            with self.assertRaises(ScopeDenied):
                issuer.issue(
                    credential=credential,
                    service="service",
                    scopes=["repository:lrail/org-a/service:push"],
                    now=1000,
                )
            with self.assertRaises(ScopeDenied):
                issuer.issue(
                    credential=credential,
                    service="service",
                    scopes=["repository:lrail/org-a/service/../foreign:pull"],
                    now=1000,
                )
            store.close()


if __name__ == "__main__":
    unittest.main()
