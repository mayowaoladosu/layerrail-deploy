from __future__ import annotations

import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
from io import BytesIO
import json
from pathlib import Path
import subprocess
import sys
import tarfile
from uuid import uuid4


SERVICES_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SERVICES_ROOT))

from phase2_test_support import (
    Forward,
    admin_headers,
    assert_status,
    kubectl_secret,
    request,
)


def digest(body: bytes) -> str:
    return "sha256:" + hashlib.sha256(body).hexdigest()


def archive(
    files: dict[str, bytes],
    *,
    symlink: tuple[str, str] | None = None,
) -> bytes:
    target = BytesIO()
    with tarfile.open(fileobj=target, mode="w") as value:
        directories = sorted(
            {
                str(Path(path).parent).replace("\\", "/")
                for path in files
                if str(Path(path).parent) != "."
            }
        )
        for directory in directories:
            item = tarfile.TarInfo(directory + "/")
            item.type = tarfile.DIRTYPE
            item.mtime = 0
            value.addfile(item)
        for path, body in sorted(files.items()):
            item = tarfile.TarInfo(path)
            item.size = len(body)
            item.mtime = 0
            value.addfile(item, BytesIO(body))
        if symlink is not None:
            item = tarfile.TarInfo(symlink[0])
            item.type = tarfile.SYMTYPE
            item.linkname = symlink[1]
            item.mtime = 0
            value.addfile(item)
    return target.getvalue()


def publish(
    gateway_url: str,
    secret: bytes,
    organization_id: str,
    revision_id: str,
    body: bytes,
) -> tuple[int, dict[str, object]]:
    path = f"/v1/static/{organization_id}/{revision_id}"
    headers = admin_headers(
        secret,
        "PUT",
        path,
        body,
        content_type="application/x-tar",
    ) | {"X-Lrail-Artifact-Digest": digest(body)}
    status, _headers, response_body = request(
        "PUT", gateway_url + path, body=body, headers=headers
    )
    return status, json.loads(response_body)


def put_evidence(
    gateway_url: str,
    secret: bytes,
    organization_id: str,
    build_id: str,
    name: str,
    body: bytes,
) -> int:
    path = f"/v1/evidence/{organization_id}/{build_id}/{name}"
    headers = admin_headers(
        secret,
        "PUT",
        path,
        body,
        content_type="application/json",
    ) | {"X-Lrail-Artifact-Digest": digest(body)}
    status, _headers, _response_body = request(
        "PUT", gateway_url + path, body=body, headers=headers
    )
    return status


def reconcile(
    gateway_url: str,
    secret: bytes,
    payload: dict[str, object],
) -> tuple[int, dict[str, object]]:
    body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    path = "/v1/retention/reconcile"
    status, _headers, response_body = request(
        "POST",
        gateway_url + path,
        body=body,
        headers=admin_headers(secret, "POST", path, body),
    )
    return status, json.loads(response_body)


def rollout(kubectl: list[str], deployment: str) -> None:
    subprocess.run(
        [
            *kubectl,
            "rollout",
            "restart",
            f"deployment/{deployment}",
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
            f"deployment/{deployment}",
            "-n",
            "lrail-system",
            "--timeout=240s",
        ],
        check=True,
    )


def assert_logs_redacted(kubectl: list[str], admin_secret: bytes) -> None:
    logs = subprocess.check_output(
        [
            *kubectl,
            "logs",
            "-n",
            "lrail-system",
            "-l",
            "app.kubernetes.io/name=artifact-gateway",
            "--all-containers=true",
            "--prefix=true",
        ],
        text=True,
        errors="replace",
    )
    if admin_secret.decode() in logs or "X-Lrail-Signature" in logs:
        raise AssertionError("artifact authorization material appeared in logs")


