#!/usr/bin/env python3
"""Validate key invariants in Caddy's adapted JSON configuration."""

from __future__ import annotations

import argparse
import json
from collections import deque
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


def is_exact_method_path_route(value: Any, method: str, required_paths: set[str]) -> bool:
    if not isinstance(value, dict):
        return False
    matchers = value.get("match")
    if not isinstance(matchers, list) or len(matchers) != 1:
        return False
    matcher = matchers[0]
    if not isinstance(matcher, dict) or set(matcher) != {"method", "path"}:
        return False
    methods = matcher.get("method")
    paths = matcher.get("path")
    return (
        methods == [method]
        and isinstance(paths, list)
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


def direct_proxy_dials(value: Any) -> list[str]:
    if not isinstance(value, dict) or value.get("handler") != "reverse_proxy":
        return []
    return [
        upstream["dial"]
        for upstream in value.get("upstreams", [])
        if isinstance(upstream, dict) and isinstance(upstream.get("dial"), str)
    ]


def proxy_dials(value: Any) -> list[str]:
    return [dial for _, node in walk(value) for dial in direct_proxy_dials(node)]


def has_status_response(value: Any, status_code: int) -> bool:
    return any(
        isinstance(node, dict)
        and node.get("handler") == "static_response"
        and node.get("status_code") == status_code
        for _, node in walk(value)
    )


def has_direct_edge_deny_header(value: Any) -> bool:
    if not isinstance(value, dict):
        return False
    for handler in value.get("handle", []):
        if not isinstance(handler, dict) or handler.get("handler") != "headers":
            continue
        response_set = handler.get("response", {}).get("set", {})
        if not isinstance(response_set, dict):
            continue
        for name, header_values in response_set.items():
            if name.lower() == "x-aichat-edge-deny" and header_values == ["provisioning"]:
                return True
    return False


def wildcard_patterns_overlap(left: str, right: str) -> bool:
    """Return whether two Caddy path patterns using `*` accept a common string."""

    pending = deque([(0, 0)])
    visited: set[tuple[int, int]] = set()
    while pending:
        left_index, right_index = pending.popleft()
        state = (left_index, right_index)
        if state in visited:
            continue
        visited.add(state)
        if left_index == len(left) and right_index == len(right):
            return True

        if left_index < len(left) and left[left_index] == "*":
            pending.append((left_index + 1, right_index))
        if right_index < len(right) and right[right_index] == "*":
            pending.append((left_index, right_index + 1))

        left_transition: tuple[str | None, int] | None = None
        if left_index < len(left):
            if left[left_index] == "*":
                left_transition = (None, left_index)
            else:
                left_transition = (left[left_index], left_index + 1)
        right_transition: tuple[str | None, int] | None = None
        if right_index < len(right):
            if right[right_index] == "*":
                right_transition = (None, right_index)
            else:
                right_transition = (right[right_index], right_index + 1)
        if left_transition is not None and right_transition is not None:
            left_character, next_left = left_transition
            right_character, next_right = right_transition
            if (
                left_character is None
                or right_character is None
                or left_character == right_character
            ):
                pending.append((next_left, next_right))
    return False


def route_can_deny_managed_post(value: Any, managed_paths: set[str]) -> bool:
    if not isinstance(value, dict) or not has_status_response(value, 403):
        return False
    matchers = value.get("match")
    if not isinstance(matchers, list):
        return False
    for matcher in matchers:
        if not isinstance(matcher, dict):
            continue
        methods = matcher.get("method")
        if methods is not None and (
            not isinstance(methods, list) or "POST" not in methods
        ):
            continue
        paths = matcher.get("path")
        if not isinstance(paths, list):
            continue
        if any(
            isinstance(candidate, str)
            and wildcard_patterns_overlap(candidate, managed)
            for candidate in paths
            for managed in managed_paths
        ):
            return True
    return False


def has_redirect(value: Any, location: str, status_code: int) -> bool:
    for _, node in walk(value):
        if not isinstance(node, dict) or node.get("handler") != "static_response":
            continue
        headers = node.get("headers", {})
        if node.get("status_code") == status_code and headers.get("Location") == [location]:
            return True
    return False


def value_at_path(value: Any, path: tuple[str | int, ...]) -> Any:
    current = value
    for part in path:
        current = current[part]
    return current


def deepest_common_ordered_list(
    value: Any,
    left_path: tuple[str | int, ...],
    right_path: tuple[str | int, ...],
) -> tuple[tuple[str | int, ...], int, int] | None:
    candidates: list[tuple[tuple[str | int, ...], int, int]] = []
    for path, node in walk(value):
        if (
            not isinstance(node, list)
            or len(left_path) <= len(path)
            or len(right_path) <= len(path)
        ):
            continue
        if left_path[: len(path)] != path or right_path[: len(path)] != path:
            continue
        left_index = left_path[len(path)]
        right_index = right_path[len(path)]
        if (
            isinstance(left_index, int)
            and isinstance(right_index, int)
            and left_index != right_index
        ):
            candidates.append((path, left_index, right_index))
    if not candidates:
        return None
    return max(candidates, key=lambda item: len(item[0]))


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
    public_path = f"{args.path_prefix}/*"
    relay_route_matches = [
        (name, server, path, value)
        for name, server in servers.items()
        if isinstance(server, dict)
        for path, value in walk(server)
        if is_exact_path_route(value, {public_path})
        and args.relay_dial in proxy_dials(value)
    ]
    require(
        len(relay_route_matches) == 1,
        "adapted Caddy config must contain one unique exact AIChat wildcard route with the Relay upstream",
    )
    _, target_server, relay_route_path, relay_route = relay_route_matches[0]
    nodes = list(walk(target_server))
    all_server_nodes = [
        (name, path, value)
        for name, server in servers.items()
        if isinstance(server, dict)
        for path, value in walk(server)
    ]

    relay_proxies = [
        (path, value)
        for path, value in walk(relay_route)
        if args.relay_dial in direct_proxy_dials(value)
    ]
    fallback_proxies = [
        (path, value)
        for path, value in nodes
        if args.fallback_dial in direct_proxy_dials(value)
    ]
    require(
        len(relay_proxies) == 1,
        f"the exact AIChat wildcard route must contain one Relay proxy {args.relay_dial}",
    )
    require(
        len(fallback_proxies) == 1,
        f"the AIChat server must contain one unique fallback proxy {args.fallback_dial}",
    )
    fallback_path, _ = fallback_proxies[0]

    require(
        relay_route_path
        and isinstance(relay_route_path[-1], int)
        and len(relay_route_path) >= 2
        and relay_route_path[-2] == "routes",
        "the exact AIChat wildcard route is not a direct member of a routes list",
    )
    relay_context_path = relay_route_path[:-1]
    relay_context = value_at_path(target_server, relay_context_path)
    require(isinstance(relay_context, list), "the exact AIChat route context is not a list")
    relay_index = relay_route_path[-1]

    required_skip_paths = {args.path_prefix, f"{args.path_prefix}/*"}
    matching_log_safety_routes = [
        (path, value)
        for path, value in nodes
        if has_log_skip_handler(value)
        and has_log_name_handler(value)
        and is_exact_path_route(value, required_skip_paths)
    ]
    require(
        len(matching_log_safety_routes) == 1,
        "adapted Caddy server must contain one exact AIChat log_name/log_skip route without host or method constraints",
    )
    log_route_path, _ = matching_log_safety_routes[0]
    log_order = deepest_common_ordered_list(target_server, log_route_path, relay_route_path)
    require(
        log_order is not None and log_order[1] < log_order[2],
        "AIChat log-skip does not precede the exact Relay route in their common route context",
    )

    fallback_order = deepest_common_ordered_list(
        target_server, relay_route_path, fallback_path
    )
    require(
        fallback_order is not None
        and relay_route_path[: len(fallback_order[0])] == fallback_order[0]
        and fallback_order[1] < fallback_order[2],
        "the exact AIChat Relay route does not precede the unique fallback in their real ancestor context",
    )

    require(
        any(
            isinstance(value, dict)
            and value.get("handler") == "request_body"
            and value.get("max_size") in (4_000_000, 4_194_304)
            for _, value in walk(relay_route)
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

    denied_paths = {
        f"{args.path_prefix}/v1/agents/register",
        f"{args.path_prefix}/v1/channels",
        f"{args.path_prefix}/v1/channels/*/join",
    }
    deny_occurrences = {
        denied: [
            value
            for _, _, value in all_server_nodes
            if is_exact_method_path_route(value, "POST", {denied})
            and has_status_response(value, 403)
        ]
        for denied in denied_paths
    }
    edge_header_routes = [
        value
        for _, _, value in all_server_nodes
        if has_direct_edge_deny_header(value)
    ]

    if args.public_provisioning == "false":
        for denied, occurrences in deny_occurrences.items():
            require(
                len(occurrences) == 1,
                f"adapted config must contain one exact POST-only public 403 deny matcher: {denied}",
            )

        deny_positions = {
            denied: [
                index
                for index, route in enumerate(relay_context)
                if is_exact_method_path_route(route, "POST", {denied})
                and has_status_response(route, 403)
            ]
            for denied in denied_paths
        }
        edge_header_positions = [
            index
            for index, route in enumerate(relay_context)
            if is_exact_method_path_route(route, "POST", denied_paths)
            and has_direct_edge_deny_header(route)
        ]

        require(
            len(edge_header_routes) == 1
            and len(edge_header_positions) == 1
            and all(len(positions) == 1 for positions in deny_positions.values())
            and edge_header_positions[0]
            < min(positions[0] for positions in deny_positions.values())
            and max(positions[0] for positions in deny_positions.values()) < relay_index,
            "the three exact POST-only provisioning denies and edge marker must be direct members of the exact Relay route context and precede it",
        )
    else:
        overlapping_denies = [
            value
            for _, _, value in all_server_nodes
            if route_can_deny_managed_post(value, denied_paths)
        ]
        require(
            not overlapping_denies,
            "public provisioning is enabled but an overlapping managed POST deny remains",
        )
        require(
            not edge_header_routes,
            "public provisioning is enabled but an AIChat edge-deny marker remains",
        )
    print("adapted Caddy route invariants passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
