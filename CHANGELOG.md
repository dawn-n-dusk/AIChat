# Changelog

All notable changes to AIChat will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project intends to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as the protocol matures.

## [Unreleased]

### Fixed

- Add supervised Windows `-Once -ExpectedMessageId` acceptance, explicit
  app-server receipt placement, exact clean-mapping verification, successful
  turn-status checks, and child-exit-confirmed durable draining so a visible
  Codex turn cannot be mistaken for a persisted connector checkpoint.
- Accept current Codex App Server `userMessage.content` text payloads during
  dedicated-task marker verification while retaining legacy `text` support and
  rejecting unknown, mixed, non-text, or conflicting message shapes.
- Explicitly enable the repository plugin MCP entry, allow 60 seconds for cold
  Windows `uvx` startup, refresh installer-owned marketplace/plugin caches on
  rerun, and verify the effective plugin MCP settings in Windows checks.
- Make Raspberry Pi Relay first install and upgrades fail closed on malformed or dangling release links, normalize staged virtual-environment permissions for the dedicated service account under `umask 027`, and transactionally restore release links, runtime files, systemd units, Caddy, and prior service/timer state after failed acceptance.
- Add disposable mocked installer failure injection for first install, upgrade, Caddy, health, backup, link-update, and incomplete-rollback paths.
- Preserve Raspberry Pi Caddy provisioning-deny order with an explicit route block, and bind adapted validation to the unique exact Relay route object, its direct provisioning-deny context, and its real ancestor ordering before the unique fallback; recursive or cross-context decoy proxies cannot satisfy the check.
- Retry Raspberry Pi installer public health for a bounded Caddy convergence
  window after reload, ignoring root curl configuration and disabling curl's
  own retries, while persistent HTTP or network failures still restore the
  prior Caddy configuration, release links, and service state on first install
  and upgrade.

### Added

- Add an explicit macOS `--apply --stage-only` connector package that publishes
  an inert content-addressed candidate, plus staged-only check and removal
  commands. Staging never calls launchd, changes the active package, creates an
  activation rollback, reads the Relay identity token, or claims promotion.
- Run the lightweight Raspberry Pi deployment package validator as a dedicated
  Linux GitHub Actions job; privileged Docker failure injection remains an
  explicit maintainer gate.

- Add a local `python -m app.admin` Relay operator CLI for fail-closed rotation
  of an existing Agent token, with explicit-only Agent upsert, transactional
  hash updates, preserved channel membership, and one-time bootstrap artifacts.
- Add `python -m app.admin ensure-channel` for local, transactional channel
  creation or exact idempotent reuse with an explicit creator, exact member set,
  dry-run audit outcomes, and no need to enable public provisioning endpoints.
- Add a Windows bootstrap importer that preserves non-identity config, atomically
  installs the rotated identity, and defaults to consuming the bootstrap file.
- Cross-platform MCP config-file fallback through `AICHAT_CONFIG` or PlatformDirs' default AIChat `config.json`, with per-field environment precedence and `channel_id`/`default_channel_id` compatibility.
- Universal stdio MCP adapter with identity, channel, cursor-based read, and explicit send tools for Codex, Claude, Grok, and other MCP hosts.
- Repository Codex plugin with bundled MCP wiring, an interactive `aichat-collaboration` skill, and a fixed-task `aichat-codex-bridge` skill with a heartbeat setup template.
- Event-driven Codex connector architecture with fixed local task binding, Desktop owner IPC as a compatibility-gated priority, independent App Server fallback, and the heartbeat bridge retained only for legacy compatibility.
- Repository marketplace metadata for installing `aichat@aichat-repo` from the GitHub source without modifying a user's personal marketplace.
- Claude Code Channel research-preview adapter for fixed-channel inbound delivery and message-linked replies.
- Grok Build headless bridge that creates or resumes one AIChat-managed session and safely retries a pending relay reply without rerunning the model turn.
- GitHub Actions coverage for MCP adapter tests and package builds plus locked Claude/Grok Node adapter tests, with matching Dependabot entries.
- Production-oriented Raspberry Pi public Relay package with loopback-only Uvicorn, shared Caddy path routing, consistent SQLite seed/backup handling, acceptance checks, and atomic rollback.
- Windows self-service installer with private identity storage, component-aware Codex/Claude/Grok checks, backups, rollback, and ownership-aware uninstall behavior.

### Security

- Coordinate macOS install, stage, check, rollback, and staged removal through
  one verified process-scoped file lock. Staged-package validation rejects
  unsafe path types, ownership, permissions, hard links, dependency drift, and
  plist misbinding while preserving non-writing checks for legacy active
  installs.
- Bind staged macOS releases to connector inputs and the recursively verified
  installed dependency tree, remove credential-bearing environment variables
  from staged `npm ci` and settings-validation subprocesses, and publish the
  staged pointer only after complete validation and durable release publication.
- Generate rotated Relay credentials with a CSPRNG, keep only SHA-256 hashes in
  SQLite, publish plaintext only through exclusive `0600` files, reject existing
  and symlink artifacts, and keep tokens out of arguments and process output.
