from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519

from .store import Operation


class ProvenanceSigner:
    def __init__(self, key_path: Path):
        key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
        if not isinstance(key, ed25519.Ed25519PrivateKey):
            raise ValueError("build signing key must be Ed25519")
        self._key = key
        public = key.public_key().public_bytes(
            serialization.Encoding.Raw,
            serialization.PublicFormat.Raw,
        )
        self._key_id = "sha256:" + hashlib.sha256(public).hexdigest()

    def sign(
        self,
        operation: Operation,
        *,
        plan_type: str,
        artifact_kind: str,
        artifact_digest: str,
        evidence: dict[str, Any],
    ) -> dict[str, Any]:
        statement = {
            "_type": "https://in-toto.io/Statement/v1",
            "subject": [
                {
                    "name": f"{operation.repository}@{artifact_digest}",
                    "digest": {"sha256": artifact_digest.removeprefix("sha256:")},
                }
            ],
            "predicateType": "https://slsa.dev/provenance/v1",
            "predicate": {
                "buildDefinition": {
                    "buildType": "https://layerrail.com/build/v1",
                    "externalParameters": {
                        "source_commit": operation.source_commit,
                        "source_root": operation.source_root,
                        "plan_type": plan_type,
                        "artifact_kind": artifact_kind,
                    },
                    "internalParameters": {
                        "runtime_class": "gvisor",
                        "builder": "lrail-buildkit-v0.26.2-capless-runc-v1",
                    },
                    "resolvedDependencies": [
                        {
                            "uri": "git+redacted",
                            "digest": {"sha256": operation.descriptor_digest.removeprefix("sha256:")},
                        }
                    ],
                },
                "runDetails": {
                    "builder": {"id": self._key_id},
                    "metadata": {
                        "invocationId": operation.operation_id,
                        "startedOn": datetime.fromtimestamp(
                            operation.created_at, timezone.utc
                        ).isoformat(timespec="seconds").replace("+00:00", "Z"),
                        "finishedOn": datetime.fromtimestamp(
                            int(operation.result["result_received_at"]), timezone.utc
                        ).isoformat(timespec="seconds").replace("+00:00", "Z"),
                    },
                    "byproducts": evidence,
                },
            },
        }
        body = json.dumps(statement, separators=(",", ":"), sort_keys=True).encode()
        return {
            "statement": statement,
            "signature": {
                "algorithm": "Ed25519",
                "key_id": self._key_id,
                "value": base64.b64encode(self._key.sign(body)).decode(),
            },
        }
