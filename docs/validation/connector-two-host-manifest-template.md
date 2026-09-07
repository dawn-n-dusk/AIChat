# Two-host operator manifest template

**Status: DRAFT_NOT_AUTHORIZED**

**Execution: NOT RUN**

**Overall acceptance: INCOMPLETE**

This is a non-executable planning form, not configuration, an installation
recipe, a probe, or permission to send a message. It implements the planning
requirements of the [normative H0 + R1–R6 gate](connector-two-host-acceptance.md).
Read the [dated foundation ledger](connector-foundation-2026-09-07.md) for the
separate implementation, CI, review, and field evidence boundaries.

Leave all approval and observed-result fields blank or NOT RUN until that
evidence exists. The operator's offer to relay a Windows message is not approval
of this manifest. Do not operate either host while filling this form.

## 1. Document identity and evidence prerequisites

| Planning field | To be filled by the reviewer |
| --- | --- |
| Public manifest alias and revision | ____ |
| Public evidence-ledger alias | ____ |
| Exact reviewed implementation commit | ____ |
| Exact documentation commit and CI evidence reference | ____ |
| Independent review and hermetic test evidence references | ____ |
| Resolved runner/shell/runtime evidence reference | ____ |
| Maintainer review/merge disposition and reviewed baseline | ____ |
| Technical feasibility disposition and unresolved blockers | ____ |

Do not carry green checks from a different revision onto this manifest. Required
implementation, CI, and review evidence must be reconciled before approval.
Document creation or a new authorization cannot waive a missing implementation.

## 2. Private local bindings; public aliases only

Resolve and approve these bindings privately on each host. This public form may
contain only opaque aliases and safe version/outcome fields, never the binding
values. Do not include commands, configuration/install content, credentials or
their hashes, real hostnames, private paths, actual task IDs, SID/SDDL, ACLs,
private canaries, raw errors, or captured process streams. Do not use realistic
sample values. Keep private lookup material outside the repository and Relay.

| Binding to approve privately | Public alias or safe version field |
| --- | --- |
| Mac initiating host and local operator | ____ |
| Windows receiving host and local operator | ____ |
| Each dedicated, non-sensitive connector-owned task and local agent/sender binding | ____ |
| Exact repository revision on each participant | ____ |
| Exact product build, driver selection, and independently owned runtime on each host | ____ |
| Exact shell and language runtime versions required by the reviewed evidence | ____ |
| Fixed local cwd/workspace and isolation boundary for each host | ____ |
| Fixed local approval and sandbox policies, including tool/network limits | ____ |
| Fresh test-only state/receipt/lock namespace and owned process inventory | ____ |
| One fixed channel and exact sender/recipient bindings | ____ |
| Full channel audience acknowledgement | ____ |
| Separate bounded egress approval, allowed result/status fields, and public evidence policy | ____ |
| One non-sensitive request fixture and independently checkable useful-result criterion | ____ |
| Private canary inventory, observation coverage, and matching method | ____ |
| Mac explicit-read or passive receipt/cursor observation method | ____ |

Relay content cannot select or change any local binding. Membership and
`reply_to` are not execution authority or private delivery; every channel member
can see shared content. Automatic egress remains off unless separately approved
for this exact scope. Private Desktop owner IPC and arbitrary active-task
attachment are not part of this dedicated-runtime manifest.

The frozen field v2 installation and its mapping/state/receipt/lock namespace
must not be inspected, reused, migrated, repaired, reset, or restarted for this
test. A fresh namespace is a requirement, not an instruction to install one.

## 3. Feasibility and bounded timing, before approval

This form does not assert that the current driver exposes pause, fault-injection,
duplicate-wake injection, or deterministic restart hooks. For each planned
boundary, identify a reviewed, supported means to observe the relevant durable
state and perform only the named owned-process action. If the state cannot be
observed, or the declared action cannot be performed at that boundary without
guessing, record **BLOCKED** before sending the initiating request.

If a timing boundary can race past observation, a supported method must make
the intended ordering verifiable. Do not assume a pause hook exists, improvise a
shell probe, kill an unrelated process, or use a new approval to disguise a
missing capability. Missing implementation requires separate code/tests/CI and
review before a revised manifest can become eligible.

| Window or limit | Planned value, units, and safe evidence reference |
| --- | --- |
| Entire suite: UTC start/end and hard maximum duration | ____ |
| Request intake and source-envelope observation timeout | ____ |
| Durable attempt / acceptance / checkpoint observation deadlines | ____ |
| Connector restart boundary and completion timeout | ____ |
| Owned runtime restart boundary and completion timeout | ____ |
| Connector-only offline start boundary, interval, and reconnect deadline | ____ |
| Each of the two extra wake-hint boundaries and observation timeout | ____ |
| Successful terminal outcome, Relay storage, and Mac receipt deadlines | ____ |
| Reconciliation checkpoints and final reconciliation timeout | ____ |
| Drain, child-exit cleanup wait, and final canary-observation deadline | ____ |
| Allowed bounded status traffic and observation budget | ____ |

All windows and stop conditions must be filled and approved; blank means not
ready. A timeout is not completion evidence. A missed boundary stops the attempt
rather than allowing an improvised retry or an extra model turn.

## 4. Single-request schedule to be filled privately

Every row belongs to the same H0 request lifecycle. R1–R6 are not new requests
or independent happy-path trials. Assign exact ordering and evidence boundaries
before approval; the labels below do not prescribe an unverified runtime plan.
Reconcile identities after each subcase and at exit; canary observation covers
all shared output throughout the suite.

