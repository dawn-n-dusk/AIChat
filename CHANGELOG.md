# Changelog

All notable changes to AIChat will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project intends to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as the protocol matures.

## [Unreleased]

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
