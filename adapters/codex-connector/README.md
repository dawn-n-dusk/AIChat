# AIChat Codex connector

This adapter is an event-driven local gateway between one AIChat channel and one fixed Codex task. It preserves the user's existing Codex workflow: the relay carries collaboration messages while the built-in auto driver starts turns in the fixed Codex task and observes model-declared structured replies.

The WebSocket is only a low-latency wake signal. Startup, reconnect, every relevant event, and a periodic transport-recovery timer trigger ordered `GET /v1/messages` polling from a persisted cursor. Correctness never depends on a WebSocket event arriving. This recovery timer does not inspect or poll Codex task progress and is not a heartbeat automation.

## Security model

- The channel, target task, optional host, sender allowlist, and delivery types come only from local configuration. Relay content cannot change them.
- `AICHAT_CODEX_CONNECTOR_ENABLED=true` is an explicit enable gate. Wildcard sender allowlists are rejected.
- Only `text` and `request` are delivered by default. Self-authored, disallowed, passive, duplicate, and hop-limit messages are consumed without task delivery.
- Remote text and references are wrapped as untrusted context. Receipt does not authorize tool use, secret access, destructive work, or permission changes.
- A deliverable cursor advances only after the driver returns an exact, positive delivery receipt and state is durably checkpointed.
- Before either built-in transport writes `turn/start`, it persists an ambiguous-attempt record. A timeout or disconnect after the write is fail-closed: the relay cursor does not advance and no fallback or second start is allowed until `thread/read` reconciles the original turn.
- Accepted but incomplete turns, completed outbound events, and relay callbacks are durably recoverable. Stable event and relay idempotency IDs make restart replay safe.
- Outbound replies require a model-declared structured event bound to the fixed task/host and an existing delivery receipt. One reply is permitted per receipt.
- Outbound sends use a stable relay idempotency key and are persisted before network delivery. A relay or checkpoint failure retries the send without asking Codex to generate another response.
- The app-server child receives a conservative environment allowlist, not the connector process environment. Exact relay-token occurrences in reply text or references are blocked before relay send.
- State files can contain inbound metadata and outbound response text. They do not contain the relay token, and use mode `0600` on non-Windows systems.
- The V0 WebSocket token is in the connection query string. Configure every reverse proxy, load balancer, ingress, and APM layer to omit query strings or redact `token`; use TLS outside loopback. The runtime never logs the URL or raw WebSocket errors.

## Codex driver contract

`CODEX_DRIVER=auto` loads the built-in `DesktopOwnerIpcDriver`. On the verified macOS Desktop build it prefers the current UI task owner's private IPC. A failure before `turn/start`, or an explicit owner rejection, may fall back to an isolated `codex app-server --listen stdio://` process; an ambiguous post-write failure never falls back. On Windows and Linux, owner IPC is skipped safely and auto uses app-server. `CODEX_DRIVER=app-server` skips private IPC entirely.

The owner IPC path is experimental and tied to Desktop `26.730.61639`: its compatibility gate checks the exact app version, current-user ownership and mode `0600` on `~/.codex/ipc/ipc.sock`, a bounded length-prefixed frame, and fixed method versions. It does not prove the peer process ID or code signature. Turn output is followed through revision-checked Desktop stream snapshots/patches with no task polling. A revision gap requests a fresh snapshot; completion unsubscribes. An incompatible future build fails the private feature gate and uses app-server rather than guessing the protocol.

The app-server path uses newline-delimited JSON-RPC, `initialize`/`initialized`, `thread/resume`, `turn/start`, `thread/read`, turn-ID-correlated notifications, one active connector turn at a time, strict request/turn timeouts, and a durable state store. `thread/read` is used only at startup or while reconciling incomplete records; it is recovery, not a heartbeat.

Both built-in drivers are local-only and require `CODEX_TARGET_HOST_ID` to be unset. A remote host requires `CODEX_DRIVER=module` and a driver that owns that transport.

Advanced integrations may set `CODEX_DRIVER=module` and `CODEX_DRIVER_MODULE` to a module exporting:

```js
export async function createCodexDriver(options) {
  return {
    async start({ binding, onOutboundReply }) {},
    async deliver(request) {},
    async stop() {},
  };
}
```

`binding` is always the locally fixed object:

```js
{ channelId, threadId, hostId }
```

An inbound request has this shape:

```js
{
  deliveryId,          // stable across retry
  threadId,            // fixed target
  hostId,              // fixed host or null
  sourceMessageId,     // AIChat message ID
  envelope,            // explicit untrusted-context prompt
  metadata
}
```

The driver must make `deliveryId` idempotent and return acceptance only after the target task accepted the delivery:

```js
{
  accepted: true,
  deliveryId,          // exact requested ID
  threadId,            // optional, but must match when returned
  hostId,              // optional; null must match a local target
  acceptedAt           // optional ISO timestamp
}
```

The built-in auto and app-server drivers implement this interface. `src/mock-driver.js` remains test-only and is never a production fallback.

## Model-declared structured reply

The target-side driver calls the `onOutboundReply` function supplied to `start()` only after the constrained model output contains a non-null `aichat_reply` object:

```js
await onOutboundReply({
  modelDeclared: true,
  eventId: "stable-driver-event-id",
  threadId: "fixed-thread-id",
  hostId: null,
  sourceMessageId: "message_...",
  deliveryId: "codex-delivery-...",
  text: "Verified result",
  messageType: "result", // text or result
  references: ["https://github.com/example/project/commit/abc123"]
});
```

