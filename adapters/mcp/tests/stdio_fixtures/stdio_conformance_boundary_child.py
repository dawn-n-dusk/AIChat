from __future__ import annotations

import json
import os
import signal
import sys
import time


def main() -> None:
    mode = sys.argv[1]
    if mode == "ignore-eof":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print(json.dumps({"jsonrpc": "2.0", "id": 0, "result": {"ready": True}}), flush=True)
    sys.stdin.buffer.readline()
    if mode == "exit-on-eof":
        raise SystemExit(19)
    if mode == "early-exit":
        raise SystemExit(17)
    if mode == "stdout-noise":
        print("synthetic stdout noise", flush=True)
    if mode in {"stdout-flood", "stderr-flood"}:
        descriptor = 1 if mode == "stdout-flood" else 2
        while True:
            os.write(descriptor, b"synthetic-noise" * 512)
    time.sleep(60)


if __name__ == "__main__":
    main()
