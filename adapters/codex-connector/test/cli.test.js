import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
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
]);
const diagnosticPhases = new Set([
  "arguments", "configuration", "lock-acquire", "driver-load", "driver-import", "driver-create",
  "driver-contract", "runtime-start", "runtime", "shutdown", "lock-release", "lock", "driver", "connector",
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
    env: { HOME: directory, USERPROFILE: directory, TMPDIR: directory, TMP: directory, TEMP: directory },
  };
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
