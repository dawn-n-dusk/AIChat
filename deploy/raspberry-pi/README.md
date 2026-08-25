# Raspberry Pi 3 public Relay deployment package

This package prepares a production-oriented, single-worker AIChat Relay for a
Debian 12/aarch64 Raspberry Pi 3. It is intentionally tailored to coexist with
the current host services:

- AIChat binds only to `127.0.0.1:8787`; port `8000` remains available to the
  existing `gohttpserver` process.
- The existing `/opt/caddy-hk/bin/caddy`, `/opt/caddy-hk/Caddyfile`, and
  `caddy-hk.service` remain the only public HTTPS entry point.
- The public base URL is configurable and currently planned as
  `https://dawnndusk-rustdesk.duckdns.org/aichat`.
- The managed `/aichat/*` route is inserted immediately before the existing
  `reverse_proxy 127.0.0.1:17300` fallback.
- RustDesk services and TCP/UDP ports `21115` through `21119` are inspected but
  never changed. These scripts contain no firewall mutation commands.

This directory is a deployment artifact, not evidence that the Pi has been
changed. Running validation locally does not connect to or deploy the host.

## Security decisions

1. `aichat-relay` is a dedicated system user with no login shell. Application,
   configuration, data, and backup directories are separate.
2. systemd hard-codes `--host 127.0.0.1`, runs one worker, denies non-loopback
   network access to the service cgroup, and grants write access only to the
   SQLite directory.
3. The installed `relay.env` explicitly enables `AICHAT_PRODUCTION_LOCKDOWN=true`,
   disables docs and all provisioning endpoints, limits HTTP traffic to 120
   requests per client IP per minute, limits WebSocket handshakes to 30 per
   client IP per minute, caps WebSockets at 128 globally and 4 per Agent, and
   trusts forwarded client addresses only from loopback (`127.0.0.0/8,::1/128`).
4. Caddy terminates HTTPS/WSS and `handle_path /aichat/*` strips the prefix
   before proxying. WebSocket Upgrade is handled by Caddy automatically.
5. Public identity/channel provisioning has two independent gates. Caddy keeps
   exact POST-only denies for Agent registration, exact channel creation, and
   channel join in an explicit ordered `route` before the Relay proxy; query
   strings still match because Caddy path matchers ignore them, while GET is not
   denied by this edge policy. Edge 403 responses carry
   `X-AIChat-Edge-Deny: provisioning` for acceptance checks. The Relay's
   production-lockdown feature flags independently deny the same mutations if a
   request reaches loopback. Controlled provisioning remains possible only by
   temporarily opening the required application flag and using an SSH tunnel
   over Tailscale while the public Caddy gate stays closed. A path prefix alone
   is routing, not access control.
6. Uvicorn access logs are disabled. Existing Caddy access logs remain enabled
   for the root/AeroLink site, while a top-level `log_skip` matcher excludes only
   `/aichat` and `/aichat/*` before redirects, provisioning denies, HTTP APIs,
   and WebSocket proxying. Caddy handler errors are not access logs and can still
   contain the failed request URI, so the route also assigns the private logger
   namespace `aichat_relay`. A managed global named logger retains only
   `http.log.error.aichat_relay` while replacing its query parameter named
   `token` with `REDACTED`; Caddy excludes that namespace from the default logger
   to prevent an unredacted duplicate. Other site access and error logs remain
   unchanged. This matters because protocol V0 places the bearer token in the
   WebSocket query string. The installer first patches a full candidate
   Caddyfile beside the live file, adapts it, structurally proves both controls,
   and only then runs Caddy validation before any package-owned
   service/data/release or live-Caddyfile change. Caddy validation may provision
   configured modules, so it is deliberately after the pure adapt/structural
   safety gate rather than described as side-effect-free. A Caddy build without
   the required log modules fails closed at this candidate step; adapted debug
   logging is also rejected.
