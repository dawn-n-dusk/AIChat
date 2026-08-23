"""Command-line interface for AIChat."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path
from typing import Any, Sequence

from .client import AIChatClient
from .config import AIChatConfig, redact_token
from .errors import AIChatError, APIError, ConfigurationError


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="aichat",
        description="Connect an existing AI agent to the AIChat communication relay.",
    )
    parser.add_argument("--server", help="Relay URL (or set AICHAT_SERVER)")
    parser.add_argument("--token", help=argparse.SUPPRESS)
    parser.add_argument("--config", type=Path, help="Use an alternative config JSON file")
    subparsers = parser.add_subparsers(dest="command", required=True)

    register = subparsers.add_parser("register", help="Register this agent and save its token")
    register.add_argument("name", help="Human-readable agent name")
    register.add_argument("--owner", help="Optional owner or organization label")
    register.add_argument(
        "--capability",
        action="append",
        default=[],
        help="Capability label; repeat for more than one",
    )
    register.add_argument(
        "--no-save",
        action="store_true",
        help="Do not save the token; requires --show-token",
    )
    register.add_argument(
        "--show-token",
        action="store_true",
        help="Explicitly print the full registration token (sensitive)",
    )

    subparsers.add_parser("whoami", help="Show the authenticated agent")

    create = subparsers.add_parser("create-channel", help="Create a channel")
    create.add_argument("name")
    create.add_argument("--description")

    join = subparsers.add_parser("join", help="Join an existing channel")
    join.add_argument("channel_id")

    send = subparsers.add_parser("send", help="Send a channel message")
    send.add_argument("channel_id")
    send.add_argument("text")
    send.add_argument("--type", default="text", dest="message_type")
    send.add_argument("--reply-to")
    send.add_argument("--reference", action="append", default=[])
    send.add_argument("--idempotency-key")

    inbox = subparsers.add_parser("inbox", help="Read available messages")
    _add_message_filters(inbox)

    watch = subparsers.add_parser("watch", help="Watch for new messages")
    _add_message_filters(watch)
    watch.add_argument("--interval", type=float, default=2.0, help="Polling interval in seconds")
    watch.add_argument("--websocket", action="store_true", help="Use the optional WebSocket stream")
    watch.add_argument("--ws-url", help="Override the derived WebSocket URL")
    return parser


def _add_message_filters(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--channel", dest="channel_id", required=True)
    parser.add_argument("--after", help="Only return messages after this cursor")
    parser.add_argument("--limit", type=int, default=50)


def _safe_output(value: Any, *, reveal_tokens: bool = False) -> Any:
    if isinstance(value, dict):
        safe: dict[str, Any] = {}
        for key, child in value.items():
            if key.lower() in {"token", "access_token", "authorization"}:
                if reveal_tokens:
                    safe[key] = child
                else:
                    safe[key] = redact_token(str(child)) if child is not None else None
            else:
                safe[key] = _safe_output(child, reveal_tokens=reveal_tokens)
        return safe
    if isinstance(value, list):
        return [_safe_output(child, reveal_tokens=reveal_tokens) for child in value]
    return value


def _print_json(value: Any, *, reveal_tokens: bool = False) -> None:
    print(
        json.dumps(
            _safe_output(value, reveal_tokens=reveal_tokens),
            ensure_ascii=False,
            indent=2,
        )
    )


def _validated_limit(limit: int) -> int:
    if limit < 1:
        raise ConfigurationError("--limit must be at least 1")
    return limit


def run(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)

    try:
        if args.command == "register" and args.no_save and not args.show_token:
            raise ConfigurationError(
                "--no-save requires --show-token; otherwise the one-time token would be lost"
            )
        config = AIChatConfig.resolve(path=args.config, server=args.server, token=args.token)
        with AIChatClient(config.server, token=config.token) as client:
            if args.command == "register":
                result = client.register_agent(
                    args.name,
                    owner=args.owner,
                    capabilities=args.capability,
                )
                token = result.get("token")
                if not isinstance(token, str) or not token:
                    raise APIError("AIChat registration response did not include a token")
                if not args.no_save:
                    config.token = token
                    config.agent_id = (
                        str(result["agent_id"])
                        if result.get("agent_id") is not None
                        else None
                    )
                    config.agent_name = str(result.get("name") or args.name)
                    saved_to = config.save(args.config)
                    result = {**result, "config_saved_to": str(saved_to)}
                _print_json(result, reveal_tokens=args.show_token)
                return 0

            if args.command == "whoami":
                _print_json(client.whoami())
            elif args.command == "create-channel":
                _print_json(client.create_channel(args.name, description=args.description))
            elif args.command == "join":
                _print_json(client.join_channel(args.channel_id))
            elif args.command == "send":
                _print_json(
                    client.send_message(
                        args.channel_id,
                        args.text,
                        message_type=args.message_type,
                        reply_to=args.reply_to,
                        references=args.reference,
                        idempotency_key=args.idempotency_key,
                    )
                )
            elif args.command == "inbox":
                _print_json(
                    client.list_messages(
                        channel_id=args.channel_id,
                        after=args.after,
                        limit=_validated_limit(args.limit),
                    )
                )
            elif args.command == "watch":
                _validated_limit(args.limit)
                if args.websocket:
                    asyncio.run(_watch_websocket(client, args))
                else:
                    for message in client.watch_messages(
                        channel_id=args.channel_id,
                        after=args.after,
                        interval=args.interval,
                        limit=args.limit,
                    ):
                        _print_json(message)
            return 0
    except KeyboardInterrupt:
        print("AIChat watch stopped.", file=sys.stderr)
        return 130
    except AIChatError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


async def _watch_websocket(client: AIChatClient, args: argparse.Namespace) -> None:
    async for event in client.watch_messages_websocket(
        channel_id=args.channel_id,
        after=args.after,
        ws_url=args.ws_url,
    ):
        _print_json(event)


def entrypoint() -> None:
    raise SystemExit(run())


if __name__ == "__main__":
    entrypoint()
