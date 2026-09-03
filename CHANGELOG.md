# Changelog

All notable changes to AIChat will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project intends to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as the protocol matures.

## [Unreleased]

### Added

- Add a read-only Windows PowerShell 5.1 MCP stdio diagnostic that first
  attests the enabled Codex `aichat` command against the repository plugin's
  exact `uvx` arguments, environment-variable names, and timeouts, then runs
  the standard MCP initialize/list flow and at most one `aichat_identity`
  call. It emits one fixed, redacted ASCII JSON contract, never prints the
  response body or identity fields, never sends Relay messages or writes
  configuration, and reports cross-process environment equivalence as
  unproven. Timeout and failure paths terminate the complete child process
  tree. Windows fixtures cover identity success, timeout cleanup, invalid
  framing, stderr canaries, command mismatch without package start, and output
  non-disclosure.

### Fixed

- Accept the recovery target's valid `verification_failed` plus
  `protected_paths_invalid` result for verify, repair, and finalize instead of
  incorrectly replacing it with `target_contract_invalid`. Runner failure
  contract version 2 adds a fixed, redacted `rejection_code` so field-set,
  version, type, error/diagnostic, operation/diagnostic, exit-code, status, and
  mutation-invariant rejections are distinguishable without forwarding inner
  JSON, exceptions, paths, SID/SDDL, credentials, or tokens. Windows
  PowerShell 5.1 tests cover the verification-stage protected-root failure for
  all three operations and each rejection category. The outer-runner test also
  installs the production `recover-transaction.ps1` beside the production
  runner with an isolated synthetic `common.ps1`, triggers the real inner
  failure, and requires byte-exact exit-1 stdout forwarding.
- Upgrade the Windows recovery JSON target contract to version 2 with a fixed,
  redacted `diagnostic_code` on every caught failure. Explicit stage markers
  now distinguish protected paths, journal and manifest validation, file/task
  snapshots, release/staging layout, ACL exactness and repair eligibility,
  concurrent revalidation, ACL repair, and journal finalization without
  matching or returning exception text. The outer runner strictly validates
  the new enum and its operation/error pairing before forwarding it. Windows
  PowerShell 5.1 coverage now builds a valid protected schema-v3 managed
  journal with real deployment backups, Task Scheduler XML, connector files,
  and native owner/DACL snapshots, then executes the production diagnose,
  repair, reverify, and finalize chain. A same-state-root StageOnly recovery
  gate proves the blocker is rejected before finalization and cleared after it.
- Add an ASCII-only, repository-owned Windows PowerShell 5.1 outer runner for
  transaction recovery automation. It accepts only fixed verify, repair, or
  finalize operations, prevents the native `powershell.exe -OutputFormat`
  option from consuming the target script's `Json` value, captures both child
  streams without deadlock, enforces a timeout and bounded child cleanup, and forwards
  only an exact versioned recovery contract. All pre-contract, stderr,
  malformed-output, schema, enum, or exit-code failures become one fixed
  redacted runner JSON object; unverifiable repair/finalize outcomes after
  child start fail closed with `mutation_possible=true`.
- Add a versioned `recover-transaction.ps1 -OutputFormat Json` contract while
  preserving the default Human output. JSON mode emits one compact ASCII-safe
  object with native booleans and fixed status/error codes, suppresses paths,
  credentials, SID/SDDL data, and raw exceptions, and reports whether the run
  may have performed a mutation even when ACL compensation restored the final
  state. Bootstrap and protected-path initialization failures are captured by
  the same contract without stderr diagnostics. Windows PowerShell 5.1
  subprocess tests cover repair-ready, exact, repair, finalize, invalid-format,
  missing or malformed shared helpers, path initialization, invalid-argument,
  verifier-failure, repair-apply failure, and finalize-apply failure outcomes;
  they also enforce exact raw stdout framing and unique top-level JSON keys.