7. SQLite backups use the SQLite backup API, run `PRAGMA quick_check`, compress
   atomically, write SHA-256 sidecars, and retain a configurable number of days.
   The script never copies a live `relay.db-wal` pair directly.

The V0 Relay still stores message content and metadata in plaintext and has no
token revocation endpoint or end-to-end encryption. The included rate and
connection limits are process-local and reset on restart; they are appropriate
only for this single-worker invited deployment.

## Package contents

- `config/deploy.env.example`: reviewed deployment values; contains no bearer token.
- `templates/aichat-relay.service`: loopback-only Relay unit.
- `templates/aichat-relay-backup.{service,timer}`: daily persistent backups.
- `templates/caddy-route.caddy`: ordered path-prefix proxy and exact POST-only
  public registration/channel provisioning denies.
- `templates/caddy-global-options.caddy`: scoped AIChat error-logger query redaction.
- `scripts/install.sh`: staged release, local health, atomic Caddy patch, validation,
  bounded public-health retry, initial-backup acceptance, and transactional
  failure rollback.
- `scripts/check.sh`: service, bind, HTTPS, registration deny, DB, backup, Caddy,
  optional WSS, and RustDesk non-interference checks.
- `scripts/rollback.sh`: atomic code rollback with optional explicit Caddy backup.
- `scripts/backup.py`: consistent SQLite backup implementation.
- `scripts/validate-package.sh`: non-root local artifact checks.

The lightweight `validate-package.sh` checks run in GitHub Actions on Linux.
The disposable Docker installer scenarios remain an explicit maintainer gate so
routine CI does not need to start privileged throwaway installation containers.

## Preflight

On the Pi, confirm the facts instead of assuming them:

```bash
uname -m
python3 --version
systemctl status caddy-hk.service --no-pager
systemctl --no-pager --type=service | grep -i rustdesk
sudo ss -lntup | grep -E ':(8000|8787|21115|21116|21117|21118|21119)([[:space:]]|$)' || true
sudo /opt/caddy-hk/bin/caddy validate \
  --config /opt/caddy-hk/Caddyfile --adapter caddyfile
```

Expected starting boundary:

- Python 3.11 or newer is available.
- `8787` is free; `8000` may remain occupied.
- RustDesk remains active on `21115-21119`.
- the Caddyfile contains exactly one fallback line matching the configured
  `AICHAT_CADDY_FALLBACK`;
- Caddy can adapt and validate the managed `log_name`/`log_skip` route and its
  scoped error-logger query filter. Access/error logging remains enabled for
  non-AIChat paths; adapted debug logging must be disabled.

No step in this package installs Caddy, modifies NAT/router rules, or edits a
firewall. Public TCP 443 and the existing certificate/DNS arrangement must
already work.

## Review and install

From a reviewed AIChat checkout on the Pi:

```bash
cd /path/to/AIChat
cp deploy/raspberry-pi/config/deploy.env.example \
  deploy/raspberry-pi/config/deploy.env
chmod 600 deploy/raspberry-pi/config/deploy.env
```

Edit `deploy.env` and set an immutable release ID, preferably including the Git
revision:

```text
AICHAT_RELEASE_ID=20260824-097ff400
```

Run the local package validator first:

```bash
deploy/raspberry-pi/scripts/validate-package.sh
```

Maintainers can also run the disposable Docker failure-injection suite. It
executes first-install and upgrade success plus first-install and upgrade
transient/persistent public-health behavior, local-health, daemon-reload, Caddy
reload, public network failures, initial-backup, previous-link, and incomplete
rollback scenarios inside throwaway containers; it never targets the host's
`/opt` or `/etc`:

```bash
AICHAT_RUN_DOCKER_INSTALL_TESTS=true \
  deploy/raspberry-pi/scripts/validate-package.sh
```

Then explicitly install:

```bash
sudo deploy/raspberry-pi/scripts/install.sh \
  deploy/raspberry-pi/config/deploy.env
```

The installer performs these state changes only when it is run:

