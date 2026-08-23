"""Reusable synchronous SDK for the AIChat V0 relay API."""

from __future__ import annotations

import json
import inspect
import time
from collections.abc import AsyncIterator, Iterator, Sequence
from typing import Any, Literal
from urllib.parse import parse_qsl, quote_plus, urlencode, urlsplit, urlunsplit

import httpx

from .errors import APIError, AuthenticationError, ConfigurationError

JsonObject = dict[str, Any]
MessageType = Literal["text", "request", "result", "status"]


class AIChatClient:
    """A small client for AIChat's HTTP API and optional WebSocket stream."""

    def __init__(
        self,
        server: str,
        *,
        token: str | None = None,
        timeout: float = 20.0,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        if not server or not server.strip():
            raise ConfigurationError("AIChat server URL cannot be empty")
        self.server = server.rstrip("/")
        self.token = token
        # Relay bearer tokens must not be forwarded through ambient shell or OS
        # proxy configuration. Call the explicitly configured relay directly.
        self._http = httpx.Client(timeout=timeout, transport=transport, trust_env=False)

    def __enter__(self) -> "AIChatClient":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def close(self) -> None:
        self._http.close()

    def register_agent(
        self,
        name: str,
        *,
        owner: str | None = None,
        capabilities: Sequence[str] | None = None,
    ) -> JsonObject:
        payload: JsonObject = {"name": name}
        if owner is not None:
            payload["owner"] = owner
        if capabilities:
            payload["capabilities"] = list(capabilities)
        return self._request("POST", "/v1/agents/register", json_body=payload, authenticated=False)

    def whoami(self) -> JsonObject:
        return self._request("GET", "/v1/me")

    def create_channel(self, name: str, *, description: str | None = None) -> JsonObject:
        payload: JsonObject = {"name": name}
        if description is not None:
            payload["description"] = description
        return self._request("POST", "/v1/channels", json_body=payload)

    def join_channel(self, channel_id: str) -> JsonObject:
        return self._request("POST", f"/v1/channels/{channel_id}/join", json_body={})

    def send_message(
        self,
        channel_id: str,
        text: str,
        *,
        message_type: MessageType = "text",
        reply_to: str | None = None,
        references: Sequence[str] | None = None,
        idempotency_key: str | None = None,
    ) -> JsonObject:
        payload: JsonObject = {
            "channel_id": channel_id,
            "type": message_type,
            "text": text,
        }
        if reply_to is not None:
            payload["reply_to"] = reply_to
        if references:
            payload["references"] = list(references)
        if idempotency_key is not None:
            payload["idempotency_key"] = idempotency_key
        return self._request("POST", "/v1/messages", json_body=payload)

    def list_messages(
        self,
        *,
        channel_id: str,
        after: str | None = None,
        limit: int = 50,
    ) -> JsonObject:
        params: dict[str, str | int] = {"limit": limit}
        params["channel_id"] = channel_id
        if after is not None:
            params["after"] = after
        return self._request("GET", "/v1/messages", params=params)

    def watch_messages(
        self,
        *,
        channel_id: str,
        after: str | None = None,
        interval: float = 2.0,
        limit: int = 50,
    ) -> Iterator[JsonObject]:
        """Poll for messages forever, yielding each item as it arrives."""

        if interval < 0:
            raise ConfigurationError("Watch interval cannot be negative")
        cursor = after
        while True:
            page = self.list_messages(channel_id=channel_id, after=cursor, limit=limit)
            items = page.get("items", [])
            if not isinstance(items, list):
                raise APIError("AIChat returned an invalid message page: 'items' is not a list")
            for item in items:
                if isinstance(item, dict):
                    yield item
            next_after = page.get("next_after")
            if next_after is not None:
                cursor = str(next_after)
            elif items and isinstance(items[-1], dict) and items[-1].get("id") is not None:
                cursor = str(items[-1]["id"])
            time.sleep(interval)

    async def watch_messages_websocket(
        self,
        *,
        channel_id: str,
        after: str | None = None,
        ws_url: str | None = None,
    ) -> AsyncIterator[JsonObject]:
        """Yield events from the optional `/v1/ws` WebSocket endpoint."""

        token = self._require_token()
        try:
            from websockets.asyncio.client import connect
            from websockets.exceptions import WebSocketException
        except ImportError as exc:
            raise ConfigurationError(
                "WebSocket support is not installed; run "
                "`python -m pip install 'aichat-client[websocket]'`"
            ) from exc

        target = self._websocket_url(ws_url, token=token)
        try:
            connect_options: dict[str, object] = {}
            # websockets 15+ added automatic proxy discovery. Older supported
            # versions have no `proxy` parameter and don't auto-proxy, so gate
            # this keyword by signature for compatibility across 14-16.
            if "proxy" in inspect.signature(connect).parameters:
                connect_options["proxy"] = None
            async with connect(target, **connect_options) as websocket:
                seen: set[str] = set()
                cursor = after
                while True:
                    page = self.list_messages(channel_id=channel_id, after=cursor, limit=200)
                    items = page.get("items", [])
                    if not isinstance(items, list):
                        raise APIError("AIChat returned an invalid message page: 'items' is not a list")
                    for item in items:
                        if not isinstance(item, dict):
                            continue
                        message_id = item.get("id")
                        if message_id is not None:
                            seen.add(str(message_id))
                        yield {"event": "message.created", "message": item}
                    next_after = page.get("next_after")
                    if not items or next_after is None or str(next_after) == cursor:
                        break
                    cursor = str(next_after)

                async for raw in websocket:
                    if not isinstance(raw, str):
                        continue
                    try:
                        event = json.loads(raw)
                    except json.JSONDecodeError as exc:
                        raise APIError("AIChat WebSocket returned invalid JSON") from exc
                    if not isinstance(event, dict):
                        continue
                    message = event.get("message")
                    if not isinstance(message, dict) or message.get("channel_id") != channel_id:
                        continue
                    message_id = message.get("id")
                    if message_id is not None and str(message_id) in seen:
                        continue
                    if message_id is not None:
                        seen.add(str(message_id))
                    yield event
        except (OSError, TimeoutError, ValueError, WebSocketException) as exc:
            reason = str(exc).replace(token, "***").replace(quote_plus(token), "***")
            suffix = f": {reason}" if reason else ""
            # Suppress the original exception because some WebSocket libraries include
            # the full query-bearing URL (and therefore the token) in its traceback.
            raise APIError(f"AIChat WebSocket connection failed{suffix}") from None

    def _request(
        self,
        method: str,
        path: str,
        *,
        json_body: JsonObject | None = None,
        params: dict[str, str | int] | None = None,
        authenticated: bool = True,
    ) -> JsonObject:
        headers: dict[str, str] = {"Accept": "application/json"}
        if authenticated:
            headers["Authorization"] = f"Bearer {self._require_token()}"
        url = f"{self.server}{path}"
        try:
            response = self._http.request(
                method,
                url,
                headers=headers,
                json=json_body,
                params=params,
            )
        except httpx.HTTPError as exc:
            raise APIError(f"Cannot reach AIChat server at {self.server}: {exc}") from exc

        if not response.is_success:
            details: Any
            try:
                details = response.json()
            except ValueError:
                details = response.text.strip() or None
            detail_message = self._error_detail(details)
            message = f"AIChat API {method} {path} failed with HTTP {response.status_code}"
            if detail_message:
                message = f"{message}: {detail_message}"
            error_type = AuthenticationError if response.status_code == 401 else APIError
            raise error_type(message, status_code=response.status_code, details=details)

        if response.status_code == 204 or not response.content:
            return {}
        try:
            data = response.json()
        except ValueError as exc:
            raise APIError(f"AIChat API {method} {path} returned invalid JSON") from exc
        if not isinstance(data, dict):
            raise APIError(f"AIChat API {method} {path} returned a non-object JSON response")
        return data

    def _require_token(self) -> str:
        if not self.token:
            raise AuthenticationError(
                "No AIChat token configured. Run `aichat register ...` or set AICHAT_TOKEN."
            )
        return self.token

    def _websocket_url(
        self,
        explicit: str | None,
        *,
        token: str,
    ) -> str:
        base = explicit or f"{self.server}/v1/ws"
        parts = urlsplit(base)
        scheme = {"http": "ws", "https": "wss"}.get(parts.scheme, parts.scheme)
        query = dict(parse_qsl(parts.query, keep_blank_values=True))
        query["token"] = token
        return urlunsplit((scheme, parts.netloc, parts.path, urlencode(query), parts.fragment))

    @staticmethod
    def _error_detail(details: Any) -> str | None:
        if isinstance(details, dict):
            value = details.get("detail") or details.get("error") or details.get("message")
            return str(value) if value is not None else None
        if details is not None:
            return str(details)
        return None
