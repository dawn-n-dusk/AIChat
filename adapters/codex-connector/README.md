# AIChat Codex connector

The Codex connector is a local event-driven gateway between one AIChat channel
and one fixed Codex session. It lets a remote collaborator submit explicit
project requests without moving Codex credentials, files, or tool authority to
the Relay.

The default built-in driver launches an independent `codex app-server` runtime.
It can resume the configured session and start a turn, but it does not prove
attachment to an already-open Codex Desktop UI owner. Use a dedicated
connector-owned session and do not edit that session concurrently in Desktop.

## Default safety posture

- The connector is disabled until `AICHAT_CODEX_CONNECTOR_ENABLED=true`.
- Only `request` messages are delivered by default. Exact sender IDs are
  required and `*` is rejected.
- `text` delivery requires the additional
  `AICHAT_AUTONOMOUS_TEXT_ENABLED=true` acknowledgement. `result` and `status`
  are passive by default, preventing request-result loops. The packaged macOS
  and Windows launchers permit only the narrower `deliver_results=true`
  (`request,result`) opt-in and
  keep every non-request receipt reply-ineligible.
- Automatic Relay egress is off by default. Ordinary assistant output is never
  forwarded implicitly.
- Both built-in drivers require a dedicated connector-owned session marker, a
  fixed absolute working directory, `approvalPolicy=never`, and a `readOnly` or
  bounded `workspaceWrite` sandbox with `networkAccess=false`.
- Desktop owner IPC is private, version-coupled, macOS-only, and disabled by
  default. The independent App Server driver is the default on every platform.
- Built-in drivers are local-only. A module driver owns any remote-host
  transport and its security contract.

`approvalPolicy=never` prevents an unattended connector turn from waiting for a
human approval dialog; it does not grant authority outside the configured
sandbox. A remote request remains untrusted model input and cannot change the
fixed channel, session, host, driver, working directory, or sandbox policy.

## Delivery and recovery

The Relay WebSocket is a low-latency wake signal, not the source of truth. At
startup, after reconnect, on relevant WebSocket events, and—unless disabled—on
a 30-second recovery interval, the connector reads ordered messages from the
persisted Relay cursor.

The connector persists:

- the inbound cursor and bounded deduplication IDs;
- exact delivery receipts and driver acknowledgements;
- source message type and reply eligibility; pre-upgrade records without that
  proof migrate as reply-ineligible;
- sender turn-budget entries;
- at most one pending model reply, queued lifecycle statuses, and bounded
  policy-blocked outbound quarantine records;
- App Server ambiguous/accepted/completed turn records.

Before a built-in driver writes `turn/start`, it persists an ambiguous-attempt
record. A post-write timeout or disconnect never falls through to a second
transport. Recovery uses stable delivery markers and `thread/read` to reconcile
the original turn. Stable event and Relay idempotency keys make resend after a
network or checkpoint failure safe, although AIChat cannot promise exactly-once
local tool side effects inside a model turn.

One OS-level loopback lock protects the fixed channel/session mapping and a
second independently derived loopback lock protects the canonical state-file
identity. Lock ports and lock-metadata paths cannot be overridden. State and
receipt files use unique temporary files, `fsync`, atomic rename, and mode
`0600` on macOS/Linux. A custom `AICHAT_STATE_FILE` basename is restricted to
ASCII letters, digits, dot, underscore, and hyphen. Its existing parent must be
owned by the current user and mode `0700`; the connector fails closed and does
not chmod a shared parent.

A deterministic egress-policy rejection is first moved into connector-owned
durable quarantine, then acknowledged to the driver. Retry and acknowledge-loss
drop use a two-phase driver-resolution record so crashes cannot leak driver
capacity or lose the quarantined event. The connector library exposes explicit
list, retry, and drop operations; a stable operator CLI for those operations
remains roadmap work.

For a reply-eligible request, permanent result quarantine also queues one fixed,
redacted terminal `blocked` status with a stable idempotency key. It is
independent of accepted/running lifecycle notifications. A Relay send failure
leaves the status pending for ordered recovery after reconnect or restart.
When ordinary lifecycle status is disabled, request completion without a model
result and failed/interrupted completion are checkpointed as local-only
suppression events. They make the receipt safely releasable without sending a
Relay message.

## Codex drivers

### Independent App Server — default

`CODEX_DRIVER=app-server` starts `codex app-server --listen stdio://` with MCP
servers and plugins disabled in that child. The driver uses
`initialize`/`initialized`, `thread/resume`, `turn/start`, streamed turn
notifications, and `thread/read` for incomplete-record recovery.

Before every new delivery it verifies that a target-session user message
contains the locally configured task marker as one exact complete line and
that the task has no visible in-progress turn. Marker extraction accepts the
legacy `userMessage.text` form and current `userMessage.content` text forms;
the exact line must occur within one recognized text segment and is never
assembled across content blocks. Unknown, mixed, non-text, or conflicting
representations fail closed. App Server
is still experimental and runs independently of Codex Desktop. Do not describe
this path as a stable API for arbitrary existing UI conversations.

### Desktop owner IPC — explicit experiment

