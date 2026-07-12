from __future__ import annotations

import asyncio
from datetime import datetime, timezone
import json
import logging
import time
from typing import Any

from .authentication import RequestAuthenticator
from .clients import (
    ArtifactGatewayClient,
    ControlPlaneClient,
    DependencyError,
    RegistryAuthClient,
)
from .config import Settings
from .contracts import BuildCommand, CancelCommand, InvalidContract, WorkerResult
from .kubernetes import BuildJobs, KubernetesError
from .provenance import ProvenanceSigner
from .redaction import redact, redact_lines
from .scanner import ScanError, ScanResult, TrivyScanner
from .store import Operation, OperationConflict, OperationStore


logger = logging.getLogger(__name__)


class BuildController:
    def __init__(
        self,
        settings: Settings,
        *,
        store: OperationStore | None = None,
        control_plane: ControlPlaneClient | None = None,
        registry: RegistryAuthClient | None = None,
        artifacts: ArtifactGatewayClient | None = None,
        jobs: BuildJobs | None = None,
        scanner: TrivyScanner | None = None,
        provenance: ProvenanceSigner | None = None,
        authenticator: RequestAuthenticator | None = None,
    ):
        self.settings = settings
        self.authenticator = authenticator or RequestAuthenticator(
            settings.shared_secret_path
        )
        self.store = store or OperationStore(settings.state_dir)
        self.control_plane = control_plane or ControlPlaneClient(
            settings.control_plane_url,
            settings.shared_secret_path,
            host_header=settings.control_plane_host,
        )
        self.registry = registry or RegistryAuthClient(
            settings.registry_auth_url, settings.registry_admin_secret_path
        )
        self.artifacts = artifacts or ArtifactGatewayClient(
            settings.artifact_gateway_url, settings.artifact_admin_secret_path
        )
        self.jobs = jobs or BuildJobs(
            namespace=settings.namespace,
            worker_image=settings.worker_image,
            callback_url="http://build-controller.lrail-system.svc.cluster.local:8080",
            registry_endpoint=settings.registry_endpoint,
        )
        self.scanner = scanner or TrivyScanner(
            executable=settings.trivy_path,
            cache_dir=settings.state_dir / "trivy-cache",
            max_critical=settings.max_critical_vulnerabilities,
        )
        self.provenance = provenance or ProvenanceSigner(settings.signing_key_path)
        self._stopping = False

    async def start(self) -> None:
        await self.jobs.start()

    async def close(self) -> None:
        self._stopping = True
        await asyncio.gather(
            self.control_plane.close(),
            self.registry.close(),
            self.artifacts.close(),
            self.jobs.close(),
            return_exceptions=True,
        )
        self.store.close()

    async def run_commands(self) -> None:
        while not self._stopping:
            processed = await self.run_command_once()
            if not processed:
                await asyncio.sleep(self.settings.reconcile_interval)

    async def run_reconciler(self) -> None:
        while not self._stopping:
            await self.reconcile_once()
            await asyncio.sleep(self.settings.reconcile_interval)

    async def run_command_once(self) -> bool:
        try:
            lease = await self.control_plane.claim()
        except DependencyError:
            logger.warning("build command dependency unavailable")
            return False
        if lease is None:
            return False
        event_id = str(lease.event.get("event_id", ""))
        try:
            if lease.event.get("event_type") == "build.requested.v1":
                await self._dispatch(BuildCommand.parse(lease.event))
            elif lease.event.get("event_type") == "build.cancellation.requested.v1":
                await self._cancel(CancelCommand.parse(lease.event))
            else:
                raise InvalidContract("unsupported build command")
            await self.control_plane.finalize(
                event_id=event_id,
                claim_token=lease.claim_token,
                outcome="published",
            )
        except (InvalidContract, OperationConflict) as error:
            logger.warning("build command rejected: %s", redact(str(error)))
            await self._finalize_safely(
                event_id=event_id,
                claim_token=lease.claim_token,
                outcome="rejected",
                safe_error="build_command_invalid",
            )
        except (DependencyError, KubernetesError) as error:
            logger.warning("build command retry scheduled: %s", redact(str(error)))
            await self._finalize_safely(
                event_id=event_id,
                claim_token=lease.claim_token,
                outcome="retry",
                safe_error="build_dependency_unavailable",
            )
        except Exception:
            logger.exception("build command encountered an internal failure")
            await self._finalize_safely(
                event_id=event_id,
                claim_token=lease.claim_token,
                outcome="retry",
                safe_error="build_controller_internal_error",
            )
        return True

    async def accept_result(self, result: WorkerResult) -> tuple[Operation, bool]:
        try:
            operation = self.store.get(result.build_id)
        except KeyError as error:
            raise OperationConflict("worker result has no build command") from error
        expected_plans = (
            {"dockerfile_web", "node_web"}
            if operation.workload_type == "web"
            else {"plain_static", "node_static"}
        )
        if result.plan_type is not None and result.plan_type not in expected_plans:
            raise OperationConflict("worker result conflicts with workload")
        if result.artifact_kind == "oci":
            expected_reference = (
                f"{self.settings.registry_endpoint}/{operation.repository}"
                f"@{result.artifact_digest}"
            )
            if result.image_reference != expected_reference:
                raise OperationConflict("worker result conflicts with artifact repository")
        return self.store.save_result(result)

    async def reconcile_once(self) -> None:
        for operation in self.store.pending():
            try:
                if operation.status == "result_pending":
                    await self._process_result(operation)
                elif operation.status == "running":
                    await self._observe_job(operation)
                elif operation.status == "canceling":
                    await self._cleanup(operation)
            except (DependencyError, KubernetesError, ScanError, OperationConflict) as error:
                logger.warning(
                    "build reconciliation deferred for %s: %s",
                    operation.build_id,
                    redact(str(error)),
                )
            except Exception:
                logger.exception(
                    "build reconciliation encountered an internal failure for %s",
                    operation.build_id,
                )

    async def _dispatch(self, command: BuildCommand) -> None:
        operation, _created = self.store.register(command)
        if operation.status in {"running", "result_pending", "completed", "failed"}:
            state = await self.jobs.status(operation.job_name)
            if operation.status != "running" or state.exists:
                return
        credentials = await self.control_plane.credentials(operation)
        expires_at = datetime.fromisoformat(credentials.expires_at.replace("Z", "+00:00"))
        remaining = int(expires_at.timestamp() - time.time()) - 30
        active_deadline = min(self.settings.build_timeout_seconds, remaining)
        if active_deadline < 60:
            raise DependencyError("clone_credential_ttl_insufficient", retryable=True)
        registry = await self.registry.register(
            repository=operation.repository,
            actions=["pull", "push"],
            expires_at=int(time.time()) + active_deadline + 60,
        )
        try:
            await self.jobs.dispatch(
                command,
                clone=credentials,
                registry=registry,
                callback_secret=self.authenticator.callback_secret(command.build_id),
                active_deadline_seconds=active_deadline,
            )
            self.store.set_running(
                operation.build_id,
                registry_credential_id=registry.credential_id,
            )
        except Exception:
            await self.registry.revoke(registry.credential_id)
            raise

    async def _cancel(self, command: CancelCommand) -> None:
        try:
            operation = self.store.get(command.build_id)
        except KeyError as error:
            raise DependencyError("build_not_dispatched", retryable=True) from error
        if (
            operation.organization_id != command.organization_id
            or operation.deployment_id != command.deployment_id
        ):
            raise InvalidContract("cancellation owner is invalid")
        if operation.status == "canceled":
            return
        self.store.mark(operation.build_id, "canceling")
        await self.jobs.delete(operation.job_name, operation.secret_name)
        if operation.registry_credential_id:
            await self.registry.revoke(operation.registry_credential_id)
        await self.control_plane.complete_cancellation(
            operation,
            operation_id=command.operation_id,
            expected_version=command.expected_version,
        )
        self.store.mark(operation.build_id, "canceled")

    async def _observe_job(self, operation: Operation) -> None:
        state = await self.jobs.status(operation.job_name)
        if not state.exists:
            if time.time() - operation.updated_at <= self.settings.result_grace_seconds:
                return
            await self._fail_without_result(
                operation,
                phase="sandbox",
                code="worker_lost",
                message="Build sandbox was lost before producing a result",
            )
        elif state.failed:
            logs = await self.jobs.logs(operation.job_name)
            await self._fail_without_result(
                operation,
                phase="sandbox",
                code="build_timeout" if state.reason == "DeadlineExceeded" else "worker_failed",
                message="Build sandbox did not complete successfully",
                logs=logs.splitlines(),
            )
        elif state.complete:
            current = int(time.time())
            observed = self.store.observe_completion(operation.build_id, now=current)
            if observed.status != "running":
                return
            if (
                observed.completion_observed_at is None
                or current - observed.completion_observed_at
                <= self.settings.result_grace_seconds
            ):
                return
            await self._fail_without_result(
                observed,
                phase="callback",
                code="result_missing",
                message="Build sandbox completed without a signed result",
            )

    async def _process_result(self, operation: Operation) -> None:
        result = operation.result
        logs = redact_lines(result.get("log_lines") or [], limit=200)
        processing = dict(result.get("processing") or {})
        log_ref = processing.get("log_ref")
        if not isinstance(log_ref, dict):
            log_ref = await self._upload_json_or_text(
                operation,
                "build.log",
                ("\n".join(logs) + "\n").encode(),
            )
            processing["log_ref"] = log_ref
            operation = self.store.merge_result(
                operation.build_id, {"processing": processing}
            )
            result = operation.result
        if result.get("status") == "failed":
            failure = result.get("failure") or {}
            await self.control_plane.send_build_event(
                operation,
                status="failed",
                evidence={
                    "logs_ref": log_ref,
                    "log_tail": logs[-50:],
                },
                failure={
                    "phase": str(failure.get("phase", "build"))[:64],
                    "code": str(failure.get("code", "build_failed"))[:64],
                    "message": str(failure.get("message", "Build failed"))[:500],
                },
            )
            await self._cleanup(operation)
            self.store.mark(
                operation.build_id,
                "failed",
                result=self._terminal_result(result) | {"log_ref": log_ref},
            )
            return

        artifact_kind = str(result["artifact_kind"])
        artifact_digest = str(result["artifact_digest"])
        archive = self.store.load_archive(operation.build_id) if artifact_kind == "static" else None
        if artifact_kind == "static" and archive is None:
            raise OperationConflict("static result archive is missing")

        scan_value = processing.get("scan")
        if isinstance(scan_value, dict):
            scan = ScanResult(
                sbom=scan_value["sbom"],
                report=scan_value["report"],
                summary=scan_value["summary"],
                passed=scan_value["passed"] is True,
            )
        elif artifact_kind == "static":
            scan = await self.scanner.scan_static(archive)
        else:
            scan_credential = await self.registry.register(
                repository=operation.repository,
                actions=["pull"],
                expires_at=int(time.time()) + 600,
            )
            try:
                scan = await self.scanner.scan_image(
                    str(result["image_reference"]), scan_credential
                )
            finally:
                await self.registry.revoke(scan_credential.credential_id)
        if not isinstance(scan_value, dict):
            processing["scan"] = {
                "sbom": scan.sbom,
                "report": scan.report,
                "summary": scan.summary,
                "passed": scan.passed,
            }
            operation = self.store.merge_result(
                operation.build_id, {"processing": processing}
            )
            result = operation.result

        manifest = processing.get("static_manifest")
        if artifact_kind == "static" and not isinstance(manifest, dict):
            manifest = await self.artifacts.static(
                organization_id=operation.organization_id,
                revision_id=operation.revision_id,
                archive=archive,
            )
            processing["static_manifest"] = manifest
            operation = self.store.merge_result(
                operation.build_id, {"processing": processing}
            )
            result = operation.result
        image_reference = (
            str(result["image_reference"]) if artifact_kind == "oci" else None
        )

        evidence_refs = processing.get("evidence_refs")
        if not isinstance(evidence_refs, dict):
            evidence_refs = await self._upload_scan_evidence(
                operation, scan, log_ref=log_ref
            )
            processing["evidence_refs"] = evidence_refs
            operation = self.store.merge_result(
                operation.build_id, {"processing": processing}
            )
            result = operation.result
        if not scan.passed:
            await self.control_plane.send_build_event(
                operation,
                status="failed",
                evidence={
                    "logs_ref": log_ref,
                    "sbom_ref": evidence_refs["sbom"],
                    "scan_ref": evidence_refs["scan"],
                    "scan_summary": scan.summary,
                    "log_tail": logs[-50:],
                },
                failure={
                    "phase": "scan",
                    "code": "critical_vulnerability",
                    "message": "Artifact failed the critical vulnerability policy",
                },
            )
            await self._cleanup(operation)
            self.store.mark(
                operation.build_id,
                "failed",
                result=self._terminal_result(result) |
                    {"scan_summary": scan.summary, "evidence": evidence_refs},
            )
            return

        evidence: dict[str, Any] = {
            "scan_status": "passed",
            "plan_type": result["plan_type"],
            "artifact_kind": artifact_kind,
            "source_commit": operation.source_commit,
            "cache_status": "disabled",
            "runtime_class": "gvisor",
            "scan_summary": scan.summary,
            "log_tail": logs[-50:],
            "logs_ref": log_ref,
            "sbom_ref": evidence_refs["sbom"],
            "scan_ref": evidence_refs["scan"],
        }
        if manifest is not None:
            evidence["static_manifest_digest"] = "sha256:" + __import__("hashlib").sha256(
                json.dumps(manifest, separators=(",", ":"), sort_keys=True).encode()
            ).hexdigest()
        if image_reference is not None:
            evidence["image_reference"] = image_reference
        provenance_ref = processing.get("provenance_ref")
        if not isinstance(provenance_ref, dict):
            provenance = self.provenance.sign(
                operation,
                plan_type=str(result["plan_type"]),
                artifact_kind=artifact_kind,
                artifact_digest=artifact_digest,
                evidence={"scan": evidence_refs["scan"], "sbom": evidence_refs["sbom"]},
            )
            provenance_ref = await self._upload_json_or_text(
                operation,
                "provenance.json",
                json.dumps(provenance, separators=(",", ":"), sort_keys=True).encode(),
            )
            processing["provenance_ref"] = provenance_ref
            operation = self.store.merge_result(
                operation.build_id, {"processing": processing}
            )
            result = operation.result
        evidence["provenance_ref"] = provenance_ref
        await self.control_plane.send_build_event(
            operation,
            status="completed",
            evidence=evidence,
            artifact_digest=artifact_digest,
        )
        await self._cleanup(operation)
        self.store.mark(
            operation.build_id,
            "completed",
            result=self._terminal_result(result) | {"evidence": evidence},
        )

    def _terminal_result(self, result: dict[str, Any]) -> dict[str, Any]:
        return {key: value for key, value in result.items() if key != "processing"}

    async def _upload_scan_evidence(
        self,
        operation: Operation,
        scan: ScanResult,
        *,
        log_ref: dict[str, Any],
    ) -> dict[str, Any]:
        sbom = await self._upload_json_or_text(
            operation,
            "sbom.json",
            json.dumps(scan.sbom, separators=(",", ":"), sort_keys=True).encode(),
        )
        report = await self._upload_json_or_text(
            operation,
            "scan.json",
            json.dumps(scan.report, separators=(",", ":"), sort_keys=True).encode(),
        )
        return {"logs": log_ref, "sbom": sbom, "scan": report}

    async def _upload_json_or_text(
        self,
        operation: Operation,
        name: str,
        body: bytes,
    ) -> dict[str, Any]:
        return await self.artifacts.evidence(
            organization_id=operation.organization_id,
            build_id=operation.build_id,
            name=name,
            body=body,
        )

    async def _fail_without_result(
        self,
        operation: Operation,
        *,
        phase: str,
        code: str,
        message: str,
        logs: list[str] | None = None,
    ) -> None:
        safe_logs = redact_lines(logs or [], limit=200)
        if not safe_logs:
            timestamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
                "+00:00", "Z"
            )
            safe_logs = [f"{timestamp} {message}"]
        log_ref = await self._upload_json_or_text(
            operation,
            "build.log",
            ("\n".join(safe_logs) + "\n").encode(),
        )
        await self.control_plane.send_build_event(
            operation,
            status="failed",
            evidence={"logs_ref": log_ref, "log_tail": safe_logs[-50:]},
            failure={"phase": phase, "code": code, "message": message},
        )
        await self._cleanup(operation)
        self.store.mark(
            operation.build_id,
            "failed",
            result={
                "status": "failed",
                "failure": {"phase": phase, "code": code, "message": message},
                "log_lines": safe_logs,
                "log_ref": log_ref,
            },
        )

    async def _cleanup(self, operation: Operation) -> None:
        await self.jobs.delete(operation.job_name, operation.secret_name)
        if operation.registry_credential_id:
            await self.registry.revoke(operation.registry_credential_id)

    async def _finalize_safely(
        self,
        *,
        event_id: str,
        claim_token: str,
        outcome: str,
        safe_error: str,
    ) -> None:
        if not event_id:
            return
        try:
            await self.control_plane.finalize(
                event_id=event_id,
                claim_token=claim_token,
                outcome=outcome,
                safe_error=safe_error,
            )
        except DependencyError:
            logger.warning("build command finalization unavailable")