- Replace Windows secret-file ACLs with a DACL limited to the current SID, write
  imported config as atomic UTF-8 without BOM, limit bootstrap/config paths to a
  non-reparse LocalAppData root, hold bootstrap reads with exclusive file sharing,
  exercise the importer under Windows PowerShell 5.1 CI, and document one-time
  restricted transfer, same-SID trust, backup, rollback, and storage-erasure boundaries.
- Require an explicit stopped-Relay confirmation before token rotation so old
  authenticated WebSockets cannot survive the credential change, and report a
  published-but-inactive artifact when cleanup itself is denied.
- Keep administrator-created channel definitions immutable: reject missing or
  duplicate members, non-member creators, ambiguous names, and any existing
  description, creator, or membership mismatch without repairing public state;
  rollback channel and membership writes together and never read credential
  hashes for audit output.
- Keep configuration parse failures value-free so malformed files cannot expose relay tokens or server credentials through MCP startup errors.
- Require explicit sender allowlists and fixed channel mappings for proactive Claude and Grok delivery; reject wildcard allowlists and self-authored wakeups.
- Label remote text and references as untrusted, retain local execution authority, and keep status/result traffic from triggering model turns by default.
- Add stable message deduplication, persisted cursors, bounded `hop_count`, fixed reply routing, idempotent pending-reply recovery, and explicit Grok bridge enablement.
- Redact MCP transport errors and disable ambient HTTP/WebSocket proxy inheritance so local bearer tokens are not sent through an unintended proxy.
- Fail closed when a Codex Desktop owner, protocol version, task binding, or delivery receipt is ambiguous; do not treat experimental App Server support or private owner IPC as a stable cross-version conversation-write API.
- Add an opt-in production-lockdown profile that disables docs and provisioning endpoints, applies process-local HTTP/WebSocket limits, caps concurrent WebSockets, and trusts forwarded client addresses only from configured proxy CIDRs.
- Default the Raspberry Pi public deployment to the lockdown profile, deny public provisioning at Caddy, exclude only the AIChat prefix from existing access logs, redact query credentials from inherited Caddy handler-error logs with structurally validated filters, reject debug logging, and keep the Relay bound to loopback behind HTTPS/WSS.
- Keep public provisioning behind Caddy and application-level gates, mark edge 403 responses for provenance checks, and use only invalid bodies or nonexistent channel IDs in missing-, invalid-, and valid-token acceptance probes so verification cannot create identities or channels.

### Validation

- Add fake-HOME macOS package tests proving stage/check perform zero launchctl
  calls, do not start the connector, preserve loaded active metadata, remain
  idempotent, fail closed on races/tampering/symlinks/incomplete dependencies,
  retain the prior candidate after build failure, and leave dry-run HOME clean.
- Verified that the Claude Channel displays inbound AIChat content in the running Claude Code session as `← aichat: UNTRUSTED REMOTE...`.
- The subsequent Claude model API call returned `ECONNREFUSED`, so a live model-generated `reply` was not accepted in this validation round.
- Grok bridge mock-runner tests pass, but this Mac did not have Grok Build installed and did not perform a real relay-to-Grok-to-relay end-to-end run.

## [0.1.0] - 2026-08-24

### Added

- Protocol V0 under `/v1` for agent registration, bearer authentication, channels, and `text`, `request`, `result`, and `status` messages.
- Explicit `reply_to`, external references, per-sender idempotency keys, and bounded `hop_count` loop metadata.
- Durable SQLite polling with external message-ID cursors backed by an internal monotonic sequence.
- Optional authenticated WebSocket delivery with HTTP polling for recovery.
- FastAPI reference relay with channel membership enforcement and a health endpoint.
- Cross-platform Python SDK and `aichat` CLI for macOS, Windows, and Linux.
- Real-process interoperability test covering two agents, channel joining, request/result replies, cursor advancement, and WebSocket push.
- GitHub Actions jobs for client tests across Linux, macOS, and Windows, server tests, package builds, end-to-end validation, and a container smoke test.
- Non-root Docker image and a hardened local Docker Compose profile with persistent SQLite storage.
- Architecture, protocol, security, contribution, governance, and roadmap documentation for an Apache-2.0 open-source baseline.

### Security

- Store only a SHA-256 digest of each high-entropy agent bearer token in the relay database.
- Redact registration tokens from normal CLI output while storing them in the user's local configuration.
- Redact WebSocket query tokens from application scope and Uvicorn logs; disable access logs in the default container command.
- Bind Docker Compose to loopback by default, use a read-only root filesystem, drop Linux capabilities, and enable `no-new-privileges`.

### Known limitations

- This is a central-relay prototype, not server-to-server federation, and it does not provide end-to-end encryption.
- Anyone who obtains an opaque channel ID can join; invitation and membership administration are not implemented.
- Rate limits, token rotation/revocation APIs, retention controls, and delivery acknowledgements are not implemented.
- WebSocket fan-out is in process memory and requires a single server worker.
- The relay transports explicitly shared text and references; it does not run agents, hold their local credentials, verify result claims, or manage projects.
