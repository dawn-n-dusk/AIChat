#!/usr/bin/env python3
"""Validate key invariants in Caddy's adapted JSON configuration."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Iterator


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--adapted-json", required=True, type=Path)
    parser.add_argument("--path-prefix", required=True)
    parser.add_argument("--relay-dial", required=True)
    parser.add_argument("--fallback-dial", required=True)
    parser.add_argument("--public-provisioning", required=True, choices=("true", "false"))
    return parser.parse_args()


def walk(value: Any, path: tuple[str | int, ...] = ()) -> Iterator[tuple[tuple[str | int, ...], Any]]:
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(child, path + (key,))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, path + (index,))


def serialized(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> int:
    args = parse_args()
    document = json.loads(args.adapted_json.read_text(encoding="utf-8"))
    nodes = list(walk(document))
    rendered = [serialized(value) for _, value in nodes]
    reverse_proxies = [
        value
        for _, value in nodes
        if isinstance(value, dict) and value.get("handler") == "reverse_proxy"
    ]
    proxy_rendered = [serialized(value) for value in reverse_proxies]
    relay_indices = [index for index, text in enumerate(proxy_rendered) if args.relay_dial in text]
    fallback_indices = [index for index, text in enumerate(proxy_rendered) if args.fallback_dial in text]
    require(relay_indices, f"adapted Caddy config has no AIChat upstream {args.relay_dial}")
    require(fallback_indices, f"adapted Caddy config has no fallback upstream {args.fallback_dial}")
    require(
        min(relay_indices) < min(fallback_indices),
        "AIChat upstream does not precede the existing fallback in adapted route order",
    )

    public_path = f"{args.path_prefix}/*"
    require(any(public_path in text for text in rendered), "adapted config has no AIChat path matcher")
    require(
        any('"max_size":4000000' in text or '"max_size":4194304' in text for text in rendered),
        "adapted AIChat route has no 4 MB request-body limit",
    )

    if args.public_provisioning == "false":
        denied_paths = (
            f"{args.path_prefix}/v1/agents/register*",
            f"{args.path_prefix}/v1/channels",
            f"{args.path_prefix}/v1/channels/*/join*",
        )
        for denied in denied_paths:
            require(any(denied in text for text in rendered), f"missing public deny matcher: {denied}")
        require(
            sum('"status_code":403' in text for text in rendered) >= 3,
            "adapted config does not contain all three provisioning 403 responses",
        )
    print("adapted Caddy route invariants passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
