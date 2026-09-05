from __future__ import annotations

from contextlib import contextmanager
from enum import Enum
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from urllib.parse import quote, quote_plus
import xml.etree.ElementTree as element_tree

import pytest


TOKEN = "stdio synthetic token/plus+percent%"
AGENT = {"agent_id": "stdio-agent-0001", "name": "MCP conformance 雪"}
PROTOCOL = "2025-06-18"
IO_TIMEOUT = 15.0
CLEANUP_TIMEOUT = 3.0
CAPTURE_LIMIT = 64 * 1024
FIXTURES = Path(__file__).parent / "stdio_fixtures"


class Phase(str, Enum):
    SETUP = "setup"
    SPAWN = "process_spawn"
    INITIALIZE = "initialize"
    TOOLS = "tools_list"
    UNKNOWN_TOOL = "unknown_tool"
    UNKNOWN_METHOD = "unknown_method"
    IDENTITY = "identity_result"
    HTTP = "identity_http"
    SHUTDOWN = "process_shutdown"
    CLEANUP = "cleanup"
    HARNESS = "harness_boundary"


class Code(str, Enum):
    INTERNAL = "HARNESS_INTERNAL"
    SPAWN = "CHILD_SPAWN_FAILED"
    NATIVE_EXECUTABLE = "NATIVE_FIXTURE_EXECUTABLE_UNAVAILABLE"
    WRITE = "STDIN_WRITE_FAILED"
    WRITE_TIMEOUT = "STDIN_WRITE_TIMEOUT"
    READ = "STDIO_READ_FAILED"
    TIMEOUT = "RESPONSE_TIMEOUT"
    EARLY_EXIT = "CHILD_EARLY_EXIT"
    STDOUT_CLOSED_RUNNING = "STDOUT_CLOSED_PROCESS_RUNNING"
    STDOUT_LIMIT = "STDOUT_LIMIT_EXCEEDED"
    STDERR_LIMIT = "STDERR_LIMIT_EXCEEDED"
    FRAME = "STDOUT_INVALID_JSONL"
    ENVELOPE = "JSONRPC_INVALID_ENVELOPE"
    ID = "JSONRPC_ID_MISMATCH"
    RPC_ERROR = "JSONRPC_UNEXPECTED_ERROR"
    RPC_ERROR_EXPECTED = "JSONRPC_ERROR_EXPECTED"
    RESULT = "RESULT_INVALID_SHAPE"
    TOOL_STATUS = "TOOL_ERROR_STATUS_MISMATCH"
    TOOL_CONTENT = "TOOL_CONTENT_INVALID"
    IDENTITY = "IDENTITY_CONTENT_MISMATCH"
    STRUCTURED = "STRUCTURED_CONTENT_MISMATCH"
    INITIALIZE = "INITIALIZE_CONTRACT_MISMATCH"
    TOOLS = "TOOL_SURFACE_MISMATCH"
    HTTP_COUNT = "IDENTITY_HTTP_COUNT_MISMATCH"
    HTTP_REQUEST = "IDENTITY_HTTP_REQUEST_MISMATCH"
    HTTP_SERVER = "LOOPBACK_SERVER_FAILED"
    REDACTION = "TOKEN_REDACTION_FAILED"
    EOF_TIMEOUT = "NATIVE_EOF_EXIT_TIMEOUT"
    EXIT = "NATIVE_EXIT_NONZERO"
    TRAILING = "UNEXPECTED_STDOUT_AFTER_RESPONSES"
    UNREAPED = "CHILD_NOT_REAPED"
    CLEANUP_TIMEOUT = "CLEANUP_EXIT_TIMEOUT"
    FORCED_CLEANUP = "UNEXPECTED_FORCED_CLEANUP"
    THREAD = "IO_THREAD_NOT_JOINED"
    ISOLATION = "SANDBOX_ISOLATION_FAILED"
    EXPECTED_FAILURE = "HARNESS_EXPECTED_FAILURE_MISSING"
    WRONG_FAILURE = "HARNESS_FAILURE_CODE_MISMATCH"
    DIAGNOSTIC = "DIAGNOSTIC_FIELDS_INVALID"


class ProbeFailure(AssertionError):
    def __init__(
        self,
        phase: Phase,
        code: Code,
        *,
        expected_exit: int | None = None,
        actual_exit: int | None = None,
    ) -> None:
        __tracebackhide__ = True
        if type(phase) is not Phase or type(code) is not Code or any(
            value is not None and (type(value) is not int or not -(2**31) <= value < 2**32)
            for value in (expected_exit, actual_exit)
        ):
            raise ProbeFailure(Phase.HARNESS, Code.DIAGNOSTIC) from None
        self.phase = phase
        self.code = code
        self.expected_exit = expected_exit
        self.actual_exit = actual_exit
        super().__init__(json.dumps({
            "phase": phase.value,
            "safeFailureCode": code.value,
            "expectedExitCode": expected_exit,
            "actualExitCode": actual_exit,
        }))


def require(
    condition: bool,
    phase: Phase,
    code: Code,
    *,
    expected_exit: int | None = None,
    actual_exit: int | None = None,
) -> None:
    __tracebackhide__ = True
    if not condition:
        raise ProbeFailure(phase, code, expected_exit=expected_exit, actual_exit=actual_exit)


