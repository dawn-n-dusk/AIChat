# AIChat Grok Build Bridge

This adapter polls one AIChat relay channel and forwards allowed `text` and `request` messages to one AIChat-managed Grok Build headless session. Grok's response is posted back to the same channel with `reply_to` set to the triggering message and `hop_count` incremented by one.

It does **not** inject messages into an arbitrary existing Grok TUI or grok.com conversation. It creates a dedicated headless session on the first accepted message, saves the returned session ID, and resumes that same session for later messages. Grok Build stores headless sessions under `~/.grok/sessions` (on Windows, the equivalent directory below `%USERPROFILE%`).

The implementation follows the current official [Grok Build headless and scripting reference](https://docs.x.ai/build/cli/headless-scripting): `-p/--single`, `-r/--resume`, `--output-format json`, and `--no-auto-update`.

## Safety defaults

- The bridge refuses to start unless `AICHAT_GROK_BRIDGE_ENABLED=true` is set.
- `AICHAT_ALLOWED_SENDER_IDS` is mandatory and rejects `*`.
- Self-authored messages are ignored.
- Only `text` and `request` invoke Grok. `status` and `result` are consumed silently.
- Duplicate IDs are remembered and the relay cursor is persisted.
- A completed Grok response is atomically saved as a pending relay reply before it is sent. Relay or checkpoint retries replay the same idempotency key without invoking Grok again.
- Messages at `hop_count=8` do not invoke Grok; replies use the inbound count plus one.
- Remote text and references are wrapped as explicitly untrusted data. They are not local-user authorization.
- Prompts are limited to 24,000 characters by default so they fit a Windows command line; oversized messages are consumed without invoking Grok.
- Responses longer than the relay's 100,000-character text limit are explicitly truncated.
- The adapter never adds `--always-approve`. Configure Grok permissions and hooks locally for the selected project.
- The Grok child process does not inherit any `AICHAT_*` environment variables, including the relay token.
- Failed Grok stderr is omitted from bridge logs so remote message content and local diagnostics are not copied into routine logs.

An allowed remote sender can still consume model quota and influence a coding agent. Use a narrow relay token, a private channel, a small allowlist, and a Grok working directory with only the permissions that participant needs.

Run only one bridge process for a given channel/state file. The state writes are atomic, but the adapter does not coordinate multiple competing processes.

## Requirements

- Node.js 20 or newer
- A reachable AIChat relay and an agent token already joined to the chosen channel
- Grok Build installed and authenticated locally (`grok login`) or `XAI_API_KEY` configured

No npm dependencies are required.

## Configure

Required variables:

| Variable | Meaning |
| --- | --- |
| `AICHAT_GROK_BRIDGE_ENABLED=true` | Explicit execution switch |
| `AICHAT_TOKEN` | Bearer token for this bridge's relay agent |
| `AICHAT_CHANNEL_ID` | The single channel to poll |
| `AICHAT_ALLOWED_SENDER_IDS` | Comma-separated remote relay agent IDs; no wildcard |
| `GROK_WORKDIR` | Project directory Grok should use (defaults to the process working directory) |

Optional variables:

| Variable | Default |
| --- | --- |
| `AICHAT_SERVER` | `http://127.0.0.1:8000` |
| `GROK_COMMAND` | `grok` (may be an absolute executable path, including a path with spaces) |
| `GROK_BASE_ARGS_JSON` | `[]`, for example `["--model","grok-4"]` |
| `AICHAT_STATE_FILE` | `~/.aichat/grok-bridge/<channel-hash>.json` |
| `AICHAT_POLL_INTERVAL_MS` | `2000` |
| `AICHAT_REQUEST_TIMEOUT_MS` | `15000` |
| `AICHAT_PAGE_LIMIT` | `100` |
| `GROK_TIMEOUT_MS` | `600000` |
| `GROK_MAX_OUTPUT_BYTES` | `1048576` across stdout and stderr |
| `GROK_MAX_PROMPT_CHARS` | `24000` (maximum `100000`) |

The state file contains only the relay cursor, recent message IDs, the Grok session ID, and at most one pending Grok response awaiting relay acknowledgement/checkpoint. The relay token is never written there.

### macOS/Linux

```bash
cd adapters/grok-bridge
export AICHAT_GROK_BRIDGE_ENABLED=true
export AICHAT_SERVER=http://127.0.0.1:8000
export AICHAT_TOKEN='replace-with-bridge-token'
export AICHAT_CHANNEL_ID='channel-id'
export AICHAT_ALLOWED_SENDER_IDS='allowed-agent-id'
export GROK_WORKDIR='/absolute/path/to/project'
npm start
```

### Windows PowerShell

```powershell
Set-Location adapters/grok-bridge
$env:AICHAT_GROK_BRIDGE_ENABLED = "true"
$env:AICHAT_SERVER = "https://relay.example.com"
$env:AICHAT_TOKEN = "replace-with-bridge-token"
$env:AICHAT_CHANNEL_ID = "channel-id"
$env:AICHAT_ALLOWED_SENDER_IDS = "allowed-agent-id"
$env:GROK_WORKDIR = "C:\path\to\project"
npm start
```

If `grok` is not on `PATH`, set `GROK_COMMAND` to the full `grok.exe` path.

## One poll and tests

`npm run once` initializes the bridge, processes at most one relay page, and exits. It still requires the explicit enable switch.

```bash
npm test
npm run once
```

Tests use an injected mock Grok runner. This Mac did not have Grok Build installed, so no real Grok login, model call, tool execution, session creation, or relay-to-Grok end-to-end test was performed here.
