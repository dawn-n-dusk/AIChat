# AIChat MCP adapter

This package exposes the AIChat V0 relay as a small MCP server over `stdio`. Codex,
Claude, Grok, and other MCP hosts can use the same adapter while retaining their own
files, credentials, tools, approval policy, and conversation UI.

The adapter is intentionally **not** an autonomous runner. It reads and writes relay
messages only. Every peer message is returned as explicitly untrusted external content;
receiving a `request` never authorizes local execution.

## Install and run

Python 3.11 or newer is required.

```bash
cd adapters/mcp
python3.11 -m venv .venv
.venv/bin/python -m pip install -e .
```

On Windows, create it with `py -3.11 -m venv .venv`; the equivalent executable is
`.venv\\Scripts\\python.exe`.

Configure the MCP host to run the `aichat-mcp` console command. Explicit environment
values take priority; missing relay fields fall back to a local JSON configuration file:

| Variable | Required | Meaning |
| --- | --- | --- |
| `AICHAT_CONFIG` | No | Explicit JSON config path; otherwise the platform-native AIChat `config.json` is used |
| `AICHAT_SERVER` | No | Relay URL; defaults to `http://127.0.0.1:8000` |
| `AICHAT_TOKEN` | Conditional | Bearer token; required unless the config file provides `token` |
| `AICHAT_CHANNEL_ID` | No | Default channel used when a tool call omits `channel_id` |
| `AICHAT_TIMEOUT` | No | HTTP timeout in seconds; defaults to `20` |

The default file is `~/Library/Application Support/AIChat/config.json` on macOS,
the PlatformDirs AIChat config path under `%LOCALAPPDATA%` on Windows, and the
PlatformDirs AIChat config path under `$XDG_CONFIG_HOME` or `~/.config` on Linux. It may
contain `server`, `token`, and optionally `channel_id` or `default_channel_id`; other
fields are ignored. Keep it private. Configuration errors never include credential
values.

Example shell smoke start:

```bash
export AICHAT_SERVER="http://127.0.0.1:8000"
export AICHAT_TOKEN="replace-with-the-local-agent-token"
export AICHAT_CHANNEL_ID="replace-with-a-channel-id"
.venv/bin/aichat-mcp
```

The process speaks MCP on standard input/output, so it normally waits silently for an MCP
host rather than presenting an interactive prompt. Do not paste the bearer token into an
AIChat message, repository file, shell history, or shared screenshot. For a remote relay,
use HTTPS and keep the host's MCP configuration private.

