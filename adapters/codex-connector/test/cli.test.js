import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";

const cliPath = fileURLToPath(new URL("../src/cli.js", import.meta.url));
const packagePath = fileURLToPath(new URL("../", import.meta.url));
const canaries = ["CLI_TOKEN_CANARY", "CLI_PRIVATE_PATH_CANARY", "S-1-5-21-999999", "D:(A;;FA;;;SY)"];
const canary = `${canaries.join(" ")} /private/CLI_PRIVATE_PATH_CANARY C:\\CLI_PRIVATE_PATH_CANARY`;
const moduleUrl = (source) => `data:text/javascript,${encodeURIComponent(source)}`;
const diagnosticCodes = new Set([
  "AICHAT_CONNECTOR_FAILED", "AICHAT_CONNECTOR_DIAGNOSTIC", "AICHAT_CONNECTOR_SHUTDOWN_FAILED",
  "AICHAT_CONNECTOR_LOCK_RELEASE_FAILED", "AICHAT_DRIVER_IMPORT_FAILED",
  "AICHAT_DRIVER_CREATE_FAILED", "AICHAT_DRIVER_CONTRACT_INVALID",
  "AICHAT_CONNECTOR_QUEUED_RECOVERY_FAILED",
]);
const diagnosticPhases = new Set([
  "arguments", "configuration", "lock-acquire", "driver-load", "driver-import", "driver-create",
  "driver-contract", "runtime-start", "runtime", "shutdown", "lock-release", "lock", "driver", "connector",
  "queued-recovery",
]);

function runCli(argumentsList, { env = {}, loaderPath } = {}) {
  const bootstrap = loaderPath
    ? ["--import", moduleUrl(`import { register } from "node:module"; register(${JSON.stringify(pathToFileURL(loaderPath).href)});`)]
    : [];
  return spawnSync(process.execPath, [...bootstrap, cliPath, ...argumentsList], {
    cwd: packagePath, env, encoding: "utf8", timeout: 15_000, maxBuffer: 1024 * 1024, windowsHide: true,
  });
}

function diagnostics(result, expectedExit = 1) {
  assert.equal(result.error, undefined);
  assert.equal(result.signal, null);
  assert.equal(result.status, expectedExit);
  assert.equal(result.stdout, "");
  for (const value of canaries) {
    assert.equal(result.stderr.includes(value), false);
    assert.equal(result.stderr.includes(encodeURIComponent(value)), false);
  }
  return result.stderr.trim().split(/\r?\n/u).filter(Boolean).map((line) => {
    const matched = /^\[aichat-codex-connector\] code=([A-Z_]+) phase=([a-z-]+)$/u.exec(line);
    assert.ok(matched, "every stderr line must be a fixed code and phase");
    const [, code, phase] = matched;
    assert.ok(diagnosticCodes.has(code));
    assert.ok(diagnosticPhases.has(phase));
    return { code, phase };
  });
}

test("CLI help needs neither configuration nor runtime dependencies", () => {
  const result = runCli(["--help"]);
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0);
  assert.equal(result.stderr, "");
  assert.match(result.stdout, /^Usage: aichat-codex-connector/u);
});

for (const argumentsList of [[canary], ["--help", canary], [`--token=${canary}\nforged diagnostic`]]) {
  test(`CLI catches unsafe argument variant ${argumentsList.length}-${argumentsList[0].startsWith("--")}`, () => {
    assert.deepEqual(diagnostics(runCli(argumentsList)), [{
      code: "AICHAT_CONNECTOR_FAILED", phase: "arguments",
    }]);
  });
}

test("CLI catches disabled configuration without inherited host environment", () => {
  assert.deepEqual(diagnostics(runCli(["--once"])), [{
    code: "AICHAT_CONNECTOR_FAILED", phase: "configuration",
  }]);
});

test("CLI configuration value failures occur before private path or platform ACL checks", () => {
  const result = runCli(["--once"], { env: {
    AICHAT_CODEX_CONNECTOR_ENABLED: "true", AICHAT_TOKEN: canary,
    AICHAT_CHANNEL_ID: "fixture-channel", AICHAT_ALLOWED_SENDER_IDS: "fixture-sender",
    CODEX_TARGET_THREAD_ID: "fixture-thread", CODEX_DRIVER: "module",
    CODEX_DRIVER_MODULE: "./unused-fixture.mjs", AICHAT_PAGE_LIMIT: canary,
    AICHAT_STATE_FILE: canary,
  } });
  assert.deepEqual(diagnostics(result), [{ code: "AICHAT_CONNECTOR_FAILED", phase: "configuration" }]);
});

