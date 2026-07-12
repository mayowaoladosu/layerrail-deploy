from __future__ import annotations

import argparse
import base64
from contextlib import ExitStack
import gzip
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time
from typing import Any, BinaryIO
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen
from uuid import uuid4

SERVICES_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICES_ROOT.parent
sys.path.insert(0, str(SERVICES_ROOT))

from phase2_test_support import Forward, admin_headers, assert_status, kubectl_secret, request


SUCCESS_SCENARIOS = {
    "recovery-web": ("dockerfile_web", "oci"),
    "dockerfile-web": ("dockerfile_web", "oci"),
    "node-web": ("node_web", "oci"),
    "public-node": ("node_web", "oci"),
    "plain-static": ("plain_static", "static"),
    "generated-static": ("node_static", "static"),
}
STATIC_CONTENT = {
    "plain-static": b"Plain static build passed",
    "generated-static": b"Generated static build passed",
}
ALL_SCENARIOS = tuple(SUCCESS_SCENARIOS) + (
    "cancel-web",
    "timeout-web",
    "scan-fail-web",
)


class BuildControllerE2E:
    def __init__(self, profile: str):
        self.profile = profile
        self.kubectl = ["kubectl", "--context", profile]
        self.run_id = uuid4().hex[:10]
        self.state_path = f"/rails/tmp/build-controller-e2e-state-{self.run_id}.json"
        self.provider_path = "/rails/tmp/build-controller-e2e-provider.json"
        self.control_plane = self._control_plane_container()
        self.password = secrets.token_urlsafe(48)
        self.username = "fixture-user"
        self.clone_urls: dict[str, str] = {}
        self.snapshots: dict[str, dict[str, Any]] = {}

    def run(self) -> None:
        self._progress("verify prerequisites")
        self._verify_prerequisites()
        self._progress("prepare fake-private Git")
        self._deploy_git_fixture()
        self._configure_rails_provider()
        self._rails("setup")
        self._progress("controller and Pod loss recovery")
        self._run_recovery()
        self._progress("build cancellation")
        self._run_cancellation()
        self._progress("build deadline")
        self._run_timeout()
        self._progress("critical scan policy")
        self._run_scan_failure()
        self._progress("supported build plans")
        self._run_successes()
        self._progress("duplicate command replay")
        self._verify_duplicate_command()
        self._progress("artifact and evidence verification")
        self._verify_artifacts_and_evidence()
        self._progress("credential and sandbox cleanup")
        self._verify_secret_absence()
        self._verify_terminal_cleanup()
        result = self._result()
        self._cleanup_fixture()
        print(json.dumps(result, separators=(",", ":"), sort_keys=True))

    def _progress(self, message: str) -> None:
        print(f"build-controller E2E: {message}", flush=True)

    def _cleanup_fixture(self) -> None:
        self._run(
            [
                *self.kubectl,
                "delete",
                "-f",
                str(
                    REPOSITORY_ROOT
                    / "infrastructure"
                    / "kubernetes"
                    / "alpha"
                    / "e2e"
                    / "git-fixture.yaml"
                ),
                "--ignore-not-found",
            ]
        )
        self._run(
            [
                *self.kubectl,
                "delete",
                "secret",
                "lrail-git-fixture",
                "-n",
                "lrail-system",
                "--ignore-not-found",
            ]
        )
        self._run(
            [
                "docker",
                "exec",
                self.control_plane,
                "rm",
                "-f",
                self.provider_path,
                self.state_path,
            ]
        )

    def _verify_prerequisites(self) -> None:
        self._run([*self.kubectl, "get", "runtimeclass", "gvisor"])
        self._run(
            [
                *self.kubectl,
                "rollout",
                "status",
                "deployment/build-controller",
                "-n",
                "lrail-system",
                "--timeout=120s",
            ]
        )
        jobs = json.loads(
            self._capture(
                [*self.kubectl, "get", "jobs", "-n", "lrail-builds", "-o", "json"]
            )
        )
        if jobs.get("items"):
            raise AssertionError("build namespace is not clean before E2E")
        environment = self._capture(
            ["docker", "inspect", self.control_plane, "--format", "{{json .Config.Env}}"]
        )
        values = json.loads(environment)
        if "DEPLOYMENT_ORCHESTRATOR=temporal" not in values:
            raise AssertionError("Rails is not running in Temporal mode")
        if f"BUILD_CONTROLLER_E2E_PROVIDER_FILE={self.provider_path}" not in values:
            raise AssertionError("Rails E2E provider boundary is not configured")
        config = json.loads(
            self._capture([*self.kubectl, "get", "--raw", f"/api/v1/nodes/{self.profile}/proxy/configz"])
        )
        if config.get("kubeletconfig", {}).get("podPidsLimit") != 512:
            raise AssertionError("kubelet did not enforce the 512 PID Pod limit")
        denied = self._run(
            [
                *self.kubectl,
                "auth",
                "can-i",
                "get",
                "secrets",
                "-n",
                "lrail-builds",
                "--as=system:serviceaccount:lrail-system:build-controller",
            ],
            check=False,
            capture=True,
        )
        if denied.returncode == 0 or denied.stdout.strip() != "no":
            raise AssertionError("build controller can read build credential Secrets")
        self._verify_admission_denial()

    def _deploy_git_fixture(self) -> None:
        self._run(
            [
                "docker",
                "build",
                "-f",
                str(REPOSITORY_ROOT / "docker" / "Dockerfile.git-fixture"),
                "-t",
                "lrail-git-fixture:dev",
                str(REPOSITORY_ROOT),
            ]
        )
        self._run(
            [
                "minikube",
                "image",
                "load",
                "--overwrite=true",
                "-p",
                self.profile,
                "lrail-git-fixture:dev",
            ]
        )
        secret = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": "lrail-git-fixture", "namespace": "lrail-system"},
            "type": "Opaque",
            "data": {"password": base64.b64encode(self.password.encode()).decode()},
        }
        self._run([*self.kubectl, "apply", "-f", "-"], input=json.dumps(secret).encode())
        self._run(
            [
                *self.kubectl,
                "apply",
                "-f",
                str(
                    REPOSITORY_ROOT
                    / "infrastructure"
                    / "kubernetes"
                    / "alpha"
                    / "e2e"
                    / "git-fixture.yaml"
                ),
            ]
        )
        self._run(
            [
                *self.kubectl,
                "rollout",
                "restart",
                "deployment/git-fixture",
                "-n",
                "lrail-system",
            ]
        )
        self._run(
            [
                *self.kubectl,
                "rollout",
                "status",
                "deployment/git-fixture",
                "-n",
                "lrail-system",
                "--timeout=180s",
            ]
        )

    def _configure_rails_provider(self) -> None:
        repositories: dict[str, dict[str, str]] = {}
        for name in ALL_SCENARIOS:
            if name == "public-node":
                commit = "1f09ebaaa711a9595d73f1f386f1afbbd38f12c7"
                clone_url = "https://github.com/heroku/nodejs-getting-started.git"
            else:
                commit = self._capture(
                    [
                        *self.kubectl,
                        "exec",
                        "-n",
                        "lrail-system",
                        "deployment/git-fixture",
                        "--",
                        "git",
                        f"--git-dir=/repos/{name}.git",
                        "rev-parse",
                        "HEAD",
                    ]
                ).strip()
                clone_url = f"http://git-fixture.lrail-system.svc.cluster.local:8080/{name}.git"
            if len(commit) != 40 or any(value not in "0123456789abcdef" for value in commit):
                raise AssertionError(f"fixture commit is invalid for {name}")
            self.clone_urls[name] = clone_url
            repositories[name] = {"clone_url": clone_url, "commit": commit}
        provider = {
            "installation_id": f"installation-{self.run_id}",
            "username": self.username,
            "secret": self.password,
            "repositories": repositories,
        }
        self._run(
            [
                "docker",
                "exec",
                "-i",
                self.control_plane,
                "sh",
                "-ec",
                f"umask 077; cat > {self.provider_path}; test -s {self.provider_path}",
            ],
            input=json.dumps(provider, separators=(",", ":")).encode(),
        )

    def _run_recovery(self) -> None:
        self._rails("deploy", "recovery-web")
        running = self._rails_wait("recovery-web", "running", 180)
        pod = self._wait_for_worker(running)
        self._verify_job_boundary(running)
        self._run(
            [
                *self.kubectl,
                "rollout",
                "restart",
                "deployment/build-controller",
                "-n",
                "lrail-system",
            ]
        )
        self._run(
            [
                *self.kubectl,
                "rollout",
                "status",
                "deployment/build-controller",
                "-n",
                "lrail-system",
                "--timeout=180s",
            ]
        )
        self._run(
            [
                *self.kubectl,
                "delete",
                "pod",
                pod,
                "-n",
                "lrail-builds",
                "--grace-period=0",
                "--force",
            ]
        )
        value = self._rails_wait("recovery-web", "succeeded", 900)
        self._assert_success("recovery-web", value)

    def _run_cancellation(self) -> None:
        self._rails("deploy", "cancel-web")
        running = self._rails_wait("cancel-web", "running", 180)
        self._wait_for_worker(running)
        self._verify_job_boundary(running)
        self._rails("cancel", "cancel-web")
        value = self._rails_wait("cancel-web", "canceled", 180)
        if value.get("revision_count") != 0:
            raise AssertionError("canceled Build created a Revision")
        self.snapshots["cancel-web"] = value
        self._assert_sandbox_removed(value)

    def _run_timeout(self) -> None:
        self._set_controller_timeout(60)
        try:
            self._rails("deploy", "timeout-web")
            running = self._rails_wait("timeout-web", "running", 180)
            self._wait_for_worker(running)
            value = self._rails_wait("timeout-web", "failed", 240)
        finally:
            self._set_controller_timeout(900)
        error = value.get("evidence", {}).get("error", {})
        if error.get("code") != "build_timeout" or value.get("revision_count") != 0:
            raise AssertionError(f"timeout failed closed incorrectly: {value}")
        self.snapshots["timeout-web"] = value
        self._assert_sandbox_removed(value)

    def _run_scan_failure(self) -> None:
        self._rails("deploy", "scan-fail-web")
        value = self._rails_wait("scan-fail-web", "failed", 900)
        error = value.get("evidence", {}).get("error", {})
        if error.get("code") != "critical_vulnerability" or value.get("revision_count") != 0:
            raise AssertionError(f"scan policy failed closed incorrectly: {value}")
        self.snapshots["scan-fail-web"] = value
        self._assert_sandbox_removed(value)

    def _run_successes(self) -> None:
        for name in (
            "dockerfile-web",
            "node-web",
            "public-node",
            "plain-static",
            "generated-static",
        ):
            first = self._rails("deploy", name)
            if name == "dockerfile-web":
                second = self._rails("deploy", name)
                if first.get("deployment_id") != second.get("deployment_id") or not second.get("replayed"):
                    raise AssertionError("duplicate Deployment did not reuse one resource")
            value = self._rails_wait(name, "succeeded", 900)
            self._assert_success(name, value)

    def _verify_duplicate_command(self) -> None:
        duplicated = self._rails("duplicate-command", "dockerfile-web")
        result = self._rails("wait-commands", "dockerfile-web")
        if result.get("build_count") != 1 or result.get("revision_count") != 1:
            raise AssertionError("duplicate build command created duplicate product state")
        if len(result.get("command_ids", [])) != 2:
            raise AssertionError("duplicate build command was not exercised")
        if duplicated.get("build_id") != result.get("build_id"):
            raise AssertionError("duplicate command changed logical Build identity")

    def _verify_artifacts_and_evidence(self) -> None:
        organization_id = self._state()["organization_id"]
        artifact_secret = kubectl_secret(
            self.kubectl, "lrail-artifact-gateway-admin", "admin-secret"
        )
        registry_secret = kubectl_secret(
            self.kubectl, "lrail-registry-auth-admin", "admin-secret"
        )
        forbidden = self._forbidden_bytes()
        with ExitStack() as stack:
            artifacts = stack.enter_context(
                Forward(kubectl=self.kubectl, resource="service/artifact-gateway", remote_port=8080)
            )
            registry_auth = stack.enter_context(
                Forward(kubectl=self.kubectl, resource="service/registry-auth", remote_port=8080)
            )
            registry = stack.enter_context(
                Forward(kubectl=self.kubectl, resource="service/registry", remote_port=5000)
            )
            for name, value in self.snapshots.items():
                if name not in SUCCESS_SCENARIOS:
                    continue
                evidence_values: dict[str, bytes] = {}
                for evidence_name in ("build.log", "sbom.json", "scan.json", "provenance.json"):
                    evidence_values[evidence_name] = self._evidence(
                        artifacts.url,
                        artifact_secret,
                        organization_id,
                        value["build_id"],
                        evidence_name,
                    )
                self._assert_forbidden_absent(evidence_values.values(), forbidden, f"{name} evidence")
                log = evidence_values["build.log"].decode(errors="replace")
                if "clone exact commit" not in log or "publish" not in log:
                    raise AssertionError(f"{name} build phases are missing from retained logs")
                sbom = json.loads(evidence_values["sbom.json"])
                scan = json.loads(evidence_values["scan.json"])
                provenance = json.loads(evidence_values["provenance.json"])
                scan_results = scan.get("Results")
                if sbom.get("bomFormat") != "CycloneDX" or (
                    scan_results is not None and not isinstance(scan_results, list)
                ):
                    raise AssertionError(f"{name} supply-chain evidence is invalid")
                self._verify_provenance(evidence_values["provenance.json"])
                if provenance.get("statement", {}).get("subject", [{}])[0].get("digest", {}).get("sha256") != value["artifact_digest"].removeprefix("sha256:"):
                    raise AssertionError(f"{name} provenance does not bind the artifact")
                if SUCCESS_SCENARIOS[name][1] == "static":
                    self._verify_static(artifacts.url, organization_id, name, value)
                else:
                    self._verify_oci(
                        registry_auth.url,
                        registry.url,
                        registry_secret,
                        organization_id,
                        value,
                        forbidden,
                    )
            failed_scan = self.snapshots["scan-fail-web"]
            report = self._evidence(
                artifacts.url,
                artifact_secret,
                organization_id,
                failed_scan["build_id"],
                "scan.json",
            )
            critical = sum(
                1
                for result in json.loads(report).get("Results", [])
                for vulnerability in result.get("Vulnerabilities") or []
                if vulnerability.get("Severity") == "CRITICAL"
            )
            if critical < 1:
                raise AssertionError("critical scan fixture did not produce a critical finding")

    def _verify_secret_absence(self) -> None:
        self._rails("verify-secret-absence")
        pod = self._controller_pod()
        checker = (
            "import json,pathlib,sys; needles=[v.encode() for v in json.loads(sys.stdin.read())]; "
            "files=[p for p in pathlib.Path('/var/lib/lrail-build-controller').rglob('*') if p.is_file()]; "
            "raise SystemExit(1 if any(n in p.read_bytes() for p in files for n in needles) else 0)"
        )
        self._run(
            [*self.kubectl, "exec", "-i", "-n", "lrail-system", pod, "--", "python", "-c", checker],
            input=json.dumps([value.decode() for value in self._forbidden_bytes()]).encode(),
        )
        logs = self._capture(
            [
                *self.kubectl,
                "logs",
                "-n",
                "lrail-system",
                "-l",
                "app.kubernetes.io/part-of=lrail-alpha",
                "--all-containers=true",
                "--prefix=true",
                "--tail=2000",
            ]
        ).encode()
        self._assert_forbidden_absent([logs], self._forbidden_bytes(), "platform logs")

    def _verify_terminal_cleanup(self) -> None:
        jobs = json.loads(self._capture([*self.kubectl, "get", "jobs", "-n", "lrail-builds", "-o", "json"]))
        pods = json.loads(self._capture([*self.kubectl, "get", "pods", "-n", "lrail-builds", "-o", "json"]))
        secrets_value = json.loads(self._capture([*self.kubectl, "get", "secrets", "-n", "lrail-builds", "-o", "json"]))
        if jobs.get("items") or pods.get("items"):
            raise AssertionError("terminal build sandboxes were retained")
        leaked = [
            value["metadata"]["name"]
            for value in secrets_value.get("items", [])
            if value["metadata"]["name"].startswith("build-credentials-")
        ]
        if leaked:
            raise AssertionError(f"terminal build credentials were retained: {leaked}")
        pvcs = json.loads(self._capture([*self.kubectl, "get", "pvc", "-n", "lrail-builds", "-o", "json"]))
        if pvcs.get("items"):
            raise AssertionError("build namespace contains a persistent cross-Build cache")

    def _assert_success(self, name: str, value: dict[str, Any]) -> None:
        expected_plan, expected_kind = SUCCESS_SCENARIOS[name]
        evidence = value.get("evidence", {})
        if value.get("deployment_status") != "scanning":
            raise AssertionError(f"{name} Deployment did not reach scanning: {value}")
        if value.get("build_status") != "succeeded" or value.get("revision_status") != "candidate":
            raise AssertionError(f"{name} did not create one candidate Revision: {value}")
        if value.get("revision_count") != 1 or not self._digest(value.get("artifact_digest")):
            raise AssertionError(f"{name} immutable artifact identity is invalid")
        if evidence.get("scan_status") != "passed":
            raise AssertionError(f"{name} scan did not pass")
        if evidence.get("plan_type") != expected_plan or evidence.get("artifact_kind") != expected_kind:
            raise AssertionError(f"{name} plan result changed")
        for key in ("logs_ref", "sbom_ref", "scan_ref", "provenance_ref"):
            if not self._digest((evidence.get(key) or {}).get("digest")):
                raise AssertionError(f"{name} is missing {key}")
        self.snapshots[name] = value
        self._assert_sandbox_removed(value)

    def _verify_job_boundary(self, value: dict[str, Any]) -> None:
        job = json.loads(
            self._capture(
                [*self.kubectl, "get", "job", value["job_name"], "-n", "lrail-builds", "-o", "json"]
            )
        )
        pod = job["spec"]["template"]["spec"]
        container = pod["containers"][0]
        if pod.get("runtimeClassName") != "gvisor" or pod.get("automountServiceAccountToken") is not False:
            raise AssertionError("build Job escaped the gVisor/no-token boundary")
        if container.get("securityContext", {}).get("privileged") is not False:
            raise AssertionError("build Job became privileged")
        if container.get("securityContext", {}).get("allowPrivilegeEscalation") is not False:
            raise AssertionError("build Job can escalate privileges")
        if not container.get("securityContext", {}).get("readOnlyRootFilesystem"):
            raise AssertionError("build Job root filesystem is writable")
        if any("hostPath" in volume or "persistentVolumeClaim" in volume for volume in pod.get("volumes", [])):
            raise AssertionError("build Job received host or persistent storage")
        credential_mount = next(
            mount for mount in container.get("volumeMounts", []) if mount.get("name") == "credentials"
        )
        if credential_mount.get("readOnly") is not True:
            raise AssertionError("build credential Secret is writable")
        serialized = json.dumps(job, separators=(",", ":")).encode()
        self._assert_forbidden_absent([serialized], self._forbidden_bytes(), "build Job spec")

    def _verify_admission_denial(self) -> None:
        pod = {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {"name": "e2e-privileged-build", "namespace": "lrail-builds"},
            "spec": {
                "runtimeClassName": "gvisor",
                "automountServiceAccountToken": False,
                "hostNetwork": True,
                "restartPolicy": "Never",
                "securityContext": {
                    "runAsUser": 0,
                    "runAsGroup": 0,
                    "seccompProfile": {"type": "RuntimeDefault"},
                },
                "containers": [
                    {
                        "name": "worker",
                        "image": "lrail-build-worker:dev",
                        "securityContext": {
                            "privileged": False,
                            "allowPrivilegeEscalation": False,
                            "readOnlyRootFilesystem": True,
                            "capabilities": {
                                "drop": ["ALL"],
                                "add": [
                                    "CHOWN",
                                    "DAC_OVERRIDE",
                                    "FOWNER",
                                    "FSETID",
                                    "KILL",
                                    "MKNOD",
                                    "NET_BIND_SERVICE",
                                    "SETFCAP",
                                    "SETGID",
                                    "SETPCAP",
                                    "SETUID",
                                    "SYS_ADMIN",
                                    "SYS_CHROOT",
                                ],
                            },
                        },
                        "resources": {
                            "limits": {"cpu": "1", "memory": "1Gi", "ephemeral-storage": "1Gi"}
                        },
                    }
                ],
            },
        }
        result = self._run(
            [*self.kubectl, "apply", "--dry-run=server", "-f", "-"],
            input=json.dumps(pod).encode(),
            check=False,
            capture=True,
        )
        if result.returncode == 0 or "lrail-build-pod-boundary" not in result.stderr:
            raise AssertionError("build admission policy allowed a privileged sandbox")

    def _verify_static(
        self, artifact_url: str, organization_id: str, name: str, value: dict[str, Any]
    ) -> None:
        revision_id = value["revision_id"]
        status, _headers, body = request(
            "GET", f"{artifact_url}/v1/static/{organization_id}/{revision_id}/manifest"
        )
        assert_status(status, 200, f"{name} static manifest")
        manifest = json.loads(body)
        index = next((item for item in manifest.get("files", []) if item.get("path") == "index.html"), None)
        if not index:
            raise AssertionError(f"{name} static manifest is missing index.html")
        status, headers, body = request(
            "GET", f"{artifact_url}/v1/static/{organization_id}/{revision_id}/files/index.html"
        )
        assert_status(status, 200, f"{name} static index")
        if STATIC_CONTENT[name] not in body or headers.get("X-Content-Type-Options") != "nosniff":
            raise AssertionError(f"{name} static output changed")

    def _verify_oci(
        self,
        auth_url: str,
        registry_url: str,
        admin_secret: bytes,
        organization_id: str,
        value: dict[str, Any],
        forbidden: tuple[bytes, ...],
    ) -> None:
        reference = value.get("evidence", {}).get("image_reference", "")
        if "/" not in reference or "@sha256:" not in reference:
            raise AssertionError("immutable image reference is missing")
        repository = reference.split("/", 1)[1].rsplit("@", 1)[0]
        if not repository.startswith(f"lrail/{organization_id}/"):
            raise AssertionError("image escaped its tenant repository")
        credential_id = str(uuid4())
        username = "lr_" + secrets.token_hex(12)
        password = secrets.token_urlsafe(48)
        path = "/v1/credentials"
        registration = json.dumps(
            {
                "credential_id": credential_id,
                "username": username,
                "password": password,
                "repository_prefix": repository,
                "actions": ["pull"],
                "expires_at": int(time.time()) + 600,
            },
            separators=(",", ":"),
        ).encode()
        status, _headers, _body = request(
            "POST",
            auth_url + path,
            body=registration,
            headers=admin_headers(admin_secret, "POST", path, registration),
        )
        assert_status(status, 201, "scan credential registration")
        try:
            basic = base64.b64encode(f"{username}:{password}".encode()).decode()
            query = urlencode(
                {"service": "lrail-alpha-registry", "scope": f"repository:{repository}:pull"}
            )
            status, _headers, body = request(
                "GET", f"{auth_url}/token?{query}", headers={"Authorization": f"Basic {basic}"}
            )
            assert_status(status, 200, "image pull token")
            token = json.loads(body)["token"]
            self._scan_registry_artifact(
                registry_url,
                repository,
                value["artifact_digest"],
                token,
                forbidden,
            )
        finally:
            delete_path = f"/v1/credentials/{credential_id}"
            request(
                "DELETE",
                auth_url + delete_path,
                headers=admin_headers(admin_secret, "DELETE", delete_path, b""),
            )

    def _scan_registry_artifact(
        self,
        registry_url: str,
        repository: str,
        digest: str,
        token: str,
        forbidden: tuple[bytes, ...],
    ) -> None:
        pending = [digest]
        seen: set[str] = set()
        while pending:
            current = pending.pop()
            if current in seen:
                continue
            seen.add(current)
            body, _media_type = self._registry_bytes(
                registry_url, repository, "manifests", current, token
            )
            if "sha256:" + hashlib.sha256(body).hexdigest() != current:
                raise AssertionError("registry manifest digest changed")
            self._assert_forbidden_absent([body], forbidden, "OCI manifest")
            manifest = json.loads(body)
            if "manifests" in manifest:
                pending.extend(item["digest"] for item in manifest["manifests"])
                continue
            descriptors = [manifest.get("config")] + list(manifest.get("layers") or [])
            for descriptor in descriptors:
                if not descriptor:
                    continue
                blob_digest = descriptor["digest"]
                stream, media_type = self._registry_stream(
                    registry_url, repository, "blobs", blob_digest, token
                )
                with stream:
                    source: BinaryIO = stream
                    if "gzip" in descriptor.get("mediaType", "") or stream.headers.get("Content-Type", "").endswith("gzip"):
                        source = gzip.GzipFile(fileobj=stream)
                    elif "zstd" in descriptor.get("mediaType", ""):
                        raise AssertionError("zstd image layers are not covered by the secret probe")
                    self._scan_stream(source, forbidden, f"OCI blob {media_type}")

    def _evidence(
        self,
        base_url: str,
        secret: bytes,
        organization_id: str,
        build_id: str,
        name: str,
    ) -> bytes:
        path = f"/v1/evidence/{organization_id}/{build_id}/{quote(name, safe='')}"
        status, _headers, body = request(
            "GET",
            base_url + path,
            headers=admin_headers(secret, "GET", path, b""),
        )
        assert_status(status, 200, f"evidence {name}")
        return body

    def _verify_provenance(self, body: bytes) -> None:
        code = """
import base64,hashlib,json,sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519
value=json.loads(sys.stdin.buffer.read())
key=serialization.load_pem_private_key(open('/run/lrail-build-controller/signing-key.pem','rb').read(),password=None)
assert isinstance(key,ed25519.Ed25519PrivateKey)
statement=json.dumps(value['statement'],separators=(',',':'),sort_keys=True).encode()
key.public_key().verify(base64.b64decode(value['signature']['value']),statement)
public=key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
assert value['signature']['key_id']=='sha256:'+hashlib.sha256(public).hexdigest()
""".strip()
        self._run(
            [
                *self.kubectl,
                "exec",
                "-i",
                "-n",
                "lrail-system",
                self._controller_pod(),
                "--",
                "python",
                "-c",
                code,
            ],
            input=body,
        )

    def _set_controller_timeout(self, seconds: int) -> None:
        self._run(
            [
                *self.kubectl,
                "set",
                "env",
                "deployment/build-controller",
                "-n",
                "lrail-system",
                f"BUILD_CONTROLLER_BUILD_TIMEOUT_SECONDS={seconds}",
            ]
        )
        self._run(
            [
                *self.kubectl,
                "rollout",
                "status",
                "deployment/build-controller",
                "-n",
                "lrail-system",
                "--timeout=180s",
            ]
        )

    def _wait_for_worker(self, value: dict[str, Any]) -> str:
        deadline = time.monotonic() + 120
        selector = f"layerrail.com/build-id={value['build_id']}"
        while time.monotonic() < deadline:
            result = self._run(
                [*self.kubectl, "get", "pods", "-n", "lrail-builds", "-l", selector, "-o", "json"],
                check=False,
                capture=True,
            )
            if result.returncode == 0:
                items = json.loads(result.stdout).get("items", [])
                running = [item for item in items if item.get("status", {}).get("phase") == "Running"]
                if running:
                    return running[0]["metadata"]["name"]
            time.sleep(0.25)
        raise AssertionError(f"worker Pod did not start for {value['build_id']}")

    def _assert_sandbox_removed(self, value: dict[str, Any]) -> None:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            job = self._run(
                [*self.kubectl, "get", "job", value["job_name"], "-n", "lrail-builds"],
                check=False,
                capture=True,
            )
            secret = self._run(
                [*self.kubectl, "get", "secret", value["secret_name"], "-n", "lrail-builds"],
                check=False,
                capture=True,
            )
            if job.returncode != 0 and secret.returncode != 0:
                return
            time.sleep(0.25)
        raise AssertionError(f"sandbox or credentials were retained for {value['build_id']}")

    def _rails_wait(self, scenario: str, expected: str, timeout: int) -> dict[str, Any]:
        return self._rails(
            "wait",
            scenario,
            extra_env={
                "BUILD_CONTROLLER_E2E_EXPECT": expected,
                "BUILD_CONTROLLER_E2E_TIMEOUT": str(timeout),
            },
            timeout=timeout + 60,
        )

    def _rails(
        self,
        action: str,
        scenario: str | None = None,
        *,
        extra_env: dict[str, str] | None = None,
        timeout: int = 180,
    ) -> dict[str, Any]:
        environment = {
            "BUILD_CONTROLLER_E2E_STATE_PATH": self.state_path,
            "BUILD_CONTROLLER_E2E_PROVIDER_FILE": self.provider_path,
            "BUILD_CONTROLLER_E2E_RUN_ID": self.run_id,
        }
        environment.update(extra_env or {})
        arguments = ["docker", "exec"]
        for key, value in environment.items():
            arguments += ["-e", f"{key}={value}"]
        arguments += [
            self.control_plane,
            "bundle",
            "exec",
            "rails",
            "runner",
            "script/build_controller_e2e.rb",
            action,
        ]
        if scenario:
            arguments.append(scenario)
        output = self._capture(arguments, timeout=timeout)
        for line in reversed(output.splitlines()):
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                return value
        raise AssertionError(f"Rails E2E action {action} returned no JSON")

    def _state(self) -> dict[str, Any]:
        output = self._capture(
            [
                "docker",
                "exec",
                self.control_plane,
                "cat",
                self.state_path,
            ]
        )
        return json.loads(output)

    def _controller_pod(self) -> str:
        return self._capture(
            [
                *self.kubectl,
                "get",
                "pod",
                "-n",
                "lrail-system",
                "-l",
                "app.kubernetes.io/name=build-controller",
                "-o",
                "jsonpath={.items[0].metadata.name}",
            ]
        ).strip()

    def _control_plane_container(self) -> str:
        values = self._capture(
            [
                "docker",
                "ps",
                "--filter",
                "label=com.docker.compose.project=devpush",
                "--filter",
                "label=com.docker.compose.service=control-plane",
                "--format",
                "{{.ID}}",
            ]
        ).splitlines()
        if len(values) != 1:
            raise RuntimeError("exactly one control-plane container must be running")
        return values[0]

    def _forbidden_bytes(self) -> tuple[bytes, ...]:
        values = [
            self.password,
            base64.b64encode(self.password.encode()).decode(),
            *self.clone_urls.values(),
        ]
        return tuple(value.encode() for value in values if value)

    def _result(self) -> dict[str, Any]:
        return {
            "status": "ok",
            "run_id": self.run_id,
            "organization_id": self._state()["organization_id"],
            "scenarios": {
                name: {
                    "deployment_id": value["deployment_id"],
                    "deployment_status": value["deployment_status"],
                    "build_id": value["build_id"],
                    "build_status": value["build_status"],
                    "revision_id": value.get("revision_id"),
                    "artifact_digest": value.get("artifact_digest"),
                }
                for name, value in sorted(self.snapshots.items())
            },
        }

    def _registry_bytes(
        self, registry_url: str, repository: str, resource: str, digest: str, token: str
    ) -> tuple[bytes, str]:
        with self._registry_stream(registry_url, repository, resource, digest, token) as response:
            return response.read(), response.headers.get("Content-Type", "")

    def _registry_stream(
        self, registry_url: str, repository: str, resource: str, digest: str, token: str
    ):
        url = f"{registry_url}/v2/{repository}/{resource}/{digest}"
        request_value = Request(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": ", ".join(
                    [
                        "application/vnd.oci.image.index.v1+json",
                        "application/vnd.oci.image.manifest.v1+json",
                        "application/vnd.docker.distribution.manifest.list.v2+json",
                        "application/vnd.docker.distribution.manifest.v2+json",
                    ]
                ),
            },
        )
        return urlopen(request_value, timeout=120)

    def _scan_stream(
        self, stream: BinaryIO, needles: tuple[bytes, ...], context: str
    ) -> None:
        overlap = max((len(value) for value in needles), default=1) - 1
        tail = b""
        while True:
            chunk = stream.read(1 << 20)
            if not chunk:
                return
            value = tail + chunk
            if any(needle in value for needle in needles):
                raise AssertionError(f"credential material appeared in {context}")
            tail = value[-overlap:] if overlap else b""

    def _assert_forbidden_absent(
        self, values: Any, forbidden: tuple[bytes, ...], context: str
    ) -> None:
        for value in values:
            if any(secret in value for secret in forbidden):
                raise AssertionError(f"credential material appeared in {context}")

    def _digest(self, value: object) -> bool:
        return (
            isinstance(value, str)
            and value.startswith("sha256:")
            and len(value) == 71
            and all(character in "0123456789abcdef" for character in value[7:])
        )

    def _capture(self, arguments: list[str], *, timeout: int = 180) -> str:
        result = self._run(arguments, capture=True, timeout=timeout)
        return result.stdout.strip()

    def _run(
        self,
        arguments: list[str],
        *,
        input: bytes | None = None,
        check: bool = True,
        capture: bool = False,
        timeout: int = 600,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            arguments,
            input=input,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.PIPE if capture else subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
        value = subprocess.CompletedProcess(
            result.args,
            result.returncode,
            result.stdout.decode(errors="replace") if result.stdout is not None else "",
            result.stderr.decode(errors="replace") if result.stderr is not None else "",
        )
        if check and value.returncode != 0:
            details = (value.stderr or value.stdout).strip()
            prefix = " ".join(arguments[:5])
            raise RuntimeError(f"command failed ({prefix}): {details[:4000]}")
        return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", default="lrail-alpha")
    args = parser.parse_args()
    try:
        BuildControllerE2E(args.profile).run()
    except (AssertionError, HTTPError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"build-controller E2E failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
