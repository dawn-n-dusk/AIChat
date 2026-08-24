from __future__ import annotations

import gzip
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
TEMPLATES = ROOT / "templates"


def run(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(arguments, check=True, text=True, capture_output=True)


class DeploymentPackageTests(unittest.TestCase):
    def test_shell_and_python_sources_parse(self) -> None:
        for script in SCRIPTS.glob("*.sh"):
            run("bash", "-n", str(script))
        for script in SCRIPTS.glob("*.py"):
            run("python3", "-m", "py_compile", str(script))

    def test_service_is_loopback_only_and_uses_dedicated_account(self) -> None:
        unit = (TEMPLATES / "aichat-relay.service").read_text()
        self.assertIn("User=aichat-relay", unit)
        self.assertIn("Group=aichat-relay", unit)
        self.assertIn("--host 127.0.0.1", unit)
        self.assertNotIn("--host 0.0.0.0", unit)
        self.assertIn("--workers 1", unit)
        self.assertIn("--no-access-log", unit)
        self.assertIn('ExecStartPre=/usr/bin/test "${AICHAT_PRODUCTION_LOCKDOWN}" = true', unit)
        self.assertIn('ExecStartPre=/usr/bin/test "${AICHAT_DOCS_ENABLED}" = false', unit)
        self.assertIn("IPAddressDeny=any", unit)
        self.assertIn("IPAddressAllow=127.0.0.0/8", unit)

    def test_production_runtime_settings_are_explicit_and_installed(self) -> None:
        example = (ROOT / "config" / "deploy.env.example").read_text()
        installer = (SCRIPTS / "install.sh").read_text()
        checker = (SCRIPTS / "check.sh").read_text()
        expected = {
            "AICHAT_PRODUCTION_LOCKDOWN": "true",
            "AICHAT_DOCS_ENABLED": "false",
            "AICHAT_AGENT_REGISTRATION_ENABLED": "false",
            "AICHAT_CHANNEL_CREATE_ENABLED": "false",
            "AICHAT_CHANNEL_JOIN_ENABLED": "false",
            "AICHAT_HTTP_RATE_LIMIT_PER_MINUTE": "120",
            "AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE": "30",
            "AICHAT_WS_MAX_CONNECTIONS": "128",
            "AICHAT_WS_MAX_CONNECTIONS_PER_AGENT": "4",
            "AICHAT_TRUSTED_PROXY_CIDRS": "127.0.0.0/8,::1/128",
        }
        for name, value in expected.items():
            self.assertIn(f"{name}={value}", example)
            self.assertIn(name, installer)
            self.assertIn(name, checker)
        self.assertIn("unauthenticated POST /${authenticated_lockdown_paths[$index]}", checker)
        self.assertIn("channel create/join feature-gate 403 checks require AICHAT_CHECK_TOKEN", checker)
        self.assertIn('-H "Authorization: Bearer $AICHAT_CHECK_TOKEN"', checker)

    def test_installed_templates_do_not_use_rustdesk_ports(self) -> None:
        protected = tuple(str(port) for port in range(21115, 21120))
        for template in TEMPLATES.iterdir():
            content = template.read_text()
            for port in protected:
                self.assertNotIn(port, content, f"{template.name} references {port}")

    def test_caddy_route_has_prefix_strip_limits_and_public_provisioning_denies(self) -> None:
        route = (TEMPLATES / "caddy-route.caddy").read_text()
        self.assertIn("handle_path __AICHAT_PATH_PREFIX__/*", route)
        self.assertIn("reverse_proxy 127.0.0.1:__AICHAT_RELAY_PORT__", route)
        self.assertIn("max_size 4MB", route)
        self.assertIn("/v1/agents/register*", route)
        self.assertIn("/v1/channels", route)
        self.assertIn("/v1/channels/*/join*", route)
        self.assertGreaterEqual(route.count("respond @aichat_public_"), 3)
        self.assertNotRegex(route, r"(?m)^\s*log\s*\{")

    def test_caddy_patcher_places_managed_route_before_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "Caddyfile"
            config.write_text(
                "example.test {\n"
                "    reverse_proxy /existing/* 127.0.0.1:17080\n"
                "    reverse_proxy 127.0.0.1:17300\n"
                "}\n"
            )
            route = root / "route.caddy"
            route.write_text(
                (TEMPLATES / "caddy-route.caddy")
                .read_text()
                .replace("__AICHAT_PATH_PREFIX__", "/aichat")
                .replace("__AICHAT_RELAY_PORT__", "8787")
            )
            run(
                "python3",
                str(SCRIPTS / "patch-caddy.py"),
                "--config",
                str(config),
                "--mode",
                "install",
                "--route",
                str(route),
                "--fallback",
                "reverse_proxy 127.0.0.1:17300",
            )
            patched = config.read_text()
            self.assertLess(patched.index("handle_path /aichat/*"), patched.index("127.0.0.1:17300"))
            self.assertEqual(patched.count("# BEGIN AICHAT RELAY"), 1)

    def test_adapted_caddy_validator_compares_reverse_proxy_handler_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            adapted = Path(directory) / "adapted.json"
            adapted.write_text(
                json.dumps(
                    {
                        "apps": {
                            "http": {
                                "servers": {
                                    "srv0": {
                                        "routes": [
                                            {
                                                "match": [{"path": ["/aichat/*"]}],
                                                "handle": [
                                                    {"handler": "request_body", "max_size": 4_000_000},
                                                    {
                                                        "handler": "reverse_proxy",
                                                        "upstreams": [{"dial": "127.0.0.1:8787"}],
                                                    },
                                                ],
                                            },
                                            {
                                                "handler": "subroute",
                                                "routes": [
                                                    {
                                                        "handle": [
                                                            {
                                                                "handler": "reverse_proxy",
                                                                "upstreams": [
                                                                    {"dial": "127.0.0.1:17300"}
                                                                ],
                                                            }
                                                        ]
                                                    }
                                                ],
                                            },
                                        ]
                                    }
                                }
                            }
                        }
                    }
                )
            )
            result = run(
                "python3",
                str(SCRIPTS / "validate-caddy-route.py"),
                "--adapted-json",
                str(adapted),
                "--path-prefix",
                "/aichat",
                "--relay-dial",
                "127.0.0.1:8787",
                "--fallback-dial",
                "127.0.0.1:17300",
                "--public-provisioning",
                "true",
            )
            self.assertIn("route invariants passed", result.stdout)

    def test_backup_is_consistent_reproducible_gzip_and_checksummed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "relay.db"
            backups = root / "backups"
            connection = sqlite3.connect(database)
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA wal_autocheckpoint=0")
            connection.execute("CREATE TABLE identities (id TEXT PRIMARY KEY, token_hash TEXT)")
            connection.execute("INSERT INTO identities VALUES ('agent-1', 'hash-1')")
            connection.commit()
            self.assertTrue(database.with_name(database.name + "-wal").is_file())
            try:
                run(
                    sys.executable,
                    str(SCRIPTS / "backup.py"),
                    "--database",
                    str(database),
                    "--output-dir",
                    str(backups),
                    "--retention-days",
                    "14",
                )
            finally:
                connection.close()
            archive = next(backups.glob("relay-*.sqlite3.gz"))
            checksum = archive.with_suffix(archive.suffix + ".sha256")
            expected = checksum.read_text().split()[0]
            self.assertEqual(expected, hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertEqual(int.from_bytes(archive.read_bytes()[4:8], "little"), 0)

            restored = root / "restored.sqlite3"
            with gzip.open(archive, "rb") as source, restored.open("wb") as target:
                target.write(source.read())
            restored_connection = sqlite3.connect(restored)
            try:
                self.assertEqual(restored_connection.execute("PRAGMA quick_check").fetchone()[0], "ok")
                self.assertEqual(
                    restored_connection.execute("SELECT id, token_hash FROM identities").fetchone(),
                    ("agent-1", "hash-1"),
                )
            finally:
                restored_connection.close()

    def test_seed_database_accepts_consistent_gzip_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.sqlite3"
            connection = sqlite3.connect(source)
            connection.execute("CREATE TABLE agents (id TEXT PRIMARY KEY)")
            connection.execute("INSERT INTO agents VALUES ('existing-agent')")
            connection.commit()
            connection.close()
            compressed = root / "source.sqlite3.gz"
            with source.open("rb") as source_handle, compressed.open("wb") as raw_target:
                with gzip.GzipFile(
                    filename="", mode="wb", fileobj=raw_target, mtime=0
                ) as target_handle:
                    target_handle.write(source_handle.read())

            destination = root / "data" / "relay.db"
            run(
                "python3",
                str(SCRIPTS / "seed-database.py"),
                "--source",
                str(compressed),
                "--destination",
                str(destination),
            )
            connection = sqlite3.connect(destination)
            try:
                self.assertEqual(connection.execute("SELECT id FROM agents").fetchone()[0], "existing-agent")
                self.assertEqual(connection.execute("PRAGMA quick_check").fetchone()[0], "ok")
            finally:
                connection.close()


if __name__ == "__main__":
    unittest.main()
