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


def run_shell(script: str, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", script, "test-shell", *arguments],
        check=False,
        text=True,
        capture_output=True,
    )


def valid_adapted_document() -> dict[str, object]:
    provisioning_paths = [
        "/aichat/v1/agents/register",
        "/aichat/v1/channels",
        "/aichat/v1/channels/*/join",
    ]
    provisioning_routes = [
        {
            "match": [{"method": ["POST"], "path": [path]}],
            "handle": [{"handler": "static_response", "status_code": 403}],
        }
        for path in provisioning_paths
    ]
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
                                "handle": [
                                    {
                                        "handler": "subroute",
                                        "routes": [
                                            {
                                                "match": [
                                                    {
                                                        "method": ["POST"],
                                                        "path": provisioning_paths,
                                                    }
                                                ],
                                                "handle": [
                                                    {
                                                        "handler": "headers",
                                                        "response": {
                                                            "set": {
                                                                "X-Aichat-Edge-Deny": [
                                                                    "provisioning"
                                                                ]
                                                            }
                                                        },
                                                    }
                                                ],
                                            },
                                            *provisioning_routes,
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
                                                                        "headers": {
                                                                            "Location": [
                                                                                "/aichat/"
                                                                            ]
                                                                        },
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
                                                    {
                                                        "handler": "subroute",
                                                        "routes": [
                                                            {
                                                                "handle": [
                                                                    {
                                                                        "handler": "rewrite",
                                                                        "strip_path_prefix": "/aichat",
                                                                    }
                                                                ]
                                                            },
                                                            {
                                                                "handle": [
                                                                    {
                                                                        "handler": "request_body",
                                                                        "max_size": 4_000_000,
                                                                    },
                                                                    {
                                                                        "handler": "reverse_proxy",
                                                                        "upstreams": [
                                                                            {
                                                                                "dial": "127.0.0.1:8787"
                                                                            }
                                                                        ],
                                                                    },
                                                                ]
                                                            },
                                                        ],
                                                    }
                                                ],
                                            },
                                        ],
                                    },
                                    {
                                        "handler": "reverse_proxy",
                                        "upstreams": [{"dial": "127.0.0.1:17300"}],
                                    },
                                ],
                            },
                        ]
                    }
                }
            }
        }
    }


def public_adapted_document() -> dict[str, object]:
    document = valid_adapted_document()
    route_context = document["apps"]["http"]["servers"]["srv0"]["routes"][1]["handle"][
        0
    ]["routes"]
    del route_context[:4]
    return document


class DeploymentPackageTests(unittest.TestCase):
    def test_shell_and_python_sources_parse(self) -> None:
        for script in (*SCRIPTS.glob("*.sh"), *(ROOT / "tests").glob("*.sh")):
            run("bash", "-n", str(script))
        for script in SCRIPTS.glob("*.py"):
            run("python3", "-m", "py_compile", str(script))

    def test_release_link_validation_is_fail_closed(self) -> None:
        script = r'''
set -Eeuo pipefail
source "$1"
status=0
resolved="$(resolve_release_link TEST_LINK "$2" "$3")" || status=$?
printf '%s\n%s\n' "$status" "$resolved"
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            releases = root / "releases"
            releases.mkdir()
            valid_release = releases / "release-a"
            valid_release.mkdir()
            outside_release = root / "outside"
            outside_release.mkdir()
            link = root / "current"

            result = run_shell(script, str(SCRIPTS / "lib.sh"), str(link), str(releases))
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.splitlines()[0], "1")

            link.symlink_to(valid_release)
            result = run_shell(script, str(SCRIPTS / "lib.sh"), str(link), str(releases))
            self.assertEqual(result.stdout.splitlines(), ["0", str(valid_release.resolve())])

            link.unlink()
            link.symlink_to(root / "missing")
            result = run_shell(script, str(SCRIPTS / "lib.sh"), str(link), str(releases))
            self.assertEqual(result.stdout.splitlines()[0], "2")
            self.assertIn("does not resolve", result.stderr)

            link.unlink()
            link.symlink_to(link)
            result = run_shell(script, str(SCRIPTS / "lib.sh"), str(link), str(releases))
            self.assertEqual(result.stdout.splitlines()[0], "2")

            link.unlink()
            link.symlink_to(outside_release)
            result = run_shell(script, str(SCRIPTS / "lib.sh"), str(link), str(releases))
            self.assertEqual(result.stdout.splitlines()[0], "2")
            self.assertIn("escaped the release directory", result.stderr)

            link.unlink()
            nested = valid_release / "server"
            nested.mkdir()
            link.symlink_to(nested)
            result = run_shell(script, str(SCRIPTS / "lib.sh"), str(link), str(releases))
            self.assertEqual(result.stdout.splitlines()[0], "2")

            link.unlink()
            link.write_text("not a symlink")
            result = run_shell(script, str(SCRIPTS / "lib.sh"), str(link), str(releases))
            self.assertEqual(result.stdout.splitlines()[0], "2")
            self.assertIn("must be a symlink", result.stderr)

    def test_atomic_symlink_short_circuits_and_never_reuses_stale_temporary(self) -> None:
        script = r'''
