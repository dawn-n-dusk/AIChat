#!/usr/bin/env python3
"""Render the token-free LaunchAgent plist."""

from __future__ import annotations

import argparse
import os
import plistlib
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--python", required=True)
    parser.add_argument("--launcher", required=True)
    parser.add_argument("--settings", required=True)
    parser.add_argument("--connector", required=True)
    parser.add_argument("--node", required=True)
    parser.add_argument("--stdout", required=True)
    parser.add_argument("--stderr", required=True)
    args = parser.parse_args()

    payload = {
        "Label": args.label,
        "ProgramArguments": [
            args.python,
            args.launcher,
            "--settings",
            args.settings,
            "--connector",
            args.connector,
            "--node",
            args.node,
        ],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ProcessType": "Background",
        "ThrottleInterval": 15,
        "StandardOutPath": args.stdout,
        "StandardErrorPath": args.stderr,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    with temporary.open("wb") as handle:
        plistlib.dump(payload, handle, sort_keys=True)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
