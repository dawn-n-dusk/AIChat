import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";

import {
  GrokRunner,
  buildGrokEnvironment,
  buildGrokArgs,
  findOutputText,
  findSessionId,
  parseGrokJson,
} from "../src/grok-runner.js";

test("buildGrokEnvironment keeps Grok runtime settings but strips AIChat secrets", () => {
  assert.deepEqual(
    buildGrokEnvironment({
      PATH: "/bin",
      XAI_API_KEY: "needed-by-grok",
      AICHAT_TOKEN: "must-not-reach-grok",
      AICHAT_CHANNEL_ID: "private-channel",
      IGNORED_UNDEFINED: undefined,
    }),
    { PATH: "/bin", XAI_API_KEY: "needed-by-grok" },
  );
});

test("buildGrokArgs creates and resumes headless JSON sessions", () => {
  assert.deepEqual(buildGrokArgs({ prompt: "hello" }), [
    "--no-auto-update",
    "-p",
    "hello",
    "--output-format",
    "json",
  ]);
  assert.deepEqual(buildGrokArgs({ baseArgs: ["--model", "grok-4"], prompt: "again", sessionId: "s1" }), [
    "--model",
    "grok-4",
    "--no-auto-update",
    "-r",
    "s1",
    "-p",
    "again",
    "--output-format",
    "json",
  ]);
});

test("parseGrokJson accepts the final JSON object and extracts common fields", () => {
  const parsed = parseGrokJson('launcher note\n{"result":"Done","sessionId":"session-1"}\n');
  assert.equal(findOutputText(parsed), "Done");
  assert.equal(findSessionId(parsed), "session-1");

  const nested = parseGrokJson('{"data":{"response":"Nested","session_id":"session-2"}}');
  assert.equal(findOutputText(nested), "Nested");
  assert.equal(findSessionId(nested), "session-2");

  const pretty = parseGrokJson('launcher note\n{\n  "result": "Pretty",\n  "sessionId": "session-3"\n}');
  assert.equal(findOutputText(pretty), "Pretty");
  assert.equal(findSessionId(pretty), "session-3");
});

test("parseGrokJson rejects empty and non-JSON output", () => {
  assert.throws(() => parseGrokJson(""), /empty stdout/);
  assert.throws(() => parseGrokJson("not json"), /not valid JSON/);
});

test("GrokRunner uses an injected mock process and parses a new session", async () => {
  const calls = [];
  const runner = new GrokRunner({
    command: "mock-grok",
    baseArgs: [],
    cwd: "/mock/project",
    timeoutMs: 1_000,
    maxOutputBytes: 10_000,
    spawnImpl(command, args, options) {
      calls.push({ command, args, options });
      const child = new EventEmitter();
      child.stdout = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      queueMicrotask(() => {
        child.stdout.emit("data", '{"result":"Mock answer","sessionId":"mock-session"}');
        child.emit("close", 0, null);
      });
      return child;
    },
  });

  const result = await runner.run({ prompt: "Mock prompt", sessionId: null });
  assert.deepEqual(result, { output: "Mock answer", sessionId: "mock-session", stderr: "" });
  assert.equal(calls[0].command, "mock-grok");
  assert.equal(calls[0].options.shell, false);
  assert.equal(Object.keys(calls[0].options.env).some((name) => name.startsWith("AICHAT_")), false);
  assert.deepEqual(calls[0].args, [
    "--no-auto-update",
    "-p",
    "Mock prompt",
    "--output-format",
    "json",
  ]);
});

test("GrokRunner does not include stderr content in a failed-command error", async () => {
  const runner = new GrokRunner({
    command: "mock-grok",
    cwd: "/mock/project",
    timeoutMs: 1_000,
    maxOutputBytes: 10_000,
    spawnImpl() {
      const child = new EventEmitter();
      child.stdout = new EventEmitter();
      child.stderr = new EventEmitter();
      child.kill = () => {};
      queueMicrotask(() => {
        child.stderr.emit("data", "private remote message and local diagnostic");
        child.emit("close", 1, null);
      });
      return child;
    },
  });

  await assert.rejects(
    () => runner.run({ prompt: "remote private prompt", sessionId: null }),
    (error) =>
      error.message.includes("stderr omitted") &&
      !error.message.includes("private remote message") &&
      !error.message.includes("remote private prompt"),
  );
});
