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


def valid_adapted_document() -> dict[str, object]:
    return {
        "logging": {
            "logs": {
                "aichat_relay_errors": {
                    "include": ["http.log.error.aichat_relay"],
                    "encoder": {
                        "format": "filter",
                        "fields": {
                            "request>uri": {
                                "filter": "query",
                                "actions": [
                                    {
                                        "type": "replace",
                                        "parameter": "token",
                                        "value": "REDACTED",
                                    }
                                ],
                            }
                        },
                    },
                },
                "default": {"exclude": ["http.log.error.aichat_relay"]},
            }
        },
        "apps": {
            "http": {
                "servers": {
                    "srv0": {
                        "routes": [
                            {
                                "match": [{"path": ["/aichat", "/aichat/*"]}],
                                "handle": [
                                    {"handler": "vars", "log_skip": True},
                                    {
                                        "handler": "vars",
                                        "access_logger_names": ["aichat_relay"],
                                    },
                                ],
                            },
                            {
                                "match": [{"path": ["/aichat"]}],
                                "handle": [
                                    {
                                        "handler": "subroute",
                                        "routes": [
                                            {
                                                "handle": [
                                                    {
                                                        "handler": "static_response",
                                                        "headers": {"Location": ["/aichat/"]},
                                                        "status_code": 308,
                                                    }
                                                ]
                                            }
                                        ],
                                    }
                                ],
                            },
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
        self.assertIn(
            "@aichat_access_log_skip path __AICHAT_PATH_PREFIX__ __AICHAT_PATH_PREFIX__/*",
            route,
        )
        self.assertIn("log_name @aichat_access_log_skip aichat_relay", route)
        self.assertIn("log_skip @aichat_access_log_skip", route)
        self.assertIn("redir * __AICHAT_PATH_PREFIX__/ 308", route)
        self.assertNotRegex(route, r"(?m)^\s*log\s*\{")

        global_options = (TEMPLATES / "caddy-global-options.caddy").read_text()
        self.assertIn("log aichat_relay_errors", global_options)
        self.assertIn("include http.log.error.aichat_relay", global_options)
        self.assertIn("request>uri query", global_options)
        self.assertIn("replace token REDACTED", global_options)

        installer = (SCRIPTS / "install.sh").read_text()
        self.assertIn("candidate Caddyfile failed AIChat route/log-safety preflight", installer)
        self.assertNotIn("Caddy access logging is enabled", installer)
        self.assertLess(
            installer.index('if ! "$AICHAT_CADDY_BINARY" adapt'),
            installer.index('! "$AICHAT_PYTHON" "$SCRIPT_DIR/validate-caddy-route.py"'),
        )
        self.assertLess(
            installer.index('! "$AICHAT_PYTHON" "$SCRIPT_DIR/validate-caddy-route.py"'),
            installer.index('! "$AICHAT_CADDY_BINARY" validate'),
        )

    def test_caddy_patcher_places_managed_route_before_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "Caddyfile"
            config.write_text(
                "example.test {\n"
                "    log {\n"
                "        output file /tmp/example-access.log\n"
                "    }\n"
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
            global_options = root / "global-options.caddy"
            global_options.write_text((TEMPLATES / "caddy-global-options.caddy").read_text())
            run(
                "python3",
                str(SCRIPTS / "patch-caddy.py"),
                "--config",
                str(config),
                "--mode",
                "install",
                "--route",
                str(route),
                "--global-options",
                str(global_options),
                "--fallback",
                "reverse_proxy 127.0.0.1:17300",
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
                "--global-options",
                str(global_options),
                "--fallback",
                "reverse_proxy 127.0.0.1:17300",
            )
            patched = config.read_text()
            self.assertLess(patched.index("handle_path /aichat/*"), patched.index("127.0.0.1:17300"))
            self.assertEqual(patched.count("# BEGIN AICHAT RELAY"), 1)
            self.assertEqual(patched.count("# BEGIN AICHAT ERROR LOGGER REDACTION"), 1)
            self.assertIn("replace token REDACTED", patched)
            self.assertIn("output file /tmp/example-access.log", patched)

    def test_adapted_caddy_validator_compares_reverse_proxy_handler_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            adapted = Path(directory) / "adapted.json"
            document = valid_adapted_document()
            document["apps"]["http"]["servers"]["srv0"]["routes"].insert(
                0,
                {
                    "match": [{"path": ["/metrics"]}],
                    "handle": [{"handler": "vars", "log_skip": True}],
                },
            )
            adapted.write_text(json.dumps(document))
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

    def test_adapted_caddy_validator_rejects_missing_or_overbroad_log_skip(self) -> None:
        invalid_matchers = (
            None,
            {"path": ["/*"]},
            {"path": ["/aichat/*"]},
            {
                "path": ["/aichat", "/aichat/*"],
                "host": ["dawnndusk-rustdesk.duckdns.org"],
            },
        )
        for matcher in invalid_matchers:
            document = valid_adapted_document()
            document["apps"]["http"]["servers"]["srv0"]["routes"].pop(0)
            if matcher is not None:
                document["apps"]["http"]["servers"]["srv0"]["routes"].insert(
                    0,
                    {
                        "match": [matcher],
                        "handle": [{"handler": "vars", "log_skip": True}],
                    },
                )
            with self.subTest(matcher=matcher), tempfile.TemporaryDirectory() as directory:
                adapted = Path(directory) / "adapted.json"
                adapted.write_text(json.dumps(document))
                result = subprocess.run(
                    [
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
                    ],
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("AIChat log_name/log_skip route", result.stderr)

    def test_adapted_caddy_validator_rejects_cross_server_log_skip(self) -> None:
        document = valid_adapted_document()
        misplaced = document["apps"]["http"]["servers"]["srv0"]["routes"].pop(0)
        document["apps"]["http"]["servers"]["other"] = {"routes": [misplaced]}
        with tempfile.TemporaryDirectory() as directory:
            adapted = Path(directory) / "adapted.json"
            adapted.write_text(json.dumps(document))
            result = subprocess.run(
                [
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
                ],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("AIChat log_name/log_skip route", result.stderr)

    def test_adapted_caddy_validator_rejects_broken_bare_prefix_redirect(self) -> None:
        for location, status in (("308", 302), ("/aichat/", 302), ("/wrong/", 308)):
            document = valid_adapted_document()
            response = document["apps"]["http"]["servers"]["srv0"]["routes"][1][
                "handle"
            ][0]["routes"][0]["handle"][0]
            response["headers"]["Location"] = [location]
            response["status_code"] = status
            with self.subTest(location=location, status=status), tempfile.TemporaryDirectory() as directory:
                adapted = Path(directory) / "adapted.json"
                adapted.write_text(json.dumps(document))
                result = subprocess.run(
                    [
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
                    ],
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("slash form with 308", result.stderr)

    def test_adapted_caddy_validator_rejects_debug_logging(self) -> None:
        document = valid_adapted_document()
        document["logging"] = {"logs": {"default": {"level": "DEBUG"}}}
        with tempfile.TemporaryDirectory() as directory:
            adapted = Path(directory) / "adapted.json"
            adapted.write_text(json.dumps(document))
            result = subprocess.run(
                [
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
                ],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("enables debug logging", result.stderr)

    def test_adapted_caddy_validator_requires_default_error_log_redaction(self) -> None:
        document = valid_adapted_document()
        document["logging"]["logs"]["aichat_relay_errors"]["encoder"]["fields"][
            "request>uri"
        ]["actions"][0]["parameter"] = "other"
        with tempfile.TemporaryDirectory() as directory:
            adapted = Path(directory) / "adapted.json"
            adapted.write_text(json.dumps(document))
            result = subprocess.run(
                [
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
                ],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("AIChat error logger", result.stderr)

    def test_caddy_restore_is_atomic_and_preserves_mode(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "Caddyfile"
            source = root / "Caddyfile.backup"
            config.write_text("changed\n")
            config.chmod(0o640)
            source.write_text("original\n")
            run(
                "python3",
                str(SCRIPTS / "patch-caddy.py"),
                "--config",
                str(config),
                "--mode",
                "restore",
                "--source",
                str(source),
            )
            self.assertEqual(config.read_text(), "original\n")
            self.assertEqual(config.stat().st_mode & 0o777, 0o640)

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