set -Eeuo pipefail
source "$1"
mode="$2"
link="$3"
command ln -s old "$link"
case "$mode" in
  stale)
    command ln -s stale "${link}.new.$$"
    ;;
  ln-fail)
    ln() { return 1; }
    ;;
  mv-fail)
    mv() { return 1; }
    ;;
  success)
    mv() {
      command rm -f -- "$3"
      command mv -f -- "$2" "$3"
    }
    ;;
esac
status=0
atomic_symlink expected "$link" || status=$?
printf 'status=%s\n' "$status"
printf 'target=%s\n' "$(command readlink "$link")"
if [[ -e "${link}.new.$$" || -L "${link}.new.$$" ]]; then
  printf 'temporary=%s\n' "$(command readlink "${link}.new.$$")"
else
  printf 'temporary=absent\n'
fi
'''
        with tempfile.TemporaryDirectory() as directory:
            link = Path(directory) / "current"
            stale = run_shell(script, str(SCRIPTS / "lib.sh"), "stale", str(link))
            self.assertEqual(stale.returncode, 0, stale.stderr)
            self.assertIn("status=1", stale.stdout)
            self.assertIn("target=old", stale.stdout)
            self.assertIn("temporary=stale", stale.stdout)
            self.assertIn("refusing to reuse stale", stale.stderr)

        with tempfile.TemporaryDirectory() as directory:
            link = Path(directory) / "current"
            ln_fail = run_shell(script, str(SCRIPTS / "lib.sh"), "ln-fail", str(link))
            self.assertEqual(ln_fail.returncode, 0, ln_fail.stderr)
            self.assertIn("status=1", ln_fail.stdout)
            self.assertIn("target=old", ln_fail.stdout)
            self.assertIn("temporary=absent", ln_fail.stdout)

        with tempfile.TemporaryDirectory() as directory:
            link = Path(directory) / "current"
            mv_fail = run_shell(script, str(SCRIPTS / "lib.sh"), "mv-fail", str(link))
            self.assertEqual(mv_fail.returncode, 0, mv_fail.stderr)
            self.assertIn("status=1", mv_fail.stdout)
            self.assertIn("target=old", mv_fail.stdout)
            self.assertIn("temporary=absent", mv_fail.stdout)

        with tempfile.TemporaryDirectory() as directory:
            link = Path(directory) / "current"
            success = run_shell(script, str(SCRIPTS / "lib.sh"), "success", str(link))
            self.assertEqual(success.returncode, 0, success.stderr)
            self.assertIn("status=0", success.stdout)
            self.assertIn("target=expected", success.stdout)
            self.assertIn("temporary=absent", success.stdout)

    def test_release_link_restore_propagates_atomic_install_failure(self) -> None:
        script = r'''
set -Eeuo pipefail
source "$1"
release="$2"
link="$3"
atomic_symlink() { return 1; }
status=0
restore_release_link_state TEST_LINK "$link" "$release" "$(dirname "$release")" || status=$?
printf 'status=%s\n' "$status"
if [[ -e "$link" || -L "$link" ]]; then
  printf 'link=present\n'
else
  printf 'link=absent\n'
