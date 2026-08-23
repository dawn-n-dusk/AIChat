#!/usr/bin/env node

import { AIChatCodexConnector } from "./connector.js";
import { loadConfig } from "./config.js";
import { loadCodexDriver } from "./driver.js";
import { RelayClient } from "./relay-client.js";
import { ConnectorRuntime } from "./runtime.js";
import { StateStore } from "./state-store.js";

async function main(argv) {
  const options = parseArguments(argv);
  if (options.help) {
    process.stdout.write(usage());
    return;
  }

  let config;
  let runtime;
  try {
    config = loadConfig();
    const binding = Object.freeze({
      channelId: config.channelId,
      threadId: config.targetThreadId,
      hostId: config.targetHostId,
    });
    const driver = await loadCodexDriver(config.driverModule, { binding, logger: console });
    const relay = new RelayClient(config);
    const stateStore = new StateStore(config.stateFile);
    const connector = new AIChatCodexConnector({
      config,
      relay,
      stateStore,
      driver,
      logger: console,
    });
    runtime = new ConnectorRuntime({ config, relay, connector, logger: console });

    if (options.once) {
      await runtime.start({ websocketEnabled: false, periodicRecovery: false });
      return;
    }

    const stopSignal = waitForStopSignal();
    await runtime.start();
    await stopSignal;
  } catch (error) {
    const detail = redact(errorMessage(error), config?.token);
    process.stderr.write(`[aichat-codex-connector] fatal: ${detail}\n`);
    process.exitCode = 1;
  } finally {
    if (runtime) {
      try {
        await runtime.stop();
      } catch {
        process.stderr.write("[aichat-codex-connector] shutdown failed\n");
        process.exitCode = 1;
      }
    }
  }
}

function parseArguments(argv) {
  const options = { once: false, help: false };
  for (const argument of argv) {
    if (argument === "--once") options.once = true;
    else if (argument === "--help" || argument === "-h") options.help = true;
    else throw new Error(`Unknown argument: ${argument}`);
  }
  return options;
}

function usage() {
  return [
    "Usage: aichat-codex-connector [--once]",
    "",
    "  --once  Recover all currently available relay messages, then exit.",
    "  --help  Show this help.",
    "",
  ].join("\n");
}

function waitForStopSignal() {
  return new Promise((resolve) => {
    process.once("SIGINT", resolve);
    process.once("SIGTERM", resolve);
  });
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function redact(value, secret) {
  return secret ? value.split(secret).join("[REDACTED]") : value;
}

await main(process.argv.slice(2));
