import assert from "node:assert/strict";
import test from "node:test";

import { defaultStateFile, loadConfig } from "../src/config.js";

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
  assert.deepEqual([...config.deliverTypes], ["text", "request"]);
  assert.equal(config.driverModule, "file:///tmp/base/driver.js");
  assert.equal(config.driverMode, "module");
  assert.match(config.stateFile, /\.aichat\/codex-connector\/[a-f0-9]{24}\.json$/);
});

test("built-in auto driver removes the normal CODEX_DRIVER_MODULE requirement", () => {
  const env = validEnv({ CODEX_DRIVER: "auto", CODEX_DRIVER_MODULE: "" });
  const config = loadConfig(env);
  assert.equal(config.driverMode, "auto");
  assert.match(config.driverModule, /desktop-owner-ipc-driver\.js$/);

  const appServer = loadConfig(validEnv({ CODEX_DRIVER: "app-server", CODEX_DRIVER_MODULE: "" }));
  assert.match(appServer.driverModule, /app-server-driver\.js$/);
  assert.throws(
    () =>
      loadConfig(
        validEnv({
          CODEX_DRIVER: "app-server",
          CODEX_DRIVER_MODULE: "",
          CODEX_TARGET_HOST_ID: "remote-host",
        }),
      ),
    /local-only/,
  );
  assert.throws(
    () => loadConfig(validEnv({ CODEX_DRIVER: "auto", CODEX_DRIVER_MODULE: "./custom.js" })),
    /only be used/,
  );
});

test("loadConfig rejects wildcard senders and invalid transport settings", () => {
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_ALLOWED_SENDER_IDS: "agent-a,*" })),
    /wildcard/,
  );
  assert.throws(() => loadConfig(validEnv({ AICHAT_SERVER: "file:///tmp/relay" })), /http/);
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_DELIVER_TYPES: "text,unknown" })),
    /unsupported/,
  );
  assert.throws(() => loadConfig(validEnv({ AICHAT_PAGE_LIMIT: "0" })), /between/);
  assert.throws(
    () => loadConfig(validEnv({ AICHAT_WEBSOCKET_ENABLED: "sometimes" })),
    /true or false/,
  );
});

test("default state path is stable per exact channel, thread, and host mapping", () => {
  assert.equal(defaultStateFile("c", "t", null), defaultStateFile("c", "t", null));
  assert.notEqual(defaultStateFile("c", "t", null), defaultStateFile("c", "t", "h"));
  assert.notEqual(defaultStateFile("c", "t", null), defaultStateFile("other", "t", null));
});
