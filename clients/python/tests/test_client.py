from __future__ import annotations

import asyncio
import json

import httpx
import pytest

from aichat_client import AIChatClient, APIError, AuthenticationError


def test_register_sends_v0_payload_without_authorization() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/v1/agents/register"
        assert request.method == "POST"
        assert "Authorization" not in request.headers
        assert json.loads(request.content) == {
            "name": "mac-agent",
            "owner": "lab",
            "capabilities": ["git", "tests"],
        }
        return httpx.Response(200, json={"agent_id": "a1", "token": "secret", "name": "mac-agent"})

    with AIChatClient("https://relay.test", transport=httpx.MockTransport(handler)) as client:
        result = client.register_agent("mac-agent", owner="lab", capabilities=["git", "tests"])

    assert result["agent_id"] == "a1"


def test_send_message_uses_bearer_token_and_omits_empty_optional_fields() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["Authorization"] == "Bearer token-123"
        assert json.loads(request.content) == {
            "channel_id": "c1",
            "type": "request",
            "text": "Run the Windows tests",
            "references": ["https://example.test/commit/abc"],
            "idempotency_key": "job-1",
        }
        return httpx.Response(201, json={
            "id": "m1",
            "channel_id": "c1",
            "sender_id": "a1",
            "type": "request",
            "text": "Run the Windows tests",
            "reply_to": None,
            "references": ["https://example.test/commit/abc"],
            "idempotency_key": "job-1",
            "hop_count": 0,
            "created_at": "2026-08-24T08:03:00Z",
        })

    with AIChatClient(
        "https://relay.test/",
        token="token-123",
        transport=httpx.MockTransport(handler),
    ) as client:
        result = client.send_message(
            "c1",
            "Run the Windows tests",
            message_type="request",
            references=["https://example.test/commit/abc"],
            idempotency_key="job-1",
        )

    assert result["id"] == "m1"


def test_list_messages_passes_filters() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/v1/messages"
        assert dict(request.url.params) == {"limit": "25", "channel_id": "c1", "after": "m4"}
        return httpx.Response(200, json={"items": [], "next_after": None})

    with AIChatClient(
        "https://relay.test",
        token="token-123",
        transport=httpx.MockTransport(handler),
    ) as client:
        assert client.list_messages(channel_id="c1", after="m4", limit=25) == {
            "items": [],
            "next_after": None,
        }


def test_missing_token_fails_before_network_request() -> None:
    def handler(_: httpx.Request) -> httpx.Response:
        raise AssertionError("network should not be called")

    with AIChatClient("https://relay.test", transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(AuthenticationError, match="No AIChat token"):
            client.whoami()


def test_api_error_includes_server_detail() -> None:
    transport = httpx.MockTransport(
        lambda _: httpx.Response(409, json={"detail": "already joined"})
    )
    with AIChatClient("https://relay.test", token="bad", transport=transport) as client:
        with pytest.raises(APIError, match="HTTP 409: already joined") as caught:
            client.join_channel("c1")
    assert caught.value.status_code == 409


def test_forbidden_channel_is_not_reported_as_bad_credentials() -> None:
    transport = httpx.MockTransport(
        lambda _: httpx.Response(403, json={"detail": "Join the channel first"})
    )
    with AIChatClient("https://relay.test", token="valid", transport=transport) as client:
        with pytest.raises(APIError) as caught:
            client.list_messages(channel_id="private")
    assert not isinstance(caught.value, AuthenticationError)


def test_websocket_url_derivation() -> None:
    client = AIChatClient("https://relay.test/base", token="token")
    try:
        assert (
            client._websocket_url(None, token="secret token")
            == "wss://relay.test/base/v1/ws?token=secret+token"
        )
    finally:
        client.close()


def test_websocket_connection_error_does_not_expose_query_token() -> None:
    secret = "secret token/with symbols"

    async def receive_one() -> None:
        client = AIChatClient("https://relay.test", token=secret)
        try:
            stream = client.watch_messages_websocket(
                channel_id="c1",
                ws_url="not-a-websocket-url",
            )
            await anext(stream)
        finally:
            client.close()

    with pytest.raises(APIError) as caught:
        asyncio.run(receive_one())

    assert secret not in str(caught.value)
    assert "secret+token%2Fwith+symbols" not in str(caught.value)
    assert caught.value.__cause__ is None


def test_create_channel_matches_v0_shape() -> None:
    response = {
        "id": "c1",
        "name": "demo",
        "description": "Cross-platform test",
        "created_by": "a1",
        "created_at": "2026-08-24T08:03:00Z",
        "joined": True,
    }

    def handler(request: httpx.Request) -> httpx.Response:
        assert json.loads(request.content) == {
            "name": "demo",
            "description": "Cross-platform test",
        }
        return httpx.Response(201, json=response)

    with AIChatClient(
        "https://relay.test",
        token="token",
        transport=httpx.MockTransport(handler),
    ) as client:
        assert client.create_channel("demo", description="Cross-platform test") == response
