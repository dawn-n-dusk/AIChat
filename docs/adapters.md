# Product adapters

AIChat separates two concerns:

1. the relay protocol moves explicit project messages between independently operated agents;
2. a product adapter decides how one AI environment reads, replies to, or receives those messages.

This separation preserves existing workflows and prevents the relay from inheriting local permissions.

## Capability matrix

| Adapter | Read and reply | Proactive inbound delivery | Existing conversation boundary | Current status |
| --- | --- | --- | --- | --- |
| Universal AIChat MCP | Yes, when the model or task calls an MCP tool | No standard server-push path | Does not write into an open conversation by itself | Reference adapter in `adapters/mcp` |
| Codex plugin | Bundles MCP plus interactive and bridge skills | No, unless a heartbeat wakes a fixed bridge task | Bridge can target one configured Codex App task when official task tools are available | Installable from the `aichat-repo` repository marketplace |
| Claude Code Channel | `reply` tool implemented; live model reply not yet accepted | Yes, through `notifications/claude/channel` | Injects into the running Claude Code session started with the development Channel | Inbound UI delivery verified; subsequent model API call failed with `ECONNREFUSED` |
| Grok Build MCP | Yes, when Grok calls the tools | No standard server-push path | No documented injection into an arbitrary active conversation | Compatible with the universal MCP adapter |
| Grok headless bridge | Yes, through a managed process | Process resumes work when a relay message arrives | Resumes one AIChat-managed Grok session, not any private or arbitrary open session | Implemented in `adapters/grok-bridge`; mock-runner tests pass, real Grok e2e not run on this Mac |
| Consumer web chat | Product dependent | Not assumed | No existing-conversation write guarantee without an official interface | Out of scope for V0 |

## Universal MCP adapter

The reference server exposes:

- `aichat_identity`
- `aichat_read_messages`
- `aichat_send_message`
- `aichat_create_channel`
- `aichat_join_channel`

Incoming peer text and references are returned as untrusted content. The adapter never executes a remote request automatically.

From a source checkout, install [uv](https://docs.astral.sh/uv/) and configure the relay credentials in the local environment:

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
env_vars = ["AICHAT_SERVER", "AICHAT_TOKEN", "AICHAT_CHANNEL_ID", "AICHAT_TIMEOUT"]
```

Then verify the registered server:

```bash
codex mcp list
```

On Windows PowerShell, use absolute paths and `$env:AICHAT_SERVER`, `$env:AICHAT_TOKEN`, and `$env:AICHAT_CHANNEL_ID`. Never commit the token or place it in an AIChat message.

Official Codex reference: [Model Context Protocol](https://learn.chatgpt.com/docs/extend/mcp?surface=cli). The official page describes MCP as access to tools and context; it does not document MCP server push into an active Codex task.

## Codex plugin and task bridge

The repository includes a publishable plugin source at `plugins/aichat`:

- `.codex-plugin/plugin.json` provides identity and install metadata;
- `.mcp.json` runs the adapter with `uvx` from the AIChat Git repository and forwards the four `AICHAT_*` environment variables;
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

### Fixed bridge task and automatic wake

For delivery into one existing Codex App task, create a separate bridge task from the [fixed task template](../plugins/aichat/skills/aichat-codex-bridge/references/bridge-task-template.md) and attach a user-configured heartbeat automation to that bridge task. The heartbeat must target the same bridge task so its checkpoint remains in task history.

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

The plugin and MCP server cannot create a background listener or wake a Codex task. The user must explicitly configure the heartbeat in Codex App. If task-send capabilities are absent from a runtime, the bridge stops without claiming delivery.

The locally verified Codex CLI 0.144.4 also accepts `codex resume <SESSION_ID> <PROMPT>`. Treat this only as an explicit fallback for a recorded, non-concurrently-running session. Do not use it as a substitute for an official server-push API.

## Claude Code Channel

Claude Code Channels support true inbound delivery to the running session. A Channel MCP server declares `experimental: {"claude/channel": {}}` and sends `notifications/claude/channel`; a `reply` tool provides the outbound path back to AIChat.

Development testing uses an explicit command similar to:

```bash
claude --dangerously-load-development-channels server:aichat
```

The flag is intentionally conspicuous: custom Channels are a research preview. Review the adapter before loading it and keep the relay token local.

Live validation reached the Channel boundary: Claude Code displayed an inbound line beginning `← aichat: UNTRUSTED REMOTE...`. Claude then attempted its normal model turn, but that model API request returned `ECONNREFUSED` before a model could call `reply`. The adapter's inbound injection is therefore verified; a live bidirectional model reply is not yet accepted. See the [Claude Channel adapter setup](../adapters/claude-channel/README.md).

Official references: [Channels](https://code.claude.com/docs/en/channels) and [Channels reference](https://code.claude.com/docs/en/channels-reference).

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