@contextmanager
def safe_boundary(phase: Phase):
    __tracebackhide__ = True
    try:
        yield
    except ProbeFailure:
        raise
    except Exception:
        raise ProbeFailure(phase, Code.INTERNAL) from None


@contextmanager
def expect_failure(phase: Phase, code: Code, *, expected_exit=None, actual_exit=None):
    __tracebackhide__ = True
    caught = []
    try:
        yield caught
    except ProbeFailure as failure:
        caught.append(failure)
        require(failure.phase is phase and failure.code is code, Phase.HARNESS, Code.WRONG_FAILURE)
        require(
            json.loads(str(failure)) == {
                "phase": phase.value,
                "safeFailureCode": code.value,
                "expectedExitCode": expected_exit,
                "actualExitCode": actual_exit,
            },
            Phase.HARNESS,
            Code.WRONG_FAILURE,
        )
    else:
        raise ProbeFailure(Phase.HARNESS, Code.EXPECTED_FAILURE)


def sandbox_environment(root: Path, relay: str, mode: str, ambient=None) -> dict[str, str]:
    with safe_boundary(Phase.SETUP):
        home = root / "home"
        home.mkdir()
        environment = {"PATH": os.defpath}
        source = os.environ if ambient is None else ambient
        for name in ("SystemRoot", "WINDIR"):
            if name in source:
                environment[name] = source[name]
        for name, directory in {
            "HOME": home,
            "USERPROFILE": home,
            "APPDATA": home / "roaming",
            "LOCALAPPDATA": home / "local",
            "XDG_CONFIG_HOME": home / "config",
            "XDG_CACHE_HOME": home / "cache",
            "XDG_DATA_HOME": home / "data",
            "XDG_STATE_HOME": home / "state",
            "TMPDIR": root / "tmp",
            "TMP": root / "tmp",
            "TEMP": root / "tmp",
        }.items():
            directory.mkdir(parents=True, exist_ok=True)
            environment[name] = str(directory)
        environment["HOMEDRIVE"] = home.drive
        environment["HOMEPATH"] = str(home)[len(home.drive):]
        config = root / "synthetic-config.json"
        config.write_text(
            json.dumps({"server": relay, "token": TOKEN, "channel_id": "stdio-channel"}),
            encoding="utf-8",
        )
        environment.update({"AICHAT_CONFIG": str(config), "AICHAT_TIMEOUT": "2"})
        if mode == "environment":
            environment.update({"AICHAT_SERVER": relay, "AICHAT_TOKEN": TOKEN, "AICHAT_CHANNEL_ID": ""})
        return environment


class LoopbackIdentity:
    def __init__(self, body: bytes | None = None, status: int = 200) -> None:
        self.body = json.dumps(AGENT).encode("utf-8") if body is None else body
        self.status = status
        self.count = 0
        self.expected_requests = True
        self.lock = threading.Lock()
        self.failed = threading.Event()

    def __enter__(self):
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def do_GET(self):
                with owner.lock:
                    owner.count += 1
                    owner.expected_requests &= (
                        self.command == "GET"
                        and self.path == "/v1/me"
                        and self.headers.get("Authorization") == f"Bearer {TOKEN}"
                    )
                self.send_response(owner.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(owner.body)))
                self.end_headers()
                self.wfile.write(owner.body)

            do_POST = do_GET
            do_PUT = do_GET
            do_DELETE = do_GET

        class Server(ThreadingHTTPServer):
            daemon_threads = True
            block_on_close = False

            def get_request(self):
                connection, address = super().get_request()
                connection.settimeout(2.0)
                return connection, address

            def handle_error(self, request, client_address):
                owner.failed.set()

        with safe_boundary(Phase.SETUP):
            self.server = Server(("127.0.0.1", 0), Handler)
            self.url = f"http://127.0.0.1:{self.server.server_port}"
            self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
            self.thread.start()
        return self

    def check(self, count: int) -> None:
        with self.lock:
            require(self.count == count, Phase.HTTP, Code.HTTP_COUNT)
            require(self.expected_requests, Phase.HTTP, Code.HTTP_REQUEST)
        require(not self.failed.is_set(), Phase.HTTP, Code.HTTP_SERVER)

    def __exit__(self, exception_type, exception, traceback):
        with safe_boundary(Phase.CLEANUP):
            stopper = threading.Thread(target=self.server.shutdown, daemon=True)
            stopper.start()
            stopper.join(CLEANUP_TIMEOUT)
            self.server.server_close()
            self.thread.join(CLEANUP_TIMEOUT)
            require(not stopper.is_alive() and not self.thread.is_alive(), Phase.CLEANUP, Code.HTTP_SERVER)


def child_arguments(mode: str | None) -> list[str]:
    executable = sys.executable
    if mode in {"stdout-close-then-exit", "stdout-closed-alive"}:
        executable = getattr(sys, "_base_executable", None)
        try:
            valid = (
                type(executable) is str
                and bool(executable)
                and Path(executable).is_absolute()
                and Path(executable).is_file()
                and os.access(executable, os.X_OK)
            )
        except (OSError, ValueError):
            valid = False
        require(valid, Phase.SPAWN, Code.NATIVE_EXECUTABLE)
    arguments = [executable, "-I", "-B", "-u"]
    if mode is None:
        return arguments + ["-m", "aichat_mcp.server"]
    return arguments + [str(FIXTURES / "stdio_conformance_boundary_child.py"), mode]


