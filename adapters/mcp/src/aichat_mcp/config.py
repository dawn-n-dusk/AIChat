"""Safe cross-platform configuration for the stdio adapter."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from platformdirs import user_config_dir


APP_NAME = "AIChat"
APP_AUTHOR = "AIChat"
DEFAULT_SERVER = "http://127.0.0.1:8000"
DEFAULT_TIMEOUT = 20.0


class AdapterConfigurationError(ValueError):
    """Raised when the MCP adapter cannot resolve safe relay settings."""


def default_config_path() -> Path:
    """Return the same platform-native config path used by the Python client."""

    return Path(user_config_dir(APP_NAME, APP_AUTHOR)) / "config.json"


def _read_config_file(path: Path, *, required: bool) -> dict[str, str]:
    if not path.exists():
        if required:
            raise AdapterConfigurationError("AICHAT_CONFIG does not reference a readable file")
        return {}

    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise AdapterConfigurationError(
            "Cannot read the AIChat JSON configuration file"
        ) from None
    if not isinstance(raw, dict):
        raise AdapterConfigurationError("The AIChat configuration file must be a JSON object")

    values: dict[str, str] = {}
    for key in ("server", "token"):
        value = raw.get(key)
        if value is None:
            continue
        if not isinstance(value, str):
            raise AdapterConfigurationError(
                f"The AIChat configuration field {key!r} must be a string"
            )
        values[key] = value.strip()

    channel_value: Any = raw.get("channel_id")
    if channel_value is None or (
        isinstance(channel_value, str) and not channel_value.strip()
    ):
        channel_value = raw.get("default_channel_id")
    if channel_value is not None:
        if not isinstance(channel_value, str):
            raise AdapterConfigurationError(
                "The AIChat configuration channel field must be a string"
            )
        values["channel_id"] = channel_value.strip()

    return values


@dataclass(frozen=True, slots=True)
class AdapterConfig:
    server: str
    token: str
    channel_id: str | None = None
    timeout: float = DEFAULT_TIMEOUT

    @classmethod
    def from_env(
        cls,
        environ: Mapping[str, str] | None = None,
        *,
        default_path: str | Path | None = None,
    ) -> "AdapterConfig":
        """Resolve explicit environment values, then the local JSON config file."""

        source = os.environ if environ is None else environ
        relevant_keys = ("AICHAT_SERVER", "AICHAT_TOKEN", "AICHAT_CHANNEL_ID")
        file_values: dict[str, str] = {}
        if any(key not in source for key in relevant_keys):
            explicit_path = source.get("AICHAT_CONFIG")
            if explicit_path is not None:
                if not explicit_path.strip():
                    raise AdapterConfigurationError("AICHAT_CONFIG cannot be empty")
                file_values = _read_config_file(
                    Path(explicit_path).expanduser(),
                    required=True,
                )
            else:
                config_path = (
                    Path(default_path).expanduser()
                    if default_path is not None
                    else default_config_path()
                )
                file_values = _read_config_file(config_path, required=False)

        server_value = (
            source["AICHAT_SERVER"].strip()
            if "AICHAT_SERVER" in source
            else file_values.get("server", DEFAULT_SERVER)
        )
        token = (
            source["AICHAT_TOKEN"].strip()
            if "AICHAT_TOKEN" in source
            else file_values.get("token", "")
        )
        channel_id = (
            source["AICHAT_CHANNEL_ID"].strip()
            if "AICHAT_CHANNEL_ID" in source
            else file_values.get("channel_id", "")
        ) or None
        timeout_value = source.get("AICHAT_TIMEOUT", str(DEFAULT_TIMEOUT)).strip()

        if not server_value:
            raise AdapterConfigurationError("AICHAT_SERVER cannot be empty")
        parsed_server = urlsplit(server_value)
        if parsed_server.scheme not in {"http", "https"} or not parsed_server.hostname:
            raise AdapterConfigurationError(
                "AICHAT_SERVER must be a valid http:// or https:// URL with a host"
            )
        if parsed_server.username is not None or parsed_server.password is not None:
            raise AdapterConfigurationError("AICHAT_SERVER must not contain credentials")
        if parsed_server.query or parsed_server.fragment:
            raise AdapterConfigurationError(
                "AICHAT_SERVER must not contain a query string or fragment"
            )
        server = urlunsplit(
            (
                parsed_server.scheme,
                parsed_server.netloc,
                parsed_server.path.rstrip("/"),
                "",
                "",
            )
        )
        if not token:
            raise AdapterConfigurationError(
                "AICHAT_TOKEN is required or a token must exist in the local AIChat config file"
            )
        try:
            timeout = float(timeout_value)
        except ValueError:
            raise AdapterConfigurationError("AICHAT_TIMEOUT must be a number") from None
        if not math.isfinite(timeout) or timeout <= 0:
            raise AdapterConfigurationError(
                "AICHAT_TIMEOUT must be a finite number greater than zero"
            )

        return cls(
            server=server,
            token=token,
            channel_id=channel_id,
            timeout=timeout,
        )

    def resolve_channel(self, channel_id: str | None) -> str:
        resolved = (channel_id or self.channel_id or "").strip()
        if not resolved:
            raise AdapterConfigurationError(
                "channel_id is required when no environment or config-file default is configured"
            )
        return resolved