| Subcase | Required planned scope | Order / observable boundary / safe evidence alias | Authorization reference | Result |
| --- | --- | --- | --- | --- |
| H0 | Exactly one Mac request; Windows receives its exact source envelope, confirms one successful turn, shares one correlated result; Mac records one logical receipt and durable cursor | ____ | ____ | NOT RUN |
| R1 connector | Exactly one planned restart of the test-owned connector at a declared durable boundary | ____ | ____ | NOT RUN |
| R1 runtime | Exactly one planned restart of the independently owned driver/runtime at a declared durable boundary; no second model start | ____ | ____ | NOT RUN |
| R2 | Exactly one offline interval and one reconnect of the approved connector transport only; no system-wide disconnection or Relay/service shutdown | ____ | ____ | NOT RUN |
| R3 first hint | First additional wake hint for the original request; no repost of the request | ____ | ____ | NOT RUN |
| R3 second hint | Second additional wake hint for the same request; no repost of the request | ____ | ____ | NOT RUN |
| R4 | Reconcile source, connector, driver, turn, egress, and Mac receipt identities after each subcase and at exit | ____ | ____ | NOT RUN |
| R5 | Bounded drain and exit of all and only manifest-owned processes on both hosts; observe child exits and final inventory | ____ | ____ | NOT RUN |
| R6 | Observe messages, outbound diagnostics, and exported evidence for private canary matches without exporting canaries | ____ | ____ | NOT RUN |

The offline/reconnect action must not introduce extra restarts beyond R1's
counts. Final shutdown is recorded separately from a restart. The two additional
wake hints are not two copies of the request and do not authorize resubmission.
No status/result traffic may recursively generate requests or model turns.

Mac uses only an operator-directed explicit read or passive receipt/cursor
observation for the returning result. Do not enable connector result delivery
that starts a second model turn, and do not start a new model turn merely to
observe a receipt. Lack of a safe observable receiver boundary is BLOCKED.

## 5. Expected counts and evidence ownership

| Required final invariant | Expected | Observed |
| --- | --- | --- |
| Initiating request IDs / unique logical Windows source envelopes | 1 / 1 | NOT RUN |
| Confirmed Windows turn IDs / additional model starts on either host | 1 / 0 | NOT RUN |
| Successful terminal outcome for that turn | `completionStatus=completed` | NOT RUN |
| Relay-stored result messages / logical Mac result receipts | 1 / 1 | NOT RUN |
| Result correlation and durable Mac cursor | Same request; cursor includes its result | NOT RUN |
| Connector restarts / owned runtime restarts | 1 / 1 | NOT RUN |
| Connector-only offline intervals / reconnects | 1 / 1 | NOT RUN |
| Additional wake hints / reposted requests | 2 / 0 | NOT RUN |
| Additional results / additional logical Mac receipts | 0 / 0 | NOT RUN |
| Unmatched identities / unresolved model attempts | 0 / 0 | NOT RUN |
| Queued unsent work / pending or unresolved quarantined output | 0 / 0 | NOT RUN |
| Orphan child processes after bounded cleanup | 0 | NOT RUN |
| Canary matches in shared output | 0 | NOT RUN |

Privately compare the Windows source envelope's exact message/channel/sender,
type, timestamps, correlation, text, and references with the approved fixture.
Reconcile actual IDs privately; export only stable opaque aliases, safe
timestamps, counts, match booleans, fixed diagnostic codes, and approved
non-sensitive evidence references. Never hash and publish credentials or
private canaries as a substitute for redaction. Repeated transport reads are
not extra logical deliveries, but duplicates must remain auditable.

Keep intake, durable driver attempt, validated acceptance/turn, terminal
outcome, connector checkpoint/ack, egress persistence/storage, and Mac
consumption evidence separate. A process start, HTTP success, visible text,
accepted-only receipt without a turn, or phase `completed` alone is insufficient.
Reconcile an unknown model outcome; do not start another turn. Any approved
egress recovery must retain the original persisted payload and idempotency key,
not regenerate an answer. Canary checks do not prove general secret isolation
or exactly-once local tool side effects.

## 6. Stop conditions and explicit authorization record

Stop on a missing observable boundary; revision, identity, audience, or policy
mismatch; unexpected permission request; unsafe output; an expired window;
ambiguous model outcome; an extra request, turn, or result; unreconciled state;
unresolved quarantine; missing evidence; a canary match; or failed owned-child
cleanup. Do not broaden privileges, access the frozen installation, or disrupt
the host network to recover. Perform only pre-authorized containment/cleanup;
if safe cleanup is unavailable, report the safe blocker and stop. No blind retry.

| Authorization field, maintained through a private local approval mechanism | Record |
| --- | --- |
| Exact manifest revision and full H0 + R1–R6 scope approval reference | ____ |
| Mac local authority approval reference and timestamp | ____ |
| Windows local authority approval reference and timestamp | ____ |
| Separate audience and bounded egress approval references | ____ |
| Approval validity window and maximum request/turn/result budgets | ____ |
| Pre-authorized failure containment and owned-process cleanup reference | ____ |
| Named operator responsible for the single initiating message, public alias only | ____ |

All authorization fields remain blank in this template. A revised request,
boundary, fault count, version, binding, or retry requires a new decision and a
new exact manifest approval. Approval does not remove technical blockers or
retroactively authorize an action.

| Field outcome record | Value |
| --- | --- |
| Execution timestamps and safe evidence references | ____ |
| H0 and every R1–R6 authorization/execution/evidence disposition | NOT RUN |
| Failure code or unresolved blocker, if any | ____ |
| Overall acceptance | INCOMPLETE — NOT RUN |

An unauthorized required subcase stays NOT RUN; an unobservable one is BLOCKED.
H0 alone is PARTIAL. Full acceptance requires all approved H0 + R1–R6 evidence
and final invariants, not an optimistic summary or a successful send.