1. rejects malformed `current`/`previous` links and an existing release path
   before changing package state;
2. creates `aichat-relay` and the four scoped directory trees;
3. creates a release-specific Python virtual environment under
   `/opt/aichat-relay/releases/<release-id>`, normalizes it to root-owned
   read/traverse permissions, and proves the service account can execute Uvicorn
   and import the application before switching `current`;
4. snapshots package-owned runtime files and systemd units, installs the
   loopback Relay and backup units, then atomically switches `current`;
5. starts and accepts local `/health`;
6. first validates a full candidate that excludes only the AIChat prefix from
   access logs and scopes its handler errors to a query-redacting named logger,
   then backs up and atomically patches the existing Caddyfile before the
   configured fallback, reloads Caddy, and accepts public `/aichat/health` with
   at most five 15-second probes separated by four 10-second sleeps. Each probe
   disables root curl configuration and curl's own retries, and suppresses
   response/error content. The roughly 115-second worst-case bound covers the
   route's 30-second active-health interval plus 3-second timeout without
   waiting indefinitely;
7. creates an initial consistent SQLite backup, enables the daily timer, and
   only then records the formerly current release as `previous`.

If staging, Relay start, Caddy validation/reload, public health, or initial
backup acceptance fails, the installer restores the exact prior `current` and
`previous` link states, package-owned runtime files and three systemd units,
then reloads systemd and restores the Relay service and backup timer's prior
enabled/active states. Caddy is restored atomically when it had changed. A
rollback failure is reported as incomplete rather than being described as a
success, and the transaction snapshot path is retained and printed for manual
recovery.

The installer intentionally retains a newly seeded database and a staged
release directory after a failed attempt for recovery and audit. It removes the
failed attempt's `current` link on a first install and never creates a
self-referential link. Inspect retained artifacts, correct the cause, and use a
new immutable release ID for the retry; the installer refuses to overwrite an
existing file, directory, symlink, or dangling symlink at the release path. It
prints the exact Caddy backup path on success; retain it for explicit rollback.

## Migrating the existing identity database before first start

Agent tokens are stored only as hashes, so preserving existing identities and
channel membership means seeding the existing SQLite database before the first
production start. Never copy a live `relay.db` alone while WAL mode is active.
Create a consistent gzip snapshot on the source host with the package's SQLite
backup API:

```bash
python3 deploy/raspberry-pi/scripts/backup.py \
  --database /absolute/path/to/live/relay.db \
  --output-dir /secure/transfer \
  --retention-days 14
```

Transfer both the resulting `.sqlite3.gz` file and its `.sha256` sidecar through
an authenticated channel, verify the checksum, then set:

```text
AICHAT_REQUIRE_SEED_DB=true
AICHAT_SEED_DB=/secure/transfer/relay-YYYYMMDDTHHMMSSZ.sqlite3.gz
```

On a first install, `install.sh` validates/decompresses the seed, runs SQLite
`quick_check`, uses the SQLite backup API again to create the target atomically,
sets `0600` ownership, and only then starts Uvicorn. It refuses to create an
empty production identity database while `AICHAT_REQUIRE_SEED_DB=true`. On an
upgrade where `/var/lib/aichat-relay/relay.db` already exists, the installer
preserves it and does not overwrite it from the seed path.

## Local administrator provisioning without public endpoints

### Rotate an existing Agent for Windows bootstrap

Prefer rotation when the Windows Agent already exists: it preserves the exact
Agent ID and all channel memberships. This is an offline administrator workflow,
not a new public API. First create and identify a consistent backup:

```bash
sudo systemctl start aichat-relay-backup.service
sudo journalctl -u aichat-relay-backup.service -n 30 --no-pager
sudo ls -l /var/backups/aichat-relay
```

Stop the Relay for a short maintenance window so old HTTP/WebSocket sessions are
closed, create a private output directory, and run the CLI from the installed
release. Replace only the explicit Agent ID:

```bash
sudo systemctl stop aichat-relay.service
if sudo systemctl is-active --quiet aichat-relay.service; then
  echo "Relay is still active; refusing token rotation" >&2
  exit 1
fi
sudo install -d -m 0700 -o aichat-relay -g aichat-relay \
  /var/lib/aichat-relay/bootstrap
sudo -u aichat-relay /opt/aichat-relay/current/venv/bin/python -m app.admin \
  --database /var/lib/aichat-relay/relay.db \
  --agent-id EXISTING_WINDOWS_AGENT_ID \
  --output /var/lib/aichat-relay/bootstrap/windows-agent.bootstrap.json \
  --server https://dawnndusk-rustdesk.duckdns.org/aichat \
  --confirm-relay-stopped
sudo systemctl start aichat-relay.service
sudo deploy/raspberry-pi/scripts/check.sh \
  deploy/raspberry-pi/config/deploy.env
```

Default behavior fails if the Agent does not exist. A genuinely new identity
requires the visibly different `--upsert --name "Windows Codex"` form; do not
use it to recover an existing ID by guesswork. Existing rotations change only
`agents.token_hash`. They do not change name, owner, capabilities, timestamps,
channels, messages, or `channel_members` rows. The safe stdout summary includes
the preserved Agent ID, `action`, membership count, artifact path, and
`token_written=true`, but no bearer token.

`--confirm-relay-stopped` is mandatory because bearer authentication is checked
when an HTTP request or WebSocket is established. Updating the stored hash does
not revoke an already authenticated WebSocket by itself. Never pass the flag
while the service is active; the explicit inactive check above is the production
gate that closes old sessions before the hash changes.

Transfer the `0600` artifact once through authenticated SCP over the private
Tailscale route, an encrypted removable volume, or an equivalently restricted
file channel. Do not place it in Git/GitHub, chat, email, a web URL, logs, or an
ordinary command argument. Have Windows run `deploy/windows/import-bootstrap.ps1`;
after Windows reports `token_present=true` and passes the online identity check,
delete the Pi and transport copies:

```bash
sudo rm -f /var/lib/aichat-relay/bootstrap/windows-agent.bootstrap.json
```

Deletion does not guarantee block-level erasure on SSD/flash media. The CLI
rolls back the database hash when a pre-commit failure is verifiably safe. If it
reports an uncertain commit, retain the artifact and backup for inspection. If
a successful artifact is lost, rotate again. Restore the full SQLite backup
only as a deliberate stopped-service recovery because doing so also reverts
later messages and membership changes.

### Ensure a channel and its exact members locally

Production channel provisioning uses the local administrator CLI. Keep
`AICHAT_PUBLIC_PROVISIONING=false` and all three application provisioning flags
disabled; do not expose or temporarily enable the HTTP channel-create or join
routes for this operation. Start and identify a consistent backup before every
production change:

```bash
sudo systemctl start aichat-relay-backup.service
sudo journalctl -u aichat-relay-backup.service -n 30 --no-pager
sudo ls -l /var/backups/aichat-relay
```

Run an exact dry-run as the Relay service account. Replace every placeholder,
repeat `--member-agent-id` for the complete desired membership, and choose one
of those members as the explicit logical creator/audit attribution:

```bash
sudo -u aichat-relay /opt/aichat-relay/current/venv/bin/python -m app.admin \
  ensure-channel \
  --database /var/lib/aichat-relay/relay.db \
  --name "Shared research project" \
  --description "Mac and Windows AI collaboration" \
  --created-by-agent-id MAC_AGENT_ID \
  --member-agent-id MAC_AGENT_ID \
  --member-agent-id WINDOWS_AGENT_ID \
  --dry-run
```

`would_create` and `would_reuse` exit successfully. `would_conflict` exits 2
and means the existing state must be inspected, not repaired by this command.
After reviewing the backup and audit summary, repeat the identical command
without `--dry-run`, then run the normal package acceptance check. No Relay
restart is required: the CLI uses `BEGIN IMMEDIATE`, commits the channel and all
membership rows together, and rolls back on validation, write, or commit
failure.