async function fixture(testContext, scenario) {
  const directory = await mkdtemp(join(tmpdir(), "aichat-cli-boundary-"));
  testContext.after(() => rm(directory, { recursive: true, force: true }));
  const driverModule = scenario === "missing-module"
    ? pathToFileURL(join(directory, "CLI_PRIVATE_PATH_CANARY-missing.mjs")).href
    : moduleUrl(driverSource(scenario));
  const sourceUrl = (name) => new URL(`../src/${name}.js`, import.meta.url).href;
  const replacements = new Map([
    [sourceUrl("config"), `export function loadConfig() { return {
      token: ${JSON.stringify(canary)}, channelId: "fixture-channel", targetThreadId: "fixture-thread",
      targetHostId: null, driverModule: ${JSON.stringify(driverModule)}, stateFile: ${JSON.stringify(canary)},
      allowedSenderIds: new Set(["fixture-sender"]), deliverTypes: new Set(["request"]),
      pageLimit: 10, maxDeliveriesPerRecovery: 10, maxTurnsPerSenderPerHour: 10,
      autoReplyEnabled: false, lifecycleStatusEnabled: false, websocketEnabled: false,
      periodicRecoveryEnabled: false
    }; }`],
    [sourceUrl("instance-lock"), `export class MappingInstanceLock {
      constructor({ logger }) { this.logger = logger; }
      async acquire() {
        ${scenario === "logger" ? `this.logger.error(${JSON.stringify(canary)});` : ""}
        ${scenario === "lock-acquire" ? `throw new Error(${JSON.stringify(canary)});` : ""}
      }
      async assertOwned() {}
      async release() { ${scenario === "lock-release" ? `throw new Error(${JSON.stringify(canary)});` : ""} }
    }`],
    [sourceUrl("relay-client"), `export class RelayClient {
      async whoAmI() { return { agent_id: ${JSON.stringify(canary)} }; }
      async listMessages() { return { items: [], next_after: null }; }
      async sendMessage() { throw new Error("fixture must not send"); }
    }`],
    [sourceUrl("state-store"), `export class StateStore {
      async load() { return {
        cursor: null, seenIds: [], outboundSeenIds: [], receipts: [], pendingOutbound: null,
        pendingStatuses: [], blockedOutbound: [], turnBudget: []
      }; }
      async save() {}
    }`],
    ["ws", `export default class WebSocket { constructor() { throw new Error("fixture must not connect"); } }`],
  ]);
  if (scenario === "runtime-import") {
    replacements.set(sourceUrl("runtime"), `throw new Error(${JSON.stringify(canary)});`);
  }
  if (scenario === "logger") {
    replacements.set(sourceUrl("runtime"), `export class ConnectorRuntime {
      constructor({ connector, logger }) { this.connector = connector; logger.error(${JSON.stringify(canary)}); }
      async start() { await this.connector.initialize(); await this.connector.requestRecovery(); }
      async stop(options) { await this.connector.stop(options); }
    }`);
  }
  if (scenario === "queued-recovery") {
    addQueuedRecoveryFixture(replacements, sourceUrl, directory);
  }
  const loaderPath = join(directory, "fixture-loader.mjs");
  await writeFile(loaderPath, `
    const replacements = new Map(${JSON.stringify([...replacements])});
    export async function resolve(specifier, context, nextResolve) {
      const resolved = specifier.startsWith(".") ? new URL(specifier, context.parentURL).href : specifier;
      if (replacements.has(resolved)) {
        return { url: "data:text/javascript," + encodeURIComponent(replacements.get(resolved)), shortCircuit: true };
      }
      return nextResolve(specifier, context);
    }
  `);
  return {
    loaderPath,
    reportPath: join(directory, "recovery-report.json"),
    env: { HOME: directory, USERPROFILE: directory, TMPDIR: directory, TMP: directory, TEMP: directory },
  };
}

