"""Cross-platform configuration persistence for AIChat."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from platformdirs import user_config_dir

from .errors import ConfigurationError

APP_NAME = "AIChat"
APP_AUTHOR = "AIChat"
DEFAULT_SERVER = "http://127.0.0.1:8000"


def default_config_path() -> Path:
    """Return the platform-native AIChat configuration path."""

    override = os.environ.get("AICHAT_CONFIG_DIR")
    base = Path(override).expanduser() if override else Path(user_config_dir(APP_NAME, APP_AUTHOR))
    return base / "config.json"


def redact_token(token: str | None) -> str | None:
    """Return a recognizable but non-secret representation of a token."""

    if token is None:
        return None
    if len(token) <= 10:
        return "***"
    return f"{token[:4]}...{token[-4:]}"


@dataclass(slots=True)
class AIChatConfig:
    server: str = DEFAULT_SERVER
    token: str | None = None
    agent_id: str | None = None
    agent_name: str | None = None

    @classmethod
    def load(cls, path: str | Path | None = None) -> "AIChatConfig":
        config_path = Path(path).expanduser() if path is not None else default_config_path()
        if not config_path.exists():
            return cls()
        try:
            raw = json.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ConfigurationError(f"Cannot read AIChat config at {config_path}: {exc}") from exc
        if not isinstance(raw, dict):
            raise ConfigurationError(f"AIChat config at {config_path} must be a JSON object")
        supported: dict[str, Any] = {
            key: raw.get(key)
            for key in ("server", "token", "agent_id", "agent_name")
            if key in raw
        }
        return cls(**supported)

    def save(self, path: str | Path | None = None) -> Path:
        """Atomically save configuration, restricting permissions on POSIX."""

        config_path = Path(path).expanduser() if path is not None else default_config_path()
        try:
            config_path.parent.mkdir(parents=True, exist_ok=True)
            temporary = config_path.with_suffix(config_path.suffix + ".tmp")
            temporary.write_text(
                json.dumps(asdict(self), ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            if os.name == "posix":
                temporary.chmod(0o600)
            temporary.replace(config_path)
            if os.name == "posix":
                config_path.chmod(0o600)
        except OSError as exc:
            raise ConfigurationError(f"Cannot save AIChat config at {config_path}: {exc}") from exc
        return config_path

    @classmethod
    def resolve(
        cls,
        *,
        path: str | Path | None = None,
        server: str | None = None,
        token: str | None = None,
    ) -> "AIChatConfig":
        """Resolve CLI, environment, saved, and default settings in that order."""

        saved = cls.load(path)
        saved.server = server or os.environ.get("AICHAT_SERVER") or saved.server or DEFAULT_SERVER
        saved.token = token or os.environ.get("AICHAT_TOKEN") or saved.token
        return saved
