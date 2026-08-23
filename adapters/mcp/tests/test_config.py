from __future__ import annotations

import json

import pytest

from aichat_mcp.config import AdapterConfig, AdapterConfigurationError, DEFAULT_SERVER


def test_config_reads_required_and_optional_environment() -> None:
    config = AdapterConfig.from_env(
        {
            "AICHAT_SERVER": "https://relay.test/",
            "AICHAT_TOKEN": " token-123 ",
            "AICHAT_CHANNEL_ID": " c1 ",
            "AICHAT_TIMEOUT": "7.5",
        }
    )

    assert config == AdapterConfig(
        server="https://relay.test",
        token="token-123",
        channel_id="c1",
        timeout=7.5,
    )


def test_config_defaults_to_loopback_relay(tmp_path) -> None:
    config = AdapterConfig.from_env(
        {"AICHAT_TOKEN": "token"},
        default_path=tmp_path / "missing.json",
    )
    assert config.server == DEFAULT_SERVER
    assert config.channel_id is None


def test_config_requires_token_without_revealing_any_value(tmp_path) -> None:
    with pytest.raises(AdapterConfigurationError, match="AICHAT_TOKEN is required"):
        AdapterConfig.from_env({}, default_path=tmp_path / "missing.json")


def test_config_reads_explicit_json_file(tmp_path) -> None:
    path = tmp_path / "agent.json"
    path.write_text(
        json.dumps(
            {
                "server": "https://saved.test/base/",
                "token": " saved-token ",
                "channel_id": " saved-channel ",
                "agent_id": "ignored-agent",
            }
        ),
        encoding="utf-8",
    )

    config = AdapterConfig.from_env({"AICHAT_CONFIG": str(path)})

    assert config == AdapterConfig(
        server="https://saved.test/base",
        token="saved-token",
        channel_id="saved-channel",
    )


def test_config_reads_platform_default_and_default_channel_alias(tmp_path) -> None:
    path = tmp_path / "config.json"
    path.write_text(
        json.dumps(
            {
                "server": "https://saved.test",
                "token": "saved-token",
                "default_channel_id": "saved-default",
            }
        ),
        encoding="utf-8",
    )

    config = AdapterConfig.from_env({}, default_path=path)

    assert config.channel_id == "saved-default"


def test_environment_fields_override_file_independently(tmp_path) -> None:
    path = tmp_path / "config.json"
    path.write_text(
        json.dumps(
            {
                "server": "https://saved.test",
                "token": "saved-token",
                "channel_id": "saved-channel",
            }
        ),
        encoding="utf-8",
    )

    config = AdapterConfig.from_env(
        {
            "AICHAT_CONFIG": str(path),
            "AICHAT_SERVER": "https://env.test/",
            "AICHAT_TOKEN": "env-token",
        }
    )

    assert config == AdapterConfig(
        server="https://env.test",
        token="env-token",
        channel_id="saved-channel",
    )


def test_explicit_empty_token_does_not_fall_back_to_file(tmp_path) -> None:
    secret = "saved-secret-that-must-not-leak"
    path = tmp_path / "config.json"
    path.write_text(
        json.dumps({"server": "https://saved.test", "token": secret}),
        encoding="utf-8",
    )

    with pytest.raises(AdapterConfigurationError) as caught:
        AdapterConfig.from_env({"AICHAT_CONFIG": str(path), "AICHAT_TOKEN": ""})

    assert secret not in str(caught.value)


def test_complete_environment_does_not_read_config_file(tmp_path) -> None:
    path = tmp_path / "broken.json"
    path.write_text("not JSON and must not be read", encoding="utf-8")

    config = AdapterConfig.from_env(
        {
            "AICHAT_CONFIG": str(path),
            "AICHAT_SERVER": "https://env.test",
            "AICHAT_TOKEN": "env-token",
            "AICHAT_CHANNEL_ID": "",
        }
    )

    assert config.channel_id is None


def test_invalid_json_error_does_not_leak_file_values_or_path(tmp_path) -> None:
    secret = "secret-that-must-not-leak"
    path = tmp_path / "private-agent.json"
    path.write_text(f'{{"token":"{secret}"', encoding="utf-8")

    with pytest.raises(AdapterConfigurationError) as caught:
        AdapterConfig.from_env({"AICHAT_CONFIG": str(path)})

    rendered = str(caught.value)
    assert secret not in rendered
    assert str(path) not in rendered


def test_invalid_config_type_does_not_leak_value(tmp_path) -> None:
    secret = "secret-that-must-not-leak"
    path = tmp_path / "config.json"
    path.write_text(
        json.dumps({"server": {"private": secret}, "token": "token"}),
        encoding="utf-8",
    )

    with pytest.raises(AdapterConfigurationError) as caught:
        AdapterConfig.from_env({"AICHAT_CONFIG": str(path)})

    assert secret not in str(caught.value)


def test_missing_explicit_config_error_does_not_leak_path(tmp_path) -> None:
    path = tmp_path / "private-missing.json"

    with pytest.raises(AdapterConfigurationError) as caught:
        AdapterConfig.from_env({"AICHAT_CONFIG": str(path)})

    assert str(path) not in str(caught.value)


@pytest.mark.parametrize(
    "value",
    [
        "relay.test",
        "ftp://relay.test",
        "http://",
        "https://user:pass@relay.test",
        "https://relay.test?token=secret",
        "https://relay.test/#fragment",
        "",
    ],
)
def test_config_rejects_invalid_server(value: str, tmp_path) -> None:
    with pytest.raises(AdapterConfigurationError, match="AICHAT_SERVER"):
        AdapterConfig.from_env(
            {
                "AICHAT_SERVER": value,
                "AICHAT_TOKEN": "token",
                "AICHAT_CHANNEL_ID": "",
            },
            default_path=tmp_path / "missing.json",
        )


@pytest.mark.parametrize("value", ["0", "-1", "nan", "inf", "-inf"])
def test_config_rejects_non_positive_or_non_finite_timeout(value: str, tmp_path) -> None:
    with pytest.raises(AdapterConfigurationError, match="AICHAT_TIMEOUT"):
        AdapterConfig.from_env(
            {"AICHAT_TOKEN": "token", "AICHAT_TIMEOUT": value},
            default_path=tmp_path / "missing.json",
        )


def test_resolve_channel_uses_argument_before_default() -> None:
    config = AdapterConfig("https://relay.test", "token", channel_id="default")
    assert config.resolve_channel("explicit") == "explicit"
    assert config.resolve_channel(None) == "default"


def test_resolve_channel_requires_a_value() -> None:
    config = AdapterConfig("https://relay.test", "token")
    with pytest.raises(AdapterConfigurationError, match="channel_id is required"):
        config.resolve_channel(None)
