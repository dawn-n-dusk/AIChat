from __future__ import annotations

import ipaddress
import os
import time
from collections import OrderedDict
from dataclasses import dataclass
from threading import Lock
from typing import Mapping, Sequence


DEFAULT_TRUSTED_PROXY_CIDRS = "127.0.0.0/8,::1/128"


def _parse_boolean(value: str | None, *, default: bool, name: str) -> bool:
    if value is None or not value.strip():
        return default
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} must be true or false")


def _parse_non_negative_integer(value: str | None, *, default: int, name: str) -> int:
    if value is None or not value.strip():
        return default
    normalized = value.strip()
    if not normalized.isdigit():
        raise ValueError(f"{name} must be a non-negative integer")
    return int(normalized)


def _parse_trusted_proxy_networks(
    value: str | None,
) -> tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...]:
    source = DEFAULT_TRUSTED_PROXY_CIDRS if value is None else value
    networks: list[ipaddress.IPv4Network | ipaddress.IPv6Network] = []
    for item in source.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            networks.append(ipaddress.ip_network(item, strict=False))
        except ValueError as exc:
            raise ValueError(f"AICHAT_TRUSTED_PROXY_CIDRS contains an invalid network: {item}") from exc
    return tuple(networks)


@dataclass(frozen=True, slots=True)
class RuntimeSettings:
    production_lockdown: bool
    docs_enabled: bool
    agent_registration_enabled: bool
    channel_create_enabled: bool
    channel_join_enabled: bool
    http_rate_limit_per_minute: int
    websocket_handshake_rate_limit_per_minute: int
    websocket_max_connections: int
    websocket_max_connections_per_agent: int
    trusted_proxy_networks: tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...]

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> "RuntimeSettings":
        source = os.environ if environ is None else environ
        lockdown = _parse_boolean(
            source.get("AICHAT_PRODUCTION_LOCKDOWN"),
            default=False,
            name="AICHAT_PRODUCTION_LOCKDOWN",
        )
        return cls(
            production_lockdown=lockdown,
            docs_enabled=_parse_boolean(
                source.get("AICHAT_DOCS_ENABLED"),
                default=not lockdown,
                name="AICHAT_DOCS_ENABLED",
            ),
            agent_registration_enabled=_parse_boolean(
                source.get("AICHAT_AGENT_REGISTRATION_ENABLED"),
                default=not lockdown,
                name="AICHAT_AGENT_REGISTRATION_ENABLED",
            ),
            channel_create_enabled=_parse_boolean(
                source.get("AICHAT_CHANNEL_CREATE_ENABLED"),
                default=not lockdown,
                name="AICHAT_CHANNEL_CREATE_ENABLED",
            ),
            channel_join_enabled=_parse_boolean(
                source.get("AICHAT_CHANNEL_JOIN_ENABLED"),
                default=not lockdown,
                name="AICHAT_CHANNEL_JOIN_ENABLED",
            ),
            http_rate_limit_per_minute=_parse_non_negative_integer(
                source.get("AICHAT_HTTP_RATE_LIMIT_PER_MINUTE"),
                default=120 if lockdown else 0,
                name="AICHAT_HTTP_RATE_LIMIT_PER_MINUTE",
            ),
            websocket_handshake_rate_limit_per_minute=_parse_non_negative_integer(
                source.get("AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE"),
                default=30 if lockdown else 0,
                name="AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE",
            ),
            websocket_max_connections=_parse_non_negative_integer(
                source.get("AICHAT_WS_MAX_CONNECTIONS"),
                default=128 if lockdown else 0,
                name="AICHAT_WS_MAX_CONNECTIONS",
            ),
            websocket_max_connections_per_agent=_parse_non_negative_integer(
                source.get("AICHAT_WS_MAX_CONNECTIONS_PER_AGENT"),
                default=4 if lockdown else 0,
                name="AICHAT_WS_MAX_CONNECTIONS_PER_AGENT",
            ),
            trusted_proxy_networks=_parse_trusted_proxy_networks(
                source.get("AICHAT_TRUSTED_PROXY_CIDRS")
            ),
        )


def _is_trusted_proxy(
    address: ipaddress.IPv4Address | ipaddress.IPv6Address,
    networks: Sequence[ipaddress.IPv4Network | ipaddress.IPv6Network],
) -> bool:
    return any(address.version == network.version and address in network for network in networks)


def client_address_from_scope(
    scope: Mapping[str, object],
    trusted_proxy_networks: Sequence[ipaddress.IPv4Network | ipaddress.IPv6Network],
) -> str:
    client = scope.get("client")
    direct_host = str(client[0]) if isinstance(client, (tuple, list)) and client else "unknown"
    try:
        direct_address = ipaddress.ip_address(direct_host)
    except ValueError:
        return direct_host

    if not _is_trusted_proxy(direct_address, trusted_proxy_networks):
        return str(direct_address)

    raw_headers = scope.get("headers")
    forwarded_values: list[str] = []
    if isinstance(raw_headers, list):
        for raw_name, raw_value in raw_headers:
            if raw_name.lower() == b"x-forwarded-for":
                forwarded_values.extend(raw_value.decode("latin-1").split(","))
    if not forwarded_values:
        return str(direct_address)

    forwarded_addresses: list[ipaddress.IPv4Address | ipaddress.IPv6Address] = []
    try:
        for value in forwarded_values:
            forwarded_addresses.append(ipaddress.ip_address(value.strip()))
    except ValueError:
        # An invalid chain is attacker-controlled input. Ignore it instead of trying
        # to salvage a possibly spoofed left-most address.
        return str(direct_address)

    # Walk from the trusted proxy toward the original client and select the first
    # untrusted hop. This resists a client prepending a fake address when a trusted
    # proxy appends the real address rather than replacing the header.
    for address in reversed(forwarded_addresses):
        if not _is_trusted_proxy(address, trusted_proxy_networks):
            return str(address)
    return str(forwarded_addresses[0])


@dataclass(frozen=True, slots=True)
class RateLimitDecision:
    allowed: bool
    retry_after_seconds: int = 0


class FixedWindowRateLimiter:
    """A bounded, process-local fixed-window limiter keyed by a trusted client address."""

    def __init__(
        self,
        limit_per_minute: int,
        *,
        clock=time.monotonic,
        max_tracked_clients: int = 10_000,
    ) -> None:
        self.limit_per_minute = limit_per_minute
        self.clock = clock
        self.max_tracked_clients = max_tracked_clients
        self._entries: OrderedDict[str, tuple[int, int]] = OrderedDict()
        self._lock = Lock()

    def check(self, key: str) -> RateLimitDecision:
        if self.limit_per_minute <= 0:
            return RateLimitDecision(True)

        now = self.clock()
        window = int(now // 60)
        with self._lock:
            stored_window, count = self._entries.get(key, (window, 0))
            if stored_window != window:
                stored_window, count = window, 0
            if count >= self.limit_per_minute:
                retry_after = max(1, int(((window + 1) * 60) - now + 0.999))
                self._entries.move_to_end(key, last=True)
                return RateLimitDecision(False, retry_after)

            self._entries[key] = (stored_window, count + 1)
            self._entries.move_to_end(key, last=True)
            while len(self._entries) > self.max_tracked_clients:
                self._entries.popitem(last=False)
        return RateLimitDecision(True)
