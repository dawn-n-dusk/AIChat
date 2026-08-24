from __future__ import annotations

import asyncio
import json
import logging

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.database import transaction
from app.main import ConnectionManager, create_app, token_hash
from app.security import FixedWindowRateLimiter, RuntimeSettings, client_address_from_scope


def test_local_defaults_preserve_v0_and_lockdown_defaults_fail_closed() -> None:
    local = RuntimeSettings.from_env({})
    assert local.docs_enabled is True
    assert local.agent_registration_enabled is True
    assert local.channel_create_enabled is True
    assert local.channel_join_enabled is True
    assert local.http_rate_limit_per_minute == 0
    assert local.websocket_handshake_rate_limit_per_minute == 0
    assert local.websocket_max_connections == 0
    assert local.websocket_max_connections_per_agent == 0

    locked = RuntimeSettings.from_env({"AICHAT_PRODUCTION_LOCKDOWN": "true"})
    assert locked.docs_enabled is False
    assert locked.agent_registration_enabled is False
    assert locked.channel_create_enabled is False
    assert locked.channel_join_enabled is False
    assert locked.http_rate_limit_per_minute == 120
    assert locked.websocket_handshake_rate_limit_per_minute == 30
    assert locked.websocket_max_connections == 128
    assert locked.websocket_max_connections_per_agent == 4


def test_lockdown_disables_docs_registration_channel_create_and_join(
    tmp_path, monkeypatch, caplog
) -> None:
    database = tmp_path / "locked.db"
    monkeypatch.setenv("AICHAT_DB_PATH", str(database))
    settings = RuntimeSettings.from_env({"AICHAT_PRODUCTION_LOCKDOWN": "true"})
    secret = "lockdown-test-token-that-must-not-be-logged"

    caplog.set_level(logging.DEBUG)
    with TestClient(create_app(settings)) as client:
        assert client.get("/docs").status_code == 404
        assert client.get("/redoc").status_code == 404
        assert client.get("/openapi.json").status_code == 404

        registration = client.post("/v1/agents/register", json={"name": "blocked"})
        assert registration.status_code == 403
        assert registration.json() == {
            "detail": "Agent registration is disabled by the relay operator"
        }

        with transaction() as connection:
            connection.execute(
                "INSERT INTO agents (id, name, owner, capabilities, token_hash, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                ("locked-agent", "Locked", None, json.dumps([]), token_hash(secret), "now"),
            )

        headers = {"Authorization": f"Bearer {secret}"}
        creation = client.post("/v1/channels", headers=headers, json={"name": "blocked"})
        assert creation.status_code == 403
        assert creation.json() == {
            "detail": "Channel creation is disabled by the relay operator"
        }

        joining = client.post("/v1/channels/arbitrary/join", headers=headers)
        assert joining.status_code == 403
        assert joining.json() == {
            "detail": "Channel joining is disabled by the relay operator"
        }

    assert secret not in caplog.text


