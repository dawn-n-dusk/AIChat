import assert from "node:assert/strict";
import test from "node:test";

import { loadConfig } from "../src/config.js";

const REQUIRED = {
  AICHAT_GROK_BRIDGE_ENABLED: "true",
  AICHAT_TOKEN: "secret",
  AICHAT_CHANNEL_ID: "channel-1",
  AICHAT_ALLOWED_SENDER_IDS: "agent-a, agent-b",
};

test("bridge is disabled unless the explicit enable switch is true", () => {
  assert.throws(() => loadConfig({ ...REQUIRED, AICHAT_GROK_BRIDGE_ENABLED: "false" }), /disabled/);
  assert.throws(() => loadConfig({ ...REQUIRED, AICHAT_GROK_BRIDGE_ENABLED: "1" }), /disabled/);
});

test("loadConfig applies cross-platform safe defaults", () => {
  const config = loadConfig(REQUIRED, { cwd: "/tmp/example" });
  assert.equal(config.server, "http://127.0.0.1:8000");
  assert.deepEqual([...config.allowedSenderIds], ["agent-a", "agent-b"]);
  assert.equal(config.grokCommand, "grok");
  assert.deepEqual(config.grokBaseArgs, []);
  assert.equal(config.pollIntervalMs, 2_000);
  assert.equal(config.maxPromptChars, 24_000);
});

test("loadConfig requires an explicit sender allowlist and parses base args as JSON", () => {
  assert.throws(
    () => loadConfig({ ...REQUIRED, AICHAT_ALLOWED_SENDER_IDS: "*" }),
    /cannot contain wildcard/,
  );
  const config = loadConfig({
    ...REQUIRED,
    GROK_COMMAND: "/opt/Grok Build/grok",
    GROK_BASE_ARGS_JSON: '["--model","grok-4"]',
  });
  assert.equal(config.grokCommand, "/opt/Grok Build/grok");
  assert.deepEqual(config.grokBaseArgs, ["--model", "grok-4"]);
  assert.throws(
    () => loadConfig({ ...REQUIRED, GROK_BASE_ARGS_JSON: "--model grok-4" }),
    /JSON array of strings/,
  );
});