def run(profile: str) -> None:
    kubectl = ["kubectl", "--context", profile]
    secret = kubectl_secret(
        kubectl, "lrail-artifact-gateway-admin", "admin-secret"
    )
    organization_id = str(uuid4())
    current_revision = str(uuid4())
    previous_revision = str(uuid4())
    failed_revision = str(uuid4())
    build_id = str(uuid4())
    website = archive(
        {
            "index.html": b"<!doctype html><h1>LayerRail alpha</h1>",
            "assets/app.1234abcd.js": b"document.body.dataset.ready='true'",
        }
    )

    with ExitStack() as stack:
        gateway = stack.enter_context(
            Forward(
                kubectl=kubectl,
                resource="service/artifact-gateway",
                remote_port=8080,
            )
        )
        for revision_id in (current_revision, previous_revision, failed_revision):
            status, manifest = publish(
                gateway.url,
                secret,
                organization_id,
                revision_id,
                website,
            )
            assert_status(status, 201, "static publication")
            if manifest["archive"]["digest"] != digest(website):
                raise AssertionError("static manifest archive digest changed")

        status, _manifest = publish(
            gateway.url,
            secret,
            organization_id,
            current_revision,
            website,
        )
        assert_status(status, 200, "idempotent static publication")

        changed = archive({"index.html": b"changed"})
        status, _body = publish(
            gateway.url,
            secret,
            organization_id,
            current_revision,
            changed,
        )
        assert_status(status, 409, "immutable revision conflict")

        traversal = archive({"../index.html": b"escape"})
        status, _body = publish(
            gateway.url,
            secret,
            organization_id,
            str(uuid4()),
            traversal,
        )
        assert_status(status, 422, "traversal rejection")
        linked = archive(
            {"index.html": b"safe"}, symlink=("assets/escape", "../../secret")
        )
        status, _body = publish(
            gateway.url,
            secret,
            organization_id,
            str(uuid4()),
            linked,
        )
        assert_status(status, 422, "symlink rejection")

        evidence = json.dumps(
            {
                "artifact_digest": digest(website),
                "critical_findings": 0,
                "status": "passed",
            },
            separators=(",", ":"),
        ).encode()
        assert_status(
            put_evidence(
                gateway.url,
                secret,
                organization_id,
                build_id,
                "scan.json",
                evidence,
            ),
            201,
            "evidence publication",
        )
        assert_status(
            put_evidence(
                gateway.url,
                secret,
                organization_id,
                build_id,
                "scan.json",
                evidence,
            ),
            200,
            "idempotent evidence publication",
        )
        evidence_path = f"/v1/evidence/{organization_id}/{build_id}/scan.json"
        status, evidence_headers, stored_evidence = request(
            "GET",
            gateway.url + evidence_path,
            headers=admin_headers(secret, "GET", evidence_path, b""),
        )
        assert_status(status, 200, "evidence read")
        if stored_evidence != evidence or evidence_headers.get("Cache-Control") != "private, no-store":
            raise AssertionError("stored evidence response changed")
        conflicting_evidence = b'{"status":"failed"}'
        assert_status(
            put_evidence(
                gateway.url,
                secret,
                organization_id,
                build_id,
                "scan.json",
                conflicting_evidence,
            ),
            409,
            "immutable evidence conflict",
        )

        reconciliation_id = str(uuid4())
        retention = {
            "reconciliation_id": reconciliation_id,
            "organization_id": organization_id,
            "retain_revision_ids": [current_revision, previous_revision],
            "delete_candidate_revision_ids": [failed_revision],
            "delete_before": datetime.now(timezone.utc).isoformat().replace(
                "+00:00", "Z"
            ),
        }
        status, result = reconcile(gateway.url, secret, retention)
        assert_status(status, 201, "retention reconciliation")
        if result["deleted_revision_ids"] != [failed_revision]:
            raise AssertionError("failed unreferenced revision was not deleted")
        status, repeated = reconcile(gateway.url, secret, retention)
        assert_status(status, 200, "idempotent retention reconciliation")
        if repeated != result:
            raise AssertionError("retention replay changed its evidence")
        status, _conflict = reconcile(
            gateway.url,
            secret,
            retention | {"delete_candidate_revision_ids": []},
        )
        assert_status(status, 409, "retention reconciliation conflict")

        for revision_id in (current_revision, previous_revision):
            status, _headers, body = request(
                "GET",
                f"{gateway.url}/v1/static/{organization_id}/{revision_id}/files/index.html",
            )
            assert_status(status, 200, "retained alias artifact read")
            if body != b"<!doctype html><h1>LayerRail alpha</h1>":
                raise AssertionError("retained static file changed")
        status, _headers, _body = request(
            "GET",
            f"{gateway.url}/v1/static/{organization_id}/{failed_revision}/manifest",
        )
        assert_status(status, 404, "expired revision deletion")
        assert_logs_redacted(kubectl, secret)

    rollout(kubectl, "minio")
    rollout(kubectl, "artifact-gateway")

    with Forward(
        kubectl=kubectl,
        resource="service/artifact-gateway",
        remote_port=8080,
    ) as gateway:
        status, _headers, body = request(
            "GET",
            f"{gateway.url}/v1/static/{organization_id}/{current_revision}/files/index.html",
        )
        assert_status(status, 200, "static persistence after storage restart")
        if body != b"<!doctype html><h1>LayerRail alpha</h1>":
            raise AssertionError("static artifact changed after restart")

    print("Static traversal, symlink, digest, size, and immutability policies passed")
    print("Current and previous Alias artifacts survived idempotent retention")
    print("Failed unreferenced artifacts expired and evidence persisted")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", default="lrail-alpha")
    args = parser.parse_args()
    try:
        run(args.profile)
    except (AssertionError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"artifact gateway E2E failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