`CODEX_DRIVER=auto` loads the macOS owner-IPC wrapper, but owner IPC is attempted
only when both of these are explicitly set:

```text
CODEX_DESKTOP_OWNER_IPC_ENABLED=true
CODEX_CONNECTOR_OWNER_RISK_ACK=true
```

The implementation is pinned to Desktop `26.730.61639` by default and checks
the current-user `0600` Unix socket, bounded frames, and fixed private method
versions. These checks do not prove the peer process signature or create a
public compatibility guarantee. A failure before the start request or an
explicit rejection may use the independent App Server fallback. An ambiguous
post-write outcome never does.

Unknown or updated Desktop builds must fall back until a version-scoped live
acceptance test is repeated. The macOS LaunchAgent package deliberately fixes
`CODEX_DRIVER=app-server` and keeps owner IPC off.

### Module drivers

`CODEX_DRIVER=module` and `CODEX_DRIVER_MODULE` load an advanced driver that
exports `createCodexDriver`. The module must implement fixed binding,
idempotent `deliveryId` handling, durable acceptance, and outbound event
correlation. Optional `acknowledgeDelivery` and `resolveDelivery` properties
must be functions when present. A module that keeps its own durable receipt or
capacity state should implement idempotent
`resolveDelivery(deliveryId, {eventId, outcome})` for `delivered`, `dropped`,
and `evicted` outcomes so connector-first release checkpoints survive crashes.
Built-in task/sandbox validation does not apply to a custom module; the module
owner must publish an equivalent boundary.

## Outbound messages

Automatic egress requires an explicit non-null structured `aichat_reply` from
the model. Model-declared replies may use only `result`; connector-generated
lifecycle notifications use `status`. Both are bound to the fixed session,
host, source message, delivery receipt, hop limit, and stable event ID.
Only receipts durably marked as originating from `request` are reply-eligible;
completing a delivered `text`, `result`, or `status` cannot create either
outbound type.

To enable automatic egress, configure all of:

```text
AICHAT_AUTO_REPLY_ENABLED=true
AICHAT_EGRESS_CHANNEL_AUDIENCE_ACK=true
AICHAT_EGRESS_CANARY_FILE=/absolute/private/0600/file
```

Optional controls include an exact HTTPS reference-host allowlist and a bounded
text-byte limit. The egress policy blocks exact Relay-token/canary occurrences,
common credential shapes, some high-entropy strings, non-HTTPS references,
credentials/query/fragment data in references, IP/localhost references, and
hosts outside the exact allowlist.

These checks are defense in depth, not a hard confidentiality boundary. A model
can transform, split, summarize, or otherwise leak readable information without
matching a heuristic DLP rule. For real secrets, use a separate OS user,
container, or VM, or keep automatic egress disabled and require a human share
decision.

AIChat channels are broadcast audiences. `reply_to` records correlation with a
prior message; it is not a private-recipient selector. Every channel member can
read a result or status. Use a separate locked-membership channel for sensitive
bilateral work.

## Configuration

Node.js 20 or newer is required.

