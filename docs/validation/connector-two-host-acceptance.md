# Connector two-host acceptance gate

Evidence cutoff: **2026-09-05**. Design issue: **#44**. Decision:
[ADR 0001](../decisions/0001-event-driven-connector.md).

**Status: planned; no new field acceptance authorized or performed.** This is a
review checklist, not an executable probe or permission to operate an existing
installation. Documentation, implementation, isolated tests, CI review, and
field acceptance must be reported separately.

## Frozen baseline and provenance

| Item | Recorded evidence | What it does not prove |
| --- | --- | --- |
| Repository baseline | GitHub-verified `main` `9e36813`; local branch `codex/connector-contract-foundation` agrees | No deployed version or product capability follows from this check |
| PR #42 | GitHub-verified `f337327`, Draft; two PowerShell 5.1 `identity-success` exit mismatches verified in check logs | Not a passing probe, MCP acceptance, or confirmed diagnosis |
| First failed mock case | Expected exit 0, observed nonzero; actual exit code, JSON, and phase absent from saved logs; later FastMCP fixture not executed | Does not establish exit 2, a specific exception, or a FastMCP failure |
| PR #38 | GitHub-verified commit prefix `aed310910588`, PR checks 28/28, merge checks 14/14, CI `33441057665`; Windows PS5.1 passed | CI success does not independently revalidate field receipts |
| PR #39 | GitHub-verified commit prefix `913483425f70`, PR checks 28/28, merge checks 21/21 including extra checks, CI `33542773489`; Windows PS5.1 passed | Different check totals are different run scopes, not a new field sample |
| Claude Channel | Repository records inbound UI display and subsequent model API `ECONNREFUSED` | Not successful live model-generated reply |
| Grok managed bridge | Repository records mock-runner coverage | Not authenticated real-Grok E2E or consumer conversation control |
| Official Claude/Grok source snapshot | Channels/reference and Grok headless/ACP Markdown verified 2026-09-05 | Not account eligibility, organization enablement, or authenticated runtime acceptance |
| Grok ACP | Official `grok agent` stdio JSON-RPC with managed sessions and `session/update` assistant chunks | No implemented or authenticated-tested AIChat ACP driver; events alone do not establish durable receipts |
| This PR | Receipt hardening, safe diagnostics, and production MCP subprocess conformance are included in scope; CI and field acceptance tracked separately | Scope is not a pass count, green matrix, or field result |

Windows field claims are **last supplied accepted facts, not live revalidated**.
The saved handoff narrative was cross-checked against GitHub; no raw field logs
or independent receipts were available for fresh field verification. Keep that
limitation separate from the confirmed CI pass counts.

The PR #42 log identifiers and the **unreproduced static candidate** are recorded
in the ADR without raw logs or private paths. The possible single-element array
unwrap / StrictMode `.Count` failure is not a confirmed root cause. Do not repair
or rerun that field probe in this work. Keep #42 Draft until a replacement PR
has green CI and completed review; only then consider closing it as superseded.

Retain connector state schema **version 5** and the existing driver store. Driver
phase literals remain `ambiguous`, `accepted`, `completed`. The frozen field
installation's old **v2** is a deployment namespace, not repository schema 2.
No step here authorizes migration, repair, reset, service replacement, credential
inspection, or requests against that installation.

## Stage 1 — ADR and contract

- [x] ADR recorded before implementation.
- [ ] Record the exact first-PR revision and reviewed scope when supplied.
- [ ] Review the synchronized architecture, capability, and acceptance documents.

The contract is sidecar plus product drivers, with an independent App Server
dedicated task preferred. AIChat stdio remains pinned/pre-release despite
officially documented stdio/Unix sockets; the official command/WebSocket
experimental and production warning remains relevant. Private IPC is
non-default/non-stable, MCP is interactive explicit read/write, Claude native is
a candidate, Grok managed is opt-in, and heartbeat is legacy.

