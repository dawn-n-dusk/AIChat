#!/usr/bin/env python3
"""Atomically manage AIChat routing and default-logger redaction in Caddy."""

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
GLOBAL_BEGIN = "# BEGIN AICHAT ERROR LOGGER REDACTION (managed by AIChat deploy package)"
GLOBAL_END = "# END AICHAT ERROR LOGGER REDACTION (managed by AIChat deploy package)"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--mode", required=True, choices=("install", "remove", "restore"))
    parser.add_argument("--route", type=Path)
    parser.add_argument("--global-options", type=Path)
    parser.add_argument("--fallback")
    parser.add_argument("--source", type=Path)
    return parser.parse_args()


def managed_range(lines: list[str], begin: str, end: str) -> tuple[int, int] | None:
    starts = [index for index, line in enumerate(lines) if line.strip() == begin]
    ends = [index for index, line in enumerate(lines) if line.strip() == end]
    if not starts and not ends:
        return None
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise SystemExit("Caddyfile contains malformed or duplicate AIChat managed markers")
    return starts[0], ends[0] + 1


def indent_block(content: str, indentation: str) -> list[str]:
    return [f"{indentation}{line}" if line else "" for line in content.splitlines()]


def remove_managed_block(original: str, begin: str, end: str) -> str:
    lines = original.splitlines()
    existing = managed_range(lines, begin, end)
    if existing is None:
        return original if original.endswith("\n") else f"{original}\n"
    start, finish = existing
    while finish < len(lines) and not lines[finish].strip():
        finish += 1
    return "\n".join(lines[:start] + lines[finish:]).rstrip() + "\n"


def brace_delta(line: str) -> int:
    delta = 0
    quote = ""
    escaped = False
    for character in line:
        if escaped:
            escaped = False
            continue
        if quote and character == "\\":
            escaped = True
            continue
        if character in ('"', "'"):
            if quote == character:
                quote = ""
            elif not quote:
                quote = character
            continue
        if not quote and character == "#":
            break
        if not quote and character == "{":
            delta += 1
        elif not quote and character == "}":
            delta -= 1
    return delta


def global_options_close(lines: list[str]) -> int | None:
    first = next(
        (index for index, line in enumerate(lines) if line.strip() and not line.lstrip().startswith("#")),
        None,
    )
    if first is None or lines[first].strip() != "{":
        return None
    depth = 0
    for index in range(first, len(lines)):
        depth += brace_delta(lines[index])
        if index > first and depth == 0:
            return index
        if depth < 0:
            break
    raise SystemExit("Caddyfile global options block is malformed")


def install_global_options(original: str, source: Path) -> str:
    content = source.read_text(encoding="utf-8").strip()
    if GLOBAL_BEGIN not in content or GLOBAL_END not in content:
        raise SystemExit("rendered global options are missing managed markers")
    lines = original.splitlines()
    existing = managed_range(lines, GLOBAL_BEGIN, GLOBAL_END)
    if existing is not None:
        start, finish = existing
        indentation = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
        replacement = indent_block(content, indentation)
        return "\n".join(lines[:start] + replacement + lines[finish:]).rstrip() + "\n"

    close = global_options_close(lines)
    if close is None:
        insertion = ["{"] + indent_block(content, "    ") + ["}", ""]
        return "\n".join(insertion + lines).rstrip() + "\n"
    closing_indent = lines[close][: len(lines[close]) - len(lines[close].lstrip())]
    insertion = indent_block(content, f"{closing_indent}    ") + [""]
    return "\n".join(lines[:close] + insertion + lines[close:]).rstrip() + "\n"


def install_route(original: str, route_path: Path, fallback: str) -> str:
    lines = original.splitlines()
    existing = managed_range(lines, BEGIN, END)
    route = route_path.read_text(encoding="utf-8").strip()
    if BEGIN not in route or END not in route:
        raise SystemExit("rendered route is missing managed markers")
    if existing is not None:
        start, finish = existing
        indentation = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
        replacement = indent_block(route, indentation)
        return "\n".join(lines[:start] + replacement + lines[finish:]).rstrip() + "\n"

    matches = [index for index, line in enumerate(lines) if line.strip() == fallback]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one Caddy fallback line {fallback!r}; found {len(matches)}")
    index = matches[0]
    indentation = lines[index][: len(lines[index]) - len(lines[index].lstrip())]
    insertion = indent_block(route, indentation) + [""]
    return "\n".join(lines[:index] + insertion + lines[index:]).rstrip() + "\n"


def build_content(args: argparse.Namespace, original: str) -> str:
    if args.mode == "restore":
        if args.source is None or not args.source.is_file() or args.source.is_symlink():
            raise SystemExit("restore mode requires a regular --source file")
        return args.source.read_text(encoding="utf-8")

    if args.mode == "remove":
        without_route = remove_managed_block(original, BEGIN, END)
        return remove_managed_block(without_route, GLOBAL_BEGIN, GLOBAL_END)

    if args.route is None or args.global_options is None or args.fallback is None:
        raise SystemExit("install mode requires --route, --global-options, and --fallback")
    with_global_options = install_global_options(original, args.global_options)
    return install_route(with_global_options, args.route, args.fallback)


def atomic_replace(config: Path, updated: str) -> None:
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


def main() -> int:
    args = parse_args()
    config = args.config
    if not config.is_file() or config.is_symlink():
        raise SystemExit("Caddy config must be an existing regular file, not a symlink")
    original = config.read_text(encoding="utf-8")
    updated = build_content(args, original)
    if updated == original:
        print("RESTORED" if args.mode == "restore" else "UNCHANGED")
        return 0


    if args.mode == "restore":
        atomic_replace(config, updated)
        print("RESTORED")
        return 0

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = config.with_name(f"{config.name}.aichat-backup-{stamp}")
    suffix = 1
    while backup.exists():
        backup = config.with_name(f"{config.name}.aichat-backup-{stamp}-{suffix}")
        suffix += 1
    shutil.copy2(config, backup)

    atomic_replace(config, updated)
    print(backup)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