The creator must be an existing Agent and an exact listed member. It supplies
the schema's logical creator and administrator audit attribution only; it does
not confer host permissions or represent consent from that Agent. Name is
normalized, while description, creator, and membership are exact immutable
matches. Repeating the same definition reuses the same UUID. Any same-name
description, creator, or member difference, any missing/duplicate member, or
multiple existing same-name rows fails closed without changing the channel or
its messages. `--description` is mandatory and its supplied value is matched
exactly.

The JSON summary contains channel audit metadata only. The command never reads
or prints bearer credentials or their database digests. If SQLite reports a
storage or uncertain commit failure, inspect the just-created consistent backup
before retrying instead of assuming that a repair is safe.

### Legacy private HTTP registration window

The local administrator CLI is the production path for Agent bootstrap and
channel provisioning. The following private HTTP procedure remains only for
legacy client compatibility and must not be used to provision a channel now
that `ensure-channel` is available.

Keep `AICHAT_PUBLIC_PROVISIONING=false`. Application-level provisioning is also
disabled. For a controlled bootstrap window, edit `/etc/aichat-relay/relay.env`,
temporarily set only `AICHAT_AGENT_REGISTRATION_ENABLED=true`, and restart
`aichat-relay.service`. Leave channel creation and joining disabled. The public
Caddy route continues to return 403 while `AICHAT_PUBLIC_PROVISIONING=false`.
Then create an SSH tunnel to the Pi over its private Tailscale address or
hostname:

```bash
# macOS/Linux OpenSSH
ssh -N -L 18787:127.0.0.1:8787 USER@RASPBERRY_PI_TAILSCALE_HOST
```

```powershell
# Windows PowerShell OpenSSH
ssh.exe -N -L 18787:127.0.0.1:8787 USER@RASPBERRY_PI_TAILSCALE_HOST
```

In a second private terminal, register through the tunnel:

```bash
aichat --server http://127.0.0.1:18787 register mac-codex \
  --owner dawnndusk --capability code
```

The CLI saves the returned token locally. Close the tunnel after registration,
restore the Agent registration flag to `false`, restart the Relay, and use the
local `ensure-channel` workflow above for membership. Run `check.sh` before
switching the client to the public base URL. Do not use the public path or an
obscure URL as a substitute for the 403 provisioning gates.

## Acceptance checks

```bash
sudo deploy/raspberry-pi/scripts/check.sh \
  deploy/raspberry-pi/config/deploy.env
```

For an optional WSS handshake, inject an existing token only into the check
process; the script redacts errors and never prints the query-bearing URL:

```bash
sudo --preserve-env=AICHAT_CHECK_TOKEN \
  AICHAT_CHECK_TOKEN='local-secret' \
  deploy/raspberry-pi/scripts/check.sh \
  deploy/raspberry-pi/config/deploy.env
```

The acceptance script never sends a schema-valid Agent registration or channel
creation payload. Its public edge probes cover missing and deliberately invalid
tokens for all three provisioning paths, and add a valid-token pass when
`AICHAT_CHECK_TOKEN` is supplied. Registration and channel creation use `{}`;
join targets a known-nonexistent ID. Every POST includes a query string, must
return 403, and must carry `X-AIChat-Edge-Deny: provisioning`; GET requests to
the same paths must not carry that marker or return the edge 403. This proves
the edge matcher is POST-only, query-independent, and ahead of the Relay without
risking a database write.

Application lockdown remains the second gate. `check.sh` verifies the installed
feature flags exactly, uses invalid local registration/channel-create bodies to
prove the acceptance run cannot create records, and, when a valid token is
supplied, requires a nonexistent channel join to return the application 403.
Without the token, that join must stop at the local authentication gate with
401. Registration and channel creation cannot be actively driven through their
application feature gates without sending a schema-valid mutation, so their
runtime protection is established by the installed-setting checks plus the
Relay security test suite, not by a potentially state-changing acceptance
request. The token is also reused for the optional WSS handshake and is never
printed.