function addQueuedRecoveryFixture(replacements, sourceUrl, directory) {
  const controlModule = moduleUrl(`
    import { writeFileSync } from "node:fs";
    export const probe = { reads: 0, wakes: 0, cursors: [], deliveries: [], cleared: 0, stops: 0, acks: 0 };
    export function installTimers() {
      globalThis.setInterval = (callback, delay) => {
        probe.delay = delay;
        probe.wake = () => { probe.wakes += 1; callback(); };
        setImmediate(() => { probe.wake(); probe.wake(); });
        return "fixture-interval";
      };
      globalThis.clearInterval = (handle) => {
        if (handle !== "fixture-interval") throw new Error("unexpected fixture interval");
        probe.cleared += 1;
      };
    }
    export function report() {
      writeFileSync(${JSON.stringify(join(directory, "recovery-report.json"))}, JSON.stringify({
        reads: probe.reads, wakes: probe.wakes, cursors: probe.cursors, deliveries: probe.deliveries,
        delay: probe.delay, cleared: probe.cleared, stops: probe.stops, acks: probe.acks,
        cursor: probe.state.cursor, seenIds: [...probe.state.seenIds],
        receiptCount: probe.state.receipts.size, turnBudgetCount: probe.state.turnBudget.length,
        pendingOutbound: probe.state.pendingOutbound, pendingStatusCount: probe.state.pendingStatuses.length
      }));
    }
  `);
  const controlImport = `import { probe, installTimers, report } from ${JSON.stringify(controlModule)};`;
  const driverModule = moduleUrl(`${controlImport}
    export function createCodexDriver() { return {
      async start() {},
      async deliver(request) {
        probe.deliveries.push(request.deliveryId);
        return {
          accepted: true, deliveryId: request.deliveryId, threadId: request.threadId,
          hostId: request.hostId, turnId: "fixture-turn"
        };
      },
      async acknowledgeDelivery() {
        if (probe.state.cursor !== "fixture-message") throw new Error("fixture acknowledgement before checkpoint");
        probe.acks += 1;
      },
      async stop() { probe.stops += 1; }
    }; }
  `);
  replacements.set(sourceUrl("config"), `${controlImport}
    export function loadConfig() { installTimers(); return {
      token: ${JSON.stringify(canary)}, channelId: "fixture-channel", targetThreadId: "fixture-thread",
      targetHostId: null, driverModule: ${JSON.stringify(driverModule)}, stateFile: ${JSON.stringify(canary)},
      allowedSenderIds: new Set(["fixture-sender"]), deliverTypes: new Set(["request"]),
      pageLimit: 10, maxDeliveriesPerRecovery: 10, maxTurnsPerSenderPerHour: 10,
      autoReplyEnabled: false, lifecycleStatusEnabled: false, websocketEnabled: false,
      periodicRecoveryEnabled: true, recoveryIntervalMs: 1234
    }; }
  `);
  replacements.set(sourceUrl("instance-lock"), `${controlImport}
    export class MappingInstanceLock {
      constructor({ onLost }) { probe.stop = onLost; }
      async acquire() {}
      async assertOwned() {}
      async release() { report(); }
    }
  `);
  replacements.set(sourceUrl("relay-client"), `${controlImport}
    export class RelayClient {
      async whoAmI() { return { agent_id: "fixture-self" }; }
      async listMessages({ after }) {
        probe.reads += 1;
        probe.cursors.push(after);
        if (probe.reads === 2) return { items: [], next_after: after };
        if (probe.reads === 3) {
          setImmediate(() => probe.wake());
          throw new Error(${JSON.stringify(canary)});
        }
        if (probe.reads === 4) setImmediate(() => probe.stop());
        if (probe.reads > 4) throw new Error("unexpected extra fixture recovery");
        return { items: [{
          id: "fixture-message", channel_id: "fixture-channel", sender_id: "fixture-sender",
          type: "request", text: "Fixture request", reply_to: null, references: [], hop_count: 0
        }], next_after: "fixture-message" };
      }
      async sendMessage() { throw new Error("fixture must not send"); }
    }
  `);
  replacements.set(sourceUrl("state-store"), `${controlImport}
    export class StateStore {
      async load() { return {
        cursor: null, seenIds: [], outboundSeenIds: [], receipts: [], pendingOutbound: null,
        pendingStatuses: [], blockedOutbound: [], turnBudget: []
      }; }
      async save(value) { probe.state = structuredClone(value); }
    }
  `);
}