class StdioChild:
    def __init__(self, root: Path, environment: dict[str, str], mode: str | None = None) -> None:
        self.condition = threading.Condition()
        self.capture = {"stdout": bytearray(), "stderr": bytearray()}
        self.overflow: set[str] = set()
        self.eof: set[str] = set()
        self.read_failed = False
        self.cursor = 0
        self.forced_cleanup = False
        self.stdout_exit_waited = False
        self.workers: list[threading.Thread] = []
        self.arguments = child_arguments(mode)
        try:
            self.process = subprocess.Popen(
                self.arguments,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=root,
                env=environment,
                bufsize=0,
            )
        except Exception:
            raise ProbeFailure(Phase.SPAWN, Code.SPAWN) from None
        try:
            for name in ("stdout", "stderr"):
                worker = threading.Thread(target=self._read, args=(name,), daemon=True)
                worker.start()
                self.workers.append(worker)
        except Exception:
            self.close()
            raise ProbeFailure(Phase.SPAWN, Code.READ) from None

    def _read(self, name: str) -> None:
        try:
            stream = getattr(self.process, name)
            while chunk := stream.read(4096):
                with self.condition:
                    remaining = CAPTURE_LIMIT - len(self.capture[name])
                    self.capture[name].extend(chunk[:remaining])
                    if len(chunk) > remaining:
                        self.overflow.add(name)
                    self.condition.notify_all()
        except Exception:
            with self.condition:
                self.read_failed = True
        finally:
            with self.condition:
                self.eof.add(name)
                self.condition.notify_all()

    def _check_capture(self, phase: Phase) -> None:
        require("stdout" not in self.overflow, phase, Code.STDOUT_LIMIT)
        require("stderr" not in self.overflow, phase, Code.STDERR_LIMIT)
        require(not self.read_failed, phase, Code.READ)

    def send(self, message: dict, phase: Phase) -> None:
        with safe_boundary(phase):
            payload = json.dumps(message, ensure_ascii=True, allow_nan=False).encode("utf-8") + b"\n"
            require(len(payload) <= 4096, phase, Code.WRITE)
            failed = threading.Event()

            def write():
                try:
                    remaining = memoryview(payload)
                    while remaining:
                        written = self.process.stdin.write(remaining)
                        if not written:
                            failed.set()
                            break
                        remaining = remaining[written:]
                except Exception:
                    failed.set()

            worker = threading.Thread(target=write, daemon=True)
            worker.start()
            self.workers.append(worker)
            worker.join(IO_TIMEOUT)
            require(not worker.is_alive(), phase, Code.WRITE_TIMEOUT)
            require(not failed.is_set(), phase, Code.WRITE)

    def receive(self, phase: Phase, timeout: float = IO_TIMEOUT) -> dict:
        deadline = time.monotonic() + timeout
        raw = None
        with self.condition:
            while True:
                self._check_capture(phase)
                newline = self.capture["stdout"].find(b"\n", self.cursor)
                if newline >= 0:
                    raw = bytes(self.capture["stdout"][self.cursor:newline])
                    self.cursor = newline + 1
                    break
                if "stdout" in self.eof:
                    break
                remaining = deadline - time.monotonic()
                require(remaining > 0, phase, Code.TIMEOUT)
                self.condition.wait(remaining)
        if raw is None:
            self.stdout_exit_waited = True
            try:
                return_code = self.process.wait(
                    timeout=max(0, min(CLEANUP_TIMEOUT, deadline - time.monotonic()))
                )
            except subprocess.TimeoutExpired:
                raise ProbeFailure(
                    phase, Code.STDOUT_CLOSED_RUNNING, expected_exit=0, actual_exit=None
                ) from None
            raise ProbeFailure(phase, Code.EARLY_EXIT, expected_exit=0, actual_exit=return_code)
        try:
            frame = json.loads(raw.decode("utf-8"))
        except Exception:
            raise ProbeFailure(phase, Code.FRAME) from None
        require(type(frame) is dict, phase, Code.ENVELOPE)
        return frame

    def request(self, method: str, request_id: str | int, phase: Phase, params=None, rpc_error=None):
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message, phase)
        return response_result(self.receive(phase), request_id, phase, rpc_error=rpc_error)

    def finish(self) -> None:
        with safe_boundary(Phase.SHUTDOWN):
            self.process.stdin.close()
            try:
                return_code = self.process.wait(timeout=CLEANUP_TIMEOUT)
            except subprocess.TimeoutExpired:
                raise ProbeFailure(
                    Phase.SHUTDOWN, Code.EOF_TIMEOUT, expected_exit=0, actual_exit=None
                ) from None
            require(return_code == 0, Phase.SHUTDOWN, Code.EXIT, expected_exit=0, actual_exit=return_code)
            self._join_workers()
            with self.condition:
                self._check_capture(Phase.SHUTDOWN)
                require(self.cursor == len(self.capture["stdout"]), Phase.SHUTDOWN, Code.TRAILING)
            self.check_redaction()
            self.check_reaped()

    def check_redaction(self) -> None:
        with self.condition:
            for value in (TOKEN, quote(TOKEN, safe=""), quote_plus(TOKEN)):
                require(
                    all(value.encode("utf-8") not in captured for captured in self.capture.values()),
                    Phase.IDENTITY,
                    Code.REDACTION,
                )

    def _join_workers(self) -> None:
        deadline = time.monotonic() + CLEANUP_TIMEOUT
        for worker in self.workers:
            worker.join(max(0, deadline - time.monotonic()))
        require(all(not worker.is_alive() for worker in self.workers), Phase.CLEANUP, Code.THREAD)

    def check_reaped(self) -> None:
        with safe_boundary(Phase.CLEANUP):
            require(self.process.pid > 0 and self.process.poll() is not None, Phase.CLEANUP, Code.UNREAPED)
            require(self.process.wait(timeout=0) == self.process.returncode, Phase.CLEANUP, Code.UNREAPED)
            if os.name != "nt":
                try:
                    os.waitpid(self.process.pid, os.WNOHANG)
                except ChildProcessError:
                    return
                raise ProbeFailure(Phase.CLEANUP, Code.UNREAPED)

    def close(self) -> None:
        with safe_boundary(Phase.CLEANUP):
            with self.condition:
                stdout_closed = "stdout" in self.eof
            if stdout_closed and not self.stdout_exit_waited and self.process.poll() is None:
                self.stdout_exit_waited = True
                try:
                    self.process.wait(timeout=CLEANUP_TIMEOUT)
                except subprocess.TimeoutExpired:
                    pass
            if self.process.poll() is None:
                self.forced_cleanup = True
                self.process.terminate()
                try:
                    self.process.wait(timeout=CLEANUP_TIMEOUT)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    try:
                        self.process.wait(timeout=CLEANUP_TIMEOUT)
                    except subprocess.TimeoutExpired:
                        raise ProbeFailure(
                            Phase.CLEANUP, Code.CLEANUP_TIMEOUT, expected_exit=None, actual_exit=None
                        ) from None
            self._join_workers()
            for name in ("stdin", "stdout", "stderr"):
                getattr(self.process, name).close()
            self.check_reaped()

    def __enter__(self):
        return self

    def __exit__(self, exception_type, exception, traceback):
        self.close()


