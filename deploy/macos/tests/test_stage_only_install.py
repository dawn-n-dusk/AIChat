from __future__ import annotations

import json
import importlib.util
import os
import shutil
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
INSTALL = REPOSITORY_ROOT / "deploy" / "macos" / "scripts" / "install.sh"
CHECK = REPOSITORY_ROOT / "deploy" / "macos" / "scripts" / "check.sh"
ROLLBACK = REPOSITORY_ROOT / "deploy" / "macos" / "scripts" / "rollback.sh"
UNINSTALL = REPOSITORY_ROOT / "deploy" / "macos" / "scripts" / "uninstall.sh"
OPERATION_LOCK = REPOSITORY_ROOT / "deploy" / "macos" / "scripts" / "operation-lock.py"
LABEL = "org.aichat.codex-connector"


class StageOnlyInstallTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="aichat-stage-only-")
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir(mode=0o700)
        self.worktree = self.root / "worktree"
        self.worktree.mkdir(mode=0o700)
        self.bin = self.root / "bin"
        self.bin.mkdir(mode=0o700)
        self.launchctl_log = self.root / "launchctl.log"
        self.launchctl_state = self.root / "launchctl.loaded"
        self.node_log = self.root / "node-exec.log"
        self.npm_log = self.root / "npm.log"
        self.npm_started = self.root / "npm.started"
        self.npm_release = self.root / "npm.release"
        self.settings_path = self.root / "settings.json"
        self.settings_path.write_text(
            json.dumps(
                {
                    "identity_config_path": str(self.home / "identity-never-read.json"),
                    "channel_id": "channel-fixed",
                    "allowed_sender_ids": ["agent-windows"],
                    "target_thread_id": "00000000-0000-0000-0000-000000000001",
                    "task_marker": (
                        "AIChat stage test marker 00000000-0000-0000-0000-000000000001"
                    ),
                    "app_server_cwd": str(self.worktree),
                    "sandbox_policy": {"type": "readOnly", "networkAccess": False},
                    "egress": {"enabled": False},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.settings_path.chmod(0o600)
        self.write_shims()
        self.environment = {
            **os.environ,
            "HOME": str(self.home),
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "TEST_LAUNCHCTL_LOG": str(self.launchctl_log),
            "TEST_LAUNCHCTL_STATE": str(self.launchctl_state),
            "TEST_NODE_EXEC_LOG": str(self.node_log),
            "TEST_STAGE_NPM_LOG": str(self.npm_log),
            "TEST_STAGE_NPM_STARTED": str(self.npm_started),
            "TEST_STAGE_NPM_RELEASE": str(self.npm_release),
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @property
    def state_root(self) -> Path:
        return (
            self.home
            / "Library"
            / "Application Support"
            / "AIChat"
            / "codex-connector-launchagent"
        )

    @property
    def plist_path(self) -> Path:
        return self.home / "Library" / "LaunchAgents" / f"{LABEL}.plist"

    def command(self, *extra: str) -> list[str]:
        return [
            "bash",
            str(INSTALL),
            *extra,
            "--settings",
            str(self.settings_path),
            "--repository-root",
            str(REPOSITORY_ROOT),
        ]

    def run_install(
        self, *extra: str, environment: dict[str, str] | None = None, check: bool = True
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            self.command(*extra),
            env=environment or self.environment,
            check=check,
            capture_output=True,
            text=True,
        )

    def test_stage_only_is_inert_idempotent_and_checkable(self) -> None:
        real_metadata_before = self.real_metadata_snapshot()
        first = self.run_install("--apply", "--stage-only")
        self.assertIn("staged=true", first.stdout)
        self.assertIn("already_staged=false", first.stdout)
        self.assertIn("launchagent_checked=false", first.stdout)
        self.assertIn("activation_performed=false", first.stdout)
        self.assertIn("promotion_supported=false", first.stdout)
        self.assertIn("connector_process_started=false", first.stdout)
        self.assertIn("token_read=false", first.stdout)
        self.assertNoLaunchctlCalls()
        self.assertFalse(self.node_log.exists(), "the connector node process must never start")
        self.assertFalse(self.state_root.joinpath("current").exists())
        self.assertFalse(self.state_root.joinpath("settings.json").exists())
        self.assertFalse(self.plist_path.exists())

        staged_check = subprocess.run(
            ["bash", str(CHECK), "--stage-only"],
            env=self.environment,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("staged=true", staged_check.stdout)
        self.assertIn("checked_scope=staged", staged_check.stdout)
        self.assertIn("token_read=false", staged_check.stdout)
        self.assertNoLaunchctlCalls()

        combined_check = subprocess.run(
            ["bash", str(CHECK)],
            env=self.environment,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("state=staged-only", combined_check.stdout)
        self.assertIn("active_installed=false", combined_check.stdout)
        self.assertNoLaunchctlCalls()

        first_pointer = os.lstat(self.state_root / "staged" / "current")
        second = self.run_install("--apply", "--stage-only")
        second_pointer = os.lstat(self.state_root / "staged" / "current")
        self.assertIn("already_staged=true", second.stdout)
        self.assertEqual(first_pointer.st_ino, second_pointer.st_ino)
        releases = [
            path
            for path in (self.state_root / "staged" / "releases").iterdir()
            if not path.name.startswith(".")
        ]
        self.assertEqual(len(releases), 1)
        self.assertEqual(self.npm_log.read_text(encoding="utf-8").splitlines(), ["ci"])
        self.assertEqual(real_metadata_before, self.real_metadata_snapshot())

    def test_stage_only_preview_is_read_only(self) -> None:
        before = list(self.home.iterdir())
        preview = self.run_install("--stage-only")
        self.assertIn("stage_only=true", preview.stdout)
        self.assertIn("dry_run=true", preview.stdout)
        self.assertIn("token_read=false", preview.stdout)
        self.assertEqual(before, list(self.home.iterdir()))
        self.assertFalse(
            self.home
            .joinpath("Library", "Application Support", "AIChat")
            .exists()
        )
        self.assertNoLaunchctlCalls()

    def test_stage_only_leaves_loaded_active_sentinels_and_launchctl_untouched(self) -> None:
        active_snapshot = self.seed_active_sentinels()
        self.launchctl_state.touch()
        completed = self.run_install("--apply", "--stage-only")
        self.assertIn("staged=true", completed.stdout)
        self.assertEqual(active_snapshot, self.active_snapshot())
        self.assertNoLaunchctlCalls()

    def test_failed_build_publishes_no_candidate_or_rollback_snapshot(self) -> None:
        environment = {**self.environment, "TEST_STAGE_NPM_FAIL": "1"}
        completed = self.run_install(
            "--apply", "--stage-only", environment=environment, check=False
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("npm ci failed", completed.stderr)
        self.assertFalse((self.state_root / "staged" / "current").exists())
        self.assertFalse((self.state_root / "last-backup").exists())
        releases = self.state_root / "staged" / "releases"
        self.assertFalse(any(path for path in releases.iterdir() if not path.name.startswith(".")))
        self.assertNoLaunchctlCalls()

    def test_successful_npm_without_locked_dependency_fails_closed(self) -> None:
        environment = {**self.environment, "TEST_STAGE_NPM_EMPTY": "1"}
        completed = self.run_install(
            "--apply", "--stage-only", environment=environment, check=False
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("protected path is unavailable", completed.stderr)
        self.assertFalse((self.state_root / "staged" / "current").exists())
        self.assertNoLaunchctlCalls()

    def test_failed_restage_preserves_the_previous_candidate(self) -> None:
        self.run_install("--apply", "--stage-only")
        pointer = self.state_root / "staged" / "current"
        previous_target = os.readlink(pointer)
        settings = json.loads(self.settings_path.read_text(encoding="utf-8"))
        settings["max_deliveries_per_recovery"] = 19
        self.settings_path.write_text(json.dumps(settings) + "\n", encoding="utf-8")
        self.settings_path.chmod(0o600)
        failed = self.run_install(
            "--apply",
            "--stage-only",
            environment={**self.environment, "TEST_STAGE_NPM_FAIL": "1"},
            check=False,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(os.readlink(pointer), previous_target)
        checked = subprocess.run(
            ["bash", str(CHECK), "--stage-only"],
            env=self.environment,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("staged=true", checked.stdout)
        self.assertNoLaunchctlCalls()

    def test_state_root_symlink_fails_closed_without_touching_target(self) -> None:
        external = self.root / "external"
        external.mkdir(mode=0o700)
        sentinel = external / "sentinel"
        sentinel.write_text("unchanged\n", encoding="utf-8")
        sentinel.chmod(0o600)
        self.state_root.parent.mkdir(parents=True, mode=0o700)
        self.state_root.symlink_to(external, target_is_directory=True)
        completed = self.run_install("--apply", "--stage-only", check=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("real directory", completed.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "unchanged\n")
        self.assertEqual(list(external.iterdir()), [sentinel])
        self.assertNoLaunchctlCalls()

    def test_staged_check_rejects_dependency_tampering(self) -> None:
        self.run_install("--apply", "--stage-only")
        release = (self.state_root / "staged" / "current").resolve(strict=True)
        package = release / "runtime" / "node_modules" / "ws" / "package.json"
        package.write_text('{"name":"ws","version":"tampered"}\n', encoding="utf-8")
        package.chmod(0o600)
        checked = subprocess.run(
            ["bash", str(CHECK), "--stage-only"],
            env=self.environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("does not match package-lock.json", checked.stderr)
        self.assertNoLaunchctlCalls()

    def test_manifest_digest_update_cannot_bypass_content_address(self) -> None:
        self.run_install("--apply", "--stage-only")
        release = (self.state_root / "staged" / "current").resolve(strict=True)
        extra = release / "runtime" / "node_modules" / "ws" / "extra.js"
        extra.write_text("export default 'tampered';\n", encoding="utf-8")
        extra.chmod(0o600)
        helper_path = REPOSITORY_ROOT / "deploy" / "macos" / "scripts" / "staged-package.py"
        spec = importlib.util.spec_from_file_location("aichat_staged_package", helper_path)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        manifest_path = release / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["dependency_digest"] = module.dependency_digest(
            release / "runtime" / "node_modules"
        )
        manifest_path.write_text(
            json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        manifest_path.chmod(0o600)
        checked = subprocess.run(
            ["bash", str(CHECK), "--stage-only"],
            env=self.environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("content fingerprint is invalid", checked.stderr)
        self.assertNoLaunchctlCalls()

    def test_staged_check_rejects_runtime_ancestor_symlink(self) -> None:
        self.run_install("--apply", "--stage-only")
        release = (self.state_root / "staged" / "current").resolve(strict=True)
        runtime = release / "runtime"
        external_runtime = self.root / "external-runtime"
        runtime.rename(external_runtime)
        runtime.symlink_to(external_runtime, target_is_directory=True)
        checked = subprocess.run(
            ["bash", str(CHECK), "--stage-only"],
            env=self.environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("real directory", checked.stderr)
        self.assertNoLaunchctlCalls()

    def test_concurrent_stage_fails_closed_on_shared_operation_lock(self) -> None:
        blocking_environment = {**self.environment, "TEST_STAGE_NPM_BLOCK": "1"}
        first = subprocess.Popen(
            self.command("--apply", "--stage-only"),
            env=blocking_environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 10
            while not self.npm_started.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(self.npm_started.exists(), "first stage did not reach npm shim")
            second = self.run_install("--apply", "--stage-only", check=False)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn("another macOS connector", second.stderr)
            self.npm_release.touch()
            stdout, stderr = first.communicate(timeout=15)
            self.assertEqual(first.returncode, 0, stderr)
            self.assertIn("staged=true", stdout)
        finally:
            self.npm_release.touch(exist_ok=True)
            if first.poll() is None:
                first.kill()
                first.wait(timeout=5)
        self.assertNoLaunchctlCalls()

    def test_check_rollback_and_uninstall_share_the_operation_lock(self) -> None:
        self.run_install("--apply", "--stage-only")
        lock_started = self.root / "lock.started"
        lock_release = self.root / "lock.release"
        lock_environment = {
            **self.environment,
            "TEST_LOCK_STARTED": str(lock_started),
            "TEST_LOCK_RELEASE": str(lock_release),
        }
        python = shutil.which("python3")
        self.assertIsNotNone(python)
        holder = subprocess.Popen(
            [
                python,
                str(OPERATION_LOCK),
                "--home",
                str(self.home),
                "--lock-path",
                str(
                    self.home
                    / "Library"
                    / "Application Support"
                    / "AIChat"
                    / ".codex-connector-operation.lock"
                ),
                "--exclusive",
                "--create",
                "/bin/bash",
                "-c",
                ': >"$TEST_LOCK_STARTED"; while [[ ! -e "$TEST_LOCK_RELEASE" ]]; do sleep 0.02; done',
            ],
            env=lock_environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 10
            while not lock_started.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(lock_started.exists(), "exclusive operation lock was not acquired")
            for command in (
                ["bash", str(CHECK), "--stage-only"],
                ["bash", str(ROLLBACK), "--apply"],
                ["bash", str(UNINSTALL), "--stage-only", "--apply"],
            ):
                completed = subprocess.run(
                    command,
                    env=self.environment,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("another macOS connector", completed.stderr)
        finally:
            lock_release.touch()
            stdout, stderr = holder.communicate(timeout=10)
            self.assertEqual(holder.returncode, 0, f"{stdout}\n{stderr}")
        self.assertTrue((self.state_root / "staged" / "current").is_symlink())

    def test_legacy_apply_still_bootstraps_and_stage_remains_separate(self) -> None:
        active = self.run_install("--apply")
        self.assertIn("active=true", active.stdout)
        self.assertIn("staged=false", active.stdout)
        calls = self.launchctl_calls()
        self.assertTrue(any(call.startswith("print ") for call in calls))
        self.assertTrue(any(call.startswith("bootstrap ") for call in calls))
        self.assertFalse(any(call.startswith(("kickstart ",)) for call in calls))
        self.assertTrue(self.state_root.joinpath("current").is_symlink())
        self.assertTrue(self.plist_path.is_file())

        self.launchctl_log.unlink()
        staged = self.run_install("--apply", "--stage-only")
        self.assertIn("staged=true", staged.stdout)
        self.assertNoLaunchctlCalls()
        active_current = os.readlink(self.state_root / "current")
        checked = subprocess.run(
            ["bash", str(CHECK)],
            env=self.environment,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("state=active-with-staged-candidate", checked.stdout)
        self.assertEqual(active_current, os.readlink(self.state_root / "current"))

    def test_active_apply_succeeds_when_isolated_candidate_is_invalid(self) -> None:
        self.run_install("--apply", "--stage-only")
        staged_pointer = self.state_root / "staged" / "current"
        staged_target = os.readlink(staged_pointer)
        release = staged_pointer.resolve(strict=True)
        dependency = release / "runtime" / "node_modules" / "ws" / "package.json"
        dependency.write_text('{"name":"ws","version":"tampered"}\n', encoding="utf-8")
        dependency.chmod(0o600)
        active = self.run_install("--apply")
        self.assertIn("active=true", active.stdout)
        self.assertIn("staged=true", active.stdout)
        self.assertIn("staged_valid=false", active.stdout)
        self.assertIn("active install succeeded", active.stderr)
        self.assertTrue(self.launchctl_state.exists())
        self.assertEqual(os.readlink(staged_pointer), staged_target)

    def test_stage_does_not_create_rollback_and_uninstall_has_no_mutating_launchctl(self) -> None:
        self.run_install("--apply", "--stage-only")
        self.assertFalse((self.state_root / "last-backup").exists())
        rollback = subprocess.run(
            ["bash", str(ROLLBACK), "--apply"],
            env=self.environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(rollback.returncode, 0)
        self.assertNoLaunchctlCalls()

        removed = subprocess.run(
            ["bash", str(UNINSTALL), "--stage-only", "--apply"],
            env=self.environment,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("staged_removed=true", removed.stdout)
        calls = self.launchctl_calls()
        self.assertTrue(calls and all(call.startswith("print ") for call in calls))
        self.assertFalse((self.state_root / "staged" / "current").exists())

    def seed_active_sentinels(self) -> dict[str, tuple[int, int, bytes | str]]:
        release = self.state_root / "releases" / "active-sentinel"
        (release / "runtime" / "src").mkdir(parents=True, mode=0o700)
        (release / "runtime" / "src" / "cli.js").write_text("sentinel\n", encoding="utf-8")
        self.state_root.chmod(0o700)
        (self.state_root / "current").symlink_to(release, target_is_directory=True)
        (self.state_root / "settings.json").write_text("settings-sentinel\n", encoding="utf-8")
        (self.state_root / "launcher.py").write_text("launcher-sentinel\n", encoding="utf-8")
        self.plist_path.parent.mkdir(parents=True, mode=0o700)
        self.plist_path.write_text("plist-sentinel\n", encoding="utf-8")
        return self.active_snapshot()

    def active_snapshot(self) -> dict[str, tuple[int, int, bytes | str]]:
        result: dict[str, tuple[int, int, bytes | str]] = {}
        paths = [
            self.state_root / "current",
            self.state_root / "settings.json",
            self.state_root / "launcher.py",
            self.plist_path,
        ]
        for path in paths:
            details = path.lstat()
            payload: bytes | str = os.readlink(path) if path.is_symlink() else path.read_bytes()
            result[str(path)] = (stat.S_IMODE(details.st_mode), details.st_ino, payload)
        return result

    def real_metadata_snapshot(self) -> dict[str, tuple[int, int, int, int] | None]:
        real_home = Path(os.path.expanduser("~"))
        paths = [
            real_home
            / "Library"
            / "Application Support"
            / "AIChat"
            / "codex-connector-launchagent",
            real_home / "Library" / "LaunchAgents" / f"{LABEL}.plist",
        ]
        result: dict[str, tuple[int, int, int, int] | None] = {}
        for path in paths:
            try:
                details = path.lstat()
                result[str(path)] = (
                    details.st_mode,
                    details.st_ino,
                    details.st_size,
                    details.st_mtime_ns,
                )
            except FileNotFoundError:
                result[str(path)] = None
        return result

    def assertNoLaunchctlCalls(self) -> None:
        self.assertEqual(self.launchctl_calls(), [])

    def launchctl_calls(self) -> list[str]:
        if not self.launchctl_log.exists():
            return []
        return self.launchctl_log.read_text(encoding="utf-8").splitlines()

    def write_shims(self) -> None:
        self.write_executable(
            "node",
            """#!/bin/bash
set -eu
if [[ "${1:-}" == "-p" ]]; then
  printf '20\\n'
  exit 0
fi
printf '%s\\n' "$*" >>"$TEST_NODE_EXEC_LOG"
exit 97
""",
        )
        self.write_executable(
            "npm",
            """#!/bin/bash
set -eu
printf 'ci\\n' >>"$TEST_STAGE_NPM_LOG"
: >"$TEST_STAGE_NPM_STARTED"
if [[ "${TEST_STAGE_NPM_FAIL:-0}" == "1" ]]; then
  exit 41
fi
if [[ "${TEST_STAGE_NPM_BLOCK:-0}" == "1" ]]; then
  while [[ ! -e "$TEST_STAGE_NPM_RELEASE" ]]; do
    sleep 0.02
  done
fi
if [[ "${TEST_STAGE_NPM_EMPTY:-0}" == "1" ]]; then
  mkdir -p node_modules
  exit 0
fi
mkdir -p node_modules/ws
version="$(python3 -c 'import json; print(json.load(open("package-lock.json"))["packages"]["node_modules/ws"]["version"])')"
printf '{"name":"ws","version":"%s"}\\n' "$version" >node_modules/ws/package.json
""",
        )
        self.write_executable(
            "launchctl",
            """#!/bin/bash
set -eu
printf '%s\\n' "$*" >>"$TEST_LAUNCHCTL_LOG"
case "${1:-}" in
  print)
    [[ -e "$TEST_LAUNCHCTL_STATE" ]]
    ;;
  bootstrap)
    : >"$TEST_LAUNCHCTL_STATE"
    ;;
  bootout)
    rm -f "$TEST_LAUNCHCTL_STATE"
    ;;
  kickstart)
    exit 99
    ;;
  *)
    exit 98
    ;;
esac
""",
        )
        self.write_executable("plutil", "#!/bin/bash\nexit 0\n")

    def write_executable(self, name: str, contents: str) -> None:
        path = self.bin / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o700)


if __name__ == "__main__":
    unittest.main()
