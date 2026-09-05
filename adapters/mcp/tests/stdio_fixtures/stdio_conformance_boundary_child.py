from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import sys
import time


def main() -> None:
    mode = sys.argv[1]
    if mode == "ignore-eof":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print(json.dumps({"jsonrpc": "2.0", "id": 0, "result": {"ready": True}}), flush=True)
    sys.stdin.buffer.readline()
    if mode == "junit-native-exits":
        import pytest

        raise SystemExit(pytest.main([
            str(Path(__file__)), "-q", "--tb=short", "--show-capture=no",
            "-p", "no:cacheprovider", "-o", "junit_logging=no",
            "--junitxml=native-exit-report.xml",
        ]))
    if mode == "exit-on-eof":
        raise SystemExit(19)
    if mode == "early-exit":
        raise SystemExit(17)
    if mode == "stdout-close-then-exit":
        os.close(sys.stdout.fileno())
        os.write(2, b"synthetic-eof-drain\n" * 1024)
        time.sleep(0.25)
        os._exit(17)
    if mode == "stdout-closed-alive":
        os.close(sys.stdout.fileno())
        time.sleep(60)
        os._exit(0)
    if mode == "stdout-noise":
        print("synthetic stdout noise", flush=True)
    if mode in {"stdout-flood", "stderr-flood"}:
        descriptor = 1 if mode == "stdout-flood" else 2
        while True:
            os.write(descriptor, b"synthetic-noise" * 512)
    time.sleep(60)


def report_native_failure(tmp_path, mode):
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from test_stdio_conformance import Phase, StdioChild, response_result, safe_boundary, sandbox_environment

    with safe_boundary(Phase.HARNESS):
        environment = sandbox_environment(tmp_path, "http://127.0.0.1:1", "file")
        with StdioChild(tmp_path, environment, mode) as child:
            response_result(child.receive(Phase.SPAWN), 0, Phase.SPAWN)
            if mode == "early-exit":
                child.send({"run": True}, Phase.HARNESS)
                child.receive(Phase.HARNESS)
            else:
                child.finish()


def test_report_early_native_exit(tmp_path):
    report_native_failure(tmp_path, "early-exit")


def test_report_nonzero_native_exit(tmp_path):
    report_native_failure(tmp_path, "exit-on-eof")


if __name__ == "__main__":
    main()
