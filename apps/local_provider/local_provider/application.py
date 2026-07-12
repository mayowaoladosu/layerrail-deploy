from __future__ import annotations

import asyncio
import logging
import signal
from typing import Any
from uuid import UUID

import aiodocker
from aiohttp import web

from .authentication import RequestSigner
from .config import Settings
from .control_plane import ControlPlaneClient, ControlPlaneRejected, ControlPlaneUnavailable
from .logs import RuntimeLogFormatter
from .processor import PermanentCommandError, Processor, TransientCommandError
from .routing import RouteWriter
from .runtime import DockerRuntime, RuntimeConflict, RuntimeUnavailable
from .state import StateStore


logger = logging.getLogger(__name__)


class Application:
    def __init__(self, settings: Settings):
        self._settings = settings
        self._store = StateStore(settings.state_dir / "provider.sqlite3")
        self._docker = aiodocker.Docker(url=settings.docker_host)
        self._signer = RequestSigner(settings.shared_secret_file)
        self._control_plane = ControlPlaneClient(
            base_url=settings.control_plane_url,
            signer=self._signer,
            host_header=settings.control_plane_host,
        )
        self._runtime = DockerRuntime(
            docker=self._docker,
            runtime_network=settings.runtime_network,
            container_port=settings.container_port,
        )
        self._log_formatter = RuntimeLogFormatter()
        self._routes = RouteWriter(
            store=self._store,
            routes_dir=settings.routes_dir,
            deploy_domain=settings.deploy_domain,
        )
        self._processor = Processor(
            store=self._store,
            runtime=self._runtime,
            routes=self._routes,
            control_plane=self._control_plane,
            allowed_image_reference=settings.allowed_image_reference,
            log_formatter=self._log_formatter,
        )
        self._stop = asyncio.Event()

    async def run(self) -> None:
        server = await self._start_health_server()
        loop = asyncio.get_running_loop()
        for signal_name in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(signal_name, self._stop.set)
        logger.info("Local provider started")
        try:
            await self._dispatch_loop()
        finally:
            await server.cleanup()
            await self._control_plane.close()
            await self._docker.close()
            self._store.close()
            logger.info("Local provider stopped")

    async def _dispatch_loop(self) -> None:
        while not self._stop.is_set():
            try:
                command = await self._control_plane.claim()
                if command is None:
                    await self._wait()
                    continue
                logger.info(
                    "Claimed %s command %s",
                    command.envelope.event_type,
                    command.envelope.event_id,
                )
                try:
                    await self._processor.process(command.envelope)
                    await self._control_plane.finalize(
                        event_id=command.envelope.event_id,
                        claim_token=command.claim_token,
                        outcome="published",
                    )
                    logger.info("Published command %s", command.envelope.event_id)
                except PermanentCommandError as error:
                    logger.warning(
                        "Command %s rejected: %s",
                        command.envelope.event_id,
                        type(error).__name__,
                    )
                    await self._control_plane.finalize(
                        event_id=command.envelope.event_id,
                        claim_token=command.claim_token,
                        outcome="rejected",
                        safe_error="Local provider rejected the command",
                    )
                except TransientCommandError as error:
                    logger.warning(
                        "Command %s will retry: %s",
                        command.envelope.event_id,
                        type(error).__name__,
                    )
                    await self._control_plane.finalize(
                        event_id=command.envelope.event_id,
                        claim_token=command.claim_token,
                        outcome="retry",
                        safe_error="Local provider is temporarily unavailable",
                    )
            except (ControlPlaneUnavailable, ControlPlaneRejected):
                logger.warning("Control plane transport unavailable")
                await self._wait()
            except Exception:
                logger.exception("Unexpected local provider loop failure")
                await self._wait()

    async def _wait(self) -> None:
        try:
            await asyncio.wait_for(
                self._stop.wait(), timeout=self._settings.poll_interval_seconds
            )
        except TimeoutError:
            pass

    async def _start_health_server(self) -> web.AppRunner:
        application = web.Application()
        application.router.add_get("/health", self._health)
        application.router.add_get("/ready", self._ready)
        application.router.add_get(
            "/v1/organizations/{organization_id}/deployments/{deployment_id}/logs",
            self._logs,
        )
        runner = web.AppRunner(application)
        await runner.setup()
        site = web.TCPSite(runner, "0.0.0.0", self._settings.health_port)
        await site.start()
        return runner

    async def _health(self, _request: web.Request) -> web.Response:
        return web.json_response({"status": "ok"})

    async def _ready(self, _request: web.Request) -> web.Response:
        checks: dict[str, Any] = {"control_plane": False, "docker": False}
        checks["control_plane"] = await self._control_plane.health()
        try:
            await self._docker.version()
            checks["docker"] = True
        except Exception:
            pass
        status = 200 if all(checks.values()) else 503
        return web.json_response({"status": "ok" if status == 200 else "unavailable", "checks": checks}, status=status)

    async def _logs(self, request: web.Request) -> web.Response:
        body = await request.read()
        if not self._signer.valid(
            method=request.method,
            path=request.path,
            body=body,
            headers=request.headers,
        ):
            return web.json_response({"code": "unauthorized"}, status=401)
        try:
            organization_id = str(UUID(request.match_info["organization_id"]))
            deployment_id = str(UUID(request.match_info["deployment_id"]))
            lines = await self._runtime.logs(
                deployment_id=deployment_id,
                organization_id=organization_id,
                limit=1000,
            )
            entries, truncated = self._log_formatter.format(lines)
            self._store.save_runtime_logs(
                deployment_id=deployment_id,
                organization_id=organization_id,
                entries=entries,
                truncated=truncated,
            )
            retained = False
        except (KeyError, ValueError, RuntimeConflict):
            cached = self._store.runtime_logs(
                deployment_id=deployment_id,
                organization_id=organization_id,
            )
            if not cached:
                return web.json_response({"code": "not_found"}, status=404)
            entries = cached["entries"]
            truncated = cached["truncated"]
            retained = True
        except RuntimeUnavailable:
            cached = self._store.runtime_logs(
                deployment_id=deployment_id,
                organization_id=organization_id,
            )
            if not cached:
                return web.json_response({"code": "unavailable"}, status=503)
            entries = cached["entries"]
            truncated = cached["truncated"]
            retained = True
        return web.json_response(
            {
                "entries": entries,
                "truncated": truncated,
                "retained": retained,
            }
        )
