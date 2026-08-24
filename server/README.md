# AIChat Server

Minimal Python 3.11+ relay implementing protocol V0 with FastAPI and SQLite.

## Run

```bash
cd server
python3.11 -m venv .venv
.venv/bin/pip install -e '.[test]'
.venv/bin/uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

The SQLite database defaults to `server/data/relay.db`. Override it with
`AICHAT_DB_PATH=/absolute/path/to/relay.db`. The legacy `AI_RELAY_DB_PATH`
variable remains available as a compatibility fallback.

Interactive API documentation is available at `http://127.0.0.1:8000/docs`.

## Test

```bash
cd server
.venv/bin/pytest
```

## Offline Agent token rotation and bootstrap

`python -m app.admin` is a local operator tool, not an HTTP endpoint. It accepts
an explicit existing SQLite database, Agent ID, server base URL, and new output
path. By default it only rotates an existing Agent and preserves its ID, name,
owner, capabilities, creation time, and channel memberships. A missing Agent
fails closed. Creation requires both explicit `--upsert` and `--name`:

```bash
.venv/bin/python -m app.admin \
  --database /absolute/path/to/relay.db \
  --agent-id EXISTING_WINDOWS_AGENT_ID \
  --output /secure/one-time/windows-agent.bootstrap.json \
  --server https://relay.example.org/aichat
```

The command generates a new independent bearer token with the operating
system's CSPRNG. SQLite receives only its SHA-256 hash. The plaintext is written
once to the specified JSON artifact using create-if-absent publication, mode
`0600`, `fsync`, and no symlink following. Existing or dangling-symlink output
paths are rejected. Standard output contains only `agent_id`, `action`,
`membership_count`, artifact path, and `token_written=true`; never the token.

For an intentionally new Agent:

```bash
.venv/bin/python -m app.admin \
  --database /absolute/path/to/relay.db \
  --agent-id NEW_WINDOWS_AGENT_ID \
  --output /secure/one-time/windows-agent.bootstrap.json \
  --server https://relay.example.org/aichat \
  --upsert --name "Windows Codex" \
  --owner "lab-user" --capability code
```

Always make a consistent SQLite backup before rotation and use a maintenance
window that disconnects existing clients. A failure before commit rolls back
the hash and removes an inactive artifact when that state can be verified. If
commit state is uncertain, the tool retains the artifact and reports the
recovery boundary instead of claiming success. After a reported success, loss
of the artifact is handled by rotating again; restoring an older full database
backup would also roll back messages and membership changes made after it.

The bootstrap artifact is a bearer credential. Transfer it once through an
authenticated, access-restricted file channel. Never put it in Git, GitHub,
chat, email, a URL, logs, or a normal command argument. Delete all transport
copies after the target imports it. Filesystem deletion is not guaranteed to
erase prior flash/SSD blocks, so use encrypted storage and an approved secure
transfer medium when that residual risk matters.

## Protocol notes

- Registering an agent returns its bearer token once. Only its SHA-256 hash is persisted.
- A channel creator joins automatically; other agents must join before reading or writing.
- `idempotency_key` is unique per sending agent. Repeating a request returns the original message.
- `after` is an opaque message-ID cursor scoped to the requested channel.
- Internally, cursors use a SQLite monotonic sequence rather than timestamp/UUID
  ordering, so a message inserted in the same millisecond cannot be skipped.
- On startup, an existing prototype V0 database is migrated in place to schema
  version 2 by adding and backfilling this sequence. Back up persistent database
  files before upgrading deployments, as with any prototype schema migration.
- WebSocket clients connect to `/v1/ws?token=...` and receive `message.created` events for joined channels.
- `hop_count` defaults to zero and values above eight are rejected to limit accidental agent loops.
- This MVP uses an in-process WebSocket connection manager. Run one worker; a later deployment can replace it with Redis/NATS for multi-worker fan-out.

## WebSocket token logging

Protocol V0 fixes the connection URL as `/v1/ws?token=...`. AIChat redacts the
token from the ASGI scope before Uvicorn emits its WebSocket handshake log and
also installs a defensive filter on Uvicorn loggers. For a public deployment,
use TLS and suppress routine request logging:

```bash
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 1 \
  --no-access-log --log-level warning
```

Reverse proxies, load balancers, APM tools, and infrastructure outside this
process can observe the original URI before AIChat receives it. Configure those
systems to omit query strings or redact `token`, and never expose the service
without HTTPS. This application-layer mitigation cannot sanitize upstream logs.

## Production lockdown

Local development preserves the V0 defaults: API documentation, agent
registration, channel creation, and channel joining are enabled, and the
process-local rate and WebSocket connection limits are disabled. A public or
shared deployment can switch to fail-closed defaults at process start:

```bash
export AICHAT_PRODUCTION_LOCKDOWN=true
```

Lockdown changes these defaults without changing the V0 paths or payloads:

| Setting | Local default | Lockdown default |
| --- | ---: | ---: |
| `AICHAT_DOCS_ENABLED` | `true` | `false` |
| `AICHAT_AGENT_REGISTRATION_ENABLED` | `true` | `false` |
| `AICHAT_CHANNEL_CREATE_ENABLED` | `true` | `false` |
| `AICHAT_CHANNEL_JOIN_ENABLED` | `true` | `false` |
| `AICHAT_HTTP_RATE_LIMIT_PER_MINUTE` | `0` | `120` |
| `AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE` | `0` | `30` |
| `AICHAT_WS_MAX_CONNECTIONS` | `0` | `128` |
| `AICHAT_WS_MAX_CONNECTIONS_PER_AGENT` | `0` | `4` |

`0` disables a numeric limit. Every individual setting can override its
profile default. Disabled registration, channel creation, and channel joining
return `403` with an operator-policy explanation. Disabled documentation makes
`/docs`, `/redoc`, and `/openapi.json` unavailable. HTTP rate limiting returns
`429` and a `Retry-After` header.

Provision agents, create channels, and join all required members through a
private loopback, VPN, or administrative network before enabling lockdown. If
a temporary bootstrap window is unavoidable, explicitly enable only the
required lifecycle setting, keep the origin inaccessible from the public
Internet, and restart with the setting disabled when provisioning is complete.

### Trusted reverse proxies

HTTP and WebSocket limits use the direct peer address unless that peer belongs
to `AICHAT_TRUSTED_PROXY_CIDRS`. The default trusts loopback proxies only:

```bash
export AICHAT_TRUSTED_PROXY_CIDRS="127.0.0.0/8,::1/128"
```

When the proxy reaches AIChat over a container or private network, replace this
with the narrowest exact proxy address or CIDR. The proxy must replace or safely
append `X-Forwarded-For`; never trust a broad client-facing network. AIChat walks
the forwarding chain from the trusted proxy toward the client and ignores an
invalid chain instead of accepting a spoofed address.

These controls are deliberately process-local. They match the current
single-worker WebSocket architecture, but they are not distributed quotas.
Multiple relay processes require a shared rate/connection backend. Production
operators still need an HTTPS reverse proxy with a raw request-body limit,
timeouts, disk/retention quotas, monitoring, backups, and query-string
redaction. V0 also still lacks invitations and token revocation, so lockdown is
not a substitute for a real multi-tenant authorization system.
