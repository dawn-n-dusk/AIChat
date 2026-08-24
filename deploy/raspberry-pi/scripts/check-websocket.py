#!/usr/bin/env python3
"""Perform an optional WSS handshake without printing the query-bearing URL."""

from __future__ import annotations

import os
from urllib.parse import quote_plus, urlsplit, urlunsplit


def main() -> int:
    token = os.environ.get("AICHAT_CHECK_TOKEN", "")
    base = os.environ.get("AICHAT_PUBLIC_BASE_URL", "")
    if not token or not base:
        raise SystemExit("AICHAT_CHECK_TOKEN and AICHAT_PUBLIC_BASE_URL are required")
    try:
        from websockets.sync.client import connect
    except ImportError:
        raise SystemExit("installed Relay environment has no synchronous websockets client") from None

    parts = urlsplit(f"{base.rstrip('/')}/v1/ws")
    scheme = "wss" if parts.scheme == "https" else "ws"
    target = urlunsplit((scheme, parts.netloc, parts.path, f"token={quote_plus(token)}", ""))
    try:
        with connect(target, open_timeout=10, proxy=None):
            pass
    except Exception as exc:
        reason = str(exc).replace(token, "[REDACTED]").replace(quote_plus(token), "[REDACTED]")
        raise SystemExit(f"WSS handshake failed: {reason}") from None
    print("WSS handshake accepted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