An [official SDK managed-work driver](https://learn.chatgpt.com/docs/codex-sdk)
is a later candidate, not this PR's replacement. Retain the current driver and
its reconciliation/receipt coverage while separately validating SDK turn
identity, reconciliation, approval/sandbox observability, and durable evidence.
SDK support is not arbitrary existing Desktop-task control.

[Grok ACP](https://docs.x.ai/build/cli/headless-scripting.md) is also a future
managed-driver candidate rather than this PR's replacement. Validate observable
session/turn identity, durable receipts, ambiguous-attempt reconciliation, and
local approval/sandbox boundaries before adoption. Do not copy example raw
stderr forwarding or `--always-approve`; timeout/cleanup does not supply
durability. Claude Channel acceptance must separately establish supported
authentication, organization enablement where required, and an open receiving
session; AIChat does not adopt the officially available permission-relay path.

## Stage 2 — minimal refactor, hermetic conformance, CI review

The following requirements define this PR's scope. Checkboxes record reviewed
evidence, not merely code presence. CI and field acceptance are tracked separately.

### Receipt and diagnostic contract

- [ ] Extract product-neutral receipt validation inside existing `src`; no new
  engine, disk schema change, or driver-store migration.
- [ ] Construct fresh allowlisted receipts; enforce strict fields and exact
  delivery/thread/host binding before delivery checkpoint or driver ack.
- [ ] Reject malformed or mismatched required evidence before checkpoint/ack;
  never preserve unknown fields in the fresh allowlisted receipt or diagnostics.
- [ ] Preserve legacy acceptance without `turnId` as accepted-only; never infer
  running from `accepted` alone. Associate running evidence with a concrete turn.
- [ ] Exercise ambiguous submission/reconciliation without a second model start;
  replay outbound work only with the same persisted payload/idempotency key.
  Driver phase `completed` includes failed/interrupted outcomes; successful
  completion requires `completionStatus=completed`, not the phase alone.
- [ ] Verify CLI and loader failures, including argument parsing, expose fixed
  phase/code values, safe logger projections, and an explicit `safeFailureCode`
  enum rather than arbitrary `AICHAT_*` strings or raw exceptions.
- [ ] Check diagnostic redaction with synthetic hostile inputs; do not introduce
  real credentials, private paths, or field logs into fixtures or test output.

### Actual production MCP subprocess, isolated transport

- [ ] Launch the actual production MCP subprocess against an isolated loopback
  HTTP fixture; do not substitute an in-memory tool call or label the unexecuted
  PR #42 FastMCP fixture as this test.
- [ ] Cover protocol initialization, tool discovery, representative explicit
  reads/writes, framing, error handling, and subprocess lifecycle using synthetic
  fixture identities/messages, with no live relay, model, or field product.
- [ ] Keep home/config/state temporary and isolated; do not discover or reuse
  host credentials, existing sessions, or frozen deployment namespaces.
- [ ] Use locked dependencies on Linux, macOS, and Windows and run the conformance
  command under Windows PowerShell 5.1. Record exact runner/shell/runtime versions.
- [ ] Capture expected and actual exit codes and safe structured diagnostics so
  a first failing fixture cannot erase the evidence needed for diagnosis.
- [ ] Review actual CI results and the exact tested revision. A planned matrix,
  submitted job, passing unrelated unit test, or draft PR is not green review.

This is hermetic subprocess conformance, **not a field probe**. Any missing
platform result remains pending. Save redacted outcome summaries with revision,
job identity, time, and test scope; do not publish raw private logs or credentials.

## Stage 3 — fresh authorization, one bounded two-host test manifest

Only a new explicit operator authorization after stage-2 review can open this
gate. It must name the permitted hosts, isolated workspaces, product builds,
dedicated tasks, channel audience, sender IDs, allowed actions, maximum turns,
egress policy, and stop conditions through a private local approval mechanism.
Do not place credentials or private paths in this document. The single approved
test manifest MUST explicitly enumerate the initiating request, planned restart
points, offline/reconnect interval, duplicate-wake count, process cleanup,
canary checks, and evidence requirements below. A manifest is not executable
authorization until those exact actions are approved.

- [ ] Record the fresh authorization and exact reviewed revision before work.
- [ ] Use independently owned, non-sensitive dedicated tasks with locally chosen
  host/driver bindings. Do not claim attachment to arbitrary active Desktop tasks.
- [ ] Preserve automatic egress as a separate opt-in and explicitly acknowledge
  the full channel audience. `reply_to` does not make a response private.
- [ ] Mac originates exactly one request ID. Windows receives its exact source
  envelope, confirms exactly one correlated turn, and shares exactly one result
  with `reply_to` equal to the Mac request ID. Mac records receipt and its durable
  cursor. Status/result traffic must not produce recursive requests or extra turns.
- [ ] Use explicit MCP reading or passive receipt/cursor observation on Mac for
  this one-turn manifest; do not enable a result-delivery mode that itself starts
  an additional connector model turn.
- [ ] Capture the distinct evidence layers below without conflating them.
- [ ] Stop on ambiguity, unexpected identity/binding, unsafe content, missing
  evidence, or unauthorized state/service changes. Do not retry a model turn or
  expand the scope automatically; ask for a new decision.

### Required manifest subcases and counts

The following subcases are normative. They operate on the **same single request**,
not one new request per fault. Restart and cleanup refer only to processes owned
by the approved isolated test, never the frozen installation or unrelated host
services. Schedule fault boundaries in advance; do not improvise a failure retry.

| Subcase | Explicit manifest action | Required evidence and final counts |
| --- | --- | --- |
| H0: correlated useful result | One Mac request reaches Windows and returns to Mac | Initiating request IDs = 1; Windows source envelopes = 1; confirmed turn IDs = 1; successful terminal outcome has `completionStatus=completed`; relay-stored result messages = 1; `reply_to` matches the request; Mac logical result receipts = 1 and durable cursor includes that result |
| R1: planned restart | Enumerate one connector restart and one owned driver/runtime restart at declared durable boundaries; record exact ordering | Same delivery/thread/host and original request remain bound; total turn IDs stay 1 and total result messages stay 1; no blind model resubmission |
| R2: offline/reconnect | Enumerate one offline interval and one reconnect with the same approved participants | Cursor recovery consumes the original identities; additional model turns = 0 and additional result messages = 0 |
| R3: duplicate wake | Deliver exactly two additional wake hints for the same request, without reposting the request | Wake duplicates may trigger reads, but additional model turns = 0, additional results = 0, and additional logical Mac receipts = 0 |
| R4: identity reconciliation | Reconcile connector delivery/event records, driver thread/host/turn records, and relay request/result IDs after each subcase and at exit | One consistent source-to-turn-to-result chain; unmatched/orphaned identities = 0; unresolved model attempts = 0; pending or unresolved quarantined output = 0 for successful acceptance. Retained matched records need not be deleted |
| R5: drain and clean exit | Drain work and exit all manifest-owned Node, Codex, PowerShell, and fixture child processes on both hosts | Queued unsent work = 0; orphan child processes = 0 after a bounded, recorded cleanup wait. Do not terminate unrelated processes to satisfy the count |
| R6: canary boundary | Check the approved private canaries against relay messages, outbound diagnostics, and exported evidence without publishing the canaries | Canary matches in shared output = 0; no secrets/private paths appear in published evidence. This is a required observed check, not proof of general secret isolation |

Record the Windows source envelope's original message/channel/sender/type,
timestamps, correlation fields, text, and references exactly against the approved
Mac fixture. Use canonical hashes and safe metadata in the public report rather
than private payloads. Repeated transport reads are not additional logical
deliveries; demonstrate deduplication rather than hiding duplicate receipts.

If a required restart, offline, duplicate-wake, reconciliation, cleanup, or canary
subcase is not explicitly authorized, mark it **NOT RUN** and the overall
acceptance **INCOMPLETE**. Do not silently perform it. A passing H0 alone is
**PARTIAL**, never full two-host E2E acceptance. Full acceptance requires every
required subcase to be authorized, executed, and evidenced with the counts above.

| Layer | Required redacted evidence | Insufficient substitute |
| --- | --- | --- |
| Relay intake | Message identity, source/receive times, fixed channel and sender gate outcome: fetched or filtered | WebSocket wake, acknowledgement text, or a reachable port |
| Driver attempt | Durable `ambiguous` record before submission and exact delivery/thread/host binding | A process started or request was written |
| Driver acceptance / terminal | Validated acceptance and concrete turn evidence; terminal record linked to the same attempt, with `completionStatus=completed` required for success | `accepted` without `turnId` described as running; phase `completed` alone treated as success despite failed/interrupted outcomes; completion inferred from a timeout |
| Connector checkpoint / ack | Durable validated ownership before driver acknowledgement | A cursor advance represented as completed work |
| Egress pending / relay-stored | Persisted output and stable key; relay storage receipt or same-key recovery | A local send attempt or newly generated replacement answer |
| Egress quarantined / resolved | Durable policy outcome and explicit local retry/drop resolution | Calling quarantine or drop a delivered reply |
| Receiver and useful result | Host A's explicit receipt of the correlated result plus bounded, independently checkable work evidence | Sender-only storage proof or the model's unverified completion claim |

An unknown model outcome stays unresolved; it is not permission to resubmit.
Authorized outbound replay uses the same payload/key. The required fault and
restart drills belong in the explicitly approved single manifest; omission is
incomplete acceptance, not implicit permission. Another initiating request,
extra drill, changed restart boundary, or blind failure retry requires a new
decision and is not authorized by this checklist.

## Recording the outcome

When evidence actually exists, append a dated summary stating the exact revision,
tested builds, authorization scope, expected/observed counts, completed layers,
failures, and unresolved hypotheses. Distinguish **passed**, **failed**, **blocked**,
**not run**, and **partial/incomplete**. Do not pre-fill successful outcomes, erase historical failures,
infer exactly-once local tool side effects, or turn a field result into a
cross-version product guarantee.
