from __future__ import annotations

import asyncio
from datetime import datetime
import json
import logging

from aiohttp import web

from .artifacts import ArtifactFault, ArtifactLimits, Artifacts
from .authentication import RequestAuthenticator
from .config import Settings
from .storage import MinioObjectStore, ObjectStore


logger = logging.getLogger(__name__)


class Application:
    def __init__(self, settings: Settings, store: ObjectStore | None = None):
        self._settings = settings
        self._auth = RequestAuthenticator(settings.admin_secret_path)
        self._store = store or MinioObjectStore(
            endpoint=settings.endpoint,
            access_key_path=settings.access_key_path,
            secret_key_path=settings.secret_key_path,
        )
        self._artifacts = Artifacts(
            self._store,
            static_bucket=settings.static_bucket,
            evidence_bucket=settings.evidence_bucket,
            limits=ArtifactLimits(
                archive_bytes=settings.max_archive_bytes,
                expanded_bytes=settings.max_expanded_bytes,
                file_bytes=settings.max_file_bytes,
                file_count=settings.max_file_count,
                evidence_bytes=settings.max_evidence_bytes,
            ),
        )

    def web_application(self) -> web.Application:
        application = web.Application(
            client_max_size=max(
                self._settings.max_archive_bytes,
                self._settings.max_evidence_bytes,
            )
        )
        application.router.add_get("/health", self._health)
        application.router.add_get("/ready", self._ready)
        application.router.add_put(
            "/v1/static/{organization_id}/{revision_id}", self._publish_static
        )
        application.router.add_get(
            "/v1/static/{organization_id}/{revision_id}/manifest",
            self._static_manifest,
        )
        application.router.add_get(
            "/v1/static/{organization_id}/{revision_id}/files/{path:.+}",
            self._static_file,
        )
        application.router.add_put(
            "/v1/evidence/{organization_id}/{build_id}/{name}", self._put_evidence
        )
        application.router.add_get(
            "/v1/evidence/{organization_id}/{build_id}/{name}", self._evidence
        )
        application.router.add_post(
            "/v1/retention/reconcile", self._reconcile
        )
        return application

    async def _health(self, _request: web.Request) -> web.Response:
        return web.json_response({"status": "ok"})

    async def _ready(self, _request: web.Request) -> web.Response:
        try:
            await asyncio.to_thread(
                self._store.list, self._settings.static_bucket, "health/"
            )
        except Exception:
            logger.exception("artifact store readiness failed")
            return web.json_response({"status": "unavailable"}, status=503)
        return web.json_response({"status": "ok"})

    async def _publish_static(self, request: web.Request) -> web.Response:
        if request.content_type != "application/x-tar":
            return self._error("archive_media_type_invalid", 415)
        try:
            body = await request.read()
        except web.HTTPRequestEntityTooLarge:
            return self._error("archive_size_invalid", 413)
        if not self._authorized(request, body):
            return self._error("unauthorized", 401)
        try:
            manifest, created = await asyncio.to_thread(
                self._artifacts.publish_static,
                organization_id=request.match_info["organization_id"],
                revision_id=request.match_info["revision_id"],
                archive=body,
                expected_digest=request.headers.get("X-Lrail-Artifact-Digest", ""),
            )
        except ArtifactFault as error:
            return self._error(error.code, error.status)
        return web.json_response(manifest, status=201 if created else 200)

    async def _static_manifest(self, request: web.Request) -> web.Response:
        try:
            manifest = await asyncio.to_thread(
                self._artifacts.static_manifest,
                organization_id=request.match_info["organization_id"],
                revision_id=request.match_info["revision_id"],
            )
        except ArtifactFault as error:
            return self._error(error.code, error.status)
        response = web.json_response(manifest)
        response.headers["Cache-Control"] = "no-cache, must-revalidate"
        return response

    async def _static_file(self, request: web.Request) -> web.Response:
        try:
            file = await asyncio.to_thread(
                self._artifacts.static_file,
                organization_id=request.match_info["organization_id"],
                revision_id=request.match_info["revision_id"],
                path=request.match_info["path"],
            )
        except ArtifactFault as error:
            return self._error(error.code, error.status)
        response = web.Response(
            body=file.body,
            content_type=file.media_type.split(";", 1)[0],
            charset="utf-8" if "charset=utf-8" in file.media_type else None,
        )
        response.headers["Cache-Control"] = file.cache_control
        response.headers["ETag"] = f'"{file.digest}"'
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    async def _put_evidence(self, request: web.Request) -> web.Response:
        try:
            body = await request.read()
        except web.HTTPRequestEntityTooLarge:
            return self._error("evidence_size_invalid", 413)
        if not self._authorized(request, body):
            return self._error("unauthorized", 401)
        try:
            value, created = await asyncio.to_thread(
                self._artifacts.put_evidence,
                organization_id=request.match_info["organization_id"],
                build_id=request.match_info["build_id"],
                name=request.match_info["name"],
                body=body,
                expected_digest=request.headers.get("X-Lrail-Artifact-Digest", ""),
            )
        except ArtifactFault as error:
            return self._error(error.code, error.status)
        return web.json_response(value, status=201 if created else 200)

    async def _evidence(self, request: web.Request) -> web.Response:
        if not self._authorized(request, b""):
            return self._error("unauthorized", 401)
        try:
            value = await asyncio.to_thread(
                self._artifacts.evidence,
                organization_id=request.match_info["organization_id"],
                build_id=request.match_info["build_id"],
                name=request.match_info["name"],
            )
        except ArtifactFault as error:
            return self._error(error.code, error.status)
        media_type = value.info.content_type
        response = web.Response(
            body=value.body,
            content_type=media_type.split(";", 1)[0],
            charset="utf-8" if "charset=utf-8" in media_type else None,
        )
        response.headers["Cache-Control"] = "private, no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    async def _reconcile(self, request: web.Request) -> web.Response:
        try:
            body = await request.read()
        except web.HTTPRequestEntityTooLarge:
            return self._error("retention_request_invalid", 413)
        if not self._authorized(request, body):
            return self._error("unauthorized", 401)
        try:
            value = json.loads(body)
            if not isinstance(value, dict) or set(value) != {
                "reconciliation_id",
                "organization_id",
                "retain_revision_ids",
                "delete_candidate_revision_ids",
                "delete_before",
            }:
                raise ValueError
            delete_before = datetime.fromisoformat(
                str(value["delete_before"]).replace("Z", "+00:00")
            )
            result, created = await asyncio.to_thread(
                self._artifacts.reconcile,
                reconciliation_id=str(value["reconciliation_id"]),
                organization_id=str(value["organization_id"]),
                retain_revision_ids=list(value["retain_revision_ids"]),
                delete_candidate_revision_ids=list(
                    value["delete_candidate_revision_ids"]
                ),
                delete_before=delete_before,
            )
        except ArtifactFault as error:
            return self._error(error.code, error.status)
        except (TypeError, ValueError, json.JSONDecodeError):
            return self._error("retention_request_invalid", 422)
        return web.json_response(result, status=201 if created else 200)

    def _authorized(self, request: web.Request, body: bytes) -> bool:
        return self._auth.valid(
            method=request.method,
            path=request.path,
            body=body,
            headers=request.headers,
        )

    def _error(self, code: str, status: int) -> web.Response:
        return web.json_response({"code": code}, status=status)


def run() -> None:
    settings = Settings.from_env()
    application = Application(settings)
    web.run_app(
        application.web_application(),
        host="0.0.0.0",
        port=settings.port,
        access_log=None,
    )
