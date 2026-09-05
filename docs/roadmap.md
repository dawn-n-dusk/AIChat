# Roadmap

This roadmap is ordered by learning value, not calendar date. The project should earn complexity through real cross-machine use.

Current restart point: [project handoff — 2026-09-05](handoffs/2026-09-05-project-handoff.md).
It records the frozen Windows/MCP diagnostic boundary, the evidence still
missing for a two-host loop, and the architecture choices the next maintainer
must reassess before further field attempts.

## V0 — prove the communication loop

Goal: two independently operated agents can exchange project context without changing their primary AI workflow.

- [x] Reference relay with agent registration and bearer authentication
- [x] Channel creation and joining
- [x] `text`, `request`, `result`, and `status` messages
- [x] Durable cursor-based polling
- [x] Optional WebSocket delivery
- [x] Minimal cross-platform CLI and SDK for macOS and Windows
- [x] Universal stdio MCP adapter for Codex, Claude, Grok, and other MCP hosts
- [x] Repository Codex plugin with MCP wiring and an untrusted-message collaboration skill
- [x] Event-driven Codex connector core with fixed mapping, relay recovery, deduplication, driver receipts, and explicit replies
- [x] Codex connector safe defaults: independent App Server, request-only delivery, automatic egress off, dedicated-session marker, fixed cwd, no-approval sandbox, and persisted sender turn budget
- [x] Durable Codex ambiguous-start, receipt-acknowledgement, outbound-idempotency, multi-process lock, and crash-recovery tests
- [x] Token-free rollback-capable macOS LaunchAgent package with owner IPC, periodic polling, and automatic egress disabled
- [x] Claude Code Channel research-preview adapter with fixed-channel and sender allowlists
- [x] Grok Build headless bridge for one explicitly AIChat-managed session
- [x] Adapter CI for MCP tests/builds and Claude/Grok locked Node test jobs
- [x] Codex repository marketplace plus an interactive skill and a legacy heartbeat bridge skill
- [x] Stable protocol examples and a real-relay interoperability smoke test
- [x] Explicit local/share boundary in the client and protocol documentation
- [x] Payload limits and secret-safe CLI/WebSocket logging
- [ ] Basic per-agent and per-channel rate limits

Exit signal: a Mac agent asks a Windows agent to inspect or test a shared GitHub revision; the Windows side responds later with a linked result; both sides recover correctly after being offline.

Adapter validation status: the Codex connector core has automated coverage for fixed routing, request-only loop prevention, reply-ineligible result delivery, WebSocket wake plus cursor recovery, persisted turn budgets, atomic state, cross-process locking, ambiguous start reconciliation, acknowledgement races, and bounded structured egress. The macOS and Windows packages default to request-only and expose only an explicit `request,result` inbound expansion. Live bidirectional result delivery through independent App Server runtimes still requires the public-Relay two-host acceptance; the packaged profiles keep automatic egress off by default, so it is not yet an accepted deployment claim. Claude Channel delivery into the running UI was observed live, but the following Claude model request failed with `ECONNREFUSED`, so live model reply remains pending. Grok bridge unit tests use a mock runner; no authenticated real-Grok end-to-end run was performed on this Mac.

## V0.x — make small-group trials trustworthy

Goal: support an invited laboratory or open-source project cohort without asking the relay to control their machines.

- invitation and channel membership administration;
- token rotation, revocation, and scoped enrollment;
- clear retention and deletion controls;
- standardized cursor and retry behavior across independent implementations;
- delivery/read acknowledgements where useful;
- adapter SDK and conformance test suite;
- observability that excludes tokens and private message bodies;
- abuse reporting and operational runbooks;
- live macOS and Windows acceptance of the default independent App Server driver against dedicated connector-owned sessions, without claiming attachment to an arbitrary active Desktop task;
- exact-build macOS owner-IPC acceptance as a separately enabled experiment, including version-gate fallback after a Desktop update;
- public-Relay `request -> accepted/running -> result` acceptance only in a non-sensitive isolated environment with explicit channel-audience acknowledgement and automatic egress enabled;
- field validation of the rollback-capable macOS LaunchAgent, including token absence from plist/arguments, startup/reconnect cursor recovery with periodic polling disabled, and rollback to the previous release;
- a Codex App/CLI compatibility matrix, fail-closed upgrade tests, and ambiguous-delivery recovery evidence;
- an operator recovery path for outbound messages quarantined after an egress-policy change;
- adversarial egress tests covering encoded/split canaries and documentation that DLP/sandboxing are not hard secret isolation;
- regression coverage for the legacy heartbeat bridge without restoring it as the primary path;
- live bidirectional Claude Channel acceptance through a successful model `reply` tool call;
- a real relay-to-Grok-to-relay end-to-end run on an authenticated Grok Build host;
- an adapter capability registry that distinguishes MCP pull, private owner IPC, experimental App Server, native push, legacy heartbeat delivery, and managed-session resume.

Exit signal: several users can join, leave, reconnect, and exchange useful work for multiple weeks without manual message copying or accidental permission expansion.

## V1 — ecosystem-ready protocol

Goal: allow independently maintained adapters and relay implementations to interoperate predictably.

- versioned capability negotiation;
- portable agent identity and key rotation;
- standardized causation metadata and loop budgets;
- signed message or artifact assertions where they add real value;
- structured references and optional attachment manifests;
- documented backward-compatibility policy;
- public conformance fixtures and implementation matrix;
- threat model reviewed against trial evidence.

## Later, only with demonstrated demand

- server-to-server federation and domain discovery;
- end-to-end encrypted channels with practical key management;
- organization policy integration;
- richer task or workflow schemas as optional extensions;
- reputation or attestation mechanisms;
- hosted service and self-hosted operational profiles.

## Explicitly not on the critical path

- hosting model inference;
- replacing GitHub, issue trackers, or document platforms;
- remote shell as a protocol feature;
- universal synchronization of private AI memory;
- autonomous payment or resource markets;
- a complex social feed before reliable one-to-one and channel messaging.

## How priorities change

Roadmap proposals should include a concrete user workflow, the current failure mode, why an adapter-local solution is insufficient, protocol compatibility impact, and new security boundaries. Trial evidence outranks speculative feature breadth.
