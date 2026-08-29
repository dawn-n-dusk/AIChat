from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
LAUNCHER_PATH = REPOSITORY_ROOT / "deploy" / "macos" / "scripts" / "launcher.py"
CORE_CONFIG_PATH = REPOSITORY_ROOT / "adapters" / "codex-connector" / "src" / "config.js"


def load_launcher_module():
    spec = importlib.util.spec_from_file_location("aichat_macos_launcher", LAUNCHER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load macOS launcher module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


launcher = load_launcher_module()


class MacOSLauncherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="aichat-macos-launcher-")
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.worktree = self.root / "worktree"
        self.home.mkdir(mode=0o700)
        self.worktree.mkdir(mode=0o700)
        self.canary = self.home / "egress-canary.txt"
        self.canary.write_text("private-canary-value-1234567890\n", encoding="utf-8")
        self.canary.chmod(0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def settings(
        self,
        *,
        egress_enabled: bool = True,
        lifecycle_status_enabled: bool = False,
        deliver_results: bool | None = None,
    ) -> dict[str, object]:
        channel_id = "channel-fixed"
        settings: dict[str, object] = {
            "identity_config_path": str(self.home / "identity.json"),
            "channel_id": channel_id,
            "allowed_sender_ids": ["agent-windows"],
            "target_thread_id": "00000000-0000-0000-0000-000000000001",
            "task_marker": "AIChat connector marker 00000000-0000-0000-0000-000000000001",
            "app_server_cwd": str(self.worktree),
            "sandbox_policy": {"type": "readOnly", "networkAccess": False},
            "egress": {
                "enabled": egress_enabled,
                "lifecycle_status_enabled": lifecycle_status_enabled,
                "acknowledged_channel_id": channel_id,
                "canary_file": str(self.canary),
                "allowed_reference_hosts": ["github.com", "docs.example.test"],
                "max_text_bytes": 4096,
            },
        }
        if deliver_results is not None:
            settings["deliver_results"] = deliver_results
        return settings

    def test_launcher_environment_is_accepted_by_real_core_config_loader(self) -> None:
        node = shutil.which("node")
        self.assertIsNotNone(node, "Node.js is required for the functional launcher regression")
        settings = launcher.validate_settings(self.settings())
        environment = launcher.build_environment(
            settings,
            {"server": "https://relay.example.test", "token": "relay-test-token-value"},
        )
        environment["HOME"] = str(self.home)
        probe = (
            f'import {{ loadConfig }} from {json.dumps(CORE_CONFIG_PATH.as_uri())};'
            "const config = loadConfig();"
            "process.stdout.write(JSON.stringify({"
            "threadId: config.targetThreadId,"
            "deliverTypes: [...config.deliverTypes],"
            "autoReplyEnabled: config.autoReplyEnabled,"
            "lifecycleStatusEnabled: config.lifecycleStatusEnabled,"
            "hosts: [...config.egressAllowedReferenceHosts],"
            "maxBytes: config.egressMaxTextBytes"
            "}));"
        )
        completed = subprocess.run(
            [node, "--input-type=module", "--eval", probe],
            cwd=self.worktree,
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        loaded = json.loads(completed.stdout)
        self.assertEqual(loaded["threadId"], settings["target_thread_id"])
        self.assertEqual(loaded["deliverTypes"], ["request"])
        self.assertTrue(loaded["autoReplyEnabled"])
        self.assertFalse(loaded["lifecycleStatusEnabled"])
        self.assertEqual(loaded["hosts"], ["github.com", "docs.example.test"])
        self.assertEqual(loaded["maxBytes"], 4096)
        self.assertEqual(environment["CODEX_TARGET_THREAD_ID"], settings["target_thread_id"])

    def test_result_delivery_is_explicit_and_preserves_request_as_the_only_reply_source(self) -> None:
        settings = launcher.validate_settings(self.settings(deliver_results=True))
        self.assertTrue(settings["deliver_results"])
        environment = launcher.build_environment(
            settings,
            {"server": "https://relay.example.test", "token": "relay-test-token-value"},
        )
        self.assertEqual(environment["AICHAT_DELIVER_TYPES"], "request,result")

        node = shutil.which("node")
        self.assertIsNotNone(node, "Node.js is required for the functional launcher regression")
        environment["HOME"] = str(self.home)
        probe = (
            f'import {{ loadConfig }} from {json.dumps(CORE_CONFIG_PATH.as_uri())};'
            "const config = loadConfig();"
            "process.stdout.write(JSON.stringify([...config.deliverTypes]));"
        )
        completed = subprocess.run(
            [node, "--input-type=module", "--eval", probe],
            cwd=self.worktree,
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(json.loads(completed.stdout), ["request", "result"])

        invalid_shape = self.settings()
        invalid_shape["deliver_results"] = "true"
        with self.assertRaisesRegex(launcher.LaunchError, "true or false"):
            launcher.validate_settings(invalid_shape)

    def test_egress_defaults_off_and_never_exports_a_canary_path(self) -> None:
        settings = self.settings(egress_enabled=False)
        del settings["egress"]
        validated = launcher.validate_settings(settings)
        environment = launcher.build_environment(
            validated,
            {"server": "https://relay.example.test", "token": "relay-test-token-value"},
        )
        self.assertFalse(validated["egress"]["enabled"])
        self.assertEqual(environment["AICHAT_AUTO_REPLY_ENABLED"], "false")
        self.assertEqual(environment["AICHAT_LIFECYCLE_STATUS_ENABLED"], "false")
        self.assertNotIn("AICHAT_EGRESS_CANARY_FILE", environment)

    def test_lifecycle_status_requires_enabled_egress_and_explicit_opt_in(self) -> None:
        disabled = self.settings(
            egress_enabled=False,
            lifecycle_status_enabled=True,
        )
        with self.assertRaisesRegex(launcher.LaunchError, "requires enabled egress"):
            launcher.validate_settings(disabled)

        settings = launcher.validate_settings(
            self.settings(lifecycle_status_enabled=True)
        )
        environment = launcher.build_environment(
            settings,
            {"server": "https://relay.example.test", "token": "relay-test-token-value"},
        )
        self.assertTrue(settings["egress"]["lifecycle_status_enabled"])
        self.assertEqual(environment["AICHAT_AUTO_REPLY_ENABLED"], "true")
        self.assertEqual(environment["AICHAT_LIFECYCLE_STATUS_ENABLED"], "true")

        node = shutil.which("node")
        self.assertIsNotNone(node, "Node.js is required for the functional launcher regression")
        environment["HOME"] = str(self.home)
        probe = (
            f'import {{ loadConfig }} from {json.dumps(CORE_CONFIG_PATH.as_uri())};'
            "const config = loadConfig();"
            "process.stdout.write(String(config.lifecycleStatusEnabled));"
        )
        completed = subprocess.run(
            [node, "--input-type=module", "--eval", probe],
            cwd=self.worktree,
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.stdout, "true")

    def test_enabled_egress_requires_exact_channel_hosts_and_private_canary(self) -> None:
        mismatch = self.settings()
        mismatch["egress"]["acknowledged_channel_id"] = "channel-other"
        with self.assertRaisesRegex(launcher.LaunchError, "exactly equal channel_id"):
            launcher.validate_settings(mismatch)

        wildcard = self.settings()
        wildcard["egress"]["allowed_reference_hosts"] = ["*.example.test"]
        with self.assertRaisesRegex(launcher.LaunchError, "exact public DNS hostnames"):
            launcher.validate_settings(wildcard)

        self.canary.chmod(0o644)
        with self.assertRaisesRegex(launcher.LaunchError, "0600 or stricter"):
            launcher.validate_settings(self.settings())

    def test_install_preflight_and_rollback_preview_report_the_same_egress_posture(self) -> None:
        settings_path = self.root / "settings.json"
        self.write_private_json(settings_path, self.settings())
        environment = {**os.environ, "HOME": str(self.home)}
        install = subprocess.run(
            [
                "bash",
                str(REPOSITORY_ROOT / "deploy" / "macos" / "scripts" / "install.sh"),
                "--settings",
                str(settings_path),
                "--repository-root",
                str(REPOSITORY_ROOT),
            ],
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("automatic_egress=true", install.stdout)
        self.assertIn("token_read=false", install.stdout)
        self.assertIn("dry_run=true", install.stdout)

        state_root = (
            self.home
            / "Library"
            / "Application Support"
            / "AIChat"
            / "codex-connector-launchagent"
        )
        backup_id = "20260826T120000Z-1234"
        backup = state_root / "backups" / backup_id
        release = state_root / "releases" / "previous"
        (release / "runtime" / "src").mkdir(parents=True, mode=0o700)
        shutil.copy2(
            REPOSITORY_ROOT / "adapters" / "codex-connector" / "src" / "cli.js",
            release / "runtime" / "src" / "cli.js",
        )
        backup.mkdir(parents=True, mode=0o700)
        (state_root / "last-backup").write_text(f"{backup_id}\n", encoding="utf-8")
        (backup / "previous-current").write_text(str(release), encoding="utf-8")
        shutil.copy2(settings_path, backup / "settings")
        shutil.copy2(LAUNCHER_PATH, backup / "launcher")
        (backup / "settings").chmod(0o600)
        (backup / "launcher").chmod(0o700)
        rollback = subprocess.run(
            [
                "bash",
                str(REPOSITORY_ROOT / "deploy" / "macos" / "scripts" / "rollback.sh"),
            ],
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("restored_automatic_egress=true", rollback.stdout)
        self.assertIn("dry_run=true", rollback.stdout)

    @unittest.skipUnless(sys.platform == "darwin", "LaunchAgent check requires macOS tools")
    def test_offline_check_reports_egress_without_reading_identity_token(self) -> None:
        state_root = (
            self.home
            / "Library"
            / "Application Support"
            / "AIChat"
            / "codex-connector-launchagent"
        )
        release = state_root / "releases" / "current-test"
        (release / "runtime" / "src").mkdir(parents=True, mode=0o700)
        shutil.copy2(
            REPOSITORY_ROOT / "adapters" / "codex-connector" / "src" / "cli.js",
            release / "runtime" / "src" / "cli.js",
        )
        state_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        (state_root / "current").symlink_to(release, target_is_directory=True)
        self.write_private_json(state_root / "settings.json", self.settings())
        shutil.copy2(LAUNCHER_PATH, state_root / "launcher.py")
        (state_root / "launcher.py").chmod(0o700)

        plist_path = self.home / "Library" / "LaunchAgents" / "org.aichat.codex-connector.plist"
        plist_path.parent.mkdir(parents=True, mode=0o700)
        with plist_path.open("wb") as handle:
            plistlib.dump(
                {
                    "Label": "org.aichat.codex-connector",
                    "ProgramArguments": ["/usr/bin/true"],
                },
                handle,
            )
        plist_path.chmod(0o600)
        shim_dir = self.root / "bin"
        shim_dir.mkdir(mode=0o700)
        launchctl_log = self.root / "launchctl.log"
        launchctl = shim_dir / "launchctl"
        launchctl.write_text(
            "#!/bin/bash\n"
            f"printf '%s\\n' \"$*\" >>{json.dumps(str(launchctl_log))}\n"
            "exit 1\n",
            encoding="utf-8",
        )
        launchctl.chmod(0o700)
        completed = subprocess.run(
            [
                "bash",
                str(REPOSITORY_ROOT / "deploy" / "macos" / "scripts" / "check.sh"),
            ],
            env={
                **os.environ,
                "HOME": str(self.home),
                "PATH": f"{shim_dir}{os.pathsep}{os.environ['PATH']}",
            },
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("automatic_egress=true", completed.stdout)
        self.assertIn("token_read=false", completed.stdout)
        self.assertIn("launchagent_loaded=false", completed.stdout)
        self.assertEqual(
            launchctl_log.read_text(encoding="utf-8").splitlines(),
            [f"print gui/{os.getuid()}/org.aichat.codex-connector"],
        )
        self.assertFalse(
            (
                self.home
                / "Library"
                / "Application Support"
                / "AIChat"
                / ".codex-connector-operation.lock"
            ).exists()
        )

    @staticmethod
    def write_private_json(path: Path, value: dict[str, object]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_text(f"{json.dumps(value)}\n", encoding="utf-8")
        path.chmod(0o600)


if __name__ == "__main__":
    unittest.main()
