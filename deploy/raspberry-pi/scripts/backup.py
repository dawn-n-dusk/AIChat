#!/usr/bin/env python3
"""Create an atomic, integrity-checked SQLite backup without copying WAL files."""

from __future__ import annotations

import argparse
import fcntl
import gzip
import hashlib
import os
import sqlite3
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--retention-days", required=True, type=int)
    return parser.parse_args()


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def sqlite_backup(source_path: Path, target_path: Path) -> None:
    # Open the live database normally. The backup service runs as the database
    # owner, and SQLite may need write access to the WAL shared-memory file even
    # though this process never mutates application rows. URI mode=ro is not
    # reliable for active WAL databases across the deployed Python/SQLite builds.
    source = sqlite3.connect(source_path, timeout=30)
    destination = sqlite3.connect(target_path)
    try:
        source.backup(destination, pages=256, sleep=0.05)
        result = destination.execute("PRAGMA quick_check").fetchone()
        if result is None or result[0] != "ok":
            raise RuntimeError(f"SQLite quick_check failed: {result!r}")
        destination.commit()
    finally:
        destination.close()
        source.close()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def remove_expired(output_dir: Path, retention_days: int, keep: Path) -> int:
    cutoff = time.time() - retention_days * 86400
    removed = 0
    for candidate in output_dir.glob("relay-*.sqlite3.gz"):
        if candidate == keep or candidate.stat().st_mtime >= cutoff:
            continue
        candidate.unlink()
        candidate.with_suffix(candidate.suffix + ".sha256").unlink(missing_ok=True)
        removed += 1
    return removed


def main() -> int:
    args = parse_args()
    if args.retention_days < 0:
        raise SystemExit("retention days must be non-negative")
    source = args.database.resolve()
    output_dir = args.output_dir.resolve()
    if not source.is_file():
        raise SystemExit(f"SQLite database does not exist: {source}")
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(output_dir, 0o700)

    lock_path = output_dir / ".backup.lock"
    with lock_path.open("a+b") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("AIChat backup already running; exiting without overlap")
            return 0

        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        final_path = output_dir / f"relay-{stamp}.sqlite3.gz"
        if final_path.exists():
            final_path = output_dir / f"relay-{stamp}-{os.getpid()}.sqlite3.gz"

        temporary_db: Path | None = None
        temporary_gzip: Path | None = None
        try:
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=".relay-backup-", suffix=".sqlite3", dir=output_dir
            )
            os.close(descriptor)
            temporary_db = Path(temporary_name)
            os.chmod(temporary_db, 0o600)
            sqlite_backup(source, temporary_db)

            descriptor, temporary_name = tempfile.mkstemp(
                prefix=".relay-backup-", suffix=".sqlite3.gz", dir=output_dir
            )
            os.close(descriptor)
            temporary_gzip = Path(temporary_name)
            with temporary_db.open("rb") as source_handle, temporary_gzip.open("wb") as raw_target:
                with gzip.GzipFile(
                    filename="", mode="wb", compresslevel=9, fileobj=raw_target, mtime=0
                ) as target_handle:
                    for chunk in iter(lambda: source_handle.read(1024 * 1024), b""):
                        target_handle.write(chunk)
            os.chmod(temporary_gzip, 0o600)
            os.replace(temporary_gzip, final_path)
            temporary_gzip = None

            checksum_path = final_path.with_suffix(final_path.suffix + ".sha256")
            checksum_temporary = checksum_path.with_suffix(checksum_path.suffix + ".tmp")
            checksum_temporary.write_text(
                f"{sha256(final_path)}  {final_path.name}\n", encoding="ascii"
            )
            os.chmod(checksum_temporary, 0o600)
            os.replace(checksum_temporary, checksum_path)
            fsync_directory(output_dir)
            removed = remove_expired(output_dir, args.retention_days, final_path)
            print(f"AIChat backup complete: {final_path}; expired_removed={removed}")
            return 0
        finally:
            if temporary_db is not None:
                temporary_db.unlink(missing_ok=True)
            if temporary_gzip is not None:
                temporary_gzip.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
