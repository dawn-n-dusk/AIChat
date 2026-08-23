from __future__ import annotations

import json

from aichat_client import cli


class FakeClient:
    def __init__(self, server: str, *, token: str | None = None) -> None:
        self.server = server
        self.token = token

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return None

    def register_agent(self, name, *, owner=None, capabilities=None):
        return {
            "agent_id": "agent-1",
            "token": "full-token-that-must-not-leak",
            "name": name,
        }

    def whoami(self):
        return {"agent_id": "agent-1", "name": "mac-agent"}


def test_register_saves_token_but_redacts_stdout(tmp_path, monkeypatch, capsys) -> None:
    config_path = tmp_path / "config.json"
    monkeypatch.setattr(cli, "AIChatClient", FakeClient)

    result = cli.run(
        [
            "--server",
            "https://relay.test",
            "--config",
            str(config_path),
            "register",
            "mac-agent",
        ]
    )

    output = capsys.readouterr().out
    shown = json.loads(output)
    saved = json.loads(config_path.read_text())
    assert result == 0
    assert shown["token"] == "full...leak"
    assert "full-token-that-must-not-leak" not in output
    assert saved["token"] == "full-token-that-must-not-leak"


def test_whoami_uses_environment_token(tmp_path, monkeypatch, capsys) -> None:
    monkeypatch.setattr(cli, "AIChatClient", FakeClient)
    monkeypatch.setenv("AICHAT_TOKEN", "from-environment")

    assert cli.run(["--config", str(tmp_path / "missing.json"), "whoami"]) == 0
    assert json.loads(capsys.readouterr().out)["agent_id"] == "agent-1"


def test_no_save_requires_explicit_show_token(tmp_path, monkeypatch, capsys) -> None:
    config_path = tmp_path / "config.json"
    monkeypatch.setattr(cli, "AIChatClient", FakeClient)

    result = cli.run(
        ["--config", str(config_path), "register", "ephemeral-agent", "--no-save"]
    )

    captured = capsys.readouterr()
    assert result == 1
    assert captured.out == ""
    assert "--no-save requires --show-token" in captured.err
    assert "full-token-that-must-not-leak" not in captured.err
    assert not config_path.exists()


def test_explicit_show_token_can_return_unsaved_token(tmp_path, monkeypatch, capsys) -> None:
    config_path = tmp_path / "config.json"
    monkeypatch.setattr(cli, "AIChatClient", FakeClient)

    result = cli.run(
        [
            "--config",
            str(config_path),
            "register",
            "ephemeral-agent",
            "--no-save",
            "--show-token",
        ]
    )

    captured = capsys.readouterr()
    assert result == 0
    assert json.loads(captured.out)["token"] == "full-token-that-must-not-leak"
    assert captured.err == ""
    assert not config_path.exists()


def test_show_token_is_never_enabled_for_other_commands(monkeypatch, capsys) -> None:
    value = {
        "token": "full-token-that-must-not-leak",
        "nested": {"authorization": "full-token-that-must-not-leak"},
    }

    cli._print_json(value)

    output = capsys.readouterr().out
    assert "full-token-that-must-not-leak" not in output
    assert json.loads(output) == {
        "token": "full...leak",
        "nested": {"authorization": "full...leak"},
    }
