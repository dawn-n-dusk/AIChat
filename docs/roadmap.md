# Roadmap

This roadmap is ordered by learning value, not calendar date. The project should earn complexity through real cross-machine use.

Current restart point: [project handoff — 2026-09-05](handoffs/2026-09-05-project-handoff.md).
It records the frozen Windows/MCP diagnostic boundary, the evidence still
missing for a two-host loop. The chosen direction is now recorded in
[ADR 0001](decisions/0001-event-driven-connector.md), tracked by design issue #44;
field attempts remain gated separately.

## Connector foundation — 2026-09-05 gates

GitHub-verified baseline: `main` `9e36813`. PR #42 at `f337327` remains Draft with
two PowerShell 5.1 identity-success exit mismatches. PR #38 (`aed310910588`)
passed PR 28/28 and merge 14/14 checks; #39 (`913483425f70`) passed PR 28/28 and
merge 21/21 checks, including additional checks. Both passed Windows PS5.1.
Windows field claims remain **last supplied accepted facts, not live revalidated**:
the handoff narrative agrees with GitHub, but raw field logs and independent
receipts were not available for fresh verification. Historical checked items
below do not certify this PR's new results.

| Priority | Scope | Exit boundary |
| --- | --- | --- |
| P0 | Current receipt/diagnostic contract and hermetic production MCP subprocess conformance | Exact revision and reviewed cross-platform/PowerShell 5.1 results; no field-probe repair or state migration |
| P1 | Gated two-host suite under one new explicit test manifest | One Mac request → exact Windows envelope → one successful turn → one correlated result → Mac receipt/cursor; required restart/offline/reconnect/duplicate-wake subcases add zero turns/results; reconciled IDs, zero orphan children, and no shared canaries |
| P2 | SDK, Claude native, and Grok ACP driver acceptance | Validate product-specific identity, reconciliation, approvals/sandbox observability, durable evidence, and authenticated acceptance before adoption or replacement |

1. **ADR and contract:** [ADR 0001](decisions/0001-event-driven-connector.md) is on
   disk before code changes. Use a stable sidecar boundary plus product drivers;
   prefer independent App Server dedicated tasks, retain interactive MCP explicit
   reads/writes, treat Claude native as a candidate and Grok managed as opt-in.
   Private IPC is non-default/non-stable; heartbeat is legacy.
2. **Minimal refactor and conformance — included in this PR; CI review tracked separately:** extract receipt
   evidence validation within existing `src`, with fresh allowlisted receipts,
   strict fields, exact delivery/thread/host binding, and validation before
   checkpoint/ack. Legacy receipts without `turnId` remain accepted-only. Add
   fixed CLI/loader phase/code diagnostics, including argument parsing, logger
   projection, and an explicit `safeFailureCode` enum rather than arbitrary
   `AICHAT_*` passthrough. Cover overlapping periodic wakes through the actual
   CLI: queued recovery rejection must produce a fixed diagnostic without a
   recursive wait, extra turn, or state reset. Separately test the actual
   production MCP subprocess with loopback HTTP, locked dependencies on Linux/macOS/Windows, and a
   PowerShell 5.1 conformance run. This is not a field probe. Inclusion in scope
   does not establish passing tests or completed CI review.
3. **Freshly authorized single two-host suite — not authorized or run:** only
   after stage 2 review, obtain a manifest explicitly enumerating the complete
   [checklist](validation/connector-two-host-acceptance.md), including planned
   restart/offline/reconnect/duplicate-wake and zero-orphan acceptance. A happy
   path alone is PARTIAL. Unapproved required subcases are NOT RUN and leave
   acceptance incomplete; never run them implicitly. No blind retry, state or
   service migration, or frozen-installation operation.

The first PR does not change connector state schema **version 5** or the driver
store. Persisted driver phases remain `ambiguous`, `accepted`, `completed`; logical
attempting/unknown/terminal labels are not schema changes. Phase `completed`
also covers failed/interrupted outcomes; success needs `completionStatus=completed`.
The old field **v2** is a deployment namespace. Ambiguous model submissions are reconciled, not
resent; outbound retries replay the same persisted payload and idempotency key.

Independent App Server stdio remains pinned/pre-release. Official documentation
lists stdio/Unix control sockets and also warns that the command/WebSocket
transport is experimental and unsupported for production; it does not promise
cross-version control over arbitrary active Desktop tasks.

The [official SDK](https://learn.chatgpt.com/docs/codex-sdk) is a later
managed-work driver candidate, not a promise of arbitrary Desktop-task control.
Retain the current driver's reconciliation/receipt coverage for this PR. Evaluate
SDK turn identity, reconciliation, approvals/sandbox observability, and durable
evidence before replacement; lower protocol-maintenance cost alone is not an
acceptance criterion. PR #42 stays Draft until a replacement PR is green and
reviewed, after which it may be closed as superseded without repairing the field
probe. The suspected StrictMode failure remains unreproduced, not a root cause.

Official Claude Channels/reference and Grok headless/ACP Markdown were verified
on 2026-09-05; account and new field acceptance remain separate. Evaluate
[`grok agent` ACP](https://docs.x.ai/build/cli/headless-scripting.md) as a future
managed-driver alternative with structured session events, not as arbitrary TUI
injection or an implemented route. Before replacement, validate session/turn
identity, durable receipts, reconciliation, and local permission observability.
Do not equate example timeout/cleanup with recovery, or adopt raw stderr
forwarding or `--always-approve` from examples.

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
- an evidence-dated adapter capability registry distinguishing MCP pull, non-default private owner IPC, pinned/pre-release App Server, native push candidates, legacy heartbeat delivery, and opt-in managed-session resume.

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