def response_result(frame: dict, request_id: str | int, phase: Phase, rpc_error=None) -> dict:
    require(frame.get("jsonrpc") == "2.0", phase, Code.ENVELOPE)
    require(type(frame.get("id")) is type(request_id) and frame["id"] == request_id, phase, Code.ID)
    require(("result" in frame) != ("error" in frame), phase, Code.ENVELOPE)
    require(set(frame) == {"jsonrpc", "id", "error" if "error" in frame else "result"}, phase, Code.ENVELOPE)
    if rpc_error is not None:
        require("error" in frame, phase, Code.RPC_ERROR_EXPECTED)
        error = frame["error"]
        require(type(error) is dict, phase, Code.RESULT)
        require(type(error.get("code")) is int and error["code"] == rpc_error, phase, Code.RPC_ERROR_EXPECTED)
        require(type(error.get("message")) is str and bool(error["message"]), phase, Code.RESULT)
        return error
    require("error" not in frame, phase, Code.RPC_ERROR)
    require(type(frame["result"]) is dict, phase, Code.RESULT)
    return frame["result"]


def tool_text(result: dict, phase: Phase, *, is_error: bool) -> str:
    require(result.get("isError", False) is is_error, phase, Code.TOOL_STATUS)
    content = result.get("content")
    require(type(content) is list and len(content) == 1, phase, Code.TOOL_CONTENT)
    block = content[0]
    require(type(block) is dict and set(block) == {"type", "text"}, phase, Code.TOOL_CONTENT)
    require(block["type"] == "text" and type(block["text"]) is str, phase, Code.TOOL_CONTENT)
    return block["text"]


def strict_equal(actual, expected) -> bool:
    return json.dumps(actual, sort_keys=True, allow_nan=False) == json.dumps(expected, sort_keys=True, allow_nan=False)


def identity_result(result: dict, expected: dict) -> None:
    with safe_boundary(Phase.IDENTITY):
        text = tool_text(result, Phase.IDENTITY, is_error=False)
        try:
            content = json.loads(text)
        except Exception:
            raise ProbeFailure(Phase.IDENTITY, Code.TOOL_CONTENT) from None
        require(strict_equal(content, expected), Phase.IDENTITY, Code.IDENTITY)
        if "structuredContent" in result:
            require(strict_equal(result["structuredContent"], content), Phase.IDENTITY, Code.STRUCTURED)


def initialize(child: StdioChild) -> None:
    result = child.request(
        "initialize",
        1,
        Phase.INITIALIZE,
        {"protocolVersion": PROTOCOL, "capabilities": {}, "clientInfo": {"name": "hermetic-conformance", "version": "1"}},
    )
    require(result.get("protocolVersion") == PROTOCOL, Phase.INITIALIZE, Code.INITIALIZE)
    require(result.get("serverInfo", {}).get("name") == "AIChat", Phase.INITIALIZE, Code.INITIALIZE)
    require(type(result.get("capabilities", {}).get("tools")) is dict, Phase.INITIALIZE, Code.INITIALIZE)
    child.send({"jsonrpc": "2.0", "method": "notifications/initialized"}, Phase.INITIALIZE)


