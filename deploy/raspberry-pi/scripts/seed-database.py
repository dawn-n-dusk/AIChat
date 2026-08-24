#!/usr/bin/env python3
"""Verify and atomically seed a Relay database from a plain or gzip snapshot."""

from __future__ import annotations

import argparse
import gzip
import os
import shutil
import sqlite3
import tempfile
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    return parser.parse_args()


def quick_check(path: Path) -> None:
    connection = sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro", uri=True)
    try:
        result = connection.execute("PRAGMA quick_check").fetchone()
    finally:
        connection.close()
    if result is None or result[0] != "ok":
        raise SystemExit(f"SQLite quick_check failed for {path}: {result!r}")


def materialize_source(source: Path, directory: Path) -> tuple[Path, bool]:
    if source.suffix != ".gz":
        return source, False
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".aichat-seed-source-", suffix=".sqlite3", dir=directory
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    with gzip.open(source, "rb") as source_handle, temporary.open("wb") as target_handle:
        shutil.copyfileobj(source_handle, target_handle, length=1024 * 1024)
    os.chmod(temporary, 0o600)
    return temporary, True


def main() -> int:
    args = parse_args()
    source = args.source.resolve()
    destination = args.destination.resolve()
    if not source.is_file():
        raise SystemExit(f"seed database does not exist: {source}")
    if destination.exists():
        raise SystemExit(f"refusing to replace existing database: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)

    materialized, remove_materialized = materialize_source(source, destination.parent)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".aichat-seed-destination-", suffix=".sqlite3", dir=destination.parent
    )
    os.close(descriptor)
    temporary_destination = Path(temporary_name)
    try:
        quick_check(materialized)
        source_connection = sqlite3.connect(
            f"{materialized.resolve().as_uri()}?mode=ro", uri=True, timeout=30
        )
        target_connection = sqlite3.connect(temporary_destination)
        try:
            source_connection.backup(target_connection, pages=256, sleep=0.05)
            target_connection.commit()
        finally:
            target_connection.close()
            source_connection.close()
        quick_check(temporary_destination)
        os.chmod(temporary_destination, 0o600)
        os.replace(temporary_destination, destination)
        print(f"AIChat seed database installed: {destination}")
        return 0
    finally:
        temporary_destination.unlink(missing_ok=True)
        if remove_materialized:
            materialized.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
