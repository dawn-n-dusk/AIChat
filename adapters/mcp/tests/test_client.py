from __future__ import annotations

import json

import httpx
import pytest

from aichat_mcp.client import AIChatAPI, AIChatAPIError
from aichat_mcp.config import AdapterConfig


@pytest.mark.asyncio
async def test_whoami_uses_bearer_token() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/v1/me"
        assert request.headers["Authorization"] == "Bearer token-123"
        return httpx.Response(200, json={"agent_id": "a1", "name": "codex"})

    api = AIChatAPI(
        AdapterConfig("https://relay.test", "token-123"),
        transport=httpx.MockTransport(handler),
    )
    assert await api.whoami() == {"agent_id": "a1", "name": "codex"}


@pytest.mark.asyncio
async def test_list_messages_sends_cursor_and_limit() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        assert dict(request.url.params) == {
            "channel_id": "c1",
            "limit": "25",
            "after": "m4",
        }
        return httpx.Response(200, json={"items": [], "next_after": "m4"})

    api = AIChatAPI(
        AdapterConfig("https://relay.test", "token"),
        transport=httpx.MockTransport(handler),
    )
    assert await api.list_messages("c1", after="m4", limit=25) == {
        "items": [],
        "next_after": "m4",
    }


@pytest.mark.asyncio
async def test_send_message_matches_protocol_shape() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        assert json.loads(request.content) == {
            "channel_id": "c1",
            "type": "request",
            "text": "Please test commit abc",
            "hop_count": 1,
            "reply_to": "m1",
            "references": ["https://example.test/commit/abc"],
            "idempotency_key": "test-abc",
        }
        return httpx.Response(201, json={"id": "m2"})

    api = AIChatAPI(
        AdapterConfig("https://relay.test", "token"),
        transport=httpx.MockTransport(handler),
    )
    result = await api.send_message(
        "c1",
        "Please test commit abc",
        message_type="request",
        reply_to="m1",
        references=["https://example.test/commit/abc"],
        idempotency_key="test-abc",
        hop_count=1,
    )
    assert result == {"id": "m2"}


@pytest.mark.asyncio
async def test_join_channel_url_quotes_opaque_id() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.raw_path == b"/v1/channels/channel%2Fwith%20spaces/join"
        return httpx.Response(200, json={"id": "channel/with spaces"})

    api = AIChatAPI(
        AdapterConfig("https://relay.test", "token"),
        transport=httpx.MockTransport(handler),
    )
    assert (await api.join_channel("channel/with spaces"))["id"] == "channel/with spaces"


@pytest.mark.asyncio
async def test_server_error_redacts_token_from_message_and_details() -> None:
    token = "secret token/with symbols"

    async def handler(_: httpx.Request) -> httpx.Response:
        return httpx.Response(
            401,
            json={"detail": f"bad {token} secret+token%2Fwith+symbols"},
        )

    api = AIChatAPI(
        AdapterConfig("https://relay.test", token),
        transport=httpx.MockTransport(handler),
    )
    with pytest.raises(AIChatAPIError) as caught:
        await api.whoami()

    rendered = f"{caught.value} {caught.value.details}"
    assert token not in rendered
    assert "secret+token%2Fwith+symbols" not in rendered


@pytest.mark.asyncio
async def test_success_response_cannot_echo_token_into_tool_context() -> None:
    token = "must-not-enter-context"
    api = AIChatAPI(
        AdapterConfig("https://relay.test", token),
        transport=httpx.MockTransport(
            lambda _: httpx.Response(
                200,
                json={"agent_id": "a1", "unexpected": token},
            )
        ),
    )
    result = await api.whoami()
    assert token not in repr(result)
    assert result["unexpected"] == "[REDACTED]"


@pytest.mark.asyncio
async def test_non_object_response_is_rejected() -> None:
    api = AIChatAPI(
        AdapterConfig("https://relay.test", "token"),
        transport=httpx.MockTransport(lambda _: httpx.Response(200, json=[])),
    )
    with pytest.raises(AIChatAPIError, match="non-object"):
        await api.whoami()
