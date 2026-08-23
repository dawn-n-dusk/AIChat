# AIChat Claude Code Channel Adapter

This adapter bridges one AIChat relay channel into the **currently running Claude Code session** using the official Claude Code Channels research-preview contract. It is a local Node.js MCP server over stdio; Claude Code starts it as a subprocess.

It declares `experimental["claude/channel"]`, emits `notifications/claude/channel`, and exposes a standard MCP `reply` tool. It does **not** relay Claude Code permission prompts.

Official references: [Claude Code Channels](https://code.claude.com/docs/en/channels) and [Channels reference](https://code.claude.com/docs/en/channels-reference).

## Security defaults

- A fixed `AICHAT_CHANNEL_ID` is the only channel read from or written to.
- `AICHAT_ALLOWED_SENDER_IDS` is mandatory, accepts relay agent IDs, and rejects wildcards.
- Messages sent by this adapter's own relay identity are ignored.
- Message IDs are deduplicated and a cursor is persisted atomically with owner-only permissions on POSIX.
- Only `text` and `request` wake Claude by default. `status` and `result` are consumed without notification, so they do not create automatic response turns.
- Every delivered event explicitly labels remote text and references as untrusted. Relay membership and an allowlist do not grant host permissions or authorize sensitive actions.
- The reply tool accepts only a `message_id` actually delivered to the current Claude session and cannot select a different channel.
- Automated replies increment `hop_count`, are refused at the relay limit, and use a stable idempotency key for safe relay retries.

These controls reduce accidental exposure; they do not make prompt injection impossible. Keep the allowlist narrow and run Claude Code with its normal local permission controls.

## Requirements

- Node.js 20 or newer
- A registered AIChat agent that has joined the configured channel
- Claude Code authenticated through a Channels-supported Anthropic account or API key
- Channels enabled by the organization, where applicable

Install dependencies from the adapter directory:

```bash
cd adapters/claude-channel
npm ci
```

## Configuration

Required environment variables:

| Variable | Meaning |
| --- | --- |
| `AICHAT_TOKEN` | Bearer token for this local Claude adapter's AIChat agent |
| `AICHAT_CHANNEL_ID` | Exact relay channel ID to bridge |
| `AICHAT_ALLOWED_SENDER_IDS` | Comma-separated relay agent IDs allowed to reach Claude; no `*` |

Optional variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `AICHAT_SERVER` | `http://127.0.0.1:8000` | AIChat relay base URL |
| `AICHAT_POLL_INTERVAL_MS` | `2000` | Delay after an empty/short page; minimum 100 ms |
| `AICHAT_REQUEST_TIMEOUT_MS` | `15000` | HTTP timeout; minimum 1000 ms |
| `AICHAT_PAGE_LIMIT` | `100` | Messages requested per page, 1-200 |
| `AICHAT_CURSOR_FILE` | `~/.aichat/claude-channel/<channel-hash>.json` | Persistent cursor/deduplication state |
| `AICHAT_DELIVER_TYPES` | `text,request` | Types that wake Claude; opt in to `status` or `result` only deliberately |

Do not put the token directly in a committed MCP configuration file. The example below assumes the variables are already exported in the environment that launches Claude Code:

```bash
export AICHAT_SERVER="https://relay.example.com"
export AICHAT_TOKEN="..."
export AICHAT_CHANNEL_ID="..."
export AICHAT_ALLOWED_SENDER_IDS="agent-id-from-windows,agent-id-from-mac"
```

## Start Claude Code from this directory

This directory includes a committed project-level `.mcp.json`:

```json
{
  "mcpServers": {
    "aichat": {
      "command": "node",
      "args": ["./src/server.js"]
    }
  }
}
```

The relative path is intentionally resolved from this adapter project. Export the variables above, stay in `adapters/claude-channel`, and start Claude there so the project MCP server is present during Channel startup discovery:

```bash
cd /absolute/path/to/AIChat/adapters/claude-channel
claude --dangerously-load-development-channels server:aichat
```

Do not pass the configuration as inline JSON for this preferred flow. Claude Code should discover the checked-in `.mcp.json` before it resolves `server:aichat`. The first launch may ask whether to trust the project MCP server; approve it only after confirming this local checkout and configuration.

If a user-level MCP entry is required instead, use the absolute path to `src/server.js`. Do not copy the bearer token into a committed `.mcp.json`; provide credentials through the launch environment or another local secret mechanism.

The flag bypasses the curated channel allowlist only. It does not bypass organization policy, and it should not be used for an untrusted server. Confirm the channel notice at startup and use `/mcp` plus Claude Code's debug log if the process fails to connect.

## Message and reply behavior

An allowed relay message is delivered with routing attributes including `message_id`, `channel_id`, `sender_id`, and `message_type`. Claude replies by calling:

```text
reply(reply_to=<exact inbound message_id>, text=<reply text>)
```

The adapter posts a `text` message to the fixed configured channel with `reply_to` set to the inbound ID. Its own outbound message is later ignored by the polling loop.

## Test

```bash
npm test
```

Channels are a Claude Code research-preview feature. Delivery notifications are not acknowledged by Claude Code: a successful MCP notification write confirms transport output, not that Claude processed the event.
