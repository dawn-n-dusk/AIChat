#!/usr/bin/env python3
"""Atomically install or remove the managed AIChat route in an existing Caddyfile."""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import tempfile
from datetime import datetime, timezone
from pathlib import Path


BEGIN = "# BEGIN AICHAT RELAY (managed by AIChat deploy package)"
END = "# END AICHAT RELAY (managed by AIChat deploy package)"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--mode", required=True, choices=("install", "remove"))
    parser.add_argument("--route", type=Path)
    parser.add_argument("--fallback")
    return parser.parse_args()


def managed_range(lines: list[str]) -> tuple[int, int] | None:
    starts = [index for index, line in enumerate(lines) if line.strip() == BEGIN]
    ends = [index for index, line in enumerate(lines) if line.strip() == END]
    if not starts and not ends:
        return None
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise SystemExit("Caddyfile contains malformed or duplicate AIChat managed markers")
    return starts[0], ends[0] + 1


def indent_route(route: str, indentation: str) -> list[str]:
    return [f"{indentation}{line}" if line else "" for line in route.splitlines()]


def build_content(args: argparse.Namespace, original: str) -> str:
    lines = original.splitlines()
    existing = managed_range(lines)
    if args.mode == "remove":
        if existing is None:
            return original if original.endswith("\n") else f"{original}\n"
        start, end = existing
        while end < len(lines) and not lines[end].strip():
            end += 1
        return "\n".join(lines[:start] + lines[end:]).rstrip() + "\n"

    if args.route is None or args.fallback is None:
        raise SystemExit("install mode requires --route and --fallback")
    route = args.route.read_text(encoding="utf-8").strip()
    if BEGIN not in route or END not in route:
        raise SystemExit("rendered route is missing managed markers")

    if existing is not None:
        start, end = existing
        indentation = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
        replacement = indent_route(route, indentation)
        return "\n".join(lines[:start] + replacement + lines[end:]).rstrip() + "\n"

    matches = [index for index, line in enumerate(lines) if line.strip() == args.fallback]
    if len(matches) != 1:
        raise SystemExit(
            f"expected exactly one Caddy fallback line {args.fallback!r}; found {len(matches)}"
        )
    index = matches[0]
    indentation = lines[index][: len(lines[index]) - len(lines[index].lstrip())]
    insertion = indent_route(route, indentation) + [""]
    return "\n".join(lines[:index] + insertion + lines[index:]).rstrip() + "\n"


def main() -> int:
    args = parse_args()
    config = args.config
    if not config.is_file() or config.is_symlink():
        raise SystemExit("Caddy config must be an existing regular file, not a symlink")
    original = config.read_text(encoding="utf-8")
    updated = build_content(args, original)
    if updated == original:
        print("UNCHANGED")
        return 0

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = config.with_name(f"{config.name}.aichat-backup-{stamp}")
    suffix = 1
    while backup.exists():
        backup = config.with_name(f"{config.name}.aichat-backup-{stamp}-{suffix}")
        suffix += 1
    shutil.copy2(config, backup)

    details = config.stat()
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{config.name}.", dir=config.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(updated)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, stat.S_IMODE(details.st_mode))
        os.chown(temporary, details.st_uid, details.st_gid)
        os.replace(temporary, config)
    finally:
        temporary.unlink(missing_ok=True)
    print(backup)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
