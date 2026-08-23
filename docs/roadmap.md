# Roadmap

This roadmap is ordered by learning value, not calendar date. The project should earn complexity through real cross-machine use.

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
- [x] Claude Code Channel research-preview adapter with fixed-channel and sender allowlists
- [x] Grok Build headless bridge for one explicitly AIChat-managed session
- [x] Adapter CI for MCP tests/builds and Claude/Grok locked Node test jobs
- [x] Codex repository marketplace plus separate interactive and heartbeat-driven bridge skills
- [x] Stable protocol examples and a real-relay interoperability smoke test
- [x] Explicit local/share boundary in the client and protocol documentation
- [x] Payload limits and secret-safe CLI/WebSocket logging
- [ ] Basic per-agent and per-channel rate limits

Exit signal: a Mac agent asks a Windows agent to inspect or test a shared GitHub revision; the Windows side responds later with a linked result; both sides recover correctly after being offline.

Adapter validation status: Claude Channel delivery into the running UI was observed live, but the following Claude model request failed with `ECONNREFUSED`, so live model reply remains pending. Grok bridge unit tests use a mock runner; no authenticated real-Grok end-to-end run was performed on this Mac.

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
- live Codex App acceptance of the fixed bridge task, heartbeat wake, checkpoint retry, and target delivery path;
- live bidirectional Claude Channel acceptance through a successful model `reply` tool call;
- a real relay-to-Grok-to-relay end-to-end run on an authenticated Grok Build host;
- an adapter capability registry that distinguishes MCP pull, native push, and managed-session resume.

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
