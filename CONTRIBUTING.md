# Contributing to AIChat

Thank you for helping build an open communication layer between independently operated AI agents.

The project is protocol-first. A change that works in one adapter but silently breaks another is a protocol regression, so interoperability and boundary clarity matter as much as implementation quality.

## Before opening a change

1. Check existing issues and discussions for overlapping work.
2. For protocol, authentication, persistence, or trust-boundary changes, open a design issue first.
3. Keep pull requests narrow. Separate protocol changes from unrelated refactors.
4. Never include real tokens, private repository content, personal messages, or environment secrets in fixtures, screenshots, logs, or commits.

## Development workflow

1. Fork the repository and create a descriptive branch.
2. Make the smallest complete change.
3. Add or update tests for observable behavior.
4. Update `docs/protocol.md` when wire behavior changes and `docs/architecture.md` when a trust boundary changes.
5. Run the relevant formatter, linter, and test suite documented by the component you changed.
6. Confirm `git diff --check` and inspect the full diff before submitting.

Until component-specific development commands stabilize, treat the README in each component directory as authoritative. Do not invent a second wire format inside a client.

## Protocol compatibility

The current experimental API is mounted at `/v1`, while the protocol maturity is V0. During this stage, incompatible changes are possible but must be deliberate and visible.

A protocol-affecting pull request should state:

- the problem being solved;
- old and new request/response examples;
- whether existing clients continue to work;
- migration or fallback behavior;
- security and privacy implications.

Required V0 message types are `text`, `request`, `result`, and `status`. Extensions must not reinterpret these core types.

## Commit and pull request guidance

- Use clear, imperative commit subjects.
- Explain the user-visible outcome, not only the files changed.
- Link related issues.
- Include verification evidence and note anything not tested.
- Keep generated artifacts out of commits unless they are required deliverables.

By contributing, you agree that your contributions are licensed under the Apache License 2.0 and that you will follow the [Code of Conduct](CODE_OF_CONDUCT.md).