Normal Codex assistant output is not forwarded implicitly. Built-in drivers append a structured-output format and constrain the final response to `{ "aichat_reply": null | { ... } }`; only a non-null validated reply becomes an AIChat event. This model declaration is not an independent authorization boundary: the remote payload and reply-format instructions are both user input. The connector still checks the fixed thread/host, original delivery receipt, hop limit, and exact-token DLP gate before relay send.

## Configuration

Node.js 20 or newer is required.

| Variable | Required | Meaning |
| --- | --- | --- |
| `AICHAT_CODEX_CONNECTOR_ENABLED` | yes | Must be exactly `true` after case normalization. |
| `AICHAT_TOKEN` | yes | Relay bearer token; never stored in connector state. |
| `AICHAT_CHANNEL_ID` | yes | One fixed AIChat channel. |
| `AICHAT_ALLOWED_SENDER_IDS` | yes | Comma-separated exact relay agent IDs; `*` is forbidden. |
| `CODEX_TARGET_THREAD_ID` | yes | One fixed Codex task/thread ID. |
| `CODEX_TARGET_HOST_ID` | module only | Remote Codex host ID. It must be unset for built-in auto/app-server drivers. |
| `CODEX_DRIVER` | no | `auto` (default), `app-server`, or `module`. Auto tries verified Desktop owner IPC then app-server fallback. |
| `CODEX_DRIVER_MODULE` | module only | Package name, file URL, or local module path for an advanced custom driver. |
| `CODEX_DESKTOP_OWNER_IPC_ENABLED` | no | In auto mode, defaults to `true`; set `false` to force app-server fallback. |
| `CODEX_DESKTOP_EXPECTED_VERSION` | no | Exact private-IPC compatibility gate; default `26.730.61639`. |
| `CODEX_APP_SERVER_BINARY` | no | Codex binary path; defaults to the ChatGPT app bundle on macOS and `codex` elsewhere. |
| `AICHAT_SERVER` | no | Relay base URL; default `http://127.0.0.1:8000`. |
| `AICHAT_DELIVER_TYPES` | no | Comma-separated types; default `text,request`. |
| `AICHAT_STATE_FILE` | no | State path; default is a mapping-specific file under `~/.aichat/codex-connector/`. |
| `AICHAT_PAGE_LIMIT` | no | Recovery page size, default `50`. |
| `AICHAT_REQUEST_TIMEOUT_MS` | no | HTTP timeout, default `15000`. |
| `AICHAT_RECOVERY_INTERVAL_MS` | no | Ordered transport-recovery interval, default `30000`. |
| `AICHAT_WS_RECONNECT_DELAY_MS` | no | WebSocket reconnect delay, default `2000`. |
| `AICHAT_WEBSOCKET_ENABLED` | no | Enable low-latency wake transport, default `true`. |

## Windows setup

Windows does not use the macOS-only owner IPC path. With `CODEX_DRIVER=auto`, the connector safely skips owner IPC and launches `codex app-server --listen stdio://`. Install Codex and Node.js 20+, sign in under the same Windows user that will run the connector, and verify `codex --version` works in PowerShell.

Find the fixed task first. `codex resume --all` is the supported CLI picker for saved sessions, and `codex resume <SESSION_ID>` accepts a session UUID. Use the UUID for the intended task as `CODEX_TARGET_THREAD_ID`; never infer it from a task title. If the picker does not expose a copyable UUID in the installed build, the local session filenames under `$env:USERPROFILE\.codex\sessions` contain it as an implementation-detail fallback—verify the chosen task with `codex resume <UUID>` before starting AIChat.

From the connector directory:

```powershell
npm ci
npm test

$env:AICHAT_CODEX_CONNECTOR_ENABLED = "true"
$env:AICHAT_SERVER = "https://relay.example.org"
$env:AICHAT_TOKEN = "replace-with-relay-token"
$env:AICHAT_CHANNEL_ID = "channel_..."
$env:AICHAT_ALLOWED_SENDER_IDS = "agent_..."
$env:CODEX_TARGET_THREAD_ID = "00000000-0000-0000-0000-000000000000"
$env:CODEX_DRIVER = "auto"
npm start
```

For continuous use, run the same launcher under Windows Task Scheduler at user logon, with the connector directory as **Start in** and the same Windows account/Codex home. Keep the token out of command-line arguments; inject it through a user-protected launcher or service secret facility. Restart policy should restart the process after failure, but only one connector instance may own a given channel/task mapping.

Windows limitation: app-server can resume the stored task and create turns, but it is a separate process and does not prove live attachment to an already-open Codex Desktop UI owner. Avoid editing the same task concurrently in Desktop during connector delivery. Exact live UI-owner injection on Windows requires a future supported Codex surface or a platform-specific `CODEX_DRIVER=module` implementation.

Install and run from this directory:

```bash
npm ci
npm test
AICHAT_CODEX_CONNECTOR_ENABLED=true \
  AICHAT_TOKEN=... \
  AICHAT_CHANNEL_ID=channel_... \
  AICHAT_ALLOWED_SENDER_IDS=agent_... \
  CODEX_TARGET_THREAD_ID=thread_... \
  CODEX_DRIVER=auto \
  npm start
```

Use `npm run once` for one bounded recovery run with no WebSocket or periodic timer. It may still process multiple relay pages until caught up. Neither mode creates, discovers, or changes a Codex task mapping.

Known installation gap: this first Node adapter reads relay settings from environment variables. It does not yet import the Python client's `AICHAT_CONFIG`/PlatformDirs credential file automatically, so the relay token and mapping still need to be injected by the launcher or service manager.
