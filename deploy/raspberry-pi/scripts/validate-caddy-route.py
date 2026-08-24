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


def is_exact_path_route(value: Any, required_paths: set[str]) -> bool:
    if not isinstance(value, dict):
        return False
    matchers = value.get("match")
    if not isinstance(matchers, list) or len(matchers) != 1:
        return False
    matcher = matchers[0]
    if not isinstance(matcher, dict) or set(matcher) != {"path"}:
        return False
    paths = matcher.get("path")
    return (
        isinstance(paths, list)
        and len(paths) == len(required_paths)
        and set(paths) == required_paths
    )


def has_log_skip_handler(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    handlers = value.get("handle", [])
    return any(
        isinstance(handler, dict)
        and handler.get("handler") == "vars"
        and handler.get("log_skip") is True
        for handler in handlers
    )


def has_log_name_handler(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    handlers = value.get("handle", [])
    return any(
        isinstance(handler, dict)
        and handler.get("handler") == "vars"
        and handler.get("access_logger_names") == ["aichat_relay"]
        for handler in handlers
    )


def proxy_dials(value: Any) -> list[str]:
    dials: list[str] = []
    for _, node in walk(value):
        if not isinstance(node, dict) or node.get("handler") != "reverse_proxy":
            continue
        for upstream in node.get("upstreams", []):
            if isinstance(upstream, dict) and isinstance(upstream.get("dial"), str):
                dials.append(upstream["dial"])
    return dials


def has_status_response(value: Any, status_code: int) -> bool:
    return any(
        isinstance(node, dict)
        and node.get("handler") == "static_response"
        and node.get("status_code") == status_code
        for _, node in walk(value)
    )


def has_redirect(value: Any, location: str, status_code: int) -> bool:
    for _, node in walk(value):
        if not isinstance(node, dict) or node.get("handler") != "static_response":
            continue
        headers = node.get("headers", {})
        if node.get("status_code") == status_code and headers.get("Location") == [location]:
            return True
    return False


def iter_route_lists(value: Any) -> Iterator[list[Any]]:
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "routes" and isinstance(child, list):
                yield child
            yield from iter_route_lists(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_route_lists(child)


def aichat_error_logger_redacts_query_token(document: dict[str, Any]) -> bool:
    logs = document.get("logging", {}).get("logs", {})
    error_logger = logs.get("aichat_relay_errors", {}) if isinstance(logs, dict) else {}
    default_logger = logs.get("default", {}) if isinstance(logs, dict) else {}
    encoder = error_logger.get("encoder", {}) if isinstance(error_logger, dict) else {}
    fields = encoder.get("fields", {}) if isinstance(encoder, dict) else {}
    uri_filter = fields.get("request>uri", {}) if isinstance(fields, dict) else {}
    actions = uri_filter.get("actions", []) if isinstance(uri_filter, dict) else []
    include = error_logger.get("include", []) if isinstance(error_logger, dict) else []
    default_exclude = default_logger.get("exclude", []) if isinstance(default_logger, dict) else []
    return (
        include == ["http.log.error.aichat_relay"]
        and "http.log.error.aichat_relay" in default_exclude
        and encoder.get("format") == "filter"
        and uri_filter.get("filter") == "query"
        and any(
            isinstance(action, dict)
            and action.get("type") == "replace"
            and action.get("parameter") == "token"
            and action.get("value") == "REDACTED"
            for action in actions
        )
    )
def main() -> int:
    args = parse_args()
    document = json.loads(args.adapted_json.read_text(encoding="utf-8"))
    logging = document.get("logging", {}).get("logs", {})
    debug_loggers = [
        name
        for name, config in logging.items()
        if isinstance(config, dict) and str(config.get("level", "")).upper() == "DEBUG"
    ]
    require(
        not debug_loggers,
        "adapted Caddy config enables debug logging; request targets may be exposed",
    )
    require(
        aichat_error_logger_redacts_query_token(document),
        "adapted Caddy AIChat error logger is not isolated and query-token redacted",
    )

    servers = document.get("apps", {}).get("http", {}).get("servers", {})
    require(isinstance(servers, dict), "adapted Caddy config has no HTTP servers")
    candidate_servers = [
        (name, server)
        for name, server in servers.items()
        if args.relay_dial in proxy_dials(server) and args.fallback_dial in proxy_dials(server)
    ]
    require(
        len(candidate_servers) == 1,
        "adapted Caddy config must place the AIChat and fallback upstreams in one server",
    )
    _, target_server = candidate_servers[0]
    nodes = list(walk(target_server))
    rendered = [serialized(value) for _, value in nodes]

    relay_proxies = [
        value
        for _, value in nodes
        if isinstance(value, dict)
        and value.get("handler") == "reverse_proxy"
        and args.relay_dial in proxy_dials(value)
    ]
    fallback_proxies = [
        value
        for _, value in nodes
        if isinstance(value, dict)
        and value.get("handler") == "reverse_proxy"
        and args.fallback_dial in proxy_dials(value)
    ]
    require(relay_proxies, f"adapted Caddy server has no AIChat upstream {args.relay_dial}")
    require(fallback_proxies, f"adapted Caddy server has no fallback upstream {args.fallback_dial}")

    required_skip_paths = {args.path_prefix, f"{args.path_prefix}/*"}
    matching_log_safety_routes = [
        value
        for _, value in nodes
        if has_log_skip_handler(value)
        and has_log_name_handler(value)
        and is_exact_path_route(value, required_skip_paths)
    ]
    require(
        len(matching_log_safety_routes) == 1,
        "adapted Caddy server must contain one exact AIChat log_name/log_skip route without host or method constraints",
    )

    ordered_contexts = [
        routes
        for routes in iter_route_lists(target_server)
        if any(
            is_exact_path_route(route, required_skip_paths)
            and has_log_skip_handler(route)
            and has_log_name_handler(route)
            for route in routes
        )
        and any(args.relay_dial in proxy_dials(route) for route in routes)
        and any(args.fallback_dial in proxy_dials(route) for route in routes)
    ]
    require(
        ordered_contexts,
        "AIChat log-skip, Relay, and fallback routes are not in one route context",
    )

    def context_order_is_safe(routes: list[Any]) -> bool:
        skip_positions = [
            index
            for index, route in enumerate(routes)
            if is_exact_path_route(route, required_skip_paths)
            and has_log_skip_handler(route)
            and has_log_name_handler(route)
        ]
        relay_positions = [
            index for index, route in enumerate(routes) if args.relay_dial in proxy_dials(route)
        ]
        fallback_positions = [
            index for index, route in enumerate(routes) if args.fallback_dial in proxy_dials(route)
        ]
        return (
            len(skip_positions) == 1
            and relay_positions
            and fallback_positions
            and skip_positions[0] < min(relay_positions) < min(fallback_positions)
        )

    require(
        any(context_order_is_safe(routes) for routes in ordered_contexts),
        "AIChat log-skip and Relay routes do not precede the fallback in one route context",
    )

    public_path = f"{args.path_prefix}/*"
    relay_routes = [
        value
        for _, value in nodes
        if is_exact_path_route(value, {public_path}) and args.relay_dial in proxy_dials(value)
    ]
    require(
        len(relay_routes) == 1,
        "adapted Caddy server must route the exact AIChat prefix wildcard to Relay",
    )
    require(
        any(
            isinstance(value, dict)
            and value.get("handler") == "request_body"
            and value.get("max_size") in (4_000_000, 4_194_304)
            for _, value in walk(relay_routes[0])
        ),
        "adapted AIChat route has no 4 MB request-body limit",
    )

    redirect_routes = [
        value
        for _, value in nodes
        if is_exact_path_route(value, {args.path_prefix})
        and has_redirect(value, f"{args.path_prefix}/", 308)
    ]
    require(
        len(redirect_routes) == 1,
        "adapted Caddy server must redirect the bare AIChat prefix to its slash form with 308",
    )

    if args.public_provisioning == "false":
        denied_paths = (
            f"{args.path_prefix}/v1/agents/register*",
            f"{args.path_prefix}/v1/channels",
            f"{args.path_prefix}/v1/channels/*/join*",
        )
        for denied in denied_paths:
            require(
                any(
                    isinstance(value, dict)
                    and denied in serialized(value.get("match", []))
                    and has_status_response(value, 403)
                    for _, value in nodes
                ),
                f"missing public 403 deny matcher: {denied}",
            )
        require(
            sum(
                1
                for _, value in nodes
                if isinstance(value, dict)
                and value.get("handler") == "static_response"
                and value.get("status_code") == 403
            )
            >= 3,
            "adapted config does not contain all three provisioning 403 responses",
        )
    print("adapted Caddy route invariants passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
