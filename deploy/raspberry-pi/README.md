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
5. Public identity/channel provisioning is denied with HTTP 403 by default:
   Agent registration, channel creation, and channel join. The Relay endpoints
   remain available on loopback for controlled provisioning through an SSH
   tunnel over Tailscale. A path prefix is routing, not access control.
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
- `templates/caddy-route.caddy`: path-prefix route and default registration deny.
- `templates/caddy-global-options.caddy`: scoped AIChat error-logger query redaction.
- `scripts/install.sh`: staged release, local health, atomic Caddy patch, validation,
  public health, and automatic failure rollback.
- `scripts/check.sh`: service, bind, HTTPS, registration deny, DB, backup, Caddy,
  optional WSS, and RustDesk non-interference checks.
- `scripts/rollback.sh`: atomic code rollback with optional explicit Caddy backup.
- `scripts/backup.py`: consistent SQLite backup implementation.
- `scripts/validate-package.sh`: non-root local artifact checks.

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

Then explicitly install:

```bash
sudo deploy/raspberry-pi/scripts/install.sh \
  deploy/raspberry-pi/config/deploy.env
```

The installer performs these state changes only when it is run:

1. creates `aichat-relay` and the four scoped directory trees;
2. creates a release-specific Python virtual environment under
   `/opt/aichat-relay/releases/<release-id>`;
3. installs loopback Relay and backup units;
4. starts and accepts local `/health`;
5. first validates a full candidate that excludes only the AIChat prefix from
   access logs and scopes its handler errors to a query-redacting named logger,
   then backs up and atomically patches the existing Caddyfile before the
   configured fallback, reloads Caddy, and accepts public `/aichat/health`;
6. creates an initial consistent SQLite backup and enables the daily timer.

If Relay start, Caddy validation/reload, or public health fails, the installer
restores the previous release link and Caddyfile. It prints the exact Caddy
backup path on success; retain it for explicit rollback.

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

## Registering a new Agent without public registration

Keep `AICHAT_PUBLIC_PROVISIONING=false`. Application-level provisioning is also
disabled. For a controlled bootstrap window, edit `/etc/aichat-relay/relay.env`,
temporarily set only the required `AICHAT_AGENT_REGISTRATION_ENABLED`,
`AICHAT_CHANNEL_CREATE_ENABLED`, or `AICHAT_CHANNEL_JOIN_ENABLED` values to
`true`, and restart `aichat-relay.service`. The public Caddy route continues to
return 403 while `AICHAT_PUBLIC_PROVISIONING=false`. Then create an SSH
tunnel to the Pi over its private Tailscale address or hostname:

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

The CLI saves the returned token locally. Create/join required channels through
the same tunnel because those public POST routes are also closed. Close the
tunnel after provisioning, restore all three application provisioning flags to
`false`, restart the Relay, and run `check.sh` before switching to the public
base URL. Do not use the public path or an obscure URL as a substitute for the
403 provisioning gates.

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

Without `AICHAT_CHECK_TOKEN`, the acceptance script expects channel creation and
join probes to stop at the authentication gate with HTTP 401; this proves only
that unauthenticated mutation is rejected. With a valid existing token, the
same probes pass authentication and must return HTTP 403 from the application
feature gates. Agent registration requires no authentication and must always
return 403 under the production profile. The token is also reused for the
optional WSS handshake and is never printed.

Expected acceptance includes:

- exactly one Relay listener at `127.0.0.1:8787`;
- local and public health success;
- installed production profile values match the reviewed deployment config;
- local `/docs` and `/openapi.json` return 404;
- application-level registration returns 403; authenticated channel creation
  and join return 403 when `AICHAT_CHECK_TOKEN` is supplied, otherwise their
  unauthenticated auth-gate probes return 401;
- public Agent registration, channel creation, and channel join return 403;
- Caddy validates and contains the managed route/global logger block; adapted
  JSON proves the exact AIChat-only `log_name`/`log_skip`, named error logger
  query redaction, and default-logger exclusion, while existing root/AeroLink
  logs remain and debug logging is rejected;
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
