#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import sys


def bundle_path(arguments: list[str]) -> Path | None:
    for index, value in enumerate(arguments):
        if value == "--bundle" and index + 1 < len(arguments):
            return Path(arguments[index + 1])
        if value.startswith("--bundle="):
            return Path(value.split("=", 1)[1])
    return None


def runtime_arguments(arguments: list[str]) -> list[str]:
    values = arguments.copy()
    for index, value in enumerate(values):
        if value == "--root" and index + 1 < len(values):
            values[index + 1] = "/state/runc"
            return values
        if value.startswith("--root="):
            values[index] = "--root=/state/runc"
            return values
    return ["--root", "/state/runc", *values]


def main() -> None:
    arguments = sys.argv[1:]
    if "run" in arguments:
        bundle = bundle_path(arguments)
        if bundle is None:
            raise SystemExit("runc bundle is missing")
        config_path = bundle / "config.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        process = config.get("process")
        if not isinstance(process, dict):
            raise SystemExit("runc process is missing")
        process["capabilities"] = {
            "bounding": [],
            "effective": [],
            "inheritable": [],
            "permitted": [],
            "ambient": [],
        }
        temporary = config_path.with_name("config.json.tmp")
        temporary.write_text(
            json.dumps(config, separators=(",", ":")), encoding="utf-8"
        )
        os.replace(temporary, config_path)
    os.execv(
        "/usr/bin/buildkit-runc",
        ["buildkit-runc", *runtime_arguments(arguments)],
    )


if __name__ == "__main__":
    main()