fi
'''
        with tempfile.TemporaryDirectory() as directory:
            releases = Path(directory) / "releases"
            release = releases / "old-current"
            link = Path(directory) / "current"
            release.mkdir(parents=True)
            result = run_shell(
                script,
                str(SCRIPTS / "lib.sh"),
                str(release.resolve()),
                str(link.resolve()),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("status=1", result.stdout)
            self.assertIn("link=absent", result.stdout)
            self.assertIn("failed to restore TEST_LINK link", result.stderr)

    def test_path_snapshot_restores_present_and_absent_states(self) -> None:
        script = r'''
set -Eeuo pipefail
source "$1"
backup_root="$2"
present="$3"
absent="$4"
snapshot_path_state "$backup_root" present "$present"
snapshot_path_state "$backup_root" absent "$absent"
printf 'changed\n' >"$present"
chmod 0600 "$present"
printf 'created\n' >"$absent"
restore_path_state "$backup_root" present "$present"
restore_path_state "$backup_root" absent "$absent"
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            backup_root = root / "snapshot"
            present = root / "relay.env"
            absent = root / "unit.service"
            present.write_text("original\n")
            present.chmod(0o640)
            result = run_shell(
                script,
                str(SCRIPTS / "lib.sh"),
                str(backup_root),
                str(present),
                str(absent),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(present.read_text(), "original\n")
            self.assertEqual(present.stat().st_mode & 0o777, 0o640)
            self.assertFalse(absent.exists())

    def test_path_restore_propagates_copy_and_remove_failures(self) -> None:
        copy_failure_script = r'''
set -Eeuo pipefail
source "$1"
backup_root="$2"
path="$3"
printf 'original\n' >"$path"
snapshot_path_state "$backup_root" value "$path"
rm -f "$path"
cp() { return 1; }
status=0
restore_path_state "$backup_root" value "$path" || status=$?
printf 'status=%s\n' "$status"
'''
        remove_failure_script = r'''
set -Eeuo pipefail
source "$1"
backup_root="$2"
path="$3"
snapshot_path_state "$backup_root" absent "$path"
printf 'created\n' >"$path"
rm() { return 1; }
status=0
restore_path_state "$backup_root" absent "$path" || status=$?
printf 'status=%s\n' "$status"
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = run_shell(
                copy_failure_script,
                str(SCRIPTS / "lib.sh"),
                str(root / "snapshot"),
                str(root / "relay.env"),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("status=1", result.stdout)
            self.assertIn("failed to restore path snapshot", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = run_shell(
                remove_failure_script,
                str(SCRIPTS / "lib.sh"),
                str(root / "snapshot"),
                str(root / "unit.service"),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("status=1", result.stdout)
            self.assertIn("failed to restore absent path state", result.stderr)

    def test_release_permissions_survive_umask_027_without_marking_plain_files_executable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory) / "release"
            server = release / "server"
            executable = release / "venv" / "bin" / "uvicorn"
            server.mkdir(parents=True, mode=0o700)
            executable.parent.mkdir(parents=True, mode=0o700)
            plain = server / "app.py"
            plain.write_text("value = 1\n")
            plain.chmod(0o600)
            executable.write_text("#!/bin/sh\n")
            executable.chmod(0o700)
            run("chmod", "-R", "u=rwX,go=rX", str(release))
            self.assertEqual(release.stat().st_mode & 0o777, 0o755)
            self.assertEqual(server.stat().st_mode & 0o777, 0o755)
            self.assertEqual(plain.stat().st_mode & 0o777, 0o644)
            self.assertEqual(executable.stat().st_mode & 0o777, 0o755)

    def test_installer_captures_and_restores_transaction_state(self) -> None:
        installer = (SCRIPTS / "install.sh").read_text()
        link_validation = installer.index("old_current=\"$(resolve_release_link")
        first_mutation = installer.index('note "creating the dedicated aichat-relay account')
        self.assertLess(link_validation, first_mutation)
        self.assertIn('[[ ! -e "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]]', installer)
        self.assertIn('chown -R root:root "$RELEASE_DIR"', installer)
        self.assertIn('chmod -R u=rwX,go=rX "$RELEASE_DIR"', installer)
        self.assertIn('runuser -u aichat-relay -- test -x', installer)
        self.assertIn('PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$RELEASE_DIR/server"', installer)
        for path in (
            '"$ETC_DIR/relay.env"',
            "/etc/systemd/system/aichat-relay.service",
            "/etc/systemd/system/aichat-relay-backup.service",
            "/etc/systemd/system/aichat-relay-backup.timer",
        ):
            self.assertIn(path, installer)
        for failure in (
            "Relay failed local health acceptance",
            "Caddy validation/adapted-route acceptance failed",
            "Caddy reload failed",
            "public HTTPS health check failed",
            "initial backup or backup timer acceptance failed",
        ):
            self.assertIn(f'fail_transaction "{failure}"', installer)
        self.assertIn("restore_installed_files || failures=", installer)
        self.assertIn("systemctl daemon-reload", installer)
        self.assertIn("service_was_enabled", installer)
        self.assertIn("timer_was_enabled", installer)
        self.assertIn("timer_was_active", installer)
        self.assertIn("unexpected installer failure rollback was incomplete", installer)
        self.assertIn("preserving transaction snapshot for manual recovery", installer)
        self.assertNotIn("rollback_release", installer)
        self.assertNotIn("relay.env.previous", installer)
        mutation_segment = installer.split("transaction_active=true", 1)[1].split(
            "transaction_active=false", 1
        )[0]
        self.assertNotRegex(mutation_segment, r"(?m)^\s*(die|exit)\b")
        final_backup = installer.index("initial backup or backup timer acceptance failed")
        previous_update = installer.index('atomic_symlink "$old_current" "$PREVIOUS_LINK"')
        self.assertLess(final_backup, previous_update)

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
        self.assertIn("invalid local registration probe cannot write an Agent", checker)
        self.assertIn("application lockdown denies non-mutating authenticated channel join", checker)
        self.assertIn("provisioning_auth_names=(missing invalid)", checker)
        self.assertIn("provisioning_auth_names+=(valid)", checker)
        self.assertIn("expect_edge_http_status 403", checker)
        self.assertIn("X-AIChat-Edge-Deny", checker)
        self.assertIn("aichat_edge_probe=", checker)
        self.assertIn("expect_not_edge_denied", checker)
        self.assertNotIn("local-registration-must-stay-closed", checker)
        self.assertNotIn("local-channel-create-must-stay-closed", checker)
        self.assertNotIn("public-registration-must-stay-closed", checker)
        self.assertNotIn("public-channel-create-must-stay-closed", checker)
        self.assertIn('-H "Authorization: Bearer $AICHAT_CHECK_TOKEN"', checker)

    def test_installed_templates_do_not_use_rustdesk_ports(self) -> None:
        protected = tuple(str(port) for port in range(21115, 21120))
        for template in TEMPLATES.iterdir():
            content = template.read_text()
            for port in protected:
                self.assertNotIn(port, content, f"{template.name} references {port}")

    def test_caddy_route_has_prefix_strip_limits_and_public_provisioning_denies(self) -> None:
        route = (TEMPLATES / "caddy-route.caddy").read_text()
        self.assertIn("route {", route)
        self.assertIn("handle_path __AICHAT_PATH_PREFIX__/*", route)
        self.assertIn("reverse_proxy 127.0.0.1:__AICHAT_RELAY_PORT__", route)
        self.assertIn("max_size 4MB", route)
        self.assertIn("/v1/agents/register", route)
        self.assertIn("/v1/channels", route)
        self.assertIn("/v1/channels/*/join", route)
        self.assertNotIn("/v1/agents/register*", route)
        self.assertNotIn("/v1/channels/*/join*", route)
        self.assertGreaterEqual(route.count("respond @aichat_public_"), 3)
        self.assertIn("X-AIChat-Edge-Deny provisioning", route)
        self.assertLess(
            route.index("respond @aichat_public_registration 403"),
            route.index("handle_path __AICHAT_PATH_PREFIX__/*"),
        )
        self.assertLess(
            route.index("respond @aichat_public_channel_create 403"),
            route.index("handle_path __AICHAT_PATH_PREFIX__/*"),
        )
        self.assertLess(
            route.index("respond @aichat_public_channel_join 403"),
            route.index("handle_path __AICHAT_PATH_PREFIX__/*"),
        )
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
            document = public_adapted_document()
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

    def test_adapted_caddy_validator_requires_ordered_provisioning_deny_context(self) -> None:
        arguments = (
            "python3",
            str(SCRIPTS / "validate-caddy-route.py"),
            "--path-prefix",
            "/aichat",
            "--relay-dial",
            "127.0.0.1:8787",
            "--fallback-dial",
            "127.0.0.1:17300",
            "--public-provisioning",
            "false",
        )

        with tempfile.TemporaryDirectory() as directory:
            adapted = Path(directory) / "adapted.json"
            adapted.write_text(json.dumps(valid_adapted_document()))
            result = run(*arguments[:2], "--adapted-json", str(adapted), *arguments[2:])
            self.assertIn("route invariants passed", result.stdout)

        invalid_documents = []

        reordered = valid_adapted_document()
        reordered_context = reordered["apps"]["http"]["servers"]["srv0"]["routes"][1][
            "handle"
        ][0]["routes"]
        registration_deny = reordered_context.pop(1)
        reordered_context.append(registration_deny)
        invalid_documents.append(("precede the Relay proxy", reordered))

        split = valid_adapted_document()
        split_outer = split["apps"]["http"]["servers"]["srv0"]["routes"]
        split_context = split_outer[1]["handle"][0]["routes"]
        split_outer.insert(1, split_context.pop(1))
        invalid_documents.append(("share one route context", split))

        get_only = valid_adapted_document()
        get_context = get_only["apps"]["http"]["servers"]["srv0"]["routes"][1][
            "handle"
        ][0]["routes"]
        get_context[1]["match"][0]["method"] = ["GET"]
        invalid_documents.append(("POST-only", get_only))

        query_bound = valid_adapted_document()
        query_context = query_bound["apps"]["http"]["servers"]["srv0"]["routes"][1][
            "handle"
        ][0]["routes"]
        query_context[1]["match"][0]["query"] = {"probe": ["required"]}
        invalid_documents.append(("POST-only", query_bound))

        for expected, document in invalid_documents:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                adapted = Path(directory) / "adapted.json"
                adapted.write_text(json.dumps(document))
                result = subprocess.run(
                    [*arguments[:2], "--adapted-json", str(adapted), *arguments[2:]],
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_adapted_caddy_validator_requires_enabled_public_route_to_have_no_managed_denies(
        self,
    ) -> None:
        arguments = (
            "python3",
            str(SCRIPTS / "validate-caddy-route.py"),
            "--path-prefix",
            "/aichat",
            "--relay-dial",
            "127.0.0.1:8787",
            "--fallback-dial",
            "127.0.0.1:17300",
            "--public-provisioning",
            "true",
        )

        documents = [(None, public_adapted_document())]
        documents.append(("exact managed POST deny remains", valid_adapted_document()))

        marker_only = public_adapted_document()
        marker_source = valid_adapted_document()["apps"]["http"]["servers"]["srv0"][
            "routes"
        ][1]["handle"][0]["routes"][0]
        marker_only["apps"]["http"]["servers"]["srv0"]["routes"][1]["handle"][0][
            "routes"
        ].insert(0, marker_source)
        documents.append(("edge-deny marker remains", marker_only))

        for expected, document in documents:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                adapted = Path(directory) / "adapted.json"
                adapted.write_text(json.dumps(document))
                result = subprocess.run(
                    [*arguments[:2], "--adapted-json", str(adapted), *arguments[2:]],
                    text=True,
                    capture_output=True,
                )
                if expected is None:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("route invariants passed", result.stdout)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(expected, result.stderr)

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
            document = public_adapted_document()
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
        document = public_adapted_document()
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
            document = public_adapted_document()
            route_context = document["apps"]["http"]["servers"]["srv0"]["routes"][1][
                "handle"
            ][0]["routes"]
            redirect = next(
                route for route in route_context if route.get("match") == [{"path": ["/aichat"]}]
            )
            response = redirect["handle"][0]["routes"][0]["handle"][0]
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
        document = public_adapted_document()
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
        document = public_adapted_document()
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
