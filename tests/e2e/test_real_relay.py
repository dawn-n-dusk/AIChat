from __future__ import annotations

import asyncio
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import quote

import httpx
from websockets.asyncio.client import connect

from aichat_client import AIChatClient


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def _unused_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _aichat_executable() -> str:
    candidate = Path(sys.executable).with_name("aichat.exe" if os.name == "nt" else "aichat")
    if candidate.is_file():
        return str(candidate)
    discovered = shutil.which("aichat")
    if discovered:
        return discovered
    raise AssertionError("The aichat CLI is not installed in the active test environment")


def _cli_environment() -> dict[str, str]:
    environment = os.environ.copy()
    for key in ("AICHAT_CONFIG_DIR", "AICHAT_SERVER", "AICHAT_TOKEN"):
        environment.pop(key, None)
    return environment


def _run_cli(server: str, config: Path, *arguments: str) -> tuple[dict, str]:
    result = subprocess.run(
        [
            _aichat_executable(),
            "--server",
            server,
            "--config",
            str(config),
            *arguments,
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
        env=_cli_environment(),
    )
    if result.returncode != 0:
        raise AssertionError(
            f"aichat {' '.join(arguments[:1])} failed with exit {result.returncode}: "
            f"{result.stderr.strip()}"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise AssertionError("aichat returned non-JSON output") from None
    if not isinstance(payload, dict):
        raise AssertionError("aichat returned a non-object JSON payload")
    return payload, result.stdout


def _wait_for_health(server: str, process: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 15
    with httpx.Client(trust_env=False) as client:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise AssertionError("The real uvicorn relay exited before becoming healthy")
            try:
                response = client.get(f"{server}/health", timeout=0.5)
                if response.status_code == 200 and response.json() == {"status": "ok"}:
                    return
            except (httpx.HTTPError, ValueError):
                pass
            time.sleep(0.05)
    raise AssertionError("The real uvicorn relay did not become healthy within 15 seconds")


def _assert_secret_absent(secret: str, output: str, *, source: str) -> None:
    if secret in output:
        # Never include either the secret or the captured output in this failure.
        raise AssertionError(f"Sensitive credential appeared in {source}") from None


def _stop_server(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


async def _send_request_while_websocket_is_connected(
    *,
    server: str,
    beta_token: str,
    alpha_config: Path,
    channel_id: str,
) -> tuple[dict, dict]:
    websocket_url = f"{server.replace('http://', 'ws://', 1)}/v1/ws?token={quote(beta_token)}"
    try:
        async with connect(websocket_url, open_timeout=5, proxy=None) as websocket:
            request, _ = await asyncio.to_thread(
                _run_cli,
                server,
                alpha_config,
                "send",
                channel_id,
                "Run the cross-host acceptance checks",
                "--type",
                "request",
                "--reference",
                "https://github.com/example/aichat/commit/demo",
                "--idempotency-key",
                "e2e-request-1",
            )
            raw_event = await asyncio.wait_for(websocket.recv(), timeout=5)
    except Exception:
        # WebSocket exceptions may embed the token-bearing URL. Suppress them so
        # credentials cannot leak into CI or shared acceptance transcripts.
        raise AssertionError("WebSocket push validation failed") from None

    if not isinstance(raw_event, str):
        raise AssertionError("WebSocket delivered a non-text event")
    event = json.loads(raw_event)
    return request, event


def test_real_server_cli_sdk_polling_and_websocket() -> None:
    with tempfile.TemporaryDirectory(prefix="aichat-e2e-") as temporary_directory:
        temporary = Path(temporary_directory)
        port = _unused_port()
        server = f"http://127.0.0.1:{port}"
        alpha_config = temporary / "alpha-config.json"
        beta_config = temporary / "beta-config.json"
        database = temporary / "relay.db"
        server_log = temporary / "uvicorn.log"

        server_environment = os.environ.copy()
        server_environment["AICHAT_DB_PATH"] = str(database)
        with server_log.open("wb") as log_handle:
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "uvicorn",
                    "app.main:app",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(port),
                    "--log-level",
                    "info",
                    "--access-log",
                ],
                cwd=REPOSITORY_ROOT / "server",
                env=server_environment,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
            )

            try:
                _wait_for_health(server, process)

                alpha_registration, alpha_stdout = _run_cli(
                    server,
                    alpha_config,
                    "register",
                    "mac-codex",
                    "--owner",
                    "e2e-lab",
                    "--capability",
                    "git",
                )
                beta_registration, beta_stdout = _run_cli(
                    server,
                    beta_config,
                    "register",
                    "windows-agent",
                    "--owner",
                    "e2e-lab",
                    "--capability",
                    "tests",
                )
                alpha_saved = json.loads(alpha_config.read_text(encoding="utf-8"))
                beta_saved = json.loads(beta_config.read_text(encoding="utf-8"))
                _assert_secret_absent(alpha_saved["token"], alpha_stdout, source="CLI output")
                _assert_secret_absent(beta_saved["token"], beta_stdout, source="CLI output")
                assert alpha_registration["agent_id"] == alpha_saved["agent_id"]
                assert beta_registration["agent_id"] == beta_saved["agent_id"]

                channel, _ = _run_cli(
                    server,
                    alpha_config,
                    "create-channel",
                    "cross-host-demo",
                    "--description",
                    "macOS and Windows coordination",
                )
                joined, _ = _run_cli(server, beta_config, "join", channel["id"])
                assert joined["id"] == channel["id"]

                request, event = asyncio.run(
                    _send_request_while_websocket_is_connected(
                        server=server,
                        beta_token=beta_saved["token"],
                        alpha_config=alpha_config,
                        channel_id=channel["id"],
                    )
                )
                assert event["event"] == "message.created"
                assert event["message"]["id"] == request["id"]
                assert event["message"]["type"] == "request"

                result, _ = _run_cli(
                    server,
                    beta_config,
                    "send",
                    channel["id"],
                    "Cross-host acceptance checks passed",
                    "--type",
                    "result",
                    "--reply-to",
                    request["id"],
                )
                assert result["reply_to"] == request["id"]

                with AIChatClient(server, token=alpha_saved["token"]) as client:
                    first_page = client.list_messages(channel_id=channel["id"], limit=1)
                    assert [item["id"] for item in first_page["items"]] == [request["id"]]
                    assert first_page["next_after"] == request["id"]

                    second_page = client.list_messages(
                        channel_id=channel["id"],
                        after=first_page["next_after"],
                        limit=50,
                    )
                    assert [item["id"] for item in second_page["items"]] == [result["id"]]
                    assert second_page["next_after"] == result["id"]

                assert database.is_file()
            finally:
                _stop_server(process)

        assert process.poll() is not None
        log_output = server_log.read_text(encoding="utf-8")
        _assert_secret_absent(alpha_saved["token"], log_output, source="real uvicorn logs")
        _assert_secret_absent(beta_saved["token"], log_output, source="real uvicorn logs")
        if "token=%5BREDACTED%5D" not in log_output and "token=[REDACTED]" not in log_output:
            raise AssertionError("Real uvicorn logs did not contain a redacted WebSocket token marker")
        print(
            "E2E PASS: real_server=healthy agents=2 channel_joined=true "
            "request_result_reply=linked polling_cursor=advanced websocket_push=received "
            "uvicorn_ws_token=redacted"
        )
