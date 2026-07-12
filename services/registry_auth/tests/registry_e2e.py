from __future__ import annotations

import argparse
import base64
from contextlib import ExitStack
import hashlib
import hmac
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from typing import BinaryIO
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
from uuid import uuid4


class Forward:
    def __init__(
        self,
        *,
        kubectl: list[str],
        resource: str,
        remote_port: int,
    ) -> None:
        self._kubectl = kubectl
        self._resource = resource
        self._remote_port = remote_port
        self._log: BinaryIO | None = None
        self._process: subprocess.Popen[bytes] | None = None
        self.port = self._free_port()

    def __enter__(self) -> "Forward":
        self._log = tempfile.TemporaryFile()
        self._process = subprocess.Popen(
            [
                *self._kubectl,
                "port-forward",
                "-n",
                "lrail-system",
                self._resource,
                f"{self.port}:{self._remote_port}",
                "--address=127.0.0.1",
            ],
            stdin=subprocess.DEVNULL,
            stdout=self._log,
            stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                self._raise_failure("port-forward exited before becoming ready")
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                    return self
            except OSError:
                time.sleep(0.1)
        self._raise_failure("port-forward did not become ready")

    def __exit__(self, *_args: object) -> None:
        if self._process is not None and self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait(timeout=5)
        if self._log is not None:
            self._log.close()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def _raise_failure(self, message: str) -> None:
        details = ""
        if self._log is not None:
            self._log.seek(0)
            details = self._log.read().decode(errors="replace").strip()
        raise RuntimeError(f"{message}: {details}")

    def _free_port(self) -> int:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            return int(listener.getsockname()[1])


def request(
    method: str,
    url: str,
    *,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes]:
    value = Request(url, data=body, headers=headers or {}, method=method)
    try:
        with urlopen(value, timeout=20) as response:
            return response.status, dict(response.headers), response.read()
    except HTTPError as error:
        return error.code, dict(error.headers), error.read()


def assert_status(actual: int, expected: int | set[int], context: str) -> None:
    values = {expected} if isinstance(expected, int) else expected
    if actual not in values:
        raise AssertionError(f"{context}: expected {sorted(values)}, received {actual}")


def admin_headers(secret: bytes, method: str, path: str, body: bytes) -> dict[str, str]:
    timestamp = str(int(time.time()))
    request_id = str(uuid4())
    message = b"\n".join(
        [timestamp.encode(), request_id.encode(), method.encode(), path.encode(), body]
    )
    signature = hmac.new(secret, message, hashlib.sha256).hexdigest()
    return {
        "Content-Type": "application/json",
        "X-Lrail-Timestamp": timestamp,
        "X-Lrail-Request-Id": request_id,
        "X-Lrail-Signature": f"sha256={signature}",
    }


def register_credential(
    auth_url: str,
    admin_secret: bytes,
    organization: str,
) -> tuple[dict[str, object], str]:
    password = "lrp_" + base64.urlsafe_b64encode(os.urandom(36)).decode()
    body = json.dumps(
        {
            "credential_id": str(uuid4()),
            "username": "lr_" + uuid4().hex,
            "password": password,
            "repository_prefix": f"lrail/{organization}/",
            "actions": ["pull", "push"],
            "expires_at": int(time.time()) + 600,
        },
        separators=(",", ":"),
    ).encode()
    path = "/v1/credentials"
    status, _headers, response_body = request(
        "POST",
        auth_url + path,
        body=body,
        headers=admin_headers(admin_secret, "POST", path, body),
    )
    assert_status(status, 201, "credential registration")
    return json.loads(response_body), password


def issue_token(
    auth_url: str,
    credential: dict[str, object],
    password: str,
    repository: str,
) -> tuple[int, str | None]:
    basic = base64.b64encode(
        f"{credential['username']}:{password}".encode()
    ).decode()
    query = urlencode(
        {
            "service": "lrail-alpha-registry",
            "scope": f"repository:{repository}:pull,push",
        }
    )
    status, _headers, body = request(
        "GET",
        f"{auth_url}/token?{query}",
        headers={"Authorization": f"Basic {basic}"},
    )
    if status != 200:
        return status, None
    return status, str(json.loads(body)["token"])


def upload_blob(registry_url: str, repository: str, token: str, body: bytes) -> str:
    authorization = {"Authorization": f"Bearer {token}"}
    status, headers, _body = request(
        "POST",
        f"{registry_url}/v2/{repository}/blobs/uploads/",
        headers=authorization,
    )
    assert_status(status, 202, "blob upload start")
    location = headers.get("Location")
    if not location:
        raise AssertionError("blob upload did not return a location")
    parsed = urlsplit(location)
    target = registry_url + parsed.path
    query = parsed.query + ("&" if parsed.query else "")
    digest = "sha256:" + hashlib.sha256(body).hexdigest()
    target += "?" + query + urlencode({"digest": digest})
    status, _headers, _body = request(
        "PUT",
        target,
        body=body,
        headers=authorization | {"Content-Type": "application/octet-stream"},
    )
    assert_status(status, 201, "blob upload completion")
    return digest


def publish_manifest(registry_url: str, repository: str, token: str) -> tuple[str, bytes]:
    config = json.dumps(
        {
            "architecture": "amd64",
            "config": {},
            "os": "linux",
            "rootfs": {"diff_ids": [], "type": "layers"},
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    config_digest = upload_blob(registry_url, repository, token, config)
    manifest = json.dumps(
        {
            "config": {
                "digest": config_digest,
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "size": len(config),
            },
            "layers": [],
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "schemaVersion": 2,
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/vnd.oci.image.manifest.v1+json",
    }
    status, response_headers, _body = request(
        "PUT",
        f"{registry_url}/v2/{repository}/manifests/e2e",
        body=manifest,
        headers=headers,
    )
    assert_status(status, 201, "manifest publication")
    digest = response_headers.get("Docker-Content-Digest")
    expected = "sha256:" + hashlib.sha256(manifest).hexdigest()
    if digest != expected:
        raise AssertionError(f"registry digest mismatch: {digest!r} != {expected!r}")
    return expected, manifest


def pull_manifest(
    registry_url: str,
    repository: str,
    digest: str,
    token: str,
) -> tuple[int, bytes]:
    status, _headers, body = request(
        "GET",
        f"{registry_url}/v2/{repository}/manifests/{digest}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.oci.image.manifest.v1+json",
        },
    )
    return status, body


def kubectl_secret(kubectl: list[str], name: str, key: str) -> bytes:
    encoded = subprocess.check_output(
        [
            *kubectl,
            "get",
            "secret",
            name,
            "-n",
            "lrail-system",
            "-o",
            f"jsonpath={{.data.{key}}}",
        ]
    )
    return base64.b64decode(encoded)


def assert_secret_absent(kubectl: list[str], password: str) -> None:
    pod = subprocess.check_output(
        [
            *kubectl,
            "get",
            "pod",
            "-n",
            "lrail-system",
            "-l",
            "app.kubernetes.io/name=registry-auth",
            "-o",
            "jsonpath={.items[0].metadata.name}",
        ],
        text=True,
    ).strip()
    check = subprocess.run(
        [
            *kubectl,
            "exec",
            "-i",
            "-n",
            "lrail-system",
            pod,
            "--",
            "python",
            "-c",
            (
                "import pathlib,sys; value=sys.stdin.buffer.read(); "
                "data=pathlib.Path('/var/lib/lrail-registry-auth/registry-auth.sqlite3').read_bytes(); "
                "raise SystemExit(1 if value in data else 0)"
            ),
        ],
        input=password.encode(),
    )
    if check.returncode != 0:
        raise AssertionError("plaintext registry credential persisted in auth state")
    logs = subprocess.check_output(
        [
            *kubectl,
            "logs",
            "-n",
            "lrail-system",
            "-l",
            "app.kubernetes.io/part-of=lrail-alpha",
            "--all-containers=true",
            "--prefix=true",
        ],
        text=True,
        errors="replace",
    )
    encoded = base64.b64encode(password.encode()).decode()
    if password in logs or encoded in logs or "Authorization:" in logs:
        raise AssertionError("registry credential or authorization header appeared in logs")


def revoke(
    auth_url: str,
    admin_secret: bytes,
    credential: dict[str, object],
) -> None:
    path = f"/v1/credentials/{credential['credential_id']}"
    status, _headers, _body = request(
        "DELETE",
        auth_url + path,
        headers=admin_headers(admin_secret, "DELETE", path, b""),
    )
    assert_status(status, 200, "credential revocation")


def rollout_registry(kubectl: list[str]) -> None:
    subprocess.run(
        [
            *kubectl,
            "rollout",
            "restart",
            "deployment/registry",
            "-n",
            "lrail-system",
        ],
        check=True,
    )
    subprocess.run(
        [
            *kubectl,
            "rollout",
            "status",
            "deployment/registry",
            "-n",
            "lrail-system",
            "--timeout=180s",
        ],
        check=True,
    )


def run(profile: str) -> None:
    kubectl = ["kubectl", "--context", profile]
    admin_secret = kubectl_secret(
        kubectl, "lrail-registry-auth-admin", "admin-secret"
    )
    organization_a = "organization-a-" + uuid4().hex[:8]
    organization_b = "organization-b-" + uuid4().hex[:8]
    repository = f"lrail/{organization_a}/sample-web"

    with ExitStack() as stack:
        auth = stack.enter_context(
            Forward(kubectl=kubectl, resource="service/registry-auth", remote_port=8080)
        )
        registry = stack.enter_context(
            Forward(kubectl=kubectl, resource="service/registry", remote_port=5000)
        )
        credential_a, password_a = register_credential(
            auth.url, admin_secret, organization_a
        )
        credential_b, password_b = register_credential(
            auth.url, admin_secret, organization_b
        )

        status, token_a = issue_token(
            auth.url, credential_a, password_a, repository
        )
        assert_status(status, 200, "tenant token issuance")
        if token_a is None:
            raise AssertionError("tenant token was absent")
        digest, manifest = publish_manifest(registry.url, repository, token_a)
        status, pulled = pull_manifest(
            registry.url, repository, digest, token_a
        )
        assert_status(status, 200, "manifest pull by digest")
        if pulled != manifest:
            raise AssertionError("pulled manifest bytes changed")

        status, token_b = issue_token(
            auth.url, credential_b, password_b, repository
        )
        assert_status(status, 403, "cross-tenant token denial")
        if token_b is not None:
            raise AssertionError("cross-tenant token was issued")

        own_b_repository = f"lrail/{organization_b}/sample-web"
        status, token_b = issue_token(
            auth.url, credential_b, password_b, own_b_repository
        )
        assert_status(status, 200, "second tenant token issuance")
        if token_b is None:
            raise AssertionError("second tenant token was absent")
        status, _body = pull_manifest(
            registry.url, repository, digest, token_b
        )
        assert_status(status, {401, 403}, "cross-tenant manifest denial")
        status, _headers, _body = request(
            "GET",
            f"{registry.url}/v2/{repository}/tags/list",
            headers={"Authorization": f"Bearer {token_b}"},
        )
        assert_status(status, {401, 403}, "cross-tenant repository listing denial")
        status, _headers, _body = request(
            "GET",
            f"{registry.url}/v2/_catalog",
            headers={"Authorization": f"Bearer {token_b}"},
        )
        assert_status(status, {401, 403}, "registry catalog denial")

        assert_secret_absent(kubectl, password_a)
        revoke(auth.url, admin_secret, credential_a)
        status, _token = issue_token(
            auth.url, credential_a, password_a, repository
        )
        assert_status(status, 401, "revoked credential denial")

    rollout_registry(kubectl)

    with ExitStack() as stack:
        auth = stack.enter_context(
            Forward(kubectl=kubectl, resource="service/registry-auth", remote_port=8080)
        )
        registry = stack.enter_context(
            Forward(kubectl=kubectl, resource="service/registry", remote_port=5000)
        )
        status, token_b = issue_token(
            auth.url, credential_b, password_b, f"lrail/{organization_b}/sample-web"
        )
        assert_status(status, 200, "credential persistence after restart")
        status, token_a = issue_token(
            auth.url, credential_a, password_a, repository
        )
        assert_status(status, 401, "revocation persistence after restart")
        if token_a is not None:
            raise AssertionError("revoked token was issued after restart")

        credential_pull, password_pull = register_credential(
            auth.url, admin_secret, organization_a
        )
        status, token_pull = issue_token(
            auth.url, credential_pull, password_pull, repository
        )
        assert_status(status, 200, "post-restart pull token issuance")
        if token_pull is None:
            raise AssertionError("post-restart pull token was absent")
        status, pulled = pull_manifest(
            registry.url, repository, digest, token_pull
        )
        assert_status(status, 200, "persistent manifest pull")
        if pulled != manifest:
            raise AssertionError("persistent manifest bytes changed")

    print(f"OCI manifest persisted and pulled by digest {digest}")
    print("Cross-tenant list, pull, and overwrite scopes were denied")
    print("Credential revocation, state persistence, and log redaction passed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", default="lrail-alpha")
    args = parser.parse_args()
    try:
        run(args.profile)
    except (AssertionError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"artifact E2E failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
