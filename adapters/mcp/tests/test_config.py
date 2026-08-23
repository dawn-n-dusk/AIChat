from __future__ import annotations

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


def test_config_defaults_to_loopback_relay() -> None:
    config = AdapterConfig.from_env({"AICHAT_TOKEN": "token"})
    assert config.server == DEFAULT_SERVER
    assert config.channel_id is None


def test_config_requires_token_without_revealing_any_value() -> None:
    with pytest.raises(AdapterConfigurationError, match="AICHAT_TOKEN is required"):
        AdapterConfig.from_env({})


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
def test_config_rejects_invalid_server(value: str) -> None:
    with pytest.raises(AdapterConfigurationError, match="AICHAT_SERVER"):
        AdapterConfig.from_env({"AICHAT_SERVER": value, "AICHAT_TOKEN": "token"})


@pytest.mark.parametrize("value", ["0", "-1", "nan", "inf", "-inf"])
def test_config_rejects_non_positive_or_non_finite_timeout(value: str) -> None:
    with pytest.raises(AdapterConfigurationError, match="AICHAT_TIMEOUT"):
        AdapterConfig.from_env({"AICHAT_TOKEN": "token", "AICHAT_TIMEOUT": value})


def test_resolve_channel_uses_argument_before_default() -> None:
    config = AdapterConfig("https://relay.test", "token", channel_id="default")
    assert config.resolve_channel("explicit") == "explicit"
    assert config.resolve_channel(None) == "default"


def test_resolve_channel_requires_a_value() -> None:
    config = AdapterConfig("https://relay.test", "token")
    with pytest.raises(AdapterConfigurationError, match="channel_id is required"):
        config.resolve_channel(None)