@pytest.mark.parametrize("mode", ["environment", "file"])
def test_production_stdio_initialize_tools_identity_and_native_exit(tmp_path, mode):
    with safe_boundary(Phase.HARNESS), LoopbackIdentity() as relay:
        environment = sandbox_environment(tmp_path, relay.url, mode)
        with StdioChild(tmp_path, environment) as child:
            initialize(child)
            result = child.request("tools/list", "tools-list", Phase.TOOLS, {})
            tools = result.get("tools")
            require(type(tools) is list and len(tools) == 5, Phase.TOOLS, Code.TOOLS)
            require(
                {tool.get("name") for tool in tools} == {
                    "aichat_identity", "aichat_read_messages", "aichat_send_message",
                    "aichat_create_channel", "aichat_join_channel",
                },
                Phase.TOOLS,
                Code.TOOLS,
            )
            require(all(tool.get("inputSchema", {}).get("type") == "object" for tool in tools), Phase.TOOLS, Code.TOOLS)
            relay.check(0)
            unknown = child.request("tools/call", 3, Phase.UNKNOWN_TOOL, {"name": "stdio_unknown_tool", "arguments": {}})
            require(tool_text(unknown, Phase.UNKNOWN_TOOL, is_error=True) == "Unknown tool: stdio_unknown_tool", Phase.UNKNOWN_TOOL, Code.TOOL_CONTENT)
            child.request("stdio/unknown-method", "unknown-method", Phase.UNKNOWN_METHOD, {}, rpc_error=-32602)
            relay.check(0)
            result = child.request("tools/call", "identity-result", Phase.IDENTITY, {"name": "aichat_identity", "arguments": {}})
            child.check_redaction()
            identity_result(result, {
                "agent": AGENT,
                "relay": relay.url,
                "default_channel_id": None if mode == "environment" else "stdio-channel",
                "token_exposed": False,
            })
            child.finish()
        require(not child.forced_cleanup, Phase.SHUTDOWN, Code.FORCED_CLEANUP, expected_exit=0, actual_exit=child.process.returncode)
        relay.check(1)


@pytest.mark.parametrize("case", ["http401", "invalid-json", "non-object"])
def test_production_stdio_identity_errors_are_tool_errors_and_redacted(tmp_path, case):
    bodies = {
        "http401": json.dumps({"detail": f"rejected {TOKEN} {quote(TOKEN, safe='')} {quote_plus(TOKEN)}"}).encode("utf-8"),
        "invalid-json": b"not-json",
        "non-object": b"[]",
    }
    details = {
        "http401": "failed with HTTP 401: rejected [REDACTED] [REDACTED] [REDACTED]",
        "invalid-json": "returned invalid JSON",
        "non-object": "returned a non-object JSON response",
    }
    with safe_boundary(Phase.HARNESS), LoopbackIdentity(bodies[case], 401 if case == "http401" else 200) as relay:
        environment = sandbox_environment(tmp_path, relay.url, "file")
        with StdioChild(tmp_path, environment) as child:
            initialize(child)
            relay.check(0)
            result = child.request("tools/call", "identity-error", Phase.IDENTITY, {"name": "aichat_identity", "arguments": {}})
            child.check_redaction()
            text = tool_text(result, Phase.IDENTITY, is_error=True)
            require(text == "Error executing tool aichat_identity: AIChat API GET /v1/me " + details[case], Phase.IDENTITY, Code.TOOL_CONTENT)
            require("structuredContent" not in result, Phase.IDENTITY, Code.STRUCTURED)
            recovery = child.request("tools/list", "after-error", Phase.TOOLS, {})
            require(type(recovery.get("tools")) is list and len(recovery["tools"]) == 5, Phase.TOOLS, Code.TOOLS)
            child.finish()
        require(not child.forced_cleanup, Phase.SHUTDOWN, Code.FORCED_CLEANUP, expected_exit=0, actual_exit=child.process.returncode)
        relay.check(1)


def test_windows_venv_wrapper_is_bypassed_only_for_native_stdout_fixtures(monkeypatch):
    base_executable = getattr(sys, "_base_executable", None)
    launcher = r"C:\synthetic-venv\Scripts\python.exe"
    monkeypatch.setattr(sys, "executable", launcher)
    for mode in (
        None, "junit-native-exits", "early-exit", "exit-on-eof", "ignore-eof",
        "silent", "stdout-noise", "stdout-flood", "stderr-flood",
        "stdout-close-then-exit", "stdout-closed-alive",
    ):
        expected = base_executable if mode in {"stdout-close-then-exit", "stdout-closed-alive"} else launcher
        arguments = child_arguments(mode)
        require(arguments[:4] == [expected, "-I", "-B", "-u"], Phase.HARNESS, Code.ISOLATION)
        tail = ["-m", "aichat_mcp.server"] if mode is None else [str(FIXTURES / "stdio_conformance_boundary_child.py"), mode]
        require(arguments[4:] == tail, Phase.HARNESS, Code.ISOLATION)


def test_missing_base_interpreter_fails_native_fixtures_without_changing_venv_modes(monkeypatch):
    monkeypatch.delattr(sys, "_base_executable", raising=False)
    for mode in ("stdout-close-then-exit", "stdout-closed-alive"):
        with expect_failure(Phase.SPAWN, Code.NATIVE_EXECUTABLE):
            child_arguments(mode)
    for mode in (None, "junit-native-exits", "early-exit", "exit-on-eof", "ignore-eof", "silent", "stdout-noise", "stdout-flood", "stderr-flood"):
        require(child_arguments(mode)[0] == sys.executable, Phase.HARNESS, Code.ISOLATION)


