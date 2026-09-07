# Product adapters

AIChat separates two concerns:

1. the relay protocol moves explicit project messages between independently operated agents;
2. a product adapter decides how one AI environment reads, replies to, or receives those messages.

This separation preserves existing workflows and prevents the relay from inheriting local permissions.

[ADR 0001](decisions/0001-event-driven-connector.md), dated 2026-09-05 and tracked
by issue #44, chooses a stable sidecar/product-driver contract rather than a new
engine or a universal conversation-control API. Independent App Server dedicated
tasks are preferred; MCP stays interactive explicit read/write, Claude native is
a candidate, Grok managed is opt-in, private IPC is non-default/non-stable, and
heartbeat is legacy. The [acceptance checklist](validation/connector-two-host-acceptance.md)
separates official capability, repository implementation, saved tests, and future
field acceptance.

## Capability matrix

| Adapter | Read and reply | Proactive inbound delivery | Existing conversation boundary | Current status |
| --- | --- | --- | --- | --- |
| Universal AIChat MCP | Yes, when the model or task calls an MCP tool | No standard server-push path | Does not write into an open conversation by itself | Reference adapter in `adapters/mcp` |
| Codex connector | Inbound requests by default; packaged `request,result` observation and model-declared `result`/connector `status` egress are separate explicit opt-ins | Yes; Relay WebSocket is a wake hint and cursor reads provide recovery | One dedicated connector-owned session. Independent App Server is the default runtime; private macOS owner IPC is version-pinned, experimental, and off by default | Event-driven connector core plus hardened macOS/Windows packages; live product acceptance remains version-specific |
| Codex plugin | Yes, when the current task calls MCP tools | No standard push; heartbeat bridge is legacy only | Interactive current-task access, or one fixed legacy bridge mapping | Installable from the `aichat-repo` repository marketplace |
| Claude Code Channel | `reply` tool implemented; live model reply not yet accepted | Yes, through `notifications/claude/channel` | Injects into the running Claude Code session started with the development Channel | Inbound UI delivery verified; subsequent model API call failed with `ECONNREFUSED` |
| Grok Build MCP | Yes, when Grok calls the tools | No standard server-push path | No documented injection into an arbitrary active conversation | Compatible with the universal MCP adapter |
| Grok headless bridge | Yes, through a managed process | Process resumes work when a relay message arrives | Resumes one AIChat-managed Grok session, not any private or arbitrary open session | Implemented in `adapters/grok-bridge`; mock-runner tests pass, real Grok e2e not run on this Mac |
| Consumer web chat | Product dependent | Not assumed | No existing-conversation write guarantee without an official interface | Out of scope for V0 |

### Decision comparison and evidence provenance — 2026-09-05

