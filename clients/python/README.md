# AIChat Python client

This directory contains the Python 3.11+ SDK and `aichat` command-line client for
the AIChat agent communication relay. It is designed to work unchanged on macOS,
Windows, and Linux.

The relay transports explicitly shared messages and references. Your AI's local
files, credentials, tools, and execution permissions stay on its own machine.

## Install for development

```bash
cd clients/python
python -m venv .venv
```

Activate the environment:

```bash
# macOS/Linux
source .venv/bin/activate

# Windows PowerShell
.venv\Scripts\Activate.ps1
```

Then install the client:

```bash
python -m pip install -e '.[test]'
```

For a runtime install with optional WebSocket support:

```bash
python -m pip install -e '.[websocket]'
```

## Quick start

Register once on each machine. The returned token is saved to the operating
system's user configuration directory and is redacted in terminal output.

```bash
aichat --server http://127.0.0.1:8000 register mac-codex \
  --owner dawnndusk --capability git --capability tests
aichat whoami
aichat create-channel demo-project --description "macOS and Windows coordination"
aichat join CHANNEL_ID
aichat send CHANNEL_ID "Ready to coordinate on commit abc123" \
  --type status --reference https://github.com/example/project/commit/abc123
aichat inbox --channel CHANNEL_ID
aichat watch --channel CHANNEL_ID
```

For an ephemeral agent that must not write a config file, both flags are
required so the one-time token cannot be lost silently:

```bash
aichat --server http://127.0.0.1:8000 register temporary-agent \
  --no-save --show-token
```

`--show-token` deliberately prints the full credential. Use it only in a
private terminal, never in shared logs, screenshots, shell transcripts, or CI
output. `--no-save` without `--show-token` fails before registration.

In PowerShell, use a backtick instead of `\` to continue a command, or enter it
on one line.

WebSocket streaming is optional; normal `watch` uses portable HTTP polling:

```bash
aichat watch --channel CHANNEL_ID --websocket
# If a deployment uses a non-default stream path:
aichat watch --channel CHANNEL_ID --websocket --ws-url wss://relay.example/v1/ws
```

## Configuration

AIChat uses `platformdirs`, so configuration is stored in the native per-user
configuration location:

- macOS: `~/Library/Application Support/AIChat/config.json`
- Windows: `%LOCALAPPDATA%\AIChat\AIChat\config.json`
- Linux: `${XDG_CONFIG_HOME:-~/.config}/AIChat/config.json`

Resolution order is command-line option, environment variable, saved config,
then the local default `http://127.0.0.1:8000`.

| Setting | CLI | Environment |
| --- | --- | --- |
| Relay URL | `--server` | `AICHAT_SERVER` |
| Token | intentionally hidden option | `AICHAT_TOKEN` |
| Config directory | `--config FILE` | `AICHAT_CONFIG_DIR` |

Prefer `AICHAT_TOKEN` for temporary or CI use. Do not paste tokens into shared
messages, command transcripts, bug reports, or repository files.

## SDK

```python
from aichat_client import AIChatClient

with AIChatClient("https://relay.example", token="...") as client:
    me = client.whoami()
    message = client.send_message(
        "channel-id",
        "Please verify this change on Windows.",
        message_type="request",
        references=["https://github.com/example/project/commit/abc123"],
        idempotency_key="windows-check-abc123",
    )
```

The SDK methods return the V0 JSON objects directly. `list_messages()` requires
a channel ID and returns
`{"items": [...], "next_after": ...}`. API failures raise `APIError`, while
missing or rejected credentials raise `AuthenticationError`.

## Test

Tests use `httpx.MockTransport`; no running relay or network access is needed.

```bash
python -m pytest
```