def test_invalid_native_interpreter_is_a_fixed_path_free_failure(tmp_path, monkeypatch):
    for executable in (None, False, "", "relative-python", str(tmp_path), str(tmp_path / "missing-python")):
        monkeypatch.setattr(sys, "_base_executable", executable)
        for mode in ("stdout-close-then-exit", "stdout-closed-alive"):
            with expect_failure(Phase.SPAWN, Code.NATIVE_EXECUTABLE):
                child_arguments(mode)
    monkeypatch.setattr(sys, "_base_executable", sys.executable)
    monkeypatch.setattr(os, "access", lambda *args: False)
    with expect_failure(Phase.SPAWN, Code.NATIVE_EXECUTABLE):
        child_arguments("stdout-closed-alive")


@pytest.mark.parametrize("mode,code", [
    ("silent", Code.TIMEOUT),
    ("early-exit", Code.EARLY_EXIT),
    ("stdout-close-then-exit", Code.EARLY_EXIT),
    ("stdout-noise", Code.FRAME),
    ("stdout-flood", Code.STDOUT_LIMIT),
    ("stderr-flood", Code.STDERR_LIMIT),
])
def test_harness_bounds_fake_child_failure_and_reaps_pid(tmp_path, mode, code):
    with safe_boundary(Phase.HARNESS):
        environment = sandbox_environment(tmp_path, "http://127.0.0.1:1", "file")
        started = time.monotonic()
        with StdioChild(tmp_path, environment, mode) as child:
            ready = response_result(child.receive(Phase.SPAWN), 0, Phase.SPAWN)
            require(ready == {"ready": True}, Phase.SPAWN, Code.RESULT)
            child.send({"run": True}, Phase.HARNESS)
            native_exit = mode in {"early-exit", "stdout-close-then-exit"}
            with expect_failure(
                Phase.HARNESS, code,
                expected_exit=0 if native_exit else None,
                actual_exit=17 if native_exit else None,
            ):
                child.receive(Phase.HARNESS, timeout=0.25 if mode == "silent" else IO_TIMEOUT)
        child.check_reaped()
        require(time.monotonic() - started < 2 * IO_TIMEOUT + 4 * CLEANUP_TIMEOUT, Phase.HARNESS, Code.TIMEOUT)
        require(all(len(value) <= CAPTURE_LIMIT for value in child.capture.values()), Phase.HARNESS, Code.STDOUT_LIMIT)
        if mode in {"early-exit", "stdout-close-then-exit"}:
            require(
                child.process.returncode == 17, Phase.HARNESS, Code.EXIT,
                expected_exit=17, actual_exit=child.process.returncode,
            )
            require(not child.forced_cleanup, Phase.CLEANUP, Code.FORCED_CLEANUP, actual_exit=child.process.returncode)
        else:
            require(child.forced_cleanup, Phase.HARNESS, Code.UNREAPED)


@pytest.mark.parametrize("mode,code,forced", [
    ("ignore-eof", Code.EOF_TIMEOUT, True),
    ("exit-on-eof", Code.EXIT, False),
])
def test_harness_native_exit_failure_is_distinct_and_cleanup_reaps_pid(tmp_path, mode, code, forced):
    with safe_boundary(Phase.HARNESS):
        environment = sandbox_environment(tmp_path, "http://127.0.0.1:1", "file")
        started = time.monotonic()
        with StdioChild(tmp_path, environment, mode) as child:
            response_result(child.receive(Phase.SPAWN), 0, Phase.SPAWN)
            with expect_failure(
                Phase.SHUTDOWN, code, expected_exit=0, actual_exit=None if forced else 19
            ) as caught:
                child.finish()
        child.check_reaped()
        require(child.forced_cleanup is forced, Phase.HARNESS, Code.UNREAPED)
        if not forced:
            require(
                child.process.returncode == 19, Phase.HARNESS, Code.EXIT,
                expected_exit=19, actual_exit=child.process.returncode,
            )
        else:
            require(caught[0].actual_exit is None, Phase.HARNESS, Code.DIAGNOSTIC)
        require(time.monotonic() - started < IO_TIMEOUT + 4 * CLEANUP_TIMEOUT, Phase.HARNESS, Code.TIMEOUT)


def test_stdout_closed_but_alive_is_not_reported_as_native_exit(tmp_path):
    with safe_boundary(Phase.HARNESS):
        environment = sandbox_environment(tmp_path, "http://127.0.0.1:1", "file")
        started = time.monotonic()
        with StdioChild(tmp_path, environment, "stdout-closed-alive") as child:
            response_result(child.receive(Phase.SPAWN), 0, Phase.SPAWN)
            child.send({"run": True}, Phase.HARNESS)
            with expect_failure(
                Phase.HARNESS, Code.STDOUT_CLOSED_RUNNING, expected_exit=0, actual_exit=None
            ) as caught:
                child.receive(Phase.HARNESS)
            require(child.process.poll() is None, Phase.HARNESS, Code.WRONG_FAILURE)
        child.check_reaped()
        require(child.forced_cleanup, Phase.CLEANUP, Code.UNREAPED)
        require(caught[0].actual_exit is None, Phase.HARNESS, Code.DIAGNOSTIC)
        require(time.monotonic() - started < IO_TIMEOUT + 4 * CLEANUP_TIMEOUT, Phase.HARNESS, Code.TIMEOUT)


