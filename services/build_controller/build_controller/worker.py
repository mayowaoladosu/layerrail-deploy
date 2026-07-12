from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tarfile
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import UUID, uuid4

from .plans import Plan, UnsupportedProject, detect_plan
from .redaction import redact


class WorkerFailure(RuntimeError):
    def __init__(self, phase: str, code: str, message: str):
        super().__init__(message)
        self.phase = phase
        self.code = code
        self.safe_message = message[:500]


class BuildLog:
    def __init__(self, known: tuple[str, ...]):
        self._known = known
        self._lines: list[str] = []

    def write(self, message: str) -> None:
        timestamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
            "+00:00", "Z"
        )
        value = f"{timestamp} {redact(message, known=self._known)}"
        self._lines.append(value)
        self._lines = self._lines[-1000:]
        print(value, flush=True)

    @property
    def lines(self) -> list[str]:
        return self._lines.copy()


class Worker:
    def __init__(self) -> None:
        self.credentials = Path(os.environ.get("BUILD_CREDENTIALS_DIR", "/run/lrail-build"))
        self.controller_url = os.environ.get(
            "BUILD_CONTROLLER_URL",
            "http://build-controller.lrail-system.svc.cluster.local:8080",
        ).rstrip("/")
        self.work = Path("/work")
        self.command = self._command()
        self.git_username = self._read("git-username")
        self.git_password = self._read("git-password")
        self.registry_username = self._read("registry-username")
        self.registry_password = self._read("registry-password")
        self.callback_secret = self._read("callback-secret").encode()
        self.log = BuildLog(
            (
                self.git_username,
                self.git_password,
                self.registry_username,
                self.registry_password,
                self.callback_secret.decode(),
            )
        )
        self._buildkit: subprocess.Popen[bytes] | None = None

    def run(self) -> int:
        try:
            self._validate_expiry()
            source = self._clone()
            plan = detect_plan(source, str(self.command["workload_type"]))
            self.log.write(f"detect {plan.type}")
            self._start_buildkit()
            result = self._build(source, plan)
            payload = {
                "contract_version": 1,
                "operation_id": self.command["operation_id"],
                "build_id": self.command["build_id"],
                "source_commit": self.command["source_commit"],
                "status": "completed",
                "plan_type": plan.type,
                "artifact_kind": plan.artifact_kind,
                "artifact_digest": result["artifact_digest"],
                "log_lines": self.log.lines,
            }
            if plan.artifact_kind == "oci":
                payload["image_reference"] = result["image_reference"]
            else:
                payload["static_archive"] = base64.b64encode(
                    result["static_archive"]
                ).decode()
            self._callback(payload)
            return 0
        except UnsupportedProject as error:
            self.log.write(str(error))
            self._failure("detect", "unsupported_project", str(error))
            return 0
        except WorkerFailure as error:
            self.log.write(error.safe_message)
            self._failure(error.phase, error.code, error.safe_message)
            return 0
        except Exception:
            self.log.write("Build sandbox encountered an internal failure")
            self._failure(
                "sandbox",
                "worker_internal_error",
                "Build sandbox encountered an internal failure",
            )
            return 0
        finally:
            if self._buildkit and self._buildkit.poll() is None:
                self._buildkit.terminate()
                try:
                    self._buildkit.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self._buildkit.kill()
                    self._buildkit.wait(timeout=5)

    def _command(self) -> dict[str, Any]:
        try:
            value = json.loads(self._read("command.json"))
        except json.JSONDecodeError as error:
            raise WorkerFailure("prepare", "command_invalid", "Build command is invalid") from error
        required = {
            "contract_version",
            "command_type",
            "operation_id",
            "organization_id",
            "deployment_id",
            "build_id",
            "revision_id",
            "service_id",
            "expected_version",
            "workload_type",
            "repository",
            "source_commit",
            "source_root",
            "descriptor_digest",
        }
        if not isinstance(value, dict) or set(value) != required:
            raise WorkerFailure("prepare", "command_invalid", "Build command is invalid")
        try:
            for key in (
                "operation_id",
                "organization_id",
                "deployment_id",
                "build_id",
                "revision_id",
                "service_id",
            ):
                UUID(str(value[key]))
        except ValueError as error:
            raise WorkerFailure("prepare", "command_invalid", "Build command is invalid") from error
        return value

    def _read(self, name: str) -> str:
        value = (self.credentials / name).read_text(encoding="utf-8").strip()
        if not value:
            raise WorkerFailure("prepare", "credential_invalid", "Build credential is invalid")
        return value

    def _validate_expiry(self) -> None:
        try:
            expires_at = datetime.fromisoformat(
                self._read("git-expires-at").replace("Z", "+00:00")
            )
        except ValueError as error:
            raise WorkerFailure("prepare", "credential_invalid", "Build credential is invalid") from error
        if expires_at <= datetime.now(timezone.utc) + timedelta(seconds=30):
            raise WorkerFailure("prepare", "credential_expired", "Build credential expired")

    def _clone(self) -> Path:
        self.log.write("clone source")
        source = self.work / "source"
        shutil.rmtree(source, ignore_errors=True)
        source.mkdir(parents=True)
        askpass = self.work / "git-askpass.sh"
        askpass.write_text(
            "#!/bin/sh\ncase \"$1\" in *Username*) cat /run/lrail-build/git-username;; *) cat /run/lrail-build/git-password;; esac\n",
            encoding="utf-8",
        )
        askpass.chmod(0o700)
        env = os.environ.copy()
        env.update(GIT_ASKPASS=str(askpass), GIT_TERMINAL_PROMPT="0")
        self._run(["git", "init", "--quiet", str(source)], phase="clone", env=env)
        self._run(
            ["git", "-C", str(source), "remote", "add", "origin", self._read("clone-url")],
            phase="clone",
            env=env,
        )
        self._run(
            [
                "git",
                "-C",
                str(source),
                "fetch",
                "--quiet",
                "--depth=1",
                "origin",
                str(self.command["source_commit"]),
            ],
            phase="clone",
            env=env,
            timeout=300,
        )
        self._run(
            ["git", "-C", str(source), "checkout", "--quiet", "--detach", "FETCH_HEAD"],
            phase="clone",
            env=env,
        )
        actual = subprocess.check_output(
            ["git", "-C", str(source), "rev-parse", "HEAD"],
            env=env,
            timeout=10,
        ).decode().strip()
        if actual != self.command["source_commit"]:
            raise WorkerFailure("clone", "commit_mismatch", "Cloned commit did not match the requested revision")
        shutil.rmtree(source / ".git")
        root = source if self.command["source_root"] == "." else source / self.command["source_root"]
        try:
            root.resolve().relative_to(source.resolve())
        except ValueError as error:
            raise WorkerFailure("clone", "source_root_invalid", "Source root is invalid") from error
        if not root.is_dir():
            raise WorkerFailure("clone", "source_root_missing", "Source root was not found")
        self.log.write(f"clone exact commit {actual[:12]}")
        return root

    def _start_buildkit(self) -> None:
        self.log.write("start isolated builder")
        buildkit_log = (self.work / "buildkitd.log").open("wb")
        self._buildkit = subprocess.Popen(
            [
                "buildkitd",
                "--root",
                "/state",
                "--addr",
                "unix:///run/buildkit/buildkitd.sock",
                "--oci-worker-snapshotter=native",
                "--oci-worker-binary=capless-runc",
            ],
            stdout=buildkit_log,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self._buildkit.poll() is not None:
                raise WorkerFailure("build", "builder_start_failed", "Isolated builder could not start")
            if Path("/run/buildkit/buildkitd.sock").exists():
                result = subprocess.run(
                    ["buildctl", "--addr", os.environ["BUILDKIT_HOST"], "debug", "workers"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=5,
                    check=False,
                )
                if result.returncode == 0:
                    return
            time.sleep(0.1)
        raise WorkerFailure("build", "builder_start_timeout", "Isolated builder did not become ready")

    def _build(self, source: Path, plan: Plan) -> dict[str, Any]:
        dockerfile_dir = source
        if plan.dockerfile is not None:
            dockerfile_dir = self.work / "dockerfile"
            shutil.rmtree(dockerfile_dir, ignore_errors=True)
            dockerfile_dir.mkdir()
            (dockerfile_dir / "Dockerfile").write_text(plan.dockerfile, encoding="utf-8")
        metadata = self.work / "metadata.json"
        arguments = [
            "buildctl",
            "--addr",
            os.environ["BUILDKIT_HOST"],
            "build",
            "--progress",
            "plain",
            "--frontend",
            "dockerfile.v0",
            "--local",
            f"context={source}",
            "--local",
            f"dockerfile={dockerfile_dir}",
            "--metadata-file",
            str(metadata),
        ]
        if plan.artifact_kind == "oci":
            endpoint = self._read("registry-endpoint")
            repository = str(self.command["repository"])
            tag = "build-" + str(self.command["build_id"]).replace("-", "")[:16]
            self._docker_config(endpoint)
            arguments += [
                "--output",
                f"type=image,name={endpoint}/{repository}:{tag},push=true,registry.insecure=true",
            ]
        else:
            output = self.work / "output"
            shutil.rmtree(output, ignore_errors=True)
            output.mkdir()
            arguments += ["--output", f"type=local,dest={output}"]
        self.log.write("build artifact")
        self._run(arguments, phase="build", timeout=840)
        if plan.artifact_kind == "static":
            archive = self._static_archive(self.work / "output")
            digest = "sha256:" + hashlib.sha256(archive).hexdigest()
            self.log.write(f"publish static artifact {digest[:19]}")
            return {"artifact_digest": digest, "static_archive": archive}
        try:
            value = json.loads(metadata.read_text(encoding="utf-8"))
            digest = value.get("containerimage.digest") or value.get(
                "containerimage.descriptor", {}
            ).get("digest")
        except (OSError, json.JSONDecodeError, AttributeError) as error:
            raise WorkerFailure("publish", "image_digest_missing", "Registry did not return an image digest") from error
        if not isinstance(digest, str) or not digest.startswith("sha256:"):
            raise WorkerFailure("publish", "image_digest_missing", "Registry did not return an image digest")
        endpoint = self._read("registry-endpoint")
        reference = f"{endpoint}/{self.command['repository']}@{digest}"
        self.log.write(f"publish immutable image {digest[:19]}")
        return {"artifact_digest": digest, "image_reference": reference}

    def _docker_config(self, endpoint: str) -> None:
        auth = base64.b64encode(
            f"{self.registry_username}:{self.registry_password}".encode()
        ).decode()
        target = Path("/root/.docker/config.json")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            json.dumps({"auths": {endpoint: {"auth": auth}}}, separators=(",", ":")),
            encoding="utf-8",
        )
        target.chmod(0o600)

    def _static_archive(self, output: Path) -> bytes:
        if not (output / "index.html").is_file():
            raise WorkerFailure("build", "static_index_missing", "Static output is missing index.html")
        target = self.work / "static.tar"
        with tarfile.open(target, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for path in sorted(output.rglob("*"), key=lambda value: value.as_posix()):
                relative = path.relative_to(output).as_posix()
                if path.is_symlink():
                    raise WorkerFailure("build", "static_symlink_denied", "Static output contains a symbolic link")
                info = archive.gettarinfo(str(path), arcname=relative)
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                info.mtime = 0
                info.mode = 0o755 if path.is_dir() else 0o644
                if path.is_file():
                    with path.open("rb") as source:
                        archive.addfile(info, source)
                elif path.is_dir():
                    archive.addfile(info)
                else:
                    raise WorkerFailure("build", "static_entry_denied", "Static output contains an unsupported entry")
        return target.read_bytes()

    def _run(
        self,
        arguments: list[str],
        *,
        phase: str,
        env: dict[str, str] | None = None,
        timeout: int = 60,
    ) -> None:
        output = self.work / f"{phase}-{hashlib.sha256(chr(0).join(arguments).encode()).hexdigest()[:12]}.log"
        try:
            with output.open("wb") as stream:
                completed = subprocess.run(
                    arguments,
                    stdout=stream,
                    stderr=subprocess.STDOUT,
                    env=env,
                    timeout=timeout,
                    check=False,
                )
            code = completed.returncode
        except subprocess.TimeoutExpired as error:
            raise WorkerFailure(phase, f"{phase}_timeout", f"{phase.title()} phase timed out") from error
        except (OSError, subprocess.SubprocessError) as error:
            raise WorkerFailure(phase, f"{phase}_failed", f"{phase.title()} phase could not run") from error
        finally:
            if output.is_file():
                with output.open("rb") as stream:
                    stream.seek(max(0, output.stat().st_size - (1 << 20)))
                    for raw in stream.read().splitlines()[-1000:]:
                        self.log.write(raw.decode(errors="replace"))
                output.unlink(missing_ok=True)
        if code != 0:
            raise WorkerFailure(phase, f"{phase}_failed", f"{phase.title()} phase failed")

    def _failure(self, phase: str, code: str, message: str) -> None:
        payload = {
            "contract_version": 1,
            "operation_id": self.command["operation_id"],
            "build_id": self.command["build_id"],
            "source_commit": self.command["source_commit"],
            "status": "failed",
            "log_lines": self.log.lines,
            "failure": {"phase": phase, "code": code, "message": message},
        }
        self._callback(payload)

    def _callback(self, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
        build_id = str(self.command["build_id"])
        path = f"/v1/builds/{build_id}/result"
        for attempt in range(5):
            timestamp = str(int(time.time()))
            request_id = str(uuid4())
            message = b"\n".join(
                [timestamp.encode(), request_id.encode(), b"PUT", path.encode(), body]
            )
            signature = hmac.new(self.callback_secret, message, hashlib.sha256).hexdigest()
            request = Request(
                self.controller_url + path,
                data=body,
                method="PUT",
                headers={
                    "Content-Type": "application/json",
                    "X-Lrail-Timestamp": timestamp,
                    "X-Lrail-Request-Id": request_id,
                    "X-Lrail-Signature": f"sha256={signature}",
                },
            )
            try:
                with urlopen(request, timeout=30) as response:
                    if response.status in {200, 202}:
                        self.log.write("submit signed result")
                        return
            except (HTTPError, URLError, TimeoutError, socket.timeout):
                if attempt == 4:
                    break
                time.sleep(2**attempt)
        raise WorkerFailure("callback", "callback_failed", "Signed build result could not be delivered")


def main() -> None:
    raise SystemExit(Worker().run())


if __name__ == "__main__":
    main()