- Add a narrowly allowlisted Windows schema-v3 `rollback_incomplete`
  ConnectorData ACL snapshot repair for the field case where sanitized Windows
  evidence showed the owner/DACL as the only verifier mismatch while protected
  backups, deployment targets, prior task state, release, staging, and failed
  release checks were exact. Recovery remains a two-step operator flow: repair
  only owner/DACL and rerun the complete read-only verifier, then invoke a
  separate `-Finalize -Apply` to archive the byte-identical journal and clear
  the blocker. The journal hash and ConnectorData content hashes are pinned
  across mutation; a partial restore is compensated to the validated semantic
  pre-run owner/DACL identity,
  while a hard-interrupted prefix remains resumable only when every entry is
  semantically one of the two fixed ACL snapshots. Raw snapshot hashes remain
  mandatory, while equivalent Windows SDDL aliases and all-Allow ACE ordering
  no longer create false mismatches. The repair never chains
  finalization or writes task, state, channel, mapping, token, or deployment
  content.
- Add a transactional Windows connector `-StageOnly` install/check/rollback
  path for supervised foreground acceptance. It installs the pinned runtime,
  settings, mapping metadata, and private ACLs without querying, creating,
  replacing, restoring, or deleting the Scheduled Task, and records that
  no-task boundary in the rollback manifest.
- Add a read-only Windows `rollback_incomplete` verifier and explicit protected
  journal finalization path, while avoiding redundant Task Scheduler writes
  when the prior task snapshot is already exact. Schema-v4 stage-only journals
  are verified and finalized under their strict `task.mode=untouched` contract
  without accessing Task Scheduler.
- Namespace packaged Windows connector state and its derived instance lock by
  a trusted local Agent/channel/task mapping digest, while preserving legacy
  `state.json` only for an unchanged pre-namespace mapping and leaving all
  prior mapping state files untouched during install and rollback.
- Apply Windows connector private ACLs through an owner-and-DACL-only native
  update that never requests SACL access or `SeSecurityPrivilege`, while
  preserving the exact current-user-only and current-user-plus-LocalSystem
  contracts and journaling connector-data migration before deployment changes.
- Protect Windows connector state, app-server receipt, and lock-metadata files
  before atomic rename with explicit current-user and LocalSystem ACLs; migrate
  only the narrow legacy current-user ACL shape during install, upgrade, or
  rollback, and reject inherited broad principals fail-closed.
- Windows supervised one-shot acceptance now distinguishes a model-declared
  Relay `result` from a locally suppressed lifecycle completion when automatic
  result egress is enabled, binds the driver event to the persisted Relay
  checkpoint, and rejects pre-existing local checkpoints.
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

- Add a standalone Windows PowerShell 5.1 read-only diagnostic for recovery
  `protected_paths_invalid` results. Its fixed version-1 ASCII JSON contract
  identifies only the allowlisted phase, ancestor/protected-root/state-root
  level, layer, and reason; it never emits paths, SID/SDDL, ACL/ACE content,
  credentials, tokens, or raw exceptions. Exact and mismatch results exit 0,
  while an unsafe-to-classify result is explicitly blocked and exits 1. The
  diagnostic does not read the recovery journal, ConnectorData, or identity
  configuration, access Task Scheduler or connector processes, mutate files or
  ACLs, or alter the existing recovery target/runner contracts. Windows tests
  enforce the schema, redaction canaries, representative real ACL mismatches,
  real ancestor/state reparse points, injected owner/unreadable-ACL
  classifications, byte-exact native-newline framing, constructor/serializer
  literal-fallback safety, and byte-for-byte fixture stability before and after
  every invocation. Recovery and diagnosis now share pure read-only canonical
  protected/state-root, ConnectorData-root, and private-tree path helpers so
  UserProfile/ConnectorData resolution cannot drift into a false `exact`
  result without changing the recovery JSON contract or reading ConnectorData.
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