def test_cleanup_waits_for_observed_stdout_eof_before_terminating(tmp_path):
    with safe_boundary(Phase.HARNESS):
        environment = sandbox_environment(tmp_path, "http://127.0.0.1:1", "file")
        started = time.monotonic()
        with StdioChild(tmp_path, environment, "stdout-close-then-exit") as child:
            response_result(child.receive(Phase.SPAWN), 0, Phase.SPAWN)
            child.send({"run": True}, Phase.HARNESS)
            with child.condition:
                require(
                    child.condition.wait_for(lambda: "stdout" in child.eof, IO_TIMEOUT),
                    Phase.HARNESS, Code.TIMEOUT,
                )
        child.check_reaped()
        require(not child.forced_cleanup, Phase.CLEANUP, Code.FORCED_CLEANUP, actual_exit=child.process.returncode)
        require(child.process.returncode == 17, Phase.HARNESS, Code.EXIT, expected_exit=17, actual_exit=child.process.returncode)
        require(time.monotonic() - started < IO_TIMEOUT + 4 * CLEANUP_TIMEOUT, Phase.HARNESS, Code.TIMEOUT)


def test_fake_child_cleanup_wait_failure_has_its_own_unknown_exit_diagnostic(tmp_path, monkeypatch):
    def unavailable_wait(*args, **kwargs):
        raise subprocess.TimeoutExpired("synthetic-wait", CLEANUP_TIMEOUT)

    with safe_boundary(Phase.HARNESS):
        environment = sandbox_environment(tmp_path, "http://127.0.0.1:1", "file")
        with StdioChild(tmp_path, environment, "silent") as child:
            response_result(child.receive(Phase.SPAWN), 0, Phase.SPAWN)
            with monkeypatch.context() as patch:
                patch.setattr(child.process, "wait", unavailable_wait)
                with expect_failure(Phase.CLEANUP, Code.CLEANUP_TIMEOUT) as caught:
                    child.close()
        child.check_reaped()
        require(caught[0].actual_exit is None, Phase.HARNESS, Code.DIAGNOSTIC)


@pytest.mark.parametrize("field", ["expected_exit", "actual_exit"])
def test_exit_diagnostics_reject_non_native_integer_values(field):
    class IntegerSubclass(int):
        pass

    for value in (True, False, 17.0, "19", {}, [], IntegerSubclass(17), 2**32, -(2**31) - 1):
        with expect_failure(Phase.HARNESS, Code.DIAGNOSTIC):
            ProbeFailure(Phase.SHUTDOWN, Code.EXIT, **{field: value})


def test_exit_diagnostics_allow_only_four_typed_fields():
    for actual in (None, -(2**31), -15, 0, 17, 19, 2**32 - 1):
        diagnostic = json.loads(str(ProbeFailure(Phase.SHUTDOWN, Code.EXIT, expected_exit=0, actual_exit=actual)))
        require(set(diagnostic) == {"phase", "safeFailureCode", "expectedExitCode", "actualExitCode"}, Phase.HARNESS, Code.DIAGNOSTIC)
        require(type(diagnostic["expectedExitCode"]) is int and diagnostic["expectedExitCode"] == 0, Phase.HARNESS, Code.DIAGNOSTIC)
        require(type(diagnostic["actualExitCode"]) is type(actual) and diagnostic["actualExitCode"] == actual, Phase.HARNESS, Code.DIAGNOSTIC)


def test_exit_diagnostics_reject_arbitrary_metadata_and_untrusted_labels():
    for phase, code in (("untrusted-phase", Code.EXIT), (Phase.SHUTDOWN, "AICHAT_UNTRUSTED")):
        with expect_failure(Phase.HARNESS, Code.DIAGNOSTIC):
            ProbeFailure(phase, code)
    with expect_failure(Phase.HARNESS, Code.INTERNAL):
        with safe_boundary(Phase.HARNESS):
            ProbeFailure(Phase.SHUTDOWN, Code.EXIT, metadata={"private": "synthetic-metadata"})


def test_real_pytest_junit_preserves_native_exit_17_and_19_as_safe_integers(tmp_path):
    with safe_boundary(Phase.HARNESS):
        environment = sandbox_environment(tmp_path, "http://127.0.0.1:1", "file")
        with StdioChild(tmp_path, environment, "junit-native-exits") as child:
            response_result(child.receive(Phase.SPAWN), 0, Phase.SPAWN)
            child.send({"run": True}, Phase.HARNESS)
            try:
                return_code = child.process.wait(timeout=IO_TIMEOUT)
            except subprocess.TimeoutExpired:
                raise ProbeFailure(Phase.HARNESS, Code.TIMEOUT, expected_exit=1, actual_exit=None) from None
            require(return_code == 1, Phase.HARNESS, Code.EXIT, expected_exit=1, actual_exit=return_code)
        child.check_redaction()
        with child.condition:
            child._check_capture(Phase.HARNESS)
        report = (tmp_path / "native-exit-report.xml").read_text(encoding="utf-8")
        for value in (TOKEN, quote(TOKEN, safe=""), quote_plus(TOKEN)):
            require(value not in report, Phase.HARNESS, Code.REDACTION)
        document = element_tree.fromstring(report)
        failures = document.findall(".//failure")
        require(len(document.findall(".//testcase")) == len(failures) == 2, Phase.HARNESS, Code.RESULT)
        require(not any(document.findall(f".//{name}") for name in ("error", "skipped", "system-out", "system-err")), Phase.HARNESS, Code.RESULT)
        diagnostics = {}
        for failure in failures:
            message = failure.get("message", "")
            diagnostic = json.loads(message[message.index("{"):])
            require(set(diagnostic) == {"phase", "safeFailureCode", "expectedExitCode", "actualExitCode"}, Phase.HARNESS, Code.DIAGNOSTIC)
            require(type(diagnostic["expectedExitCode"]) is int and diagnostic["expectedExitCode"] == 0, Phase.HARNESS, Code.DIAGNOSTIC)
            require(type(diagnostic["actualExitCode"]) is int, Phase.HARNESS, Code.DIAGNOSTIC)
            diagnostics[diagnostic["safeFailureCode"]] = (diagnostic["phase"], diagnostic["actualExitCode"])
        require(diagnostics == {
            Code.EARLY_EXIT.value: (Phase.HARNESS.value, 17),
            Code.EXIT.value: (Phase.SHUTDOWN.value, 19),
        }, Phase.HARNESS, Code.DIAGNOSTIC)


