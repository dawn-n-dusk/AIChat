# Connector foundation evidence ledger — 2026-09-07

**Round scope: documentation/evidence updates, a version-only test-wrapper
banner, and additional production read/write conformance; field acceptance NOT RUN.** This ledger preserves
implementation evidence recorded on **2026-09-05** and separately records
**2026-09-07 metadata refreshed** by the coordinating review. The documentation
pass edits documents only and consumes supplied metadata; it does not repeat
GitHub operations, inspect credentials, run a Relay, or operate Windows. A
separate test agent owns the version-only PowerShell test-wrapper banner.
Product source, workflow definitions, wire protocol, schemas, dependencies, and
deployment behavior are unchanged by this follow-up scope.

The follow-up independent review found a P2 evidence overclaim: the historical
five production subprocess cases invoked identity, while message read/send and
channel create/join were only discovered by name. The checklist now separates
those facts; message read/write execution at `1fa9aad` remains NOT RUN. New
representative read/write/read-back conformance must have its own reviewed SHA,
counts, and CI evidence in PR #45 before merge. It cannot retroactively expand
the historical 41 conformance / 5 production case scope. Channel creation/join
execution is not certified by the representative message test either.

The added test's local report is separate: production message read/send/read-back
1/1, complete conformance 42/42 including 6 production cases, and unit tests
38/38; zero failures/errors/skips. The test-file Git blob is
`a84784b1f02f90cf49c23d75b38476c550583013`. It was tested from an isolated external
snapshot with locked dependencies on macOS arm64, Python `3.11.15`, pytest
`8.4.2`, and MCP `1.29.0`. Full follow-up revision review and hosted CI remain
unrecorded in this preparation snapshot; append their exact SHA/results to PR #45.

Related documents: [ADR 0001](../decisions/0001-event-driven-connector.md),
[normative acceptance gate](connector-two-host-acceptance.md), and
[non-executable operator manifest](connector-two-host-manifest-template.md).
The [2026-09-05 handoff](../handoffs/2026-09-05-project-handoff.md) and its evidence
cutoff remain historical records, not newly observed field facts.

## Revision and review provenance

