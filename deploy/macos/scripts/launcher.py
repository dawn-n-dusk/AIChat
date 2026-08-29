#!/usr/bin/env python3
"""Launch the Codex connector without placing its Relay token in launchd metadata."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any, NoReturn
from urllib.parse import urlparse


SAFE_ENV_NAMES = {
    "CODEX_HOME",
    "HOME",
    "LANG",
    "LANGUAGE",
    "LOGNAME",
    "PATH",
    "SHELL",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE",
    "TMPDIR",
    "USER",
}


class LaunchError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--settings", required=True)
    parser.add_argument("--connector", required=True)
    parser.add_argument("--node", required=True)
    parser.add_argument("--check-settings", action="store_true")
    return parser.parse_args()


def fail(message: str) -> NoReturn:
    raise LaunchError(message)


def load_private_json(path_value: str, label: str) -> tuple[Path, dict[str, Any]]:
    path = Path(path_value).expanduser()
    try:
        details = path.stat()
    except OSError as exc:
        raise LaunchError(f"{label} is unavailable: {exc.strerror or 'read failed'}") from exc
    if not stat.S_ISREG(details.st_mode):
        fail(f"{label} must be a regular file")
    if details.st_uid != os.getuid():
        fail(f"{label} must be owned by the current user")
    if stat.S_IMODE(details.st_mode) & 0o077:
        fail(f"{label} permissions must be 0600 or stricter")
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LaunchError(f"{label} is not readable valid JSON") from exc
    if not isinstance(parsed, dict):
        fail(f"{label} must contain a JSON object")
    return path, parsed


def required_string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{name} must be a non-empty string")
    return value.strip()


def positive_integer(value: Any, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        fail(f"{name} must be an integer from {minimum} through {maximum}")
    return value


def validate_settings(settings: dict[str, Any]) -> dict[str, Any]:
    supported = {
        "identity_config_path",
        "channel_id",
        "allowed_sender_ids",
        "target_thread_id",
        "task_marker",
        "app_server_cwd",
        "sandbox_policy",
        "max_turns_per_sender_per_hour",
        "max_deliveries_per_recovery",
        "codex_app_server_binary",
        "egress",
    }
    if set(settings) - supported:
        fail("macOS connector settings contain unsupported fields")
    forbidden = {"token", "authorization", "api_key", "access_token", "client_secret"}
    if contains_forbidden_key(settings, forbidden):
        fail("macOS connector settings must not contain credentials")

    channel_id = required_string(settings.get("channel_id"), "channel_id")
    target_thread_id = required_string(settings.get("target_thread_id"), "target_thread_id")
    task_marker = required_string(settings.get("task_marker"), "task_marker")
    if any(
        "\x00" in value or "\n" in value or "\r" in value
        for value in (channel_id, target_thread_id, task_marker)
    ):
        fail("channel_id, target_thread_id, and task_marker must not contain control lines")
    if not 16 <= len(task_marker) <= 200:
        fail("task_marker must contain 16 through 200 characters")

    senders = settings.get("allowed_sender_ids")
    if (
        not isinstance(senders, list)
        or not senders
        or any(not isinstance(value, str) or not value.strip() for value in senders)
    ):
        fail("allowed_sender_ids must be a non-empty string array")
    normalized_senders = list(dict.fromkeys(value.strip() for value in senders))
    if "*" in normalized_senders:
        fail("allowed_sender_ids must not contain '*'")
    if any("," in value or "\n" in value or "\r" in value for value in normalized_senders):
        fail("allowed_sender_ids must not contain commas or line breaks")

    cwd = Path(required_string(settings.get("app_server_cwd"), "app_server_cwd"))
    if not cwd.is_absolute():
        fail("app_server_cwd must be absolute")
    try:
        resolved_cwd = cwd.resolve(strict=True)
    except OSError as exc:
        raise LaunchError("app_server_cwd must exist") from exc
    if not resolved_cwd.is_dir():
        fail("app_server_cwd must be a directory")

    sandbox = settings.get("sandbox_policy")
    if not isinstance(sandbox, dict):
        fail("sandbox_policy must be an object")
    if set(sandbox) - {"type", "networkAccess", "writableRoots"}:
        fail("sandbox_policy contains unsupported fields")
    if sandbox.get("type") not in {"readOnly", "workspaceWrite"}:
        fail("sandbox_policy.type must be readOnly or workspaceWrite")
    if sandbox.get("networkAccess") is not False:
        fail("sandbox_policy.networkAccess must be false")
    if sandbox["type"] == "workspaceWrite":
        roots = sandbox.get("writableRoots", [])
        if not isinstance(roots, list) or any(not isinstance(value, str) for value in roots):
            fail("sandbox_policy.writableRoots must be an array")
        for value in roots:
            root = Path(value)
            if not root.is_absolute():
                fail("every writableRoot must be absolute")
            try:
                resolved_root = root.resolve(strict=True)
                resolved_root.relative_to(resolved_cwd)
            except (OSError, ValueError) as exc:
                raise LaunchError("every writableRoot must exist inside app_server_cwd") from exc

    identity_path = required_string(
        settings.get(
            "identity_config_path",
            "~/Library/Application Support/AIChat/config.json",
        ),
        "identity_config_path",
    )
    max_turns = positive_integer(
        settings.get("max_turns_per_sender_per_hour", 10),
        "max_turns_per_sender_per_hour",
        1,
        1_000,
    )
    max_deliveries = positive_integer(
        settings.get("max_deliveries_per_recovery", 20),
        "max_deliveries_per_recovery",
        1,
        200,
    )
    codex_binary = settings.get("codex_app_server_binary")
    if codex_binary is not None:
        codex_binary = executable(
            required_string(codex_binary, "codex_app_server_binary"),
            "codex_app_server_binary",
        )

    egress = validate_egress(settings.get("egress"), channel_id)

    return {
        "identity_config_path": identity_path,
        "channel_id": channel_id,
        "allowed_sender_ids": normalized_senders,
        "target_thread_id": target_thread_id,
        "task_marker": task_marker,
        "app_server_cwd": str(resolved_cwd),
        "sandbox_policy": sandbox,
        "max_turns_per_sender_per_hour": max_turns,
        "max_deliveries_per_recovery": max_deliveries,
        "codex_app_server_binary": codex_binary,
        "egress": egress,
    }


def validate_egress(value: Any, channel_id: str) -> dict[str, Any]:
    if value is None:
        value = {}
    if not isinstance(value, dict):
        fail("egress must be an object")
    supported = {
        "enabled",
        "lifecycle_status_enabled",
        "acknowledged_channel_id",
        "canary_file",
        "allowed_reference_hosts",
        "max_text_bytes",
    }
    if set(value) - supported:
        fail("egress contains unsupported fields")
    enabled = value.get("enabled", False)
    if not isinstance(enabled, bool):
        fail("egress.enabled must be true or false")
    lifecycle_status_enabled = value.get("lifecycle_status_enabled", False)
    if not isinstance(lifecycle_status_enabled, bool):
        fail("egress.lifecycle_status_enabled must be true or false")
    if lifecycle_status_enabled and not enabled:
        fail("lifecycle status requires enabled egress")

    acknowledged_channel_id = value.get("acknowledged_channel_id")
    if acknowledged_channel_id is not None:
        acknowledged_channel_id = required_string(
            acknowledged_channel_id,
            "egress.acknowledged_channel_id",
        )
        if acknowledged_channel_id != channel_id:
            fail("egress.acknowledged_channel_id must exactly equal channel_id")
    elif enabled:
        fail("enabled egress requires acknowledged_channel_id")

    raw_hosts = value.get("allowed_reference_hosts", [])
    if not isinstance(raw_hosts, list) or any(not isinstance(host, str) for host in raw_hosts):
        fail("egress.allowed_reference_hosts must be an array")
    hosts: list[str] = []
    for raw_host in raw_hosts:
        host = raw_host.strip().lower()
        if not is_exact_https_reference_host(host):
            fail("egress.allowed_reference_hosts must contain exact public DNS hostnames")
        if host not in hosts:
            hosts.append(host)

    max_text_bytes = positive_integer(
        value.get("max_text_bytes", 8_192),
        "egress.max_text_bytes",
        128,
        100_000,
    )
    canary_file = value.get("canary_file")
    if canary_file is not None:
        canary_path = Path(required_string(canary_file, "egress.canary_file")).expanduser()
        if not canary_path.is_absolute():
            fail("egress.canary_file must be absolute or home-relative")
        canary_file = (
            str(validate_private_canary_file(str(canary_path)))
            if enabled
            else str(canary_path)
        )
    elif enabled:
        fail("enabled egress requires canary_file")

    return {
        "enabled": enabled,
        "lifecycle_status_enabled": lifecycle_status_enabled,
        "acknowledged_channel_id": acknowledged_channel_id,
        "canary_file": canary_file,
        "allowed_reference_hosts": hosts,
        "max_text_bytes": max_text_bytes,
    }


def is_exact_https_reference_host(value: str) -> bool:
    if not value or len(value) > 253 or value in {"localhost"} or value.endswith(".localhost"):
        return False
    if "://" in value or any(character in value for character in "/*?#@:"):
        return False
    labels = value.split(".")
    return len(labels) >= 2 and all(
        1 <= len(label) <= 63
        and re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", label) is not None
        for label in labels
    )


def validate_private_canary_file(path_value: str) -> Path:
    path = Path(path_value).expanduser()
    if not path.is_absolute():
        fail("egress.canary_file must be absolute or home-relative")
    try:
        details = path.lstat()
    except OSError as exc:
        raise LaunchError("egress.canary_file is unavailable") from exc
    if stat.S_ISLNK(details.st_mode) or not stat.S_ISREG(details.st_mode):
        fail("egress.canary_file must be a non-symlink regular file")
    if details.st_nlink != 1:
        fail("egress.canary_file must not have hardlink aliases")
    if details.st_uid != os.getuid():
        fail("egress.canary_file must be owned by the current user")
    if stat.S_IMODE(details.st_mode) & 0o077:
        fail("egress.canary_file permissions must be 0600 or stricter")
    try:
        canary = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise LaunchError("egress.canary_file is unreadable") from exc
    if not 16 <= len(canary) <= 512 or "\n" in canary or "\r" in canary:
        fail("egress.canary_file must contain one 16 through 512 character canary")
    return path.resolve(strict=True)


def contains_forbidden_key(value: Any, forbidden: set[str]) -> bool:
    if isinstance(value, dict):
        return any(
            str(key).lower() in forbidden or contains_forbidden_key(child, forbidden)
            for key, child in value.items()
        )
    if isinstance(value, list):
        return any(contains_forbidden_key(child, forbidden) for child in value)
    return False


def validate_server(value: Any) -> str:
    server = required_string(value, "identity server")
    parsed = urlparse(server)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        fail("identity server must be an http(s) URL")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        fail("identity server must not contain credentials, query, or fragment data")
    loopback = parsed.hostname.lower() in {"127.0.0.1", "::1", "localhost"}
    if parsed.scheme != "https" and not loopback:
        fail("identity server must use HTTPS outside loopback")
    return server.rstrip("/")


def executable(path_value: str, label: str) -> str:
    path = Path(path_value).expanduser()
    if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
        fail(f"{label} must be an absolute executable file")
    return str(path)


def regular_file(path_value: str, label: str) -> str:
    path = Path(path_value).expanduser()
    if not path.is_absolute() or not path.is_file():
        fail(f"{label} must be an absolute regular file")
    return str(path)


def build_environment(settings: dict[str, Any], identity: dict[str, Any]) -> dict[str, str]:
    token = required_string(identity.get("token"), "identity token")
    server = validate_server(identity.get("server"))
    environment = {
        key: value
        for key, value in os.environ.items()
        if isinstance(value, str) and (key in SAFE_ENV_NAMES or key.startswith("LC_"))
    }
    environment.update(
        {
            "AICHAT_CODEX_CONNECTOR_ENABLED": "true",
            "AICHAT_SERVER": server,
            "AICHAT_TOKEN": token,
            "AICHAT_CHANNEL_ID": settings["channel_id"],
            "AICHAT_ALLOWED_SENDER_IDS": ",".join(settings["allowed_sender_ids"]),
            "AICHAT_DELIVER_TYPES": "request",
            "AICHAT_AUTONOMOUS_TEXT_ENABLED": "false",
            "AICHAT_WEBSOCKET_ENABLED": "true",
            "AICHAT_PERIODIC_RECOVERY_ENABLED": "false",
            "AICHAT_AUTO_REPLY_ENABLED": str(settings["egress"]["enabled"]).lower(),
            "AICHAT_LIFECYCLE_STATUS_ENABLED": str(
                settings["egress"]["lifecycle_status_enabled"]
            ).lower(),
            "AICHAT_MAX_TURNS_PER_SENDER_PER_HOUR": str(
                settings["max_turns_per_sender_per_hour"]
            ),
            "AICHAT_MAX_DELIVERIES_PER_RECOVERY": str(
                settings["max_deliveries_per_recovery"]
            ),
            "CODEX_DRIVER": "app-server",
            "CODEX_TARGET_THREAD_ID": settings["target_thread_id"],
            "CODEX_CONNECTOR_TASK_OWNED": "true",
            "CODEX_CONNECTOR_TASK_MARKER": settings["task_marker"],
            "CODEX_APP_SERVER_CWD": settings["app_server_cwd"],
            "CODEX_APP_SERVER_APPROVAL_POLICY": "never",
            "CODEX_APP_SERVER_SANDBOX_POLICY_JSON": json.dumps(
                settings["sandbox_policy"], separators=(",", ":")
            ),
            "CODEX_DESKTOP_OWNER_IPC_ENABLED": "false",
        }
    )
    environment.update(
        {
            "AICHAT_EGRESS_CHANNEL_AUDIENCE_ACK": str(
                settings["egress"]["enabled"]
            ).lower(),
            "AICHAT_EGRESS_ALLOWED_REFERENCE_HOSTS": ",".join(
                settings["egress"]["allowed_reference_hosts"]
            ),
            "AICHAT_EGRESS_MAX_TEXT_BYTES": str(settings["egress"]["max_text_bytes"]),
        }
    )
    if settings["egress"]["enabled"]:
        environment["AICHAT_EGRESS_CANARY_FILE"] = settings["egress"]["canary_file"]
    if settings["codex_app_server_binary"]:
        environment["CODEX_APP_SERVER_BINARY"] = settings["codex_app_server_binary"]
    return environment


def main() -> int:
    args = parse_args()
    _, raw_settings = load_private_json(args.settings, "connector settings")
    settings = validate_settings(raw_settings)
    node = executable(args.node, "node binary")
    connector = regular_file(args.connector, "connector entrypoint")
    if args.check_settings:
        print("settings_ok=true")
        print("token_read=false")
        print(f"automatic_egress={str(settings['egress']['enabled']).lower()}")
        print(
            "lifecycle_status_enabled="
            f"{str(settings['egress']['lifecycle_status_enabled']).lower()}"
        )
        return 0

    _, identity = load_private_json(settings["identity_config_path"], "AIChat identity config")
    environment = build_environment(settings, identity)
    os.execve(node, [node, connector], environment)
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LaunchError as exc:
        print(f"aichat macOS launcher: {exc}", file=sys.stderr)
        raise SystemExit(1)
