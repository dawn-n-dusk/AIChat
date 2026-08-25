import assert from "node:assert/strict";
import { access, chmod, link, mkdir, mkdtemp, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  defaultInstanceLockPort,
  defaultStateFile,
  defaultStateLockPort,
  loadConfig,
} from "../src/config.js";

function validEnv(overrides = {}) {
  return {
    AICHAT_CODEX_CONNECTOR_ENABLED: "true",
    AICHAT_TOKEN: "relay-secret",
    AICHAT_CHANNEL_ID: "channel-1",
    AICHAT_ALLOWED_SENDER_IDS: "agent-a,agent-b",
    CODEX_TARGET_THREAD_ID: "thread-1",
    CODEX_DRIVER: "module",
    CODEX_DRIVER_MODULE: "./driver.js",
    ...overrides,
  };
}

test("loadConfig requires an explicit enable gate and complete fixed mapping", () => {
  assert.throws(() => loadConfig(validEnv({ AICHAT_CODEX_CONNECTOR_ENABLED: "false" })), /disabled/);
  assert.throws(() => loadConfig(validEnv({ CODEX_TARGET_THREAD_ID: "" })), /required/);
  assert.throws(() => loadConfig(validEnv({ AICHAT_ALLOWED_SENDER_IDS: "" })), /required/);

  const config = loadConfig(validEnv({ CODEX_TARGET_HOST_ID: "host-1" }), { cwd: "/tmp/base" });
  assert.equal(config.channelId, "channel-1");
  assert.equal(config.targetThreadId, "thread-1");
  assert.equal(config.targetHostId, "host-1");
  assert.deepEqual([...config.allowedSenderIds], ["agent-a", "agent-b"]);
  assert.deepEqual([...config.deliverTypes], ["request"]);
  assert.equal(config.driverModule, "file:///tmp/base/driver.js");
  assert.equal(config.driverMode, "module");
  assert.match(config.stateFile, /\.aichat\/codex-connector\/[a-f0-9]{24}\.json$/);
  assert.equal(config.instanceStateLockPort, defaultStateLockPort(config.stateFile));
  assert.match(config.instanceLockIdentity, /^[a-f0-9]{64}$/);
});

test("built-in drivers require a dedicated low-privilege connector task", () => {
  const safeBuiltIn = {
    CODEX_DRIVER_MODULE: "",
    CODEX_CONNECTOR_TASK_OWNED: "true",
    CODEX_CONNECTOR_TASK_MARKER: "AICHAT_CONNECTOR_TASK_MARKER_1",
    CODEX_APP_SERVER_CWD: "/tmp",
    CODEX_APP_SERVER_APPROVAL_POLICY: "never",
    CODEX_APP_SERVER_SANDBOX_POLICY_JSON: JSON.stringify({
      type: "readOnly",
      networkAccess: false,
    }),
  };
  const env = validEnv({ CODEX_DRIVER: "auto", ...safeBuiltIn });
  const config = loadConfig(env);
  assert.equal(config.driverMode, "auto");
  assert.match(config.driverModule, /desktop-owner-ipc-driver\.js$/);

  const appServer = loadConfig(validEnv({ CODEX_DRIVER: "app-server", ...safeBuiltIn }));
  assert.match(appServer.driverModule, /app-server-driver\.js$/);
  assert.throws(
    () =>
      loadConfig(
        validEnv({
          CODEX_DRIVER: "app-server",
          ...safeBuiltIn,
          CODEX_TARGET_HOST_ID: "remote-host",
        }),
      ),
    /local-only/,
  );
  assert.throws(
    () => loadConfig(validEnv({ CODEX_DRIVER: "auto", ...safeBuiltIn, CODEX_DRIVER_MODULE: "./custom.js" })),
    /only be used/,
  );
  assert.throws(
    () => loadConfig(validEnv({ CODEX_DRIVER: "app-server", CODEX_DRIVER_MODULE: "" })),
    /TASK_OWNED/,
  );
});

test("loadConfig rejects wildcard senders and invalid transport settings", () => {
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_ALLOWED_SENDER_IDS: "agent-a,*" })),
    /wildcard/,
  );
  assert.throws(() => loadConfig(validEnv({ AICHAT_SERVER: "file:///tmp/relay" })), /http/);
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_SERVER: "http://relay.example.org/aichat" })),
    /must use https/,
  );
  assert.equal(
    loadConfig(validEnv({ AICHAT_SERVER: "https://relay.example.org/aichat/" })).server,
    "https://relay.example.org/aichat",
  );
  for (const server of [
    "http://localhost:8000",
    "http://agent.localhost:8000",
    "http://127.0.0.2:8000",
    "http://[::1]:8000",
  ]) {
    assert.equal(loadConfig(validEnv({ AICHAT_SERVER: server })).server, server);
  }
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_DELIVER_TYPES: "text,unknown" })),
    /unsupported/,
  );
  assert.throws(() => loadConfig(validEnv({ AICHAT_PAGE_LIMIT: "0" })), /between/);
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_WEBSOCKET_ENABLED: "sometimes" })),
    /true or false/,
  );
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_DELIVER_TYPES: "text,request" })),
    /AUTONOMOUS_TEXT_ENABLED/,
  );
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_INSTANCE_LOCK_PORT: "43000" })),
    /cannot override/,
  );
  assert.throws(
    () =>
      loadConfig(
        validEnv({ AICHAT_INSTANCE_LOCK_METADATA_PATH: "/tmp/custom-lock-owner.json" }),
      ),
    /cannot be overridden/,
  );
  assert.equal(
    loadConfig(
      validEnv({
        AICHAT_INSTANCE_LOCK_PORT: String(
          defaultInstanceLockPort("channel-1", "thread-1", null),
        ),
      }),
    ).instanceLockPort,
    defaultInstanceLockPort("channel-1", "thread-1", null),
  );
});

