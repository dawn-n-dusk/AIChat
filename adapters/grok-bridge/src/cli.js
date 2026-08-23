#!/usr/bin/env node

import { AIChatGrokBridge } from "./bridge.js";
import { loadConfig } from "./config.js";
import { GrokRunner } from "./grok-runner.js";
import { RelayClient } from "./relay-client.js";
import { StateStore } from "./state-store.js";

async function main() {
  const config = loadConfig();
  const relay = new RelayClient(config);
  const stateStore = new StateStore(config.stateFile);
  const runner = new GrokRunner({
    command: config.grokCommand,
    baseArgs: config.grokBaseArgs,
    cwd: config.grokWorkingDirectory,
    timeoutMs: config.grokTimeoutMs,
    maxOutputBytes: config.maxOutputBytes,
  });
  const bridge = new AIChatGrokBridge({ config, relay, stateStore, runner });
  const shutdown = () => bridge.stop();
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  await bridge.initialize();
  if (process.argv.includes("--once")) {
    await bridge.pollOnce();
  } else {
    await bridge.run();
  }
}

main().catch((error) => {
  console.error(`[aichat-grok-bridge] fatal: ${error instanceof Error ? error.message : error}`);
  process.exitCode = 1;
});
