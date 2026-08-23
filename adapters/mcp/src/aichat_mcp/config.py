"""Environment-only configuration for the stdio adapter."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
import math
import os
from urllib.parse import urlsplit, urlunsplit


DEFAULT_SERVER = "http://127.0.0.1:8000"
DEFAULT_TIMEOUT = 20.0


class AdapterConfigurationError(ValueError):
    """Raised when the MCP adapter cannot resolve safe relay settings."""


@dataclass(frozen=True, slots=True)
class AdapterConfig:
    server: str
    token: str
    channel_id: str | None = None
    timeout: float = DEFAULT_TIMEOUT

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> "AdapterConfig":
        source = os.environ if environ is None else environ
        server_value = source.get("AICHAT_SERVER", DEFAULT_SERVER).strip()
        token = source.get("AICHAT_TOKEN", "").strip()
        channel_id = source.get("AICHAT_CHANNEL_ID", "").strip() or None
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
                "AICHAT_TOKEN is required; register an AIChat agent and keep its token local"
            )
        try:
            timeout = float(timeout_value)
        except ValueError as exc:
            raise AdapterConfigurationError("AICHAT_TIMEOUT must be a number") from exc
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
                "channel_id is required when AICHAT_CHANNEL_ID is not configured"
            )
        return resolved