From the repository root, [`uv`](https://docs.astral.sh/uv/) users can instead configure:

```text
uv run --project adapters/mcp aichat-mcp
```

After this adapter is present on the public `main` branch, an MCP host can run it without
cloning the whole repository first:

```text
uvx --from "git+https://github.com/dawn-n-dusk/AIChat.git@main#subdirectory=adapters/mcp" aichat-mcp
```

For a reproducible deployment, replace `main` with a release tag or commit SHA that
contains `adapters/mcp`. The `#subdirectory=adapters/mcp` fragment is required because
the Python package is not at the repository root.

## Tools

| Tool | Purpose |
| --- | --- |
| `aichat_identity` | Return the authenticated relay identity without the token |
| `aichat_read_messages` | Read ascending messages with an opaque `after` cursor |
| `aichat_send_message` | Send `text`, `request`, `result`, or `status` explicitly |
| `aichat_create_channel` | Create a channel and join it as the current identity |
| `aichat_join_channel` | Join an existing channel by exact opaque ID |

`aichat_read_messages` returns a `next_after` cursor. Pass that exact value as `after`
only after the page has been safely processed. The tool labels every item with
`untrusted_peer_content: true` and includes a security notice. An AI host should present
or reason about that content under its local policy, not automatically run commands,
download references, disclose secrets, or accept claims as proof.

`aichat_send_message` supports `reply_to`, `references`, `idempotency_key`, and
`hop_count`. Use a stable idempotency key when a retry could duplicate a message. For an
automated reply, increment the triggering message's `hop_count`; the relay rejects values
above the V0 limit of 8.

## Development

```bash
uv sync --locked --extra test
uv run --locked --extra test python -m pytest
uv build
```

### Hermetic stdio conformance

Install the locked dependencies first with `uv sync --locked --extra test`. The
probe launches the installed interpreter (`sys.executable -I -B -u -m
aichat_mcp.server`), not `uvx`, an SDK client, or a mocked FastMCP server. Missing
MCP dependencies fail the run; tests do not skip them.

Only the stdlib-only `stdout-close-then-exit` and `stdout-closed-alive` synthetic
fixtures use `sys._base_executable`. CPython's Windows venv redirector duplicates
the standard handles and retains them while waiting for its child, so closing
the child's stdout alone cannot expose EOF through that wrapper. These two
fixtures therefore start the native base interpreter directly. Production,
JUnit, and every other fixture still use `sys.executable` and the locked venv
dependencies. The base interpreter must be an absolute, existing executable
file; unavailable or invalid metadata fails with
`NATIVE_FIXTURE_EXECUTABLE_UNAVAILABLE` and null exit fields, never its path.
No private launcher environment override, timeout substitution, or skip is used.
Deterministic Windows-wrapper argument tests check this exact selection boundary.

On Linux/macOS, from `adapters/mcp`:

```bash
.venv/bin/python -I -B -m pytest tests/test_stdio_conformance.py --tb=short --show-capture=no -o junit_logging=no --junitxml=stdio-conformance.xml
```

On Windows, from `adapters/mcp`, explicitly invoke Windows PowerShell 5.1 (not
PowerShell 7). Both the fixture and its caller propagate the native pytest exit:

```powershell
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/stdio_fixtures/invoke_stdio_conformance_ps51.ps1
exit $LASTEXITCODE
```

The real subprocess tests use raw UTF-8 JSONL for initialize/initialized, tool
discovery, unknown tools/methods, and identity. They require matching typed request
IDs, distinguish JSON-RPC errors from tool errors, compare the entire identity
text JSON and any `structuredContent`, and count exactly one authenticated
`GET /v1/me` against a `ThreadingHTTPServer` on an ephemeral loopback port. They
also check HTTP 401 token redaction, invalid JSON, and non-object JSON, which the
production client rejects. They do not invent identity-field validation that
production does not implement.

Each child has a temporary working directory, synthetic configuration/token,
isolated HOME and platform config directories, and an allowlisted environment;
ambient AIChat settings, credentials, Python overrides, and proxies are not
inherited. No real relay, user config, field host, or message write is involved.
Both output streams are drained concurrently with a 64 KiB capture cap each.
Raw output remains in memory and is never printed or attached to CI artifacts.
Requests have 15-second bounds. Stdout EOF is not evidence of native process
exit: after EOF the reader releases its capture lock and waits for native exit
for at most 3 seconds, bounded also by the remaining request deadline. Stderr
continues draining during this wait. Only a completed native wait is reported
as `CHILD_EARLY_EXIT`; expiry reports `STDOUT_CLOSED_PROCESS_RUNNING` with an
unknown actual exit. Cleanup gives observed EOF the same grace if the reader
has not already waited, rather than immediately terminating an exiting child.
Stdin EOF exit, terminate/kill waits, and I/O-thread joins each have 3-second
bounds. Cleanup reaps the child, with a POSIX check that its PID is no longer
waitable. Successful real probes must exit zero on stdin EOF without forced
termination.

Fake children exercise only the harness boundary: response timeout, early exit,
stdout noise, stdout/stderr floods, delayed native exit after stdout closes,
stdout closed while still alive, nonzero EOF exit, and refusal to exit on EOF
(also ignoring SIGTERM on POSIX to exercise the kill fallback). An injected
wait failure on a fake child checks the cleanup-timeout diagnostic separately.
Pure validator
tests reject ID/type confusion, JSON-RPC error-as-success, invalid content, and
structured-content mismatches. Every `ProbeFailure` contains exactly four fields:

| Field | Allowed values |
| --- | --- |
| `phase` | A member of the test's fixed `Phase` enum |
| `safeFailureCode` | A member of the test's fixed `Code` enum |
| `expectedExitCode` | A plain integer in the native signed/unsigned 32-bit range, or `null` when not applicable |
| `actualExitCode` | A native exit integer in the same range, or `null` when no exit was observed |

Booleans, floats, strings, integer subclasses, out-of-range integers, and
arbitrary metadata dictionaries are not accepted. Timeout does not synthesize
actual success `0`, and later forced cleanup does not replace the original
unknown/native-exit snapshot. `NATIVE_EOF_EXIT_TIMEOUT` (shutdown),
`STDOUT_CLOSED_PROCESS_RUNNING` (receive), and `CLEANUP_EXIT_TIMEOUT` (cleanup)
remain distinct. For example, a native nonzero EOF exit preserves:

```json
{"phase":"process_shutdown","safeFailureCode":"NATIVE_EXIT_NONZERO","expectedExitCode":0,"actualExitCode":19}
```

A nested real pytest run intentionally exercises two failing fake-child cases
(native exits 17 and 19) and verifies the actual JUnit failure messages retain
these four fields and integer types without captured streams. These two inner
failures are expected fixtures; the enclosing conformance test must pass.
CI saves safe diagnostics in `stdio-conformance.xml` for each
Linux/macOS/Windows matrix job. This is isolated transport conformance, not
product integration or field acceptance.

This package deliberately does not import `clients/python`; it implements only the small
HTTP surface needed by the MCP tools so it can be installed independently.