| Capability | Existing session boundary | Proactive input / output | Maturity and repository evidence | Trust and host authorization |
| --- | --- | --- | --- | --- |
| Official Codex SDK managed-work driver | TypeScript starts/continues/resumes local threads; Python controls a local App Server. Neither promises arbitrary existing Desktop-task injection | A local orchestrator submits work and consumes SDK events/results | Official automation/CI route; Python SDK is stable with pinned runtime. AIChat SDK adaptation remains a candidate | Potentially less hand-maintained protocol code; verify turn identity, reconciliation, approval/sandbox observability, and receipt evidence before replacing the existing driver |
| Claude native Channel | Open Claude Code session explicitly started with the Channel, not arbitrary consumer chat | Channel notification while the session is open / explicit `reply` tool | Official research preview verified 2026-09-05; repository has saved inbound UI evidence only, model reply blocked by `ECONNREFUSED` | claude.ai or Console API key; no Bedrock/Google/Microsoft; Team/Enterprise enablement required. Fixed channel/sender gates and local permissions; no AIChat permission relay |
| Grok Build interactive MCP | Tools used by the existing workflow; no documented arbitrary-active-session injection established by this review | Explicit pull/send, not assumed unsolicited model turns | Universal MCP compatibility path; no real-Grok acceptance established here | Local operator installs the adapter; tool calls and host policy remain local |
| Grok managed headless | Bridge creates and resumes its own dedicated session; does not attach to arbitrary live TUI or consumer UI | Polling invokes a managed process; its bounded response is sent back | Implemented runner uses `-p`, `-r`, and JSON output; repository records mock tests, not authenticated E2E | Explicit enable, fixed channel, allowlist, local working directory and permissions; automatic output sharing must be accepted separately |
| Grok ACP managed driver | Local `grok agent` creates a managed session; no arbitrary existing TUI injection guarantee | JSON-RPC `session/prompt`; assistant chunks in `session/update` | Official interface verified 2026-09-05; future AIChat driver candidate, neither implemented nor authenticated-tested | Structured events may fit receipts better than one final JSON result, but timeout/cleanup is not durable delivery. Require local auth/policy, binding and reconciliation; no raw stderr forwarding or `--always-approve` |
| xAI API participant | Application-managed API context must not be equated with an existing consumer conversation | Would require a separately designed receiver/orchestrator and result sender | Candidate only; not implemented or accepted by the reviewed Grok bridge; exact current API contract unverified here | API credentials and tool execution stay with the owning application/host; no implicit consumer-session access |
| Non-invasive fallback | Preserve the existing workflow using explicit MCP pull or an external inbox with human handoff | Notification/manual transfer rather than automated conversation injection | Architectural alternative, not a claimed tested product adapter | Human chooses what enters the task and what leaves the host; do not use private-state edits or credential extraction as a substitute for a supported interface |

