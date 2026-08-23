"""Independent HTTP client for the AIChat V0 relay contract."""

from __future__ import annotations

from typing import Any
from urllib.parse import quote, quote_plus

import httpx

from .config import AdapterConfig


JsonObject = dict[str, Any]


class AIChatAPIError(RuntimeError):
    """A sanitized relay or transport error suitable for an MCP tool result."""

    def __init__(
        self,
        message: str,
        *,
        status_code: int | None = None,
        details: Any = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.details = details


class AIChatAPI:
    """Minimal async client used only by the MCP adapter package."""

    def __init__(
        self,
        config: AdapterConfig,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.config = config
        self._transport = transport

    async def whoami(self) -> JsonObject:
        return await self._request("GET", "/v1/me")

    async def create_channel(
        self,
        name: str,
        *,
        description: str | None = None,
    ) -> JsonObject:
        payload: JsonObject = {"name": name}
        if description is not None:
            payload["description"] = description
        return await self._request("POST", "/v1/channels", json_body=payload)

    async def join_channel(self, channel_id: str) -> JsonObject:
        return await self._request(
            "POST",
            f"/v1/channels/{quote(channel_id, safe='')}/join",
            json_body={},
        )

    async def list_messages(
        self,
        channel_id: str,
        *,
        after: str | None = None,
        limit: int = 50,
    ) -> JsonObject:
        params: dict[str, str | int] = {"channel_id": channel_id, "limit": limit}
        if after is not None:
            params["after"] = after
        return await self._request("GET", "/v1/messages", params=params)

    async def send_message(
        self,
        channel_id: str,
        text: str,
        *,
        message_type: str = "text",
        reply_to: str | None = None,
        references: list[str] | None = None,
        idempotency_key: str | None = None,
        hop_count: int = 0,
    ) -> JsonObject:
        payload: JsonObject = {
            "channel_id": channel_id,
            "type": message_type,
            "text": text,
            "hop_count": hop_count,
        }
        if reply_to is not None:
            payload["reply_to"] = reply_to
        if references:
            payload["references"] = references
        if idempotency_key is not None:
            payload["idempotency_key"] = idempotency_key
        return await self._request("POST", "/v1/messages", json_body=payload)

    async def _request(
        self,
        method: str,
        path: str,
        *,
        json_body: JsonObject | None = None,
        params: dict[str, str | int] | None = None,
    ) -> JsonObject:
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self.config.token}",
        }
        try:
            async with httpx.AsyncClient(
                timeout=self.config.timeout,
                transport=self._transport,
                # Do not forward the bearer token through ambient OS/shell proxies.
                # LAN and loopback relay URLs must be contacted directly.
                trust_env=False,
            ) as client:
                response = await client.request(
                    method,
                    f"{self.config.server}{path}",
                    headers=headers,
                    json=json_body,
                    params=params,
                )
        except httpx.HTTPError as exc:
            reason = self._redact(str(exc))
            suffix = f": {reason}" if reason else ""
            raise AIChatAPIError(
                f"Cannot reach AIChat server at {self.config.server}{suffix}"
            ) from None

        if not response.is_success:
            try:
                details: Any = response.json()
            except ValueError:
                details = response.text.strip() or None
            details = self._redact_value(details)
            detail_message = self._error_detail(details)
            message = f"AIChat API {method} {path} failed with HTTP {response.status_code}"
            if detail_message:
                message = f"{message}: {detail_message}"
            raise AIChatAPIError(
                message,
                status_code=response.status_code,
                details=details,
            )

        if response.status_code == 204 or not response.content:
            return {}
        try:
            data = response.json()
        except ValueError:
            raise AIChatAPIError(
                f"AIChat API {method} {path} returned invalid JSON"
            ) from None
        if not isinstance(data, dict):
            raise AIChatAPIError(
                f"AIChat API {method} {path} returned a non-object JSON response"
            )
        return self._redact_value(data)

    def _redact(self, value: str) -> str:
        token = self.config.token
        redacted = value.replace(token, "[REDACTED]")
        redacted = redacted.replace(quote(token, safe=""), "[REDACTED]")
        return redacted.replace(quote_plus(token), "[REDACTED]")

    def _redact_value(self, value: Any) -> Any:
        if isinstance(value, str):
            return self._redact(value)
        if isinstance(value, list):
            return [self._redact_value(item) for item in value]
        if isinstance(value, dict):
            return {
                self._redact(str(key)): self._redact_value(item)
                for key, item in value.items()
            }
        return value

    @staticmethod
    def _error_detail(details: Any) -> str | None:
        if isinstance(details, dict):
            value = details.get("detail") or details.get("error") or details.get("message")
            return str(value) if value is not None else None
        return str(details) if details is not None else None
