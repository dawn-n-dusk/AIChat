from __future__ import annotations

import json
import os

from aichat_client.config import AIChatConfig, redact_token


def test_config_round_trip(tmp_path) -> None:
    path = tmp_path / "nested" / "config.json"
    original = AIChatConfig(
        server="https://relay.test",
        token="very-secret-token",
        agent_id="a1",
        agent_name="mac-agent",
    )

    assert original.save(path) == path
    assert AIChatConfig.load(path) == original
    assert json.loads(path.read_text())["token"] == "very-secret-token"
    if os.name == "posix":
        assert path.stat().st_mode & 0o777 == 0o600


def test_environment_overrides_saved_config(tmp_path, monkeypatch) -> None:
    path = tmp_path / "config.json"
    AIChatConfig(server="https://saved.test", token="saved").save(path)
    monkeypatch.setenv("AICHAT_SERVER", "https://env.test")
    monkeypatch.setenv("AICHAT_TOKEN", "env-token")

    resolved = AIChatConfig.resolve(path=path)

    assert resolved.server == "https://env.test"
    assert resolved.token == "env-token"


def test_token_redaction() -> None:
    assert redact_token("1234567890abcdef") == "1234...cdef"
    assert redact_token("short") == "***"
    assert redact_token(None) is None
