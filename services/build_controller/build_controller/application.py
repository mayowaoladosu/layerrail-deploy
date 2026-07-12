from __future__ import annotations

import asyncio
import json
import logging
import os

from aiohttp import web

from .authentication import CallbackAuthenticator
from .config import Settings
from .contracts import InvalidContract, WorkerResult
from .controller import BuildController
from .store import OperationConflict


logger = logging.getLogger(__name__)


class Application:
    def __init__(
        self,
        settings: Settings,
        controller: BuildController | None = None,
        *,
        background: bool = True,
    ):
        self._settings = settings
        self._controller = controller or BuildController(settings)
        self._callback_auth = CallbackAuthenticator(self._controller.authenticator)
        self._background = background
        self._tasks: list[asyncio.Task[None]] = []

    def web_application(self) -> web.Application:
        application = web.Application(client_max_size=self._settings.max_result_bytes)
        application.router.add_get("/health", self._health)
        application.router.add_get("/ready", self._ready)
        application.router.add_put("/v1/builds/{build_id}/result", self._result)
        application.on_startup.append(self._startup)
        application.on_cleanup.append(self._cleanup)
        return application

    async def _startup(self, _application: web.Application) -> None:
        await self._controller.start()
        if self._background:
            self._tasks = [
                asyncio.create_task(self._controller.run_commands()),
                asyncio.create_task(self._controller.run_reconciler()),
            ]

    async def _cleanup(self, _application: web.Application) -> None:
        for task in self._tasks:
            task.cancel()
        if self._tasks:
            await asyncio.gather(*self._tasks, return_exceptions=True)
        await self._controller.close()

    async def _health(self, _request: web.Request) -> web.Response:
        return web.json_response({"status": "ok"})

    async def _ready(self, _request: web.Request) -> web.Response:
        try:
            await self._controller.jobs.start()
        except Exception:
            logger.exception("build controller readiness failed")
            return web.json_response({"status": "unavailable"}, status=503)
        return web.json_response({"status": "ok"})

    async def _result(self, request: web.Request) -> web.Response:
        build_id = request.match_info["build_id"]
        try:
            body = await request.read()
        except web.HTTPRequestEntityTooLarge:
            return self._error("result_size_invalid", 413)
        if not self._callback_auth.valid(
            build_id=build_id,
            method=request.method,
            path=request.path,
            body=body,
            headers=request.headers,
        ):
            logger.warning("build result authentication failed for %s", build_id)
            return self._error("unauthorized", 401)
        try:
            value = json.loads(body)
            result = WorkerResult.parse(
                value,
                build_id=build_id,
                max_static_archive_bytes=self._settings.max_static_archive_bytes,
                max_log_lines=self._settings.max_log_lines,
            )
            operation, created = await self._controller.accept_result(result)
        except (UnicodeDecodeError, json.JSONDecodeError, InvalidContract):
            logger.warning("build result contract was rejected for %s", build_id)
            return self._error("result_invalid", 422)
        except OperationConflict:
            logger.warning("build result conflicted for %s", build_id)
            return self._error("result_conflict", 409)
        logger.info(
            "build result accepted for %s (replayed=%s)",
            build_id,
            not created,
        )
        return web.json_response(
            {
                "build_id": operation.build_id,
                "status": operation.status,
                "replayed": not created,
            },
            status=202 if created else 200,
        )

    def _error(self, code: str, status: int) -> web.Response:
        return web.json_response({"code": code}, status=status)


def run() -> None:
    os.umask(0o077)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    settings = Settings.from_env()
    application = Application(settings)
    web.run_app(
        application.web_application(),
        host="0.0.0.0",
        port=settings.port,
        access_log=None,
    )