Expected acceptance includes:

- exactly one Relay listener at `127.0.0.1:8787`;
- local and public health success;
- installed production profile values match the reviewed deployment config;
- local `/docs` and `/openapi.json` return 404;
- application lockdown settings match the reviewed false values; invalid local
  registration/channel-create bodies return 422 without creating records, and
  a valid-token nonexistent join returns the application 403 when
  `AICHAT_CHECK_TOKEN` is supplied (otherwise it returns the auth-gate 401);
- public Agent registration, channel creation, and channel join return a
  marker-bearing edge 403 for missing/invalid and optional valid tokens even
  with query strings, while GET is not rejected by the POST-only edge matcher;
- Caddy validates and contains the managed route/global logger block; adapted
  JSON binds the three exact provisioning denies to the direct parent of the
  unique exact Relay route and proves that route precedes the unique fallback in
  their real ancestor context, plus the exact AIChat-only `log_name`/`log_skip`,
  named error logger query redaction, and default-logger exclusion, while
  existing root/AeroLink logs remain and debug logging is rejected;
- SQLite and latest-backup integrity pass;
- RustDesk listeners remain visible and no AIChat unit references their ports.

## Mac and Windows client cutover

The public base includes `/aichat`; do not append `/v1`. HTTP clients concatenate
their `/v1/...` paths, while Python and Codex connector WebSocket builders derive
`wss://dawnndusk-rustdesk.duckdns.org/aichat/v1/ws`. Caddy strips `/aichat`
before proxying, so no Relay application code change is required.

macOS/Linux temporary cutover:

```bash
export AICHAT_SERVER=https://dawnndusk-rustdesk.duckdns.org/aichat
aichat whoami
```

Windows PowerShell temporary cutover:

```powershell
$env:AICHAT_SERVER = "https://dawnndusk-rustdesk.duckdns.org/aichat"
aichat whoami
```

For the Codex connector or another long-running adapter, update its protected
launcher/service environment and restart only that local adapter. For the MCP
plugin using the private AIChat `config.json`, change only its `server` field;
preserve the existing `token`, `channel_id`, and file permissions, then restart
the AI product/task so it reloads configuration.

Verify on both hosts:

```bash
aichat whoami
aichat inbox --channel CHANNEL_ID --limit 1
aichat watch --channel CHANNEL_ID --websocket
```

## Backup and restore

Inspect timers and create an on-demand backup:

```bash
systemctl list-timers aichat-relay-backup.timer
sudo systemctl start aichat-relay-backup.service
sudo journalctl -u aichat-relay-backup.service -n 30 --no-pager
sudo ls -l /var/backups/aichat-relay
```

Restore is an explicit maintenance operation: stop the Relay, preserve the
current DB, decompress a chosen backup to a temporary file, run
`PRAGMA quick_check`, atomically replace `relay.db`, fix ownership/mode, and
restart. Code rollback intentionally never replaces the database.

## Rollback

Roll back to the previously active code release:

```bash
sudo deploy/raspberry-pi/scripts/rollback.sh \
  deploy/raspberry-pi/config/deploy.env previous
```

Or select a named release:

```bash
sudo deploy/raspberry-pi/scripts/rollback.sh \
  deploy/raspberry-pi/config/deploy.env 20260824-097ff400
```

To restore a specific Caddy backup printed by `install.sh`, pass it as the third
argument. The script validates it before replacement and restores the current
Caddyfile if reload fails:

```bash
sudo deploy/raspberry-pi/scripts/rollback.sh \
  deploy/raspberry-pi/config/deploy.env previous \
  /opt/caddy-hk/Caddyfile.aichat-backup-YYYYMMDDTHHMMSSZ
```

Rollback does not alter RustDesk, the fallback upstream, firewall policy, or the
SQLite database.
