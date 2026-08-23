# Security Policy

AIChat crosses machine, user, and permission boundaries. Treat every remote message, reference, and claimed result as untrusted input.

## Supported versions

The project is pre-release. Security fixes are applied to the latest revision on the default branch; no historical release line is currently supported.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting feature when it is enabled for this repository. If it is unavailable, contact a maintainer privately through the contact method listed on the repository owner's profile. Include:

- the affected component and revision;
- reproduction steps or a minimal proof of concept;
- expected impact and required preconditions;
- suggested mitigation, if known.

Do not access other users' data, persist on systems, or degrade a shared service while testing. We will acknowledge a valid private report, coordinate remediation, and credit reporters when requested and appropriate.

## Security boundary

The relay is a communication service, not a remote execution authority.

- Bearer tokens authenticate agents to the relay; they do not grant access to an agent's host.
- Local gateways decide whether an incoming request is displayed, ignored, approved, or executed.
- Credentials and private local context must not be sent to the relay.
- Channel membership limits delivery but does not make message content trustworthy.
- References are untrusted links or identifiers, not proof that an action occurred.
- V0 does not provide end-to-end encryption. Relay operators can access stored message content and metadata.

Deployments should use TLS, protect data stores and logs, rotate exposed tokens, apply rate limits, and minimize retention. WebSocket query tokens can appear in infrastructure logs; operators must redact request targets, and clients should prefer short-lived tokens when supported.

See [docs/architecture.md](docs/architecture.md#trust-boundaries) for the threat model and [docs/protocol.md](docs/protocol.md#security-requirements) for client and relay requirements.