def test_feature_overrides_can_open_a_private_bootstrap_window(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("AICHAT_DB_PATH", str(tmp_path / "bootstrap.db"))
    settings = RuntimeSettings.from_env(
        {
            "AICHAT_PRODUCTION_LOCKDOWN": "true",
            "AICHAT_AGENT_REGISTRATION_ENABLED": "true",
            "AICHAT_CHANNEL_CREATE_ENABLED": "true",
            "AICHAT_CHANNEL_JOIN_ENABLED": "true",
        }
    )
    with TestClient(create_app(settings)) as client:
        agent = client.post("/v1/agents/register", json={"name": "bootstrap"})
        assert agent.status_code == 201
        channel = client.post(
            "/v1/channels",
            headers={"Authorization": f"Bearer {agent.json()['token']}"},
            json={"name": "bootstrap"},
        )
        assert channel.status_code == 201


def test_client_address_only_trusts_forwarding_from_configured_proxies() -> None:
    networks = RuntimeSettings.from_env({}).trusted_proxy_networks
    trusted_scope = {
        "client": ("127.0.0.1", 50000),
        "headers": [(b"x-forwarded-for", b"203.0.113.9, 198.51.100.20")],
    }
    assert client_address_from_scope(trusted_scope, networks) == "198.51.100.20"

    untrusted_scope = {
        "client": ("198.51.100.30", 50000),
        "headers": [(b"x-forwarded-for", b"203.0.113.99")],
    }
    assert client_address_from_scope(untrusted_scope, networks) == "198.51.100.30"

    invalid_chain = {
        "client": ("127.0.0.1", 50000),
        "headers": [(b"x-forwarded-for", b"not-an-ip, 198.51.100.20")],
    }
    assert client_address_from_scope(invalid_chain, networks) == "127.0.0.1"


def test_http_rate_limit_returns_429_without_logging_authorization(tmp_path, monkeypatch, caplog) -> None:
    monkeypatch.setenv("AICHAT_DB_PATH", str(tmp_path / "rate.db"))
    settings = RuntimeSettings.from_env({"AICHAT_HTTP_RATE_LIMIT_PER_MINUTE": "2"})
    secret = "rate-limit-token-that-must-not-be-logged"
    caplog.set_level(logging.DEBUG)

    with TestClient(create_app(settings)) as client:
        headers = {"Authorization": f"Bearer {secret}"}
        assert client.get("/health", headers=headers).status_code == 200
        assert client.get("/health", headers=headers).status_code == 200
        limited = client.get("/health", headers=headers)

    assert limited.status_code == 429
    assert limited.json() == {"detail": "HTTP request rate limit exceeded"}
    assert int(limited.headers["Retry-After"]) >= 1
    assert secret not in caplog.text


def test_fixed_window_limiter_resets_and_bounds_tracked_clients() -> None:
    current = [0.0]
    limiter = FixedWindowRateLimiter(1, clock=lambda: current[0], max_tracked_clients=2)
    assert limiter.check("one").allowed is True
    assert limiter.check("one").allowed is False
    limiter.check("two")
    limiter.check("three")
    assert len(limiter._entries) == 2
    current[0] = 61.0
    assert limiter.check("one").allowed is True


class FakeWebSocket:
    def __init__(self) -> None:
        self.accepted = False

    async def accept(self) -> None:
        self.accepted = True

    async def send_json(self, _: dict) -> None:
        return None


def test_connection_manager_enforces_global_and_per_agent_limits() -> None:
    async def exercise() -> None:
        manager = ConnectionManager(max_connections=2, max_connections_per_agent=1)
        first = FakeWebSocket()
        duplicate = FakeWebSocket()
        second = FakeWebSocket()
        overflow = FakeWebSocket()

        assert await manager.connect("agent-one", first) is None
        assert first.accepted is True
        assert "per-agent" in (await manager.connect("agent-one", duplicate) or "")
        assert duplicate.accepted is False
        assert await manager.connect("agent-two", second) is None
        assert "global" in (await manager.connect("agent-three", overflow) or "")
        assert overflow.accepted is False

        await manager.disconnect("agent-one", first)
        assert await manager.connect("agent-three", overflow) is None
        assert overflow.accepted is True

    asyncio.run(exercise())


def test_websocket_handshake_rate_limit_closes_safely_without_logging_token(
    tmp_path, monkeypatch, caplog
) -> None:
    monkeypatch.setenv("AICHAT_DB_PATH", str(tmp_path / "websocket-rate.db"))
    settings = RuntimeSettings.from_env(
        {"AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE": "1"}
    )
    first_secret = "first-websocket-token-that-must-not-be-logged"
    second_secret = "second-websocket-token-that-must-not-be-logged"
    caplog.set_level(logging.DEBUG)

    with TestClient(create_app(settings)) as client:
        with pytest.raises(WebSocketDisconnect) as invalid:
            with client.websocket_connect(f"/v1/ws?token={first_secret}"):
                pass
        assert invalid.value.code == 1008

        with pytest.raises(WebSocketDisconnect) as limited:
            with client.websocket_connect(f"/v1/ws?token={second_secret}"):
                pass
        assert limited.value.code == 1013

    assert first_secret not in caplog.text
    assert second_secret not in caplog.text
