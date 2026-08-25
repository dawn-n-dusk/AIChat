#!/usr/bin/env python3
"""Build and inspect an inert macOS connector candidate without launchctl."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NoReturn


SCHEMA_VERSION = 1
EXPECTED_LABEL = "org.aichat.codex-connector"


class StageError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise StageError(message)


def owned_lstat(path: Path) -> os.stat_result:
    try:
        details = path.lstat()
    except OSError as exc:
        raise StageError(f"protected path is unavailable: {path}") from exc
    if details.st_uid != os.getuid():
        fail(f"protected path is not owned by the current user: {path}")
    return details


def require_directory(path: Path, *, exact_mode: int | None = None) -> None:
    details = owned_lstat(path)
    if not stat.S_ISDIR(details.st_mode) or stat.S_ISLNK(details.st_mode):
        fail(f"protected path must be a real directory: {path}")
    if exact_mode is not None and stat.S_IMODE(details.st_mode) != exact_mode:
        fail(f"protected directory permissions must be {exact_mode:04o}: {path}")


def ensure_directory(path: Path, *, exact_mode: int | None = None) -> None:
    if path.exists() or path.is_symlink():
        require_directory(path, exact_mode=exact_mode)
        return
    try:
        path.mkdir(mode=exact_mode or 0o700)
    except FileExistsError:
        pass
    require_directory(path, exact_mode=exact_mode)


def ensure_state_root(home: Path, state_root: Path) -> None:
    if not home.is_absolute() or not state_root.is_absolute():
        fail("HOME and state root must be absolute")
    try:
        relative = state_root.relative_to(home)
    except ValueError as exc:
        raise StageError("state root must be inside HOME") from exc
    require_directory(home)
    cursor = home
    for component in relative.parts:
        cursor = cursor / component
        ensure_directory(cursor, exact_mode=0o700 if cursor == state_root else None)


def require_operation_lock(home: Path, state_root: Path, *, exclusive: bool) -> None:
    expected_state_root = home / "Library" / "Application Support" / "AIChat" / "codex-connector-launchagent"
    if state_root != expected_state_root:
        fail("unexpected macOS connector state root")
    raw_descriptor = os.environ.get("AICHAT_MACOS_OPERATION_LOCK_FD", "")
    lock_mode = os.environ.get("AICHAT_MACOS_OPERATION_LOCK_MODE", "")
    if not raw_descriptor.isdigit():
        fail("the macOS connector operation lock is not held")
    if lock_mode not in {"shared", "exclusive"} or (exclusive and lock_mode != "exclusive"):
        fail("the macOS connector operation lock mode is insufficient")
    descriptor = int(raw_descriptor)
    try:
        details = os.fstat(descriptor)
    except OSError as exc:
        raise StageError("the macOS connector operation lock descriptor is invalid") from exc
    lock_path = state_root.parent / ".codex-connector-operation.lock"
    latest = owned_lstat(lock_path)
    if not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid():
        fail("the macOS connector operation lock is not a current-user regular file")
    if details.st_nlink != 1 or stat.S_IMODE(details.st_mode) != 0o600:
        fail("the macOS connector operation lock permissions are invalid")
    if (details.st_dev, details.st_ino) != (latest.st_dev, latest.st_ino):
        fail("the macOS connector operation lock path does not match the held descriptor")
    requested_mode = fcntl.LOCK_EX if lock_mode == "exclusive" else fcntl.LOCK_SH
    try:
        fcntl.flock(descriptor, requested_mode | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        raise StageError("the macOS connector operation lock is not held") from exc


def validate_publish_arguments(args: argparse.Namespace) -> None:
    if args.label != EXPECTED_LABEL:
        fail("unexpected LaunchAgent label")
    home = Path(args.home)
    expected_log_dir = home / "Library" / "Logs" / "AIChat"
    if Path(args.log_dir) != expected_log_dir:
        fail("unexpected staged log directory")
    for name in ("node", "npm", "python"):
        value = getattr(args, name)
        if not Path(value).is_absolute() or "\n" in value or "\r" in value:
            fail(f"{name} path must be an absolute single-line path")
        if not Path(value).exists() or not os.access(value, os.X_OK):
            fail(f"{name} path must name an executable")
    for name in ("connector_source", "script_dir", "settings"):
        if not Path(getattr(args, name)).is_absolute():
            fail(f"{name} path must be absolute")


def sanitized_environment() -> dict[str, str]:
    environment: dict[str, str] = {}
    forbidden_fragments = ("TOKEN", "SECRET", "AUTHORIZATION", "API_KEY", "PASSWORD")
    forbidden_prefixes = ("AICHAT_", "OPENAI_", "ANTHROPIC_", "XAI_")
    for name, value in os.environ.items():
        upper = name.upper()
        if upper.startswith(forbidden_prefixes) or any(part in upper for part in forbidden_fragments):
            continue
        environment[name] = value
    return environment


def require_private_file(path: Path, *, executable: bool = False) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise StageError(f"protected file is unavailable: {path}") from exc
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            fail(f"protected file must be regular: {path}")
        if before.st_uid != os.getuid():
            fail(f"protected file is not owned by the current user: {path}")
        if before.st_nlink != 1:
            fail(f"protected file must have exactly one hard link: {path}")
        if stat.S_IMODE(before.st_mode) & 0o077:
            fail(f"protected file permissions expose group or other users: {path}")
        if executable and not before.st_mode & stat.S_IXUSR:
            fail(f"protected launcher is not executable: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    latest = owned_lstat(path)
    identity_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    identity_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    identity_latest = (latest.st_dev, latest.st_ino, latest.st_size, latest.st_mtime_ns)
    if identity_before != identity_after or identity_after != identity_latest:
        fail(f"protected file changed while it was read: {path}")
    return b"".join(chunks)


def write_file(path: Path, payload: bytes, mode: int) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def connector_inputs(connector_source: Path) -> list[tuple[str, bytes]]:
    required = [connector_source / "package.json", connector_source / "package-lock.json"]
    source_root = connector_source / "src"
    require_directory(connector_source)
    require_directory(source_root)
    inputs: list[tuple[str, bytes]] = []
    for path in required:
        inputs.append((path.relative_to(connector_source).as_posix(), read_source_file(path)))
    for path in sorted(source_root.rglob("*")):
        details = owned_lstat(path)
        if stat.S_ISDIR(details.st_mode) and not stat.S_ISLNK(details.st_mode):
            continue
        if not stat.S_ISREG(details.st_mode) or stat.S_ISLNK(details.st_mode):
            fail(f"connector source contains an unsupported file type: {path}")
        inputs.append((path.relative_to(connector_source).as_posix(), read_source_file(path)))
    if not any(name == "src/cli.js" for name, _ in inputs):
        fail("connector source is missing src/cli.js")
    return inputs


def read_source_file(path: Path) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise StageError(f"connector source is unreadable: {path}") from exc
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            fail(f"connector source file must be regular: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    latest = path.lstat()
    identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns)
    if identity(before) != identity(after) or identity(after) != identity(latest):
        fail(f"connector source changed while it was read: {path}")
    return b"".join(chunks)


def fingerprint(
    inputs: list[tuple[str, bytes]],
    settings: bytes,
    launcher: bytes,
    *,
    label: str,
    node: str,
    python: str,
    log_dir: str,
    dependency_digest_value: str | None = None,
) -> str:
    digest = hashlib.sha256()
    digest.update(b"aichat-macos-staged-package-v1\0")
    values = [
        ("label", label.encode()),
        ("node", node.encode()),
        ("python", python.encode()),
        ("log_dir", log_dir.encode()),
        ("settings.json", settings),
        ("launcher.py", launcher),
        *inputs,
    ]
    if dependency_digest_value is not None:
        values.append(("node_modules", dependency_digest_value.encode("ascii")))
    for name, payload in values:
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def expected_plist(
    release: Path,
    *,
    label: str,
    node: str,
    python: str,
    log_dir: str,
) -> dict[str, object]:
    return {
        "Label": label,
        "ProgramArguments": [
            python,
            str(release / "launcher.py"),
            "--settings",
            str(release / "settings.json"),
            "--connector",
            str(release / "runtime" / "src" / "cli.js"),
            "--node",
            node,
        ],
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ProcessType": "Background",
        "ThrottleInterval": 15,
        "StandardOutPath": str(Path(log_dir) / "codex-connector.out.log"),
        "StandardErrorPath": str(Path(log_dir) / "codex-connector.err.log"),
    }


def protect_release_tree(root: Path) -> None:
    for directory, names, files in os.walk(root, topdown=True, followlinks=False):
        directory_path = Path(directory)
        details = directory_path.lstat()
        if not stat.S_ISDIR(details.st_mode) or stat.S_ISLNK(details.st_mode):
            fail(f"staged release contains an unsupported directory: {directory_path}")
        os.chmod(directory_path, 0o700)
        for name in [*names, *files]:
            path = directory_path / name
            details = path.lstat()
            if stat.S_ISLNK(details.st_mode):
                fail(f"staged release must not contain symlinks: {path}")
            if stat.S_ISREG(details.st_mode):
                os.chmod(path, 0o600)
            elif not stat.S_ISDIR(details.st_mode):
                fail(f"staged release contains an unsupported file type: {path}")
    os.chmod(root / "launcher.py", 0o700)


def dependency_digest(node_modules: Path) -> str:
    require_directory(node_modules, exact_mode=0o700)
    digest = hashlib.sha256()
    digest.update(b"aichat-node-modules-v1\0")
    for path in sorted(node_modules.rglob("*")):
        details = owned_lstat(path)
        relative = path.relative_to(node_modules).as_posix().encode("utf-8")
        digest.update(relative)
        digest.update(b"\0")
        if stat.S_ISDIR(details.st_mode) and not stat.S_ISLNK(details.st_mode):
            if stat.S_IMODE(details.st_mode) != 0o700:
                fail(f"staged dependency directory permissions must be 0700: {path}")
            digest.update(b"D\0")
            continue
        if not stat.S_ISREG(details.st_mode) or stat.S_ISLNK(details.st_mode):
            fail(f"staged dependencies contain an unsupported file type: {path}")
        payload = require_private_file(path)
        digest.update(b"F\0")
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def validate_locked_dependencies(runtime: Path) -> None:
    try:
        lock = json.loads(require_private_file(runtime / "package-lock.json").decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StageError("staged package lock is invalid") from exc
    packages = lock.get("packages") if isinstance(lock, dict) else None
    if not isinstance(packages, dict):
        fail("staged package lock does not contain a packages map")
    expected = {
        name: value
        for name, value in packages.items()
        if isinstance(name, str) and name.startswith("node_modules/")
    }
    for relative, locked in sorted(expected.items()):
        if not isinstance(locked, dict) or not isinstance(locked.get("version"), str):
            fail("staged package lock dependency metadata is invalid")
        dependency = runtime / relative
        require_directory(dependency, exact_mode=0o700)
        try:
            package = json.loads(require_private_file(dependency / "package.json").decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise StageError(f"staged dependency package metadata is invalid: {relative}") from exc
        if not isinstance(package, dict) or package.get("version") != locked["version"]:
            fail(f"staged dependency version does not match package-lock.json: {relative}")
        locked_name = locked.get("name")
        if locked_name is not None and package.get("name") != locked_name:
            fail(f"staged dependency name does not match package-lock.json: {relative}")


def load_manifest(release: Path) -> dict[str, object]:
    raw = require_private_file(release / "manifest.json")
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StageError("staged manifest is invalid") from exc
    if not isinstance(manifest, dict) or manifest.get("schema") != SCHEMA_VERSION:
        fail("staged manifest schema is unsupported")
    return manifest


def validate_release(release: Path) -> tuple[dict[str, object], str]:
    require_directory(release, exact_mode=0o700)
    manifest = load_manifest(release)
    required_strings = (
        "fingerprint",
        "source_fingerprint",
        "dependency_digest",
        "label",
        "node",
        "python",
        "log_dir",
    )
    if any(not isinstance(manifest.get(name), str) or not manifest[name] for name in required_strings):
        fail("staged manifest fields are invalid")
    if manifest["label"] != EXPECTED_LABEL:
        fail("staged manifest contains an unexpected LaunchAgent label")
    if any(
        not Path(str(manifest[name])).is_absolute()
        or "\n" in str(manifest[name])
        or "\r" in str(manifest[name])
        for name in ("node", "python", "log_dir")
    ):
        fail("staged manifest paths are invalid")
    if manifest["fingerprint"] != release.name or len(release.name) != 64:
        fail("staged release fingerprint does not match its directory")
    package_inputs: list[tuple[str, bytes]] = []
    runtime = release / "runtime"
    require_directory(runtime, exact_mode=0o700)
    for name in ("package.json", "package-lock.json"):
        package_inputs.append((name, require_private_file(runtime / name)))
    source_root = runtime / "src"
    require_directory(source_root, exact_mode=0o700)
    for path in sorted(source_root.rglob("*")):
        details = owned_lstat(path)
        if stat.S_ISDIR(details.st_mode) and not stat.S_ISLNK(details.st_mode):
            if stat.S_IMODE(details.st_mode) != 0o700:
                fail(f"staged directory permissions must be 0700: {path}")
            continue
        if not stat.S_ISREG(details.st_mode) or stat.S_ISLNK(details.st_mode):
            fail(f"staged source contains an unsupported file type: {path}")
        package_inputs.append((path.relative_to(runtime).as_posix(), require_private_file(path)))
    settings = require_private_file(release / "settings.json")
    launcher = require_private_file(release / "launcher.py", executable=True)
    node_modules = runtime / "node_modules"
    validate_locked_dependencies(runtime)
    computed_dependency_digest = dependency_digest(node_modules)
    if manifest["dependency_digest"] != computed_dependency_digest:
        fail("staged dependency content digest is invalid")
    computed_source = fingerprint(
        package_inputs,
        settings,
        launcher,
        label=str(manifest["label"]),
        node=str(manifest["node"]),
        python=str(manifest["python"]),
        log_dir=str(manifest["log_dir"]),
    )
    if manifest["source_fingerprint"] != computed_source:
        fail("staged source fingerprint is invalid")
    computed = fingerprint(
        package_inputs,
        settings,
        launcher,
        label=str(manifest["label"]),
        node=str(manifest["node"]),
        python=str(manifest["python"]),
        log_dir=str(manifest["log_dir"]),
        dependency_digest_value=computed_dependency_digest,
    )
    if computed != manifest["fingerprint"]:
        fail("staged release content fingerprint is invalid")
    plist_path = release / f"{manifest['label']}.plist"
    plist_bytes = require_private_file(plist_path)
    try:
        plist = plistlib.loads(plist_bytes)
    except Exception as exc:  # plistlib raises several value/parse exceptions.
        raise StageError("staged plist is invalid") from exc
    expected = expected_plist(
        release,
        label=str(manifest["label"]),
        node=str(manifest["node"]),
        python=str(manifest["python"]),
        log_dir=str(manifest["log_dir"]),
    )
    if plist != expected:
        fail("staged plist binding does not match the staged release")
    summary = subprocess.run(
        [
            str(manifest["python"]),
            str(release / "launcher.py"),
            "--settings",
            str(release / "settings.json"),
            "--connector",
            str(release / "runtime" / "src" / "cli.js"),
            "--node",
            str(manifest["node"]),
            "--check-settings",
        ],
        check=True,
        capture_output=True,
        text=True,
        env=sanitized_environment(),
    ).stdout
    if "token_read=false" not in summary.splitlines():
        fail("staged settings validation did not preserve the token boundary")
    automatic_egress = "false"
    for line in summary.splitlines():
        if line.startswith("automatic_egress="):
            automatic_egress = line.split("=", 1)[1]
    if automatic_egress not in {"true", "false"}:
        fail("staged settings validation returned an invalid egress posture")
    return manifest, automatic_egress


def resolve_current(staged_root: Path, *, required: bool) -> Path | None:
    current = staged_root / "current"
    if not current.exists() and not current.is_symlink():
        if required:
            fail("no staged macOS connector candidate is installed")
        return None
    details = owned_lstat(current)
    if not stat.S_ISLNK(details.st_mode):
        fail("staged current pointer must be a symbolic link")
    try:
        canonical_releases = (staged_root / "releases").resolve(strict=True)
        canonical_target = current.resolve(strict=True)
        relative = canonical_target.relative_to(canonical_releases)
    except (OSError, ValueError) as exc:
        raise StageError("staged current pointer escapes its release directory") from exc
    if len(relative.parts) != 1 or canonical_target.parent != canonical_releases:
        fail("staged current pointer must name one direct staged release")
    return staged_root / "releases" / relative.name


def removal_tombstones(staged_root: Path) -> list[Path]:
    return sorted(staged_root.glob(".removed-current.*"))


def reject_interrupted_removal(staged_root: Path) -> None:
    if removal_tombstones(staged_root) or list(staged_root.glob(".removed-release.*")):
        fail("an interrupted staged removal must be recovered with uninstall.sh --apply --stage-only")


def recover_interrupted_removal(staged_root: Path) -> bool:
    tombstones = removal_tombstones(staged_root)
    release_tombstones = sorted(staged_root.glob(".removed-release.*"))
    current = staged_root / "current"
    if not tombstones and not release_tombstones:
        return False
    if len(tombstones) > 1 or len(release_tombstones) > 1:
        fail("interrupted staged removal state is ambiguous")
    releases = staged_root / "releases"
    canonical_releases = releases.resolve(strict=True)
    pointer = current if current.exists() or current.is_symlink() else (tombstones[0] if tombstones else None)
    candidate: Path | None = None
    if pointer is not None:
        details = owned_lstat(pointer)
        if not stat.S_ISLNK(details.st_mode):
            fail("interrupted staged removal pointer must be a symbolic link")
        raw_target = os.readlink(pointer)
        canonical_candidate = (pointer.parent / raw_target).resolve(strict=False)
        try:
            relative = canonical_candidate.relative_to(canonical_releases)
        except ValueError as exc:
            raise StageError("interrupted staged removal pointer escapes releases") from exc
        if len(relative.parts) != 1:
            fail("interrupted staged removal pointer is invalid")
        candidate = releases / relative.name

    if release_tombstones and current.is_symlink():
        assert candidate is not None
        os.rename(release_tombstones[0], candidate)
        fsync_directory(releases)
        validate_release(candidate)
        return False
    if release_tombstones:
        if tombstones:
            tombstones[0].unlink()
            fsync_directory(staged_root)
        shutil.rmtree(release_tombstones[0])
        fsync_directory(staged_root)
        return True
    if tombstones and candidate is not None and candidate.exists():
        os.replace(tombstones[0], current)
        fsync_directory(staged_root)
        return False
    if tombstones:
        tombstones[0].unlink()
    fsync_directory(staged_root)
    return True


def publish(args: argparse.Namespace) -> None:
    home = Path(args.home)
    state_root = Path(args.state_root)
    validate_publish_arguments(args)
    require_operation_lock(home, state_root, exclusive=True)
    ensure_state_root(home, state_root)
    staged_root = state_root / "staged"
    releases = staged_root / "releases"
    ensure_directory(staged_root, exact_mode=0o700)
    ensure_directory(releases, exact_mode=0o700)
    reject_interrupted_removal(staged_root)

    settings = require_private_file(Path(args.settings))
    launcher = read_source_file(Path(args.script_dir) / "launcher.py")
    inputs = connector_inputs(Path(args.connector_source))
    source_fingerprint = fingerprint(
        inputs,
        settings,
        launcher,
        label=args.label,
        node=args.node,
        python=args.python,
        log_dir=args.log_dir,
    )
    previous = resolve_current(staged_root, required=False)
    if previous is not None:
        previous_manifest, automatic_egress = validate_release(previous)
        if previous_manifest["source_fingerprint"] == source_fingerprint:
            print("staged=true")
            print("already_staged=true")
            print(f"staged_release={previous_manifest['fingerprint']}")
            print("checked_scope=staged")
            print("launchagent_checked=false")
            print("activation_performed=false")
            print("promotion_supported=false")
            print("connector_process_started=false")
            print("token_read=false")
            print(f"automatic_egress={automatic_egress}")
            return

    build = Path(tempfile.mkdtemp(prefix=".build-", dir=releases))
    os.chmod(build, 0o700)
    try:
        runtime = build / "runtime"
        (runtime / "src").mkdir(parents=True, mode=0o700)
        for name, payload in inputs:
            destination = runtime / name
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if not destination.exists():
                write_file(destination, payload, 0o600)
        try:
            subprocess.run(
                [args.npm, "ci", "--omit=dev", "--ignore-scripts"],
                cwd=runtime,
                check=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=sanitized_environment(),
            )
        except subprocess.CalledProcessError as exc:
            raise StageError("npm ci failed while building staged runtime") from exc
        write_file(build / "settings.json", settings, 0o600)
        write_file(build / "launcher.py", launcher, 0o700)
        protect_release_tree(build)
        validate_locked_dependencies(runtime)
        installed_dependency_digest = dependency_digest(runtime / "node_modules")
        package_fingerprint = fingerprint(
            inputs,
            settings,
            launcher,
            label=args.label,
            node=args.node,
            python=args.python,
            log_dir=args.log_dir,
            dependency_digest_value=installed_dependency_digest,
        )
        release = releases / package_fingerprint
        if release.is_symlink():
            fail("staged release path must not be a symbolic link")
        if release.exists():
            validate_release(release)
        else:
            plist = expected_plist(
                release,
                label=args.label,
                node=args.node,
                python=args.python,
                log_dir=args.log_dir,
            )
            write_file(
                build / f"{args.label}.plist",
                plistlib.dumps(plist, sort_keys=True),
                0o600,
            )
            manifest = {
                "schema": SCHEMA_VERSION,
                "fingerprint": package_fingerprint,
                "source_fingerprint": source_fingerprint,
                "label": args.label,
                "node": args.node,
                "python": args.python,
                "log_dir": args.log_dir,
                "dependency_digest": installed_dependency_digest,
            }
            write_file(
                build / "manifest.json",
                (json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode(),
                0o600,
            )
            protect_release_tree(build)
            validate_release_at_build_path(build, release)
            for directory, _, files in os.walk(build, topdown=False):
                for name in files:
                    descriptor = os.open(Path(directory) / name, os.O_RDONLY)
                    try:
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
                fsync_directory(Path(directory))
            os.rename(build, release)
            fsync_directory(releases)
    finally:
        if build.exists():
            shutil.rmtree(build)
    validate_release(release)

    already_staged = previous == release
    if not already_staged:
        temporary_pointer = staged_root / f".current.{os.getpid()}"
        if temporary_pointer.exists() or temporary_pointer.is_symlink():
            fail("temporary staged pointer already exists")
        try:
            os.symlink(f"releases/{package_fingerprint}", temporary_pointer)
            os.replace(temporary_pointer, staged_root / "current")
            fsync_directory(staged_root)
        finally:
            if temporary_pointer.exists() or temporary_pointer.is_symlink():
                temporary_pointer.unlink()

    _, automatic_egress = validate_release(release)
    print("staged=true")
    print(f"already_staged={str(already_staged).lower()}")
    print(f"staged_release={package_fingerprint}")
    print("checked_scope=staged")
    print("launchagent_checked=false")
    print("activation_performed=false")
    print("promotion_supported=false")
    print("connector_process_started=false")
    print("token_read=false")
    print(f"automatic_egress={automatic_egress}")


def validate_release_at_build_path(build: Path, final_release: Path) -> None:
    manifest = load_manifest(build)
    plist_path = build / f"{manifest['label']}.plist"
    plist = plistlib.loads(require_private_file(plist_path))
    expected = expected_plist(
        final_release,
        label=str(manifest["label"]),
        node=str(manifest["node"]),
        python=str(manifest["python"]),
        log_dir=str(manifest["log_dir"]),
    )
    if plist != expected:
        fail("staged plist binding is invalid before publication")
    summary = subprocess.run(
        [
            str(manifest["python"]),
            str(build / "launcher.py"),
            "--settings",
            str(build / "settings.json"),
            "--connector",
            str(build / "runtime" / "src" / "cli.js"),
            "--node",
            str(manifest["node"]),
            "--check-settings",
        ],
        check=True,
        capture_output=True,
        text=True,
        env=sanitized_environment(),
    ).stdout
    if "token_read=false" not in summary.splitlines():
        fail("staged settings validation did not preserve the token boundary")


def check(args: argparse.Namespace) -> None:
    home = Path(args.home)
    state_root = Path(args.state_root)
    require_operation_lock(home, state_root, exclusive=False)
    require_directory(home)
    require_directory(state_root, exact_mode=0o700)
    staged_root = state_root / "staged"
    require_directory(staged_root, exact_mode=0o700)
    require_directory(staged_root / "releases", exact_mode=0o700)
    reject_interrupted_removal(staged_root)
    release = resolve_current(staged_root, required=True)
    assert release is not None
    manifest, automatic_egress = validate_release(release)
    print("staged=true")
    print(f"staged_release={manifest['fingerprint']}")
    print("checked_scope=staged")
    print("launchagent_checked=false")
    print("activation_performed=false")
    print("promotion_supported=false")
    print("connector_process_started=false")
    print("token_read=false")
    print(f"automatic_egress={automatic_egress}")


def remove(args: argparse.Namespace) -> None:
    home = Path(args.home)
    state_root = Path(args.state_root)
    require_operation_lock(home, state_root, exclusive=True)
    require_directory(home)
    if not state_root.exists() and not state_root.is_symlink():
        print("staged=false")
        print("staged_removed=false")
        print("token_read=false")
        return
    require_directory(state_root, exact_mode=0o700)
    staged_root = state_root / "staged"
    if not staged_root.exists() and not staged_root.is_symlink():
        print("staged=false")
        print("staged_removed=false")
        print("token_read=false")
        return
    require_directory(staged_root, exact_mode=0o700)
    require_directory(staged_root / "releases", exact_mode=0o700)
    if recover_interrupted_removal(staged_root):
        print("staged=false")
        print("staged_removed=true")
        print("token_read=false")
        return
    release = resolve_current(staged_root, required=False)
    if release is None:
        print("staged=false")
        print("staged_removed=false")
        print("token_read=false")
        return
    validate_release(release)
    current = staged_root / "current"
    tombstone = staged_root / f".removed-current.{os.getpid()}"
    release_tombstone = staged_root / f".removed-release.{release.name}.{os.getpid()}"
    os.rename(release, release_tombstone)
    fsync_directory(staged_root / "releases")
    fsync_directory(staged_root)
    pointer_removed = False
    try:
        os.replace(current, tombstone)
        fsync_directory(staged_root)
        tombstone.unlink()
        fsync_directory(staged_root)
        pointer_removed = True
        shutil.rmtree(release_tombstone)
        fsync_directory(staged_root)
    except BaseException:
        if not pointer_removed and release_tombstone.exists():
            os.rename(release_tombstone, release)
            fsync_directory(staged_root / "releases")
            validate_release(release)
            if tombstone.is_symlink() and not current.exists() and not current.is_symlink():
                os.replace(tombstone, current)
                fsync_directory(staged_root)
        elif pointer_removed:
            fsync_directory(staged_root)
        raise
    print("staged=false")
    print("staged_removed=true")
    print("token_read=false")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    subparsers = root.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--home", required=True)
    prepare_parser.add_argument("--state-root", required=True)
    verify_parser = subparsers.add_parser("verify-lock")
    verify_parser.add_argument("--home", required=True)
    verify_parser.add_argument("--state-root", required=True)
    verify_parser.add_argument("--exclusive", action="store_true")
    for name in ("publish", "check", "remove"):
        sub = subparsers.add_parser(name)
        sub.add_argument("--home", required=True)
        sub.add_argument("--state-root", required=True)
        if name == "publish":
            sub.add_argument("--settings", required=True)
            sub.add_argument("--connector-source", required=True)
            sub.add_argument("--script-dir", required=True)
            sub.add_argument("--node", required=True)
            sub.add_argument("--npm", required=True)
            sub.add_argument("--python", required=True)
            sub.add_argument("--label", required=True)
            sub.add_argument("--log-dir", required=True)
    return root


def main() -> int:
    args = parser().parse_args()
    if args.command == "prepare":
        require_operation_lock(Path(args.home), Path(args.state_root), exclusive=True)
        ensure_state_root(Path(args.home), Path(args.state_root))
    elif args.command == "verify-lock":
        require_operation_lock(
            Path(args.home),
            Path(args.state_root),
            exclusive=args.exclusive,
        )
    elif args.command == "publish":
        publish(args)
    elif args.command == "check":
        check(args)
    elif args.command == "remove":
        remove(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (StageError, OSError, subprocess.SubprocessError) as exc:
        print(f"aichat macOS staged package: {exc}", file=sys.stderr)
        raise SystemExit(1)