@pytest.mark.parametrize("frame,code", [
    ({"jsonrpc": "2.0", "id": "1", "result": {}}, Code.ID),
    ({"jsonrpc": "2.0", "id": True, "result": {}}, Code.ID),
    ({"jsonrpc": "1.0", "id": 1, "result": {}}, Code.ENVELOPE),
    ({"jsonrpc": "2.0", "id": 1, "error": {"code": -32603, "message": "synthetic"}}, Code.RPC_ERROR),
    ({"jsonrpc": "2.0", "id": 1, "result": {}, "error": {}}, Code.ENVELOPE),
    ({"jsonrpc": "2.0", "id": 1}, Code.ENVELOPE),
    ({"jsonrpc": "2.0", "id": 1, "result": []}, Code.RESULT),
], ids=["string-id", "bool-id", "version", "rpc-error", "result-and-error", "missing-result", "result-type"])
def test_harness_rejects_response_confusion_with_safe_codes(frame, code):
    with expect_failure(Phase.IDENTITY, code):
        response_result(frame, 1, Phase.IDENTITY)


@pytest.mark.parametrize("case,code", [
    ("error-flag", Code.TOOL_STATUS),
    ("numeric-flag", Code.TOOL_STATUS),
    ("extra-block", Code.TOOL_CONTENT),
    ("non-text", Code.TOOL_CONTENT),
    ("text-not-json", Code.TOOL_CONTENT),
    ("wrong-identity", Code.IDENTITY),
    ("numeric-false", Code.IDENTITY),
    ("structured-mismatch", Code.STRUCTURED),
])
def test_harness_strict_identity_validation_has_distinct_safe_codes(case, code):
    expected = {"agent": AGENT, "token_exposed": False}
    result = {"isError": False, "content": [{"type": "text", "text": json.dumps(expected)}]}
    if case == "error-flag":
        result["isError"] = True
    elif case == "numeric-flag":
        result["isError"] = 0
    elif case == "extra-block":
        result["content"] *= 2
    elif case == "non-text":
        result["content"][0]["type"] = "image"
    elif case == "text-not-json":
        result["content"][0]["text"] = "synthetic-noise"
    elif case == "wrong-identity":
        result["content"][0]["text"] = "{}"
    elif case == "numeric-false":
        result["content"][0]["text"] = json.dumps({"agent": AGENT, "token_exposed": 0})
    else:
        result["structuredContent"] = {"agent": AGENT, "token_exposed": True}
    with expect_failure(Phase.IDENTITY, code):
        identity_result(result, expected)


def test_sandbox_does_not_inherit_ambient_configuration_credentials_or_proxies(tmp_path):
    with safe_boundary(Phase.HARNESS):
        ambient = dict.fromkeys([
            "AICHAT_SERVER", "AICHAT_TOKEN", "AICHAT_CONFIG", "AICHAT_CHANNEL_ID",
            "AICHAT_PRIVATE", "AWS_SECRET_ACCESS_KEY", "OPENAI_API_KEY", "GITHUB_TOKEN",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy",
            "all_proxy", "no_proxy", "PYTHONPATH", "PYTHONHOME", "HOME", "USERPROFILE",
            "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "PATH",
        ], "synthetic-ambient-must-not-propagate")
        environment = sandbox_environment(tmp_path, "http://127.0.0.1:1", "file", ambient)
        require("synthetic-ambient-must-not-propagate" not in environment.values(), Phase.HARNESS, Code.ISOLATION)
        require({name for name in environment if name.startswith("AICHAT_")} == {"AICHAT_CONFIG", "AICHAT_TIMEOUT"}, Phase.HARNESS, Code.ISOLATION)
        for name in ("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "AICHAT_CONFIG", "TEMP", "TMPDIR"):
            require(Path(environment[name]).is_relative_to(tmp_path), Phase.HARNESS, Code.ISOLATION)


def test_unexpected_exception_is_replaced_by_allowlisted_diagnostic():
    with expect_failure(Phase.HARNESS, Code.INTERNAL):
        with safe_boundary(Phase.HARNESS):
            raise RuntimeError("AICHAT_UNTRUSTED synthetic raw exception must not become a diagnostic")