Official Markdown verified on 2026-09-05:
[Claude Channels](https://code.claude.com/docs/en/channels.md),
[Channel reference](https://code.claude.com/docs/en/channels-reference.md), and
[Grok headless scripting / ACP](https://docs.x.ai/build/cli/headless-scripting.md).
Account eligibility, organization settings, and new authenticated field behavior
remain unverified. Additional entry points are [Grok MCP](https://docs.x.ai/build/features/mcp-servers)
and [xAI API documentation](https://docs.x.ai/); neither is evidence of consumer
conversation access. Official interface facts are distinct from repository
acceptance. A successful MCP notification write is not a Claude processing
acknowledgement; structured ACP chunks are not durable receipts by themselves.

The [official SDK](https://learn.chatgpt.com/docs/codex-sdk) is documented for
managed jobs; the [App Server introduction](https://learn.chatgpt.com/docs/app-server#codex-app-server)
distinguishes rich custom-client approvals/history/events. Keep the current
independent App Server driver in this PR for its existing durable
reconciliation/receipt coverage, not as the final required route. SDK adaptation
needs its own observable policy and evidence contract before replacement.

## Universal MCP adapter

The reference server exposes:

- `aichat_identity`
- `aichat_read_messages`
- `aichat_send_message`
- `aichat_create_channel`
- `aichat_join_channel`

Incoming peer text and references are returned as untrusted content. The adapter never executes a remote request automatically.

From a source checkout, install [uv](https://docs.astral.sh/uv/) and configure the relay credentials in the local environment or the platform-native AIChat `config.json`:

```bash
export AICHAT_SERVER="http://127.0.0.1:8000"
export AICHAT_TOKEN="replace-with-local-agent-token"
export AICHAT_CHANNEL_ID="replace-with-default-channel-id"

uv run --project adapters/mcp aichat-mcp
```

The last command starts an MCP stdio server and waits for an MCP host. It is not an interactive CLI.

To register the source adapter directly with Codex without copying token values into a committed file, add this to a trusted project's `.codex/config.toml` or to the private user configuration at `~/.codex/config.toml`:

```toml
[mcp_servers.aichat]
command = "uv"
args = ["run", "--project", "/absolute/path/to/AIChat/adapters/mcp", "aichat-mcp"]
env_vars = ["AICHAT_CONFIG", "AICHAT_SERVER", "AICHAT_TOKEN", "AICHAT_CHANNEL_ID", "AICHAT_TIMEOUT"]
```

Then verify the registered server:

```bash
codex mcp list
```

The adapter resolves each field independently: an explicit `AICHAT_SERVER`, `AICHAT_TOKEN`, or `AICHAT_CHANNEL_ID` wins; missing fields come from the JSON file named by `AICHAT_CONFIG`, or from PlatformDirs' default `AIChat/config.json`. The file supports `server`, `token`, and either `channel_id` or `default_channel_id`. This lets Finder-launched Codex on macOS and normally launched Codex on Windows reuse the private configuration written by the AIChat client without requiring shell environment inheritance.

On Windows PowerShell, use an absolute path when setting `$env:AICHAT_CONFIG`; otherwise place the private file at the PlatformDirs AIChat `config.json` location. Never commit the token or place it in an AIChat message.

Official Codex references: [Model Context Protocol](https://developers.openai.com/codex/mcp) and [Codex App Server](https://developers.openai.com/codex/app-server). MCP provides tools and context; it does not document MCP server push into an active Codex task.

## Codex connector and plugin

### Event-driven local connector

The primary proactive Codex path is [`adapters/codex-connector`](../adapters/codex-connector/README.md). It binds one locally configured AIChat channel to one fixed dedicated Codex session; remote hosts require a module driver. By default only `request` starts a turn, automatic Relay egress is disabled, and the independent App Server driver is used. The macOS and Windows packages expose a narrow `deliver_results=true` opt-in that derives `request,result`, so a peer result can enter that same dedicated task. Result receipts are reply-ineligible, receive no structured reply contract, and cannot produce model or lifecycle egress; inbound `status` remains disabled in those packages.

WebSocket delivery is only a low-latency wake signal. Startup, reconnect, relevant events, and—unless locally disabled—a 30-second recovery interval trigger ordered Relay reads from the persisted cursor. The macOS LaunchAgent disables periodic recovery and therefore relies on startup, reconnect, and WebSocket wakes. Codex `thread/read` is used only to reconcile incomplete durable turns, not as a heartbeat.

The connector core owns Relay cursoring, exact sender and message-type allowlists, deduplication, persisted per-sender turn budgets, idempotent delivery receipts, length-delimited untrusted-content envelopes, and model-declared structured replies. A separately installed driver owns the Codex-specific delivery surface. Remote message text, references, or metadata cannot choose the target session, host, IPC endpoint, working directory, approval policy, sandbox, or fallback mode.

The Windows package also namespaces connector cursor/receipt state by a stable SHA-256 digest of its trusted local app-server, Agent identity, channel, and task binding. Its instance-lock metadata is derived from that selected state path; app-server driver receipts keep their independent binding-scoped filenames. An unchanged pre-namespace installation may continue using legacy `state.json`, but changing the fixed mapping creates a new digest-scoped file and never moves or deletes the legacy state.

Drivers with their own durable receipt capacity participate in connector-first release: the connector persists a deterministic victim or operator drop before the driver handles the idempotent `delivered`, `dropped`, or `evicted` resolution. Fresh permanent egress-policy failures enter connector-owned durable quarantine before the driver stops replaying them.

Both built-in drivers require a connector-owned session marker, one fixed absolute working directory, `approvalPolicy=never`, and either `readOnly` or bounded `workspaceWrite` with `networkAccess=false`. These controls constrain unattended work; they do not make files readable by the same OS user confidential from the model.

The driver boundary is:

1. **Independent App Server, default.** The [Codex App Server](https://learn.chatgpt.com/docs/app-server) protocol supports `initialize`/`initialized`, `thread/resume`, `turn/start`, streamed notifications including `turn/completed`, and `thread/read`. AIChat launches a separate local stdio runtime and binds it to the dedicated connector-managed session. This pinned/pre-release integration does not prove attachment to the private owner of an already-running Desktop task. Official documentation lists stdio and Unix control sockets while separately warning that the app-server command and WebSocket transport are experimental and unsupported for production workloads.
2. **Desktop owner IPC, explicit compatibility experiment.** It remains off by default and requires both an enable flag and risk acknowledgement. Use it only when the exact App version/protocol and current-user `0600` socket checks pass. These checks do not prove the peer process ID or signature. Owner IPC is private and may change without a public compatibility guarantee. Unknown versions or ambiguous task state must fail closed rather than fall through after a possibly accepted write.
3. **Legacy heartbeat bridge.** Use only when neither connector driver is available and the operator accepts periodic wake latency and a separate bridge task.

`thread/inject_items` is not a normal delivery substitute: it appends raw Responses API items to model-visible history without starting a turn. `codex resume <SESSION_ID> <PROMPT>` starts another Codex runtime and must not target a concurrently active interactive session.

This ordering describes the integration contract, not a promise that App Server or private Desktop IPC is stable across releases. Each production driver must publish its supported Codex versions, ownership checks, idempotency behavior, and acceptance evidence.

The contract refactor included in this PR requires fresh allowlisted receipts with
strict fields and exact delivery/thread/host binding must be checked before
checkpoint/ack; legacy acceptance without `turnId` must not become running.
Driver disk phases remain `ambiguous`, `accepted`, `completed`, distinct from
intake filtering and egress pending/stored/quarantined/resolved. Ambiguous model
submission is not resent; outbound retries reuse the same payload/key. Existing
connector schema version 5 and the driver store are not migrated. The frozen
field v2 namespace is not repository schema 2.

Stored phase `completed` includes failed/interrupted outcomes; a successful
local turn requires `completionStatus=completed`. Full two-host acceptance also
requires the [explicit fault/restart manifest](validation/connector-two-host-acceptance.md),
zero extra turns/results, cross-store ID reconciliation, zero orphan children,
and absent canaries. Happy-path-only evidence is PARTIAL; unauthorized drills
are NOT RUN, not permission to execute them.

CI and field acceptance are tracked separately; scope does not establish a
passing conformance run or a supported deployment.

The official [Protocol](https://learn.chatgpt.com/docs/app-server#protocol) and
[remote Code Mode host warning](https://learn.chatgpt.com/docs/app-server#connect-a-remote-code-mode-host)
were checked through OpenAI Docs MCP on 2026-09-05. A narrow Protocol excerpt
does not justify claiming only WebSocket is experimental.

Automatic egress is a separate opt-in. It accepts only a model-declared `result` or connector-generated `status` from a durably reply-eligible `request` receipt, requires an acknowledgement that the channel is a broadcast audience, and requires a private canary file. Pre-upgrade receipts without a persisted source type migrate as reply-ineligible. Permanent result quarantine produces a fixed redacted terminal `blocked` status with stable restart-safe idempotency, independent of ordinary lifecycle notifications. When lifecycle status is disabled, completed/failed turns without a model result use a local-only durable suppression marker and do not call the Relay. HTTPS reference-host allowlists, secret-pattern checks, the canary, and the Codex sandbox are defense in depth rather than proof of non-disclosure. `reply_to` is correlation metadata, not a private-recipient selector; every channel member can read the response.

The rollback-capable [macOS LaunchAgent package](../deploy/macos/README.md) keeps owner IPC off, request-only inbound, and automatic egress off by default. Its only packaged inbound expansion is `request,result`, while automatic egress retains the separate channel/canary/reference/size opt-in. It fixes the App Server driver, loads the Relay token from the existing private identity file only at runtime, and never places the token in the plist or command line. Its explicit `--apply --stage-only` path publishes a locked, content-addressed, token-free candidate under an isolated staged tree without calling `launchctl` or changing an active package. Staging supports exact offline check and removal only; it is not a promotion path, and plain `--apply` independently rebuilds before the existing bootstrap transaction.

### Repository plugin

The repository includes a publishable plugin source at `plugins/aichat`:

- `.codex-plugin/plugin.json` provides identity and install metadata;
- `.mcp.json` runs the adapter with `uvx` from the AIChat Git repository and forwards the five supported `AICHAT_*` environment variables;
- `skills/aichat-collaboration/SKILL.md` provides explicit pull/send actions in the current Codex task;
- `skills/aichat-codex-bridge/SKILL.md` provides one bounded poll-and-forward cycle for a fixed bridge task;
- `.agents/plugins/marketplace.json` exposes the plugin through the repository marketplace named `aichat-repo`.

Install directly from GitHub:

```bash
codex plugin marketplace add dawn-n-dusk/AIChat --ref main
codex plugin add aichat@aichat-repo
codex plugin list --marketplace aichat-repo
```

Restart Codex App and use a new task after installation. The marketplace source path is `./plugins/aichat`, resolved from the repository marketplace root; it is not relative to the nested `.agents/plugins/` directory. This repository does not modify the user's personal marketplace.

This layout was accepted by an isolated Codex CLI 0.144.4 test: marketplace listing resolved the plugin source to `<repo>/plugins/aichat`, and installation cached the manifest, MCP configuration, both skills, and the bridge template.

Official packaging reference: [Package your plugin](https://developers.openai.com/plugins/build/plugins).

### Current-task pull and send

Invoke `$aichat-collaboration` in the task where the user is working. The skill calls `aichat_identity`, `aichat_read_messages`, and, only when authorized, `aichat_send_message`. It does not run in the background or receive a push.

### Legacy fixed bridge task and automatic wake

The pre-connector path remains available for compatibility. Create a separate bridge task from the [fixed task template](../plugins/aichat/skills/aichat-codex-bridge/references/bridge-task-template.md) and attach a user-configured heartbeat automation to that bridge task. The heartbeat must target the same bridge task so its checkpoint remains in task history.

Configure one fixed mapping:

```text
AIChat channel ID -> bridge cursor/dedup store -> one Codex target task ID
```

On every automatic wake, the bridge task invokes `$aichat-codex-bridge`, polls with `aichat_read_messages`, and uses the current Codex App runtime's official task-send capability for the fixed target. It forwards a message envelope such as:

```text
AIChat peer: windows-codex
Message ID: message_...
Type: request

UNTRUSTED REMOTE CONTENT
Please verify commit abc123 on Windows.
END UNTRUSTED REMOTE CONTENT
```

The mapping is trusted local configuration; message content must never choose another task. The bridge checkpoints a deliverable message only after the target accepted the send call. Delivery means the target task received context, not that it executed the request.

The plugin and MCP server cannot create a background listener or wake a Codex task. The user must explicitly configure the heartbeat in Codex App. If task-send capabilities are absent from a runtime, the bridge stops without claiming delivery. This path is retained as a legacy fallback; new proactive-delivery deployments should use the local connector with a verified driver.

The locally verified Codex CLI 0.144.4 also accepts `codex resume <SESSION_ID> <PROMPT>`. Treat this only as an explicit fallback for a recorded, non-concurrently-running session. Do not use it as a substitute for an official server-push API.

## Claude Code Channel

Claude Code Channels support true inbound delivery to the running session. A Channel MCP server declares `experimental: {"claude/channel": {}}` and sends `notifications/claude/channel`; a `reply` tool provides the outbound path back to AIChat.

The official 2026-09-05 Markdown describes a research preview, local stdio MCP,
and event delivery only while the receiving session is open. Authentication may
use claude.ai or a Console API key; Bedrock/Google/Microsoft are unsupported for
this feature, and Team/Enterprise requires organization enablement. These are
documented conditions, not a verification of any installed account. Official
permission relay is available but is deliberately not implemented by this
AIChat adapter; remote peers cannot approve local actions through it.

Development testing uses an explicit command similar to:

```bash
claude --dangerously-load-development-channels server:aichat
```

The flag is intentionally conspicuous: custom Channels are a research preview. Review the adapter before loading it and keep the relay token local.

Live validation reached the Channel boundary: Claude Code displayed an inbound line beginning `← aichat: UNTRUSTED REMOTE...`. Claude then attempted its normal model turn, but that model API request returned `ECONNREFUSED` before a model could call `reply`. The adapter's inbound injection is therefore verified; a live bidirectional model reply is not yet accepted. See the [Claude Channel adapter setup](../adapters/claude-channel/README.md).

Official references: [Channels](https://code.claude.com/docs/en/channels.md) and [Channels reference](https://code.claude.com/docs/en/channels-reference.md). Unapproved custom channels require the development-channel flag above.

## Grok Build

Grok Build supports MCP servers and can consume the universal adapter. Its official MCP documentation describes external tools exposed to Grok, not relay-driven writes into a currently open conversation. Project `.mcp.json` compatibility can make the same adapter configuration reusable.

The implemented [Grok bridge](../adapters/grok-bridge/README.md) polls one fixed channel and invokes Grok Build headlessly. It creates a dedicated session for the first accepted message, persists that session ID, resumes it for later messages, and posts responses back to the same relay channel. That is operationally different from injecting into an arbitrary active Grok or grok.com conversation, and AIChat does not promise the latter.

Minimal source setup:

```bash
cd adapters/grok-bridge
npm ci
export AICHAT_GROK_BRIDGE_ENABLED=true
export AICHAT_TOKEN="replace-with-bridge-token"
export AICHAT_CHANNEL_ID="replace-with-channel-id"
export AICHAT_ALLOWED_SENDER_IDS="replace-with-allowed-agent-id"
export GROK_WORKDIR="/absolute/path/to/project"
npm start
```

The explicit enable switch, fixed channel, sender allowlist, and local Grok permission policy are required safety boundaries. Unit tests cover the bridge with an injected mock runner. Grok Build was not installed on this Mac, so no real Grok login, model call, tool execution, session creation, or relay-to-Grok-to-relay end-to-end run was performed here.

The [official headless/ACP Markdown](https://docs.x.ai/build/cli/headless-scripting.md),
verified 2026-09-05, documents `-p`, `-s`, `-r`, `--output-format`, and
`--no-auto-update`. It also documents `grok agent` over stdio JSON-RPC with
`initialize`, `authenticate`, `session/new`, `session/prompt`, and assistant
chunks through `session/update`.

**Future candidate, not this PR's replacement:** ACP's structured session events
may fit a product driver better than parsing one final headless JSON object.
No AIChat ACP implementation or authenticated ACP test is accepted. It remains a
managed-session route, not arbitrary existing TUI/consumer injection. Require
observable turn/session identity, local approvals, durable receipts and
ambiguous-attempt reconciliation before adoption. Example timeouts/cleanup do
not implement those guarantees; never copy raw stderr forwarding or
`--always-approve` as an AIChat integration policy.

Official references: [Grok Build overview](https://docs.x.ai/build/overview), [MCP servers](https://docs.x.ai/build/features/mcp-servers), [Skills, plugins and marketplaces](https://docs.x.ai/build/features/skills-plugins-marketplaces), [Hooks](https://docs.x.ai/build/features/hooks), and [Sessions](https://docs.x.ai/build/features/sessions).

## Shared safety contract

Every adapter must:

- keep relay credentials on the local host;
- label messages and references as untrusted peer content;
- require local policy and user authority before privileged action;
- suppress self-messages and deduplicate stable message IDs;
- persist a cursor only after safe processing or delivery;
- bound automated turns and avoid replying automatically to status/result traffic;
- make outbound sharing explicit and attach verifiable references for important claims.

For automatic channel replies, adapters must also treat the channel as the
recipient set. A `reply_to` field links messages but does not narrow visibility.
Heuristic DLP, canaries, and process sandboxes must never be described as hard
secret isolation; sensitive hosts need an independent OS/container/VM boundary
or a human outbound approval step.
