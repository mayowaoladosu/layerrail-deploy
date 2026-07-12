from __future__ import annotations

import base64
import json
import logging
import re
import time
from uuid import UUID

from aiohttp import web

from .authentication import RequestAuthenticator
from .config import Settings
from .store import CredentialConflict, CredentialStore
from .tokens import ScopeDenied, TokenIssuer


logger = logging.getLogger(__name__)
_USERNAME = re.compile(r"^lr_[a-zA-Z0-9_-]{8,77}$")


class Application:
    def __init__(self, settings: Settings):
        self._settings = settings
        self._store = CredentialStore(settings.state_path)
        self._admin_auth = RequestAuthenticator(settings.admin_secret_path)
        self._tokens = TokenIssuer(
            signing_key_path=settings.signing_key_path,
            issuer=settings.issuer,
            service=settings.service,
            ttl_seconds=settings.token_ttl_seconds,
        )

    def web_application(self) -> web.Application:
        application = web.Application(client_max_size=64 * 1024)
        application.router.add_get("/health", self._health)
        application.router.add_get("/ready", self._ready)
        application.router.add_get("/token", self._token)
        application.router.add_post("/v1/credentials", self._register)
        application.router.add_delete(
            "/v1/credentials/{credential_id}", self._revoke
        )
        application.on_cleanup.append(self._cleanup)
        return application

    async def _health(self, _request: web.Request) -> web.Response:
        return web.json_response({"status": "ok"})

    async def _ready(self, _request: web.Request) -> web.Response:
        return web.json_response({"status": "ok"})

    async def _register(self, request: web.Request) -> web.Response:
        body = await request.read()
        if not self._admin_auth.valid(
            method=request.method,
            path=request.path,
            body=body,
            headers=request.headers,
        ):
            return self._error("unauthorized", 401)
        try:
            value = json.loads(body)
            if not isinstance(value, dict) or set(value) != {
                "credential_id",
                "username",
                "password",
                "repository_prefix",
                "actions",
                "expires_at",
            }:
                raise ValueError
            credential_id = str(UUID(str(value["credential_id"])))
            username = str(value["username"])
            if not _USERNAME.fullmatch(username):
                raise ValueError
            credential = self._store.register(
                credential_id=credential_id,
                username=username,
                password=str(value["password"]),
                repository_prefix=str(value["repository_prefix"]),
                actions=list(value["actions"]),
                expires_at=int(value["expires_at"]),
            )
        except CredentialConflict:
            return self._error("credential_conflict", 409)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            return self._error("invalid_credential", 422)
        return web.json_response(
            {
                "credential_id": credential.credential_id,
                "username": credential.username,
                "repository_prefix": credential.repository_prefix,
                "actions": list(credential.actions),
                "expires_at": credential.expires_at,
            },
            status=201,
        )

    async def _revoke(self, request: web.Request) -> web.Response:
        body = await request.read()
        if not self._admin_auth.valid(
            method=request.method,
            path=request.path,
            body=body,
            headers=request.headers,
        ):
            return self._error("unauthorized", 401)
        try:
            credential_id = str(UUID(request.match_info["credential_id"]))
        except (KeyError, ValueError):
            return self._error("not_found", 404)
        if not self._store.revoke(credential_id):
            return self._error("not_found", 404)
        return web.json_response({"status": "revoked"})

    async def _token(self, request: web.Request) -> web.Response:
        credentials = self._basic_credentials(request)
        if credentials is None:
            return self._challenge()
        username, password = credentials
        credential = self._store.authenticate(username, password)
        if credential is None:
            return self._challenge()
        try:
            token = self._tokens.issue(
                credential=credential,
                service=request.query.get("service", ""),
                scopes=request.query.getall("scope", []),
            )
        except ScopeDenied:
            return self._error("insufficient_scope", 403)
        response = web.json_response(token)
        response.headers["Cache-Control"] = "no-store"
        return response

    def _basic_credentials(self, request: web.Request) -> tuple[str, str] | None:
        header = request.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return None
        try:
            decoded = base64.b64decode(header[6:], validate=True).decode()
            username, password = decoded.split(":", 1)
        except (ValueError, UnicodeDecodeError):
            return None
        return username, password

    def _challenge(self) -> web.Response:
        response = self._error("invalid_credentials", 401)
        response.headers["WWW-Authenticate"] = 'Basic realm="lrail-alpha-registry"'
        return response

    def _error(self, code: str, status: int) -> web.Response:
        return web.json_response({"code": code}, status=status)

    async def _cleanup(self, _application: web.Application) -> None:
        self._store.close()


def run() -> None:
    settings = Settings.from_env()
    application = Application(settings)
    web.run_app(
        application.web_application(),
        host="0.0.0.0",
        port=settings.port,
        access_log=None,
    )