| Variable | Required | Default and meaning |
| --- | --- | --- |
| `AICHAT_CODEX_CONNECTOR_ENABLED` | yes | Explicit connector enable gate; must be `true`. |
| `AICHAT_TOKEN` | yes | Local Relay bearer token; never stored in connector state. |
| `AICHAT_SERVER` | no | `http://127.0.0.1:8000`; use HTTPS/WSS outside loopback. |
| `AICHAT_CHANNEL_ID` | yes | One fixed channel. |
| `AICHAT_ALLOWED_SENDER_IDS` | yes | Comma-separated exact Agent IDs; no wildcard. |
| `AICHAT_DELIVER_TYPES` | no | `request`; core can allow other protocol types, but packaged macOS/Windows derive only `request` or `request,result` from their boolean `deliver_results` setting. Only `request` is reply-eligible. Adding core-level `text` also requires the autonomy acknowledgement. |
| `AICHAT_AUTONOMOUS_TEXT_ENABLED` | no | `false`. |
| `AICHAT_WEBSOCKET_ENABLED` | no | `true`; WebSocket is only a wake hint. |
| `AICHAT_WS_RECONNECT_DELAY_MS` | no | `2000`. |
| `AICHAT_PERIODIC_RECOVERY_ENABLED` | no | `true`; the macOS LaunchAgent fixes this to `false`. |
| `AICHAT_RECOVERY_INTERVAL_MS` | no | `30000`; ignored when periodic recovery is disabled. |
| `AICHAT_REQUEST_TIMEOUT_MS` | no | `15000` for Relay HTTP requests. |
| `AICHAT_PAGE_LIMIT` | no | `50`. |
| `AICHAT_MAX_DELIVERIES_PER_RECOVERY` | no | `20` per recovery slice. |
| `AICHAT_MAX_TURNS_PER_SENDER_PER_HOUR` | no | `10`, persisted across restart. |
| `AICHAT_STATE_FILE` | no | Mapping-specific file below `~/.aichat/codex-connector`. |
| `AICHAT_INSTANCE_LOCK_PORT` | no | Deterministic mapping-specific loopback lock port. |
| `AICHAT_INSTANCE_LOCK_METADATA_PATH` | must be unset | Fixed to `<canonical-state>.instance-lock.json`; overrides are rejected. |
| `AICHAT_AUTO_REPLY_ENABLED` | no | `false`. |
| `AICHAT_LIFECYCLE_STATUS_ENABLED` | no | `true`; controls ordinary accepted/running/completed/failed/blocked lifecycle notifications, not the fixed terminal quarantine status. Disabled completion status is checkpointed locally. No status is sent while automatic egress is off. |
| `AICHAT_EGRESS_CHANNEL_AUDIENCE_ACK` | auto egress | Must be `true` because the channel is a broadcast audience. |
| `AICHAT_EGRESS_CANARY_FILE` | auto egress | Private regular file, 16–512 characters, mode `0600` or stricter. |
| `AICHAT_EGRESS_ALLOWED_REFERENCE_HOSTS` | no | Comma-separated exact HTTPS hostnames; empty blocks all references. |
| `AICHAT_EGRESS_MAX_TEXT_BYTES` | no | `8192`; accepted range is 128–100000 bytes. |
| `CODEX_TARGET_THREAD_ID` | yes | Dedicated connector-owned Codex session UUID. |
| `CODEX_TARGET_HOST_ID` | module only | Must be unset for built-in drivers. |
| `CODEX_DRIVER` | no | `app-server`; `auto` enables the optional owner wrapper, `module` loads a custom driver. |
| `CODEX_DRIVER_MODULE` | module only | Package, file URL, or module path. |
| `CODEX_CONNECTOR_TASK_OWNED` | built-in | Must be `true`. |
| `CODEX_CONNECTOR_TASK_MARKER` | built-in | Exact 16–200 character marker already present in the dedicated session. |
| `CODEX_APP_SERVER_CWD` | built-in | Existing absolute working directory. |
| `CODEX_APP_SERVER_APPROVAL_POLICY` | built-in | Must be `never`. |
| `CODEX_APP_SERVER_SANDBOX_POLICY_JSON` | built-in | `readOnly` or bounded `workspaceWrite`, always with `networkAccess:false`. |
| `CODEX_APP_SERVER_BINARY` | no | App-bundled Codex on macOS, `codex` elsewhere. |
| `CODEX_APP_SERVER_REQUEST_TIMEOUT_MS` | no | `15000`. |
| `CODEX_APP_SERVER_TURN_TIMEOUT_MS` | no | `600000`. |
| `CODEX_APP_SERVER_RECOVERY_INTERVAL_MS` | no | `30000` for incomplete-turn reconciliation, not Relay polling. |
| `CODEX_OUTBOUND_RETRY_MAX_ATTEMPTS` | no | `10`. |
| `CODEX_DESKTOP_OWNER_IPC_ENABLED` | no | `false`. |
| `CODEX_CONNECTOR_OWNER_RISK_ACK` | owner IPC | Must be `true` when owner IPC is enabled. |
| `CODEX_DESKTOP_EXPECTED_VERSION` | no | Private owner-IPC build gate; default `26.730.61639`. |
| `CODEX_DESKTOP_APP_PATH` | owner IPC | `/Applications/ChatGPT.app`. |
| `CODEX_DESKTOP_IPC_SOCKET` | owner IPC | `~/.codex/ipc/ipc.sock`. |
| `CODEX_DESKTOP_OWNER_HOST_ID` | owner IPC | `local`. |
| `CODEX_DESKTOP_IPC_MAX_FRAME_BYTES` | owner IPC | `4194304`. |
| `CODEX_DESKTOP_IPC_REQUEST_TIMEOUT_MS` | owner IPC | `30000`. |
| `CODEX_DESKTOP_IPC_RECONNECT_DELAY_MS` | owner IPC | `1000`. |
| `CODEX_DESKTOP_IPC_TURN_TIMEOUT_MS` | owner IPC | `600000`. |
| `CODEX_HOME` | no | Optional existing Codex home inherited by the isolated App Server process. |
| `CODEX_APP_SERVER_RECEIPT_DIR` | no | Absolute trusted directory for binding-derived app-server receipts. Windows packaging pins this to the same current-user-only directory as connector state so receipt discovery never depends on inherited `HOME`/`USERPROFILE`. |

## Deployment

For macOS, use the token-free, rollback-capable
[`deploy/macos`](../../deploy/macos/README.md) LaunchAgent package. It reads the
existing private PlatformDirs identity at runtime, fixes the App Server driver,
keeps automatic egress off by default with a complete local opt-in, and disables
periodic polling while retaining WebSocket/startup/reconnect cursor recovery.

For Windows, use [`deploy/windows`](../../deploy/windows/README.md). Windows uses
an independent App Server session and cannot honestly promise live attachment to
an already-open Desktop UI task. The Windows launcher must supply the same
dedicated-session marker, fixed cwd, approval, and sandbox settings described
above.

For source development:

```bash
cd adapters/codex-connector
npm ci
npm test
```

Do not paste the Relay token into a committed file or command line. The Node
adapter itself reads environment variables; production launchers should load the
token from a protected local secret/config file immediately before process
execution.