test("default state path is stable per exact channel, thread, and host mapping", () => {
  assert.equal(defaultStateFile("c", "t", null), defaultStateFile("c", "t", null));
  assert.notEqual(defaultStateFile("c", "t", null), defaultStateFile("c", "t", "h"));
  assert.notEqual(defaultStateFile("c", "t", null), defaultStateFile("other", "t", null));
});

test("state identity canonicalizes a symlinked parent and rejects unsafe state aliases", async (t) => {
  if (process.platform === "win32") return t.skip("directory symlink setup is platform-specific");
  const directory = await mkdtemp(join(tmpdir(), "aichat-state-alias-"));
  const privateDirectory = join(directory, "private");
  const aliasDirectory = join(directory, "alias");
  await mkdir(privateDirectory, { mode: 0o700 });
  await symlink(privateDirectory, aliasDirectory, "dir");
  const realState = join(privateDirectory, "state.json");
  const aliasState = join(aliasDirectory, "state.json");
  const realConfig = loadConfig(validEnv({ AICHAT_STATE_FILE: realState }));
  const aliasConfig = loadConfig(
    validEnv({ AICHAT_CHANNEL_ID: "channel-2", AICHAT_STATE_FILE: aliasState }),
  );
  assert.equal(realConfig.stateFile, aliasConfig.stateFile);
  assert.equal(realConfig.instanceStateLockPort, aliasConfig.instanceStateLockPort);
  assert.notEqual(realConfig.instanceLockPort, aliasConfig.instanceLockPort);

  const target = join(privateDirectory, "target.json");
  const stateSymlink = join(privateDirectory, "state-link.json");
  await writeFile(target, "{}", { mode: 0o600 });
  await symlink(target, stateSymlink);
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_STATE_FILE: stateSymlink })),
    /must not be a symlink/,
  );
});

test("state configuration fails closed without changing an existing shared parent mode", async (t) => {
  if (process.platform === "win32") return t.skip("POSIX mode check is not available");
  const directory = await mkdtemp(join(tmpdir(), "aichat-state-shared-parent-"));
  const shared = join(directory, "workspace");
  await mkdir(shared, { mode: 0o755 });
  await chmod(shared, 0o755);
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_STATE_FILE: join(shared, "state.json") })),
    /permissions must be 0700/,
  );
  assert.equal((await stat(shared)).mode & 0o777, 0o755);
});

test("fresh state names follow the private directory case semantics", async (t) => {
  if (process.platform === "win32") return t.skip("POSIX private-directory setup is not available");
  const directory = await mkdtemp(join(tmpdir(), "aichat-state-case-"));
  const privateDirectory = join(directory, "private");
  await mkdir(privateDirectory, { mode: 0o700 });
  const probe = join(privateDirectory, "CaseProbeAa");
  await writeFile(probe, "x", { mode: 0o600 });
  let caseInsensitive = true;
  try {
    await access(join(privateDirectory, "caseprobeaa"));
  } catch {
    caseInsensitive = false;
  }
  const lower = loadConfig(
    validEnv({ AICHAT_STATE_FILE: join(privateDirectory, "state.json") }),
  );
  const upper = loadConfig(
    validEnv({ AICHAT_CHANNEL_ID: "channel-upper", AICHAT_STATE_FILE: join(privateDirectory, "STATE.JSON") }),
  );
  if (caseInsensitive) {
    assert.equal(lower.stateFile, upper.stateFile);
    assert.equal(lower.instanceStateLockPort, upper.instanceStateLockPort);
  } else {
    assert.notEqual(lower.stateFile, upper.stateFile);
  }
});

test("state basenames reject Unicode filesystem-fold aliases", async (t) => {
  if (process.platform === "win32") return t.skip("POSIX private-directory setup is not available");
  const directory = await mkdtemp(join(tmpdir(), "aichat-state-unicode-fold-"));
  const privateDirectory = join(directory, "private");
  await mkdir(privateDirectory, { mode: 0o700 });
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_STATE_FILE: join(privateDirectory, "Straße.json") })),
    /basename must use only ASCII/,
  );
  const ascii = loadConfig(
    validEnv({ AICHAT_STATE_FILE: join(privateDirectory, "STRASSE.json") }),
  );
  assert.match(ascii.stateFile, /STRASSE\.json$|strasse\.json$/);
});

test("state and fixed lock metadata reject hardlink aliases", async (t) => {
  if (process.platform === "win32") return t.skip("hardlink ownership semantics are platform-specific");
  const directory = await mkdtemp(join(tmpdir(), "aichat-state-hardlink-"));
  const privateDirectory = join(directory, "private");
  await mkdir(privateDirectory, { mode: 0o700 });
  const statePath = join(privateDirectory, "state.json");
  await writeFile(statePath, "{}", { mode: 0o600 });
  await link(statePath, `${statePath}.instance-lock.json`);
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_STATE_FILE: statePath })),
    /hardlink aliases/,
  );
});