function driverSource(scenario) {
  if (scenario === "module-evaluation") return `throw new Error(${JSON.stringify(canary)});`;
  if (scenario === "missing-factory") return "export const other = true;";
  if (scenario === "factory") {
    return `export function createCodexDriver() { throw new Error(${JSON.stringify(canary)}); }`;
  }
  if (scenario === "contract") {
    return `export function createCodexDriver() { return { get start() { throw new Error(${JSON.stringify(canary)}); } }; }`;
  }
  return `export function createCodexDriver({ logger }) {
    ${scenario === "logger" ? `
      const unsafe = { toString() { throw new Error("logger must not coerce values"); } };
      for (const method of ["error", "warn", "info", "log", "debug", "trace"]) {
        logger[method](new Error(${JSON.stringify(canary)}), unsafe, { phase: ${JSON.stringify(canary)} });
      }
    ` : ""}
    return {
      async start() { ${scenario === "runtime-start" ? `throw {
        code: "AICHAT_DRIVER_IMPORT_FAILED", phase: "driver-import", message: ${JSON.stringify(canary)}
      };` : ""} },
      async deliver() { throw new Error("fixture must not deliver"); },
      async stop() { ${scenario === "shutdown" ? `throw new Error(${JSON.stringify(canary)});` : ""} }
    };
  }`;
}

for (const [scenario, code, phase] of [
  ["lock-acquire", "AICHAT_CONNECTOR_FAILED", "lock-acquire"],
  ["missing-module", "AICHAT_DRIVER_IMPORT_FAILED", "driver-import"],
  ["module-evaluation", "AICHAT_DRIVER_IMPORT_FAILED", "driver-import"],
  ["missing-factory", "AICHAT_DRIVER_CONTRACT_INVALID", "driver-contract"],
  ["factory", "AICHAT_DRIVER_CREATE_FAILED", "driver-create"],
  ["contract", "AICHAT_DRIVER_CONTRACT_INVALID", "driver-contract"],
  ["runtime-import", "AICHAT_CONNECTOR_FAILED", "runtime-start"],
  ["runtime-start", "AICHAT_CONNECTOR_FAILED", "runtime-start"],
  ["shutdown", "AICHAT_CONNECTOR_SHUTDOWN_FAILED", "shutdown"],
  ["lock-release", "AICHAT_CONNECTOR_LOCK_RELEASE_FAILED", "lock-release"],
]) {
  test(`CLI projects ${scenario} failure without raw exception, token, path, SID, or ACL`, async (testContext) => {
    const options = await fixture(testContext, scenario);
    const projected = diagnostics(runCli(["--once"], options));
    assert.deepEqual(projected.filter((entry) => entry.code !== "AICHAT_CONNECTOR_DIAGNOSTIC"), [{ code, phase }]);
  });
}

test("CLI projects all component logger arguments without inspecting or echoing them", async (testContext) => {
  const options = await fixture(testContext, "logger");
  const projected = diagnostics(runCli(["--once"], options), 0);
  assert.equal(projected.length, 9);
  assert.ok(projected.every((entry) => entry.code === "AICHAT_CONNECTOR_DIAGNOSTIC"));
  assert.deepEqual(new Set(projected.map((entry) => entry.phase)), new Set(["lock", "driver", "runtime", "connector"]));
});

test("actual CLI owns a queued recovery rejection after overlapping periodic wakes", async (testContext) => {
  const options = await fixture(testContext, "queued-recovery");
  const result = runCli([], options);
  assert.equal(result.stderr.includes(canaries[0]), false, "queued recovery must not leak the canary");
  const projected = diagnostics(result, 0);
  assert.deepEqual(projected.filter((entry) => entry.code !== "AICHAT_CONNECTOR_DIAGNOSTIC"), [{
    code: "AICHAT_CONNECTOR_QUEUED_RECOVERY_FAILED", phase: "queued-recovery",
  }]);
  const report = JSON.parse(await readFile(options.reportPath, "utf8"));
  assert.equal(report.deliveries.length, 1);
  assert.match(report.deliveries[0], /^codex-delivery-[a-f0-9]{64}$/u);
  assert.deepEqual(report, {
    reads: 4, wakes: 3, cursors: [null, "fixture-message", "fixture-message", "fixture-message"],
    deliveries: report.deliveries, delay: 1234, cleared: 1, stops: 1, acks: 4,
    cursor: "fixture-message", seenIds: ["fixture-message"], receiptCount: 1, turnBudgetCount: 1,
    pendingOutbound: null, pendingStatusCount: 0,
  });
});
