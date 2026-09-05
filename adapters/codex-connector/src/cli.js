#!/usr/bin/env node

import { AIChatCodexConnector } from "./connector.js";
import { loadConfig } from "./config.js";
import { driverFailureDiagnostic, loadCodexDriver } from "./driver.js";
import { RelayClient } from "./relay-client.js";
import { StateStore } from "./state-store.js";
import { MappingInstanceLock } from "./instance-lock.js";

const DIAGNOSTIC_CODES = new Set([
  "AICHAT_CONNECTOR_FAILED",
  "AICHAT_CONNECTOR_DIAGNOSTIC",
  "AICHAT_CONNECTOR_SHUTDOWN_FAILED",
  "AICHAT_CONNECTOR_LOCK_RELEASE_FAILED",
  "AICHAT_DRIVER_IMPORT_FAILED",
  "AICHAT_DRIVER_CREATE_FAILED",
  "AICHAT_DRIVER_CONTRACT_INVALID",
]);
const DIAGNOSTIC_PHASES = new Set([
  "arguments",
  "configuration",
  "lock-acquire",
  "driver-load",
  "driver-import",
  "driver-create",
  "driver-contract",
  "runtime-start",
  "runtime",
  "shutdown",
  "lock-release",
  "lock",
  "driver",
  "connector",
]);

async function main(argv) {
  let phase = "arguments";
  let runtime;
  let instanceLock;
  let drainOnStop = false;
  try {
    const options = parseArguments(argv);
    if (options.help) {
      process.stdout.write(usage());
      return;
    }
    phase = "configuration";
    const config = loadConfig();
    phase = "lock-acquire";
    const lockLost = deferred();
    instanceLock = new MappingInstanceLock({
      port: config.instanceLockPort,
      statePort: config.instanceStateLockPort,
      metadataPath: config.instanceLockMetadataPath,
      bindingId: config.instanceLockIdentity,
      statePath: config.stateFile,
      logger: diagnosticLogger("lock"),
      onLost: () => lockLost.resolve(),
    });
    await instanceLock.acquire();
    const binding = Object.freeze({
      channelId: config.channelId,
      threadId: config.targetThreadId,
      hostId: config.targetHostId,
    });
    phase = "driver-load";
    const driver = await loadCodexDriver(config.driverModule, {
      binding,
      logger: diagnosticLogger("driver"),
    });
    phase = "runtime-start";
    const { ConnectorRuntime } = await import("./runtime.js");
    const relay = new RelayClient(config);
    const stateStore = new StateStore(config.stateFile);
    const connector = new AIChatCodexConnector({
      config,
      relay,
      stateStore,
      driver,
      instanceLock,
      logger: diagnosticLogger("connector"),
    });
    runtime = new ConnectorRuntime({
      config,
      relay,
      connector,
      logger: diagnosticLogger("runtime"),
    });

    if (options.once) {
      drainOnStop = true;
      await runtime.start({ websocketEnabled: false, periodicRecovery: false });
      return;
    }

    const stopSignal = waitForStopSignal();
    await runtime.start();
    phase = "runtime";
    const stopReason = await Promise.race([
      stopSignal.then(() => "signal"),
      lockLost.promise.then(() => "lock-lost"),
    ]);
    drainOnStop = stopReason === "signal";
  } catch (error) {
    const diagnostic = driverFailureDiagnostic(error);
    writeDiagnostic(diagnostic?.code ?? "AICHAT_CONNECTOR_FAILED", diagnostic?.phase ?? phase);
    process.exitCode = 1;
  } finally {
    if (runtime) {
      try {
        await runtime.stop({ drain: drainOnStop });
      } catch {
        writeDiagnostic("AICHAT_CONNECTOR_SHUTDOWN_FAILED", "shutdown");
        process.exitCode = 1;
      }
    }
    if (instanceLock) {
      try {
        await instanceLock.release();
      } catch {
        writeDiagnostic("AICHAT_CONNECTOR_LOCK_RELEASE_FAILED", "lock-release");
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
    else throw new Error("AICHAT_CONNECTOR_ARGUMENT_INVALID");
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

function writeDiagnostic(code, phase) {
  const safeCode = DIAGNOSTIC_CODES.has(code) ? code : "AICHAT_CONNECTOR_FAILED";
  const safePhase = DIAGNOSTIC_PHASES.has(phase) ? phase : "runtime";
  process.stderr.write(`[aichat-codex-connector] code=${safeCode} phase=${safePhase}\n`);
}

function diagnosticLogger(phase) {
  return Object.freeze(
    Object.fromEntries(
      ["error", "warn", "info", "log", "debug", "trace"].map((method) => [
        method,
        () => writeDiagnostic("AICHAT_CONNECTOR_DIAGNOSTIC", phase),
      ]),
    ),
  );
}

function deferred() {
  let resolve;
  const promise = new Promise((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

await main(process.argv.slice(2));
