# macOS Codex connector LaunchAgent

This package installs the event-driven Codex connector as a per-user
LaunchAgent. It is intentionally conservative:

- `CODEX_DRIVER=app-server` is fixed. The private Desktop owner IPC path remains
  disabled.
- Only `request` messages from exact allowed sender IDs start Codex turns.
- Automatic AIChat egress is disabled by default and requires the complete
  local `egress` opt-in described below. General accepted/running/completed/
  failed lifecycle status remains disabled even after opt-in.
- Relay WebSocket events wake ordered cursor recovery. The 30-second periodic
  recovery timer is disabled. Startup and WebSocket reconnect still recover from
  the persisted cursor.
- The connector targets one dedicated connector-owned Codex session, one fixed
  absolute working directory, `approvalPolicy=never`, and either a `readOnly` or
  bounded `workspaceWrite` sandbox with `networkAccess=false`.

The App Server process is an independent Codex runtime. It can resume the fixed
session and create a turn, but it does not prove attachment to an already-open
Codex Desktop UI task. Do not edit the same session concurrently in Desktop.

## Credential boundary

The Relay token is not accepted in `config.example.json`, copied into this
repository, placed in the LaunchAgent plist, or passed as a command-line
argument. At service start, `launcher.py` reads the existing private macOS
identity file (normally `~/Library/Application Support/AIChat/config.json`),
checks current-user ownership and mode `0600`, and puts the token only into the
connector process environment immediately before `execve`.

This protects the token from plist and command-line disclosure. It does not
isolate the token from another process already running as the same macOS user or
from an administrator. Use a separate OS user, container, or VM when that is a
required boundary.

## Prepare the dedicated session

1. Create a new Codex session used only by this connector.
2. Send one local user message containing a unique marker between 16 and 200
   characters. Put the exact same value in `task_marker`.
3. Record the session UUID as `target_thread_id`.
4. Create a dedicated project worktree and set its absolute path as
   `app_server_cwd`.
5. Keep `readOnly` for inspection-only work. For code changes, use:

```json
{
  "type": "workspaceWrite",
  "networkAccess": false,
  "writableRoots": [
    "/absolute/path/to/dedicated/project-worktree"
  ]
}
```

Every writable root must already exist and resolve inside `app_server_cwd`.
Neither sandboxing nor the connector's heuristic outbound DLP is a hard
confidentiality boundary for files readable by the same OS user.

## Install

Copy the example to a private path outside the repository, edit the non-secret
mapping, and restrict it:

```bash
mkdir -p "$HOME/Library/Application Support/AIChat"
install -m 600 deploy/macos/config.example.json \
  "$HOME/Library/Application Support/AIChat/codex-connector-settings.json"
```

Run a read-only preflight first:

```bash
deploy/macos/scripts/install.sh \
  --settings "$HOME/Library/Application Support/AIChat/codex-connector-settings.json" \
  --repository-root "$PWD"
```

The preflight validates settings but deliberately does not read the identity
token. Apply only after reviewing the reported paths:

```bash
deploy/macos/scripts/install.sh --apply \
  --settings "$HOME/Library/Application Support/AIChat/codex-connector-settings.json" \
  --repository-root "$PWD"
```

The preflight never reads the Relay identity token. When egress is enabled it
does inspect the separately configured canary file to enforce current-user
ownership, a single regular-file link, mode `0600` or stricter, and one bounded
line of content.

The installer stages a versioned runtime under
`~/Library/Application Support/AIChat/codex-connector-launchagent/releases`,
runs `npm ci --omit=dev --ignore-scripts`, snapshots the prior plist/settings/
launcher/current-release link, and only then replaces and bootstraps the
LaunchAgent. A failed bootstrap restores the snapshot. Real tokens are never
read by the installer.

## Check and rollback

The check is offline and never reads the identity file:

```bash
deploy/macos/scripts/check.sh
```

Preview or apply the most recent rollback:

```bash
deploy/macos/scripts/rollback.sh
deploy/macos/scripts/rollback.sh --apply
```

Rollback preserves the newer release directory for forensic inspection or a
later manual recovery. It validates and reports the restored egress posture,
then restores the previous current link, settings, launcher, plist, and
loaded/unloaded state recorded by the installer.

## Outbound collaboration

The package always fixes inbound delivery to `request`; `text`, `result`, and
`status` messages cannot start a Codex turn. A receipt also persists the source
message type and reply eligibility. Only completion of a delivered `request`
may produce a model `result` or connector-generated `status`; old receipt state
without that proof migrates as reply-ineligible.

To opt in to automatic results, first create a separate private canary:

```bash
umask 077
openssl rand -hex 32 > \
  "$HOME/Library/Application Support/AIChat/codex-connector-egress-canary.txt"
chmod 600 \
  "$HOME/Library/Application Support/AIChat/codex-connector-egress-canary.txt"
```

Then change the settings block to:

```json
{
  "egress": {
    "enabled": true,
    "acknowledged_channel_id": "the-exact-same-value-as-channel_id",
    "canary_file": "~/Library/Application Support/AIChat/codex-connector-egress-canary.txt",
    "allowed_reference_hosts": ["github.com"],
    "max_text_bytes": 8192
  }
}
```

`acknowledged_channel_id` must exactly equal `channel_id`. Reference entries
are exact public DNS hostnames, not wildcards or URLs; every emitted reference
must still be a credential-free HTTPS URL on that list. `max_text_bytes` must
be from 128 through 100000. Re-run install preflight, apply, and `check.sh`; all
three report `automatic_egress=true` only when this full opt-in validates.

If a model result is permanently rejected by the egress DLP/size/reference
policy, the connector durably quarantines it and independently queues one fixed
terminal `blocked` status. That status contains no original error, policy
detail, model text, or secret. Its stable idempotency key survives Relay send
failure and process restart. This terminal notification is independent of the
general lifecycle-status switch. Accepted/running/completed/failed
notifications remain off in this package; a completion without a model result
is checkpointed as a local-only suppression event so its receipt can be safely
released without Relay egress.

`reply_to` correlates a response with a prior message; it is not a private
recipient selector. Every channel member can read the response. Even with the
canary and DLP checks, automatic egress is heuristic and must not be treated as
proof that secrets cannot leave the host.
