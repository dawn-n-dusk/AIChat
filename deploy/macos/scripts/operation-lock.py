#!/usr/bin/env python3
"""Run one macOS package operation while holding its process-scoped file lock."""

from __future__ import annotations

import argparse
import fcntl
import os
import stat
import subprocess
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"aichat macOS operation lock: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_owned_directory(path: Path) -> None:
    try:
        details = path.lstat()
    except OSError:
        fail(f"lock parent is unavailable: {path}")
    if not stat.S_ISDIR(details.st_mode) or stat.S_ISLNK(details.st_mode):
        fail(f"lock parent must be a real directory: {path}")
    if details.st_uid != os.getuid():
        fail(f"lock parent is not owned by the current user: {path}")


def ensure_parent(home: Path, parent: Path, create: bool) -> None:
    if not home.is_absolute() or not parent.is_absolute():
        fail("HOME and lock parent must be absolute")
    try:
        relative = parent.relative_to(home)
    except ValueError:
        fail("lock parent must be inside HOME")
    require_owned_directory(home)
    cursor = home
    for component in relative.parts:
        cursor = cursor / component
        if not cursor.exists() and not cursor.is_symlink():
            if not create:
                fail("operation lock is not initialized")
            try:
                cursor.mkdir(mode=0o700)
            except FileExistsError:
                pass
        require_owned_directory(cursor)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True)
    parser.add_argument("--lock-path", required=True)
    parser.add_argument("--shared", action="store_true")
    parser.add_argument("--exclusive", action="store_true")
    parser.add_argument("--create", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.shared == args.exclusive:
        fail("choose exactly one lock mode")
    if not args.command:
        fail("a command is required")

    home = Path(args.home)
    lock_path = Path(args.lock_path)
    if lock_path.name != ".codex-connector-operation.lock":
        fail("unexpected operation lock filename")
    ensure_parent(home, lock_path.parent, args.create)
    flags = os.O_RDWR
    if args.create:
        flags |= os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError:
        fail("operation lock is unavailable")
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid():
            fail("operation lock must be a current-user regular file")
        if details.st_nlink != 1 or stat.S_IMODE(details.st_mode) != 0o600:
            fail("operation lock must have one link and mode 0600")
        latest = lock_path.lstat()
        if (details.st_dev, details.st_ino) != (latest.st_dev, latest.st_ino):
            fail("operation lock path changed while opening")
        mode = fcntl.LOCK_SH if args.shared else fcntl.LOCK_EX
        try:
            fcntl.flock(descriptor, mode | fcntl.LOCK_NB)
        except BlockingIOError:
            fail("another macOS connector install, stage, check, or removal operation is active")
        os.set_inheritable(descriptor, True)
        environment = dict(os.environ)
        environment["AICHAT_MACOS_OPERATION_LOCK_FD"] = str(descriptor)
        environment["AICHAT_MACOS_OPERATION_LOCK_MODE"] = (
            "shared" if args.shared else "exclusive"
        )
        completed = subprocess.run(
            args.command,
            env=environment,
            pass_fds=(descriptor,),
            check=False,
        )
        return completed.returncode
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    raise SystemExit(main())
