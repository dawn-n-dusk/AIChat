import assert from "node:assert/strict";
import test from "node:test";

import { loadConfig } from "../src/config.js";

const REQUIRED = {
  AICHAT_TOKEN: "secret",
  AICHAT_CHANNEL_ID: "channel-1",
  AICHAT_ALLOWED_SENDER_IDS: "agent-a, agent-b",
};

test("loadConfig applies safe delivery defaults", () => {
  const config = loadConfig(REQUIRED);
  assert.equal(config.server, "http://127.0.0.1:8000");
  assert.deepEqual([...config.allowedSenderIds], ["agent-a", "agent-b"]);
  assert.deepEqual([...config.deliverTypes], ["text", "request"]);
  assert.equal(config.pollIntervalMs, 2_000);
});

test("loadConfig requires an explicit sender allowlist and rejects wildcards", () => {
  assert.throws(
    () => loadConfig({ ...REQUIRED, AICHAT_ALLOWED_SENDER_IDS: "" }),
    /AICHAT_ALLOWED_SENDER_IDS is required/,
  );
  assert.throws(
    () => loadConfig({ ...REQUIRED, AICHAT_ALLOWED_SENDER_IDS: "*" }),
    /cannot contain wildcard/,
  );
});

test("loadConfig validates custom types and polling values", () => {
  const config = loadConfig({
    ...REQUIRED,
    AICHAT_DELIVER_TYPES: "request,result",
    AICHAT_POLL_INTERVAL_MS: "500",
    AICHAT_CURSOR_FILE: "./state.json",
  });
  assert.deepEqual([...config.deliverTypes], ["request", "result"]);
  assert.equal(config.pollIntervalMs, 500);
  assert.match(config.cursorFile, /state\.json$/);

  assert.throws(
    () => loadConfig({ ...REQUIRED, AICHAT_DELIVER_TYPES: "request,command" }),
    /unsupported message type/,
  );
});