PR state and check conclusions in this section are a **2026-09-07 refresh
snapshot**, not an assertion about the PR after that observation. Subsequent
documentation/version-banner revision CI, review, and merge evidence belongs in
[PR #45](https://github.com/dawn-n-dusk/AIChat/pull/45), bound to its actual exact
SHA. A merge updates main through GitHub; this ledger does not require a new
documentation commit merely to embed its own final SHA.

| Item | Exact recorded value | Evidence boundary |
| --- | --- | --- |
| Main baseline | `9e36813e5f3a6668fbd9c0a32bde64c85666d530` | Live `origin/main` metadata supplied by the coordinating review on 2026-09-07; not a deployed-host revision |
| Implementation revision | `1fa9aad304c64943b2fcb6593071656222a2ef9c` | Exact foundation revision to which the historical tests and checked stage-1/2 items apply |
| Successor PR | [#45](https://github.com/dawn-n-dusk/AIChat/pull/45), OPEN, non-Draft, not merged | 2026-09-07 metadata refresh; not permission to merge or deploy |
| Hosted check metadata | 36/36 successful: two runs of 18 jobs each, linked below | Refreshed check conclusions for the implementation revision, not 36 distinct test suites or CI for this document delta |
| GitHub reviews | `[]`; no formal approval | Independent agent review is not a GitHub approval |
| Frozen diagnostic PR | [#42](https://github.com/dawn-n-dusk/AIChat/pull/42), Draft/frozen at `f337327eed8eec7514834fbc65d023e3be91e616` | Not mergeable or field-executable; no repair or rerun in this documentation work |
| Follow-up commit SHA at preparation | UNKNOWN — no final documentation/version-banner revision recorded here | Append the actual exact SHA to PR #45 when it exists; do not substitute the implementation SHA or pre-fill a future commit |
| Follow-up revision CI at preparation | NOT RUN / no run ID recorded here | Append actual banner/version and test evidence to PR #45; historical green checks do not cover a changed HEAD |
| 2026-09-07 independent production-diff review | Completed within the bounded scope below; no reproducible P0/P1/P2 found | Independent agent review, not GitHub approval or documentation-delta review |
| Separate MCP/hermetic and hosted-evidence recheck | Completed as reported in the 2026-09-07 test-agent section below | Separate from the code review's static MCP/CI inspection; no new hosted run or field acceptance |
| Documentation/version-banner delta independent review | PENDING | Do not carry the implementation review onto new documents or test-wrapper output |
| Field authorization and H0 + R1–R6 | NOT AUTHORIZED / NOT RUN | Preparing or offering to relay a message is not exact manifest approval |

## Independent review recorded 2026-09-07

The coordinating review supplied the completed Galileo agent report for
`1fa9aad304c64943b2fcb6593071656222a2ef9c` against baseline
`9e36813e5f3a6668fbd9c0a32bde64c85666d530`. Within that production diff, the
reviewer found no reproducible P0/P1/P2 in receipt binding, ack after persistence,
ambiguous-attempt recovery, queued recovery, or safe diagnostics. This is a
bounded independent agent review, not a whole-system safety claim, formal GitHub
approval, review of the documentation delta, or field acceptance.

| Reported local check | Runtime | Recorded outcome | Limit |
| --- | --- | --- | --- |
| Boundary tests | Node `v25.9.0` | 125/125 passed; 0 failed, 0 skipped | Local implementation-revision scope, not the historical hosted Linux Node 20 suite |
| Synthetic driver recovery tests | Node `v25.9.0` | 9/9 passed; 0 failed, 0 skipped | Synthetic recovery, not a real model or two-host runtime restart |
| MCP and CI inspection by the code reviewer | Static review only | No execution/recount result asserted by that reviewer | Separate test-agent evidence is recorded below; do not attribute it to the code review |

These counts belong to the 2026-09-07 report and are not added to the historical
CI totals. The documents in this update still await their own independent review.

## Separate test-agent verification recorded 2026-09-07

The test agent rechecked both historical runs against exact head
`1fa9aad304c64943b2fcb6593071656222a2ef9c`: each run has 18/18 successful jobs.
This refresh and artifact recount verify old run evidence, not a new CI run for
the documentation revision. Separately, the agent reported these local reruns
of the implementation scope; no field runtime was involved.

| Local rerun | Exact reported runtime | Outcome and scope |
| --- | --- | --- |
| Portable Codex boundary suite | Node `20.20.2` | 86/86 passed across 3 files; distinct from the code reviewer's broader Node `v25.9.0` 125/125 boundary and 9/9 recovery scopes |
| MCP conformance | Python `3.11.15`, pytest `8.4.2`, MCP `1.29.0` | 41 cases passed, including 5 production subprocess cases; isolated synthetic transport, not Codex App-hosted return-path acceptance |
| MCP unit suite | Python `3.11.15`, pytest `8.4.2`, MCP `1.29.0` | 38 passed; separate from the 41 conformance cases |

For **each** of the two linked historical runs, all three OS MCP jobs report
41 conformance plus 38 unit passes. All six conformance JUnit reports were
checked: each has 41 cases including exactly 5 production cases, 0 failures,
0 errors, 0 skipped cases, and 0 captured streams. This is bounded artifact
evidence, not proof that arbitrary runtime output is safe.

The historical macOS/Windows portable jobs each report 86/86; the Linux full
connector suite remains 210 total, 206 passed, 4 existing macOS-only skips.
Do not sum overlapping suites or duplicate push/PR runs into a new unique-test
count. Exact safe CI version evidence and remaining gaps follow below.

## Hosted evidence recorded 2026-09-05

The run conclusions and detailed counts below are the **2026-09-05 record**,
independently rechecked on 2026-09-07 as described above. The refresh is not a
new hosted or field execution. Run/job links identify historical evidence, not
authorization to reproduce it on an installed host.

| Run or job | Recorded result | Scope and limits |
| --- | --- | --- |
| [Push run 33975311484](https://github.com/dawn-n-dusk/AIChat/actions/runs/33975311484) | 18/18 jobs successful | Implementation revision above; one of the two check scopes |
| [PR run 33975313925](https://github.com/dawn-n-dusk/AIChat/actions/runs/33975313925) | 18/18 jobs successful | Same implementation revision; do not add overlapping test counts across runs |
| [Windows MCP job 101330861927](https://github.com/dawn-n-dusk/AIChat/actions/runs/33975313925/job/101330861927) | 41 conformance cases passed, 0 failed, 0 skipped; includes 5 actual production MCP subprocess cases. Separately, 38 MCP unit tests passed; combined total 79 | Synthetic loopback HTTP fixture and isolated configuration; not a public Relay, real model, Codex App host-context tool return, or installed Windows sample |
| Conformance artifact inspection | Historical Windows recount: 41 cases including 5 production-process cases; 2026-09-07 independent verification covers all six platform/run reports, each 41/5 with 0 failures/errors/skips and 0 captured streams | Test-agent artifact recount supplied to this documentation pass; not a new hosted run |
| [Linux connector job 101330862036](https://github.com/dawn-n-dusk/AIChat/actions/runs/33975313925/job/101330862036) | 210 total: 206 passed, 0 failed, 4 pre-existing macOS-only IPC skips | Recorded Node 20 suite; skipped platform cases are not Linux passes |
| macOS/Windows portable Codex boundary jobs | 86/86 per job, verified in the 2026-09-07 recheck of the linked historical runs | Historical cross-platform boundary coverage, not authenticated product/field E2E |

The historical record also reports 176/176 local targeted Codex tests and a
final independent fixture-delta check of 6/6. These are separate local/review
scopes, not additional hosted job counts. The final independent agent review
accepted the feature-PR scope; it was neither a formal GitHub approval nor a
two-host acceptance result.

### Runner and runtime evidence still to reconcile

The test-agent recheck supplies these safe version facts for the historical
runs: Windows/macOS CI Python `3.11.9`, Linux CI Python `3.11.16`, and CI Node
`20.20.2`. The Windows CI evidence explicitly identifies PowerShell **Desktop
5.1** and a passing edition/version gate, but its full patch/build version is
**UNKNOWN**. Do not infer that value from a passing gate, a runner label, or the
local Python/Node rerun. The test agent also supplied runner `2.337.0` for the
listed jobs and the following exact image evidence. Image versions do not
establish shell versions; exact shell versions on all three platforms remain
unknown in the old runs.

| Historical job scope | Push run 33975311484 image | PR run 33975313925 image |
| --- | --- | --- |
| Windows MCP and portable connector | `windows-2025-vs2026` / `20260824.214.3` | `windows-2025-vs2026` / `20260824.214.3` |
| Linux MCP and full connector | `ubuntu-24.04` / `20260831.293.1` | `ubuntu-24.04` / `20260831.293.1` |
| macOS MCP | `macos-26-arm64` / `20260831.0337.3` | `macos-26-arm64` / `20260728.0273.1` |
| macOS portable connector | `macos-26-arm64` / `20260831.0337.3` | `macos-26-arm64` / `20260831.0337.3` |

The test agent reports a completed five-line, version-only banner in
`invoke_stdio_conformance_ps51.ps1`, with fixed `phase=test-runtime`,
`shell=WindowsPowerShell`, and a four-component integer version. Its ASCII and
diff checks passed as reported; actual new-CI execution/version evidence is
still pending. This is a test-wrapper output change, not a claim that every
fixture is unchanged. It adds no product runtime or deployment behavior.

Only a successful new run and its exact SHA, recorded in PR #45, can supply new
banner evidence. It cannot retroactively fill the older `1fa9aad` shell-build
gap. Do not infer an old shell patch from either an image label or a newer run.

| Version/review evidence and remaining gaps | Status |
| --- | --- |
| Exact CI Python runtime versions | Windows/macOS `3.11.9`; Linux `3.11.16`, supplied by the test-agent recheck |
| Exact CI Node runtime version | `20.20.2`, supplied by the test-agent recheck |
| Exact runner and image versions | Runner `2.337.0`; per-run/job images above |
| Windows PowerShell edition and major/minor gate | Desktop `5.1`; explicit CI gate passed |
| Full Windows PowerShell patch/build version | UNKNOWN — exact-runtime checklist item remains unchecked |
| Exact historical Linux/macOS shell versions | UNKNOWN — not inferable from runner/image metadata |
| Exact production subprocess interpreter selection evidence beyond reported Python versions | PENDING — do not infer from a setup label |
| Independent historical Windows/Linux job and six JUnit artifact recount | Completed as reported in the 2026-09-07 test-agent section |
| Separate test-agent local rerun scope and outcomes | Portable 86/86; MCP conformance 41 including production 5; MCP unit 38, with runtimes above |
| Independent production-diff review disposition | Completed as reported above; no reproducible P0/P1/P2 in its limited scope |
| Independent documentation/version-banner delta review disposition | PENDING |
| New-run exact shell version from the test-wrapper banner | PENDING — record with actual run/SHA in PR #45 after CI succeeds |

Publish only safe version metadata and bounded outcome codes. Do not export
interpreter paths, host task IDs, tokens, credential hashes, SID/SDDL, ACLs,
canary values, raw stdout/stderr, or exception text. Unavailable evidence stays
unverified; it must not be filled by assumption.

## Historical failures are retained

| Revision | Recorded failure or correction | Disposition |
| --- | --- | --- |
| `51be4bb` | Independent P1: queued recovery rejection could bypass the safe CLI boundary. P2: native exit failure lost the actual exit-code evidence. Windows synthetic early-exit cleanup also failed | Not the accepted final revision; failures are not erased by later green CI |
| `61e1638` | Added the queued rejection observer with fixed diagnostics, preserved original rejection and expected/actual native exit evidence, and bounded the EOF/exit cleanup race | Intermediate revision; the stdout-closed-but-alive fixture still exposed the Windows virtual-environment launcher handle behavior |
| `1fa9aad` | Restricted the base-interpreter correction to the two synthetic stdout-close fixtures; production cases retain their production interpreter path | Historical final fixture review 6/6 and hosted evidence above; not a field workaround or permission to retry Windows |

The queued failure uses the fixed code
`AICHAT_CONNECTOR_QUEUED_RECOVERY_FAILED` and phase `queued-recovery`. Native
exit evidence retains controlled expected/actual integer-or-null values.
Neither correction justifies raw exception forwarding, global rejection
swallowing, extra model turns, or weakened fixture expectations.

## What the foundation evidence supports

- Strict fresh allowlisted receipts and exact delivery/thread/host binding
  before checkpoint/ack; legacy acceptance without a turn remains accepted-only.
- Existing ambiguous-attempt reconciliation and same-payload/key egress recovery,
  with safe CLI/loader/logging diagnostics and synthetic redaction coverage.
- Actual production MCP subprocess framing, identity calls and errors, and
  lifecycle conformance against isolated transport. Tool discovery is not
  execution evidence for message read/send or channel create/join calls.
- No new connector engine, Relay protocol, or disk migration: connector schema
  remains version 5 and driver store version 3. Frozen field v2 denotes a
  deployment namespace, not schema version 2.

Checked items in the [stage-1/2 checklist](connector-two-host-acceptance.md) refer
only to this historical implementation evidence. They do not certify arbitrary
future HEADs, this documentation/version-banner delta, formal review, runtime compatibility,
exactly-once local tool side effects, or Mac–Windows–Mac field acceptance.

## Remaining gates and handoff

1. Retain the completed bounded implementation review, separate local reruns,
   and historical hosted/artifact recount above. Resolve the remaining exact
   shell/interpreter evidence gaps and independent documentation/banner review
   without converting unknown values into passes; reopen affected checklist
   items when new evidence warrants it. Close the follow-up P2 with accurate
   historical scope and newly reviewed production message read/write evidence
   before merging; record new counts separately from the historical five cases.
2. After the documentation/version-banner revision exists, append its actual
   exact SHA, CI run evidence including the new version output, independent
   review, and maintainer merge disposition to PR #45.
   Merge readiness requires completed independent review and successful updated
   CI; a prior green revision is insufficient. The unmerged/no-formal-approval
   state above is only the refresh snapshot. No self-referential documentation
   SHA update is needed. Keep #42 frozen; closing or superseding it is a separate
   maintainer action, not performed by this document.
3. Prepare the [operator manifest](connector-two-host-manifest-template.md) with
   private local bindings and independently observable boundaries. Missing
   restart/offline/wake observability is BLOCKED, not fixed by authorization.
4. Only a new explicit approval of the exact feasible manifest can permit one
   bounded H0 + R1–R6 suite. All field results here remain NOT RUN; no service,
   namespace, deployment, or Windows-message action is authorized.

Last-supplied Windows Relay/DNS/TLS/configuration/token-presence metadata and
direct authenticated identity success remain historical handoff facts, not a
fresh host check. The Codex App-hosted MCP return path and proactive two-host
collaboration loop remain unaccepted. Current Windows process/service state
has not been revalidated by this documentation work.
