import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough, Writable } from "node:stream";
import test from "node:test";

import {
  AppServerDriver,
  AppServerReceiptStore,
  DeliveryStartError,
  parseModelDeclaredReply,
  withReplyContract,
} from "../src/app-server-driver.js";
import {
  DesktopOwnerIpcClient,
  DesktopOwnerIpcDriver,
  applyPatch,
} from "../src/desktop-owner-ipc-driver.js";
import { assertCodexDriver, loadCodexDriver, validateDriverReceipt } from "../src/driver.js";

const binding = { channelId: "channel-1", threadId: "thread-1", hostId: null };

test("generic driver loader and receipt validation enforce the contract", async () => {
  assert.throws(() => assertCodexDriver({}), /missing start/);
  assert.throws(
    () => validateDriverReceipt({ accepted: true, deliveryId: "other" }, "expected"),
    /does not match/,
  );
  const module = `data:text/javascript,${encodeURIComponent(`
    export async function createCodexDriver() {
      return { async start() {}, async deliver() {}, async stop() {} };
    }
  `)}`;
  const driver = await loadCodexDriver(module, {});
  assert.equal(typeof driver.deliver, "function");
});

test("AppServerDriver starts a fixed turn, correlates notifications, and emits model-declared reply", async () => {
  const protocol = [];
  const process = fakeAppServer((message, child) => {
    protocol.push(message);
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/resume") child.respond(message.id, { thread: { id: "thread-1" } });
    else if (message.method === "turn/start") {
      child.respond(message.id, { turn: { id: "turn-1", status: "inProgress", items: [] } });
      setImmediate(() => {
        child.notify("item/completed", {
          threadId: "thread-1",
          turnId: "turn-1",
          item: {
            type: "agentMessage",
            id: "item-1",
            text: JSON.stringify({
              aichat_reply: {
                text: "Verified result",
                message_type: "result",
                references: ["https://example.test/result"],
              },
            }),
          },
        });
        child.notify("turn/completed", {
          threadId: "thread-1",
          turn: { id: "turn-1", status: "completed", items: [] },
        });
      });
    }
  });
  const outbound = [];
  const stored = [];
  const driver = new AppServerDriver({
    binding,
    env: {},
    spawnImpl: () => process,
    receiptStore: {
      async load() { return { records: [] }; },
      async save(_binding, state) { stored.push(structuredClone(state)); },
    },
    logger: { error() {} },
  });
  await driver.start({ binding, onOutboundReply: async (event) => outbound.push(event) });
  const receipt = await driver.deliver(deliveryRequest());
  assert.equal(receipt.accepted, true);
  assert.equal(receipt.turnId, "turn-1");
  await waitFor(() => outbound.length === 1);
  assert.equal(outbound[0].sourceMessageId, "message-1");
  assert.equal(outbound[0].text, "Verified result");
  assert.equal(outbound[0].messageType, "result");
  assert.equal(stored.at(-1).records[0].turnId, "turn-1");

  const turnStart = protocol.find((message) => message.method === "turn/start");
  assert.equal(turnStart.params.threadId, "thread-1");
  assert.deepEqual(turnStart.params.input[0].text_elements, []);
  assert.match(turnStart.params.input[0].text, /MODEL-DECLARED STRUCTURED REPLY FORMAT/);
  assert.equal(turnStart.params.clientUserMessageId, "delivery-1");
  const replyObject = turnStart.params.outputSchema.properties.aichat_reply.anyOf[1];
  assert.deepEqual(replyObject.required, ["text", "message_type", "references"]);
  assert.deepEqual(replyObject.properties.message_type.enum, ["text", "result", null]);

  const duplicate = await driver.deliver(deliveryRequest());
  assert.equal(duplicate.duplicate, true);
  assert.equal(protocol.filter((message) => message.method === "turn/start").length, 1);
  await driver.stop();
});

test("app-server post-write timeout stays ambiguous, persists, and never starts a second turn", async () => {
  const protocol = [];
  const timers = controllableTimers();
  const process = fakeAppServer((message, child) => {
    protocol.push(message);
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/resume") {
      child.respond(message.id, { thread: { id: "thread-1" } });
    } else if (message.method === "thread/read") {
      child.respond(message.id, { thread: { id: "thread-1", turns: [] } });
    }
    // turn/start is deliberately accepted by stdin but receives no response.
  });
  const store = memoryReceiptStore();
  const driver = new AppServerDriver({
    binding,
    env: {
      CODEX_APP_SERVER_REQUEST_TIMEOUT_MS: "1000",
      CODEX_APP_SERVER_RECOVERY_INTERVAL_MS: "1000",
    },
    spawnImpl: () => process,
    receiptStore: store,
    timers,
    logger: { error() {} },
  });
  await driver.start({ binding, onOutboundReply: async () => {} });
  const first = driver.deliver(deliveryRequest());
  await waitFor(() => protocol.some((message) => message.method === "turn/start"));
  timers.fireFirst(1_000);
  await assert.rejects(first, /ambiguous/);
  assert.equal(store.state.records[0].phase, "ambiguous");
  assert.equal(protocol.filter((message) => message.method === "turn/start").length, 1);

  await assert.rejects(() => driver.deliver(deliveryRequest()), /remains ambiguous/);
  assert.equal(protocol.filter((message) => message.method === "turn/start").length, 1);
  await driver.stop();
});

test("owner ambiguous start never falls back to app-server turn/start", async () => {
  const protocol = [];
  const process = fakeAppServer((message, child) => {
    protocol.push(message);
    if (message.method === "initialize") child.respond(message.id, {});
  });
  const store = memoryReceiptStore();
  const driver = new AppServerDriver({
    binding,
    env: {},
    spawnImpl: () => process,
    receiptStore: store,
    logger: { error() {} },
  });
  await driver.start({ binding, onOutboundReply: async () => {} });
  await assert.rejects(
    () =>
      driver.deliver(deliveryRequest(), {
        externalStarter: async () => {
          throw new DeliveryStartError("owner timeout", "ambiguous");
        },
      }),
    /ambiguous/,
  );
  assert.equal(store.state.records[0].phase, "ambiguous");
  assert.equal(protocol.some((message) => message.method === "turn/start"), false);
  await driver.stop();
});

test("owner pre-send connection failure safely falls back to one app-server turn", async () => {
  const protocol = [];
  const process = fakeAppServer((message, child) => {
    protocol.push(message);
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/resume") {
      child.respond(message.id, { thread: { id: "thread-1" } });
    } else if (message.method === "turn/start") {
      child.respond(message.id, { turn: { id: "turn-fallback-1", status: "inProgress" } });
    }
  });
  const appServer = new AppServerDriver({
    binding,
    env: {},
    spawnImpl: () => process,
    receiptStore: memoryReceiptStore(),
    logger: { error() {} },
  });
  const owner = new DesktopOwnerIpcDriver({
    appServerDriver: appServer,
    ownerClient: {
      featureEnabled: true,
      async start() {},
      async startTurn() {
        throw new DeliveryStartError("owner socket unavailable", "pre-send");
      },
      async stop() {},
    },
    logger: { error() {} },
  });
  await owner.start({ binding, onOutboundReply: async () => {} });
  const receipt = await owner.deliver(deliveryRequest());
  assert.equal(receipt.turnId, "turn-fallback-1");
  assert.equal(protocol.filter((message) => message.method === "turn/start").length, 1);
  await owner.stop();
});

test("completion save failure exposes no outbound event until recovery persists it", async () => {
  const timers = controllableTimers();
  const process = fakeAppServer((message, child) => {
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/read") {
      child.respond(message.id, {
        thread: {
          id: "thread-1",
          turns: [completedTurn("turn-1", deliveryRequest().envelope, "Persist first")],
        },
      });
    }
  });
  const store = memoryReceiptStore(
    { records: [acceptedRecord()] },
    { failSaveCalls: [1] },
  );
  const outbound = [];
  const driver = new AppServerDriver({
    binding,
    env: { CODEX_APP_SERVER_RECOVERY_INTERVAL_MS: "1000" },
    spawnImpl: () => process,
    receiptStore: store,
    timers,
    logger: { error() {} },
  });
  await driver.start({
    binding,
    onOutboundReply: async (event) => {
      assert.equal(store.state.records[0].phase, "completed");
      assert.equal(store.state.records[0].outboundEvent.eventId, event.eventId);
      outbound.push(event);
    },
  });
  assert.equal(outbound.length, 0);
  assert.equal(store.state.records[0].phase, "accepted");
  assert.equal(store.state.records[0].outboundEvent, null);

  timers.fireFirst(1_000);
  await waitFor(() => outbound.length === 1);
  assert.equal(store.state.records[0].phase, "completed");
  await driver.stop();
});

test("restart reconciles an ambiguous delivery by durable source markers without resending", async () => {
  const record = ambiguousRecord();
  const protocol = [];
  const process = fakeAppServer((message, child) => {
    protocol.push(message);
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/read") {
      child.respond(message.id, {
        thread: {
          id: "thread-1",
          turns: [completedTurn("turn-recovered-1", deliveryRequest().envelope, "Recovered reply")],
        },
      });
    }
  });
  const store = memoryReceiptStore({ records: [record] });
  const outbound = [];
  const driver = new AppServerDriver({
    binding,
    env: {},
    spawnImpl: () => process,
    receiptStore: store,
    logger: { error() {} },
  });
  await driver.start({ binding, onOutboundReply: async (event) => outbound.push(event) });
  await waitFor(() => outbound.length === 1);
  assert.equal(store.state.records[0].phase, "completed");
  assert.equal(store.state.records[0].turnId, "turn-recovered-1");
  assert.equal(outbound[0].text, "Recovered reply");
  assert.equal(protocol.some((message) => message.method === "turn/start"), false);
  await driver.stop();
});

test("restart reconstructs accepted completion, persists one stable outbound event, and replays it", async () => {
  const initial = acceptedRecord();
  const store = memoryReceiptStore({ records: [initial] });
  const firstProtocol = [];
  const firstProcess = fakeAppServer((message, child) => {
    firstProtocol.push(message);
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/read") {
      child.respond(message.id, {
        thread: {
          id: "thread-1",
          turns: [completedTurn("turn-1", deliveryRequest().envelope, "Durable reply")],
        },
      });
    }
  });
  const firstEvents = [];
  const firstDriver = new AppServerDriver({
    binding,
    env: {},
    spawnImpl: () => firstProcess,
    receiptStore: store,
    logger: { error() {} },
  });
  await firstDriver.start({
    binding,
    onOutboundReply: async (event) => {
      firstEvents.push(structuredClone(event));
      assert.equal(store.state.records[0].outboundEvent.eventId, event.eventId);
      throw new Error("connector unavailable");
    },
  });
  await waitFor(() => firstEvents.length === 1);
  await firstDriver.stop();
  assert.equal(store.state.records[0].phase, "completed");
  assert.equal(store.state.records[0].outboundDelivered, false);

  const secondProcess = fakeAppServer((message, child) => {
    if (message.method === "initialize") child.respond(message.id, {});
  });
  const secondEvents = [];
  const secondDriver = new AppServerDriver({
    binding,
    env: {},
    spawnImpl: () => secondProcess,
    receiptStore: store,
    logger: { error() {} },
  });
  await secondDriver.start({
    binding,
    onOutboundReply: async (event) => secondEvents.push(structuredClone(event)),
  });
  await waitFor(() => secondEvents.length === 1);
  assert.equal(secondEvents[0].eventId, firstEvents[0].eventId);
  assert.equal(secondEvents[0].text, "Durable reply");
  await waitFor(() => store.state.records[0].outboundDelivered === true);
  await secondDriver.stop();
});

test("app-server child receives a conservative environment without connector secrets", async () => {
  let childOptions;
  const process = fakeAppServer((message, child) => {
    if (message.method === "initialize") child.respond(message.id, {});
  });
  const driver = new AppServerDriver({
    binding,
    env: {
      PATH: "/usr/bin",
      HOME: "/tmp/test-home",
      LANG: "en_US.UTF-8",
      HTTPS_PROXY: "https://proxy.example.test:443",
      HTTP_PROXY: "http://user:password@proxy.example.test",
      AICHAT_TOKEN: "relay-secret",
      AICHAT_CONFIG: "/secret/config",
      AICHAT_CHANNEL_ID: "channel-1",
      CODEX_TARGET_THREAD_ID: "thread-secret-mapping",
      UNRELATED_SECRET: "also-secret",
    },
    spawnImpl: (_binary, _args, options) => {
      childOptions = options;
      return process;
    },
    receiptStore: memoryReceiptStore(),
    logger: { error() {} },
  });
  await driver.start({ binding, onOutboundReply: async () => {} });
  assert.deepEqual(childOptions.env, {
    PATH: "/usr/bin",
    HOME: "/tmp/test-home",
    LANG: "en_US.UTF-8",
    HTTPS_PROXY: "https://proxy.example.test:443",
  });
  assert.equal(Object.keys(childOptions.env).some((name) => name.startsWith("AICHAT_")), false);
  await driver.stop();
});

test("built-in Codex drivers reject non-local host bindings", async () => {
  const remoteBinding = { ...binding, hostId: "remote-host" };
  const appServer = new AppServerDriver({
    env: {},
    spawnImpl: () => {
      throw new Error("must not spawn");
    },
    receiptStore: memoryReceiptStore(),
  });
  await assert.rejects(
    () => appServer.start({ binding: remoteBinding, onOutboundReply: async () => {} }),
    /local-only/,
  );
  const owner = new DesktopOwnerIpcDriver({
    appServerDriver: { async start() {}, async stop() {} },
    ownerClient: { async start() {}, async stop() {} },
  });
  await assert.rejects(
    () => owner.start({ binding: remoteBinding, onOutboundReply: async () => {} }),
    /local-only/,
  );
});

test("AppServerReceiptStore migrates v1 accepted receipts to durable v2 records", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-app-server-state-"));
  const path = join(directory, "receipts.json");
  await writeFile(
    path,
    JSON.stringify({
      version: 1,
      binding,
      receipts: [
        {
          deliveryId: "delivery-1",
          sourceMessageId: "message-1",
          threadId: "thread-1",
          hostId: null,
          turnId: "turn-1",
          acceptedAt: "2026-08-24T00:00:00.000Z",
        },
      ],
    }),
  );
  const store = new AppServerReceiptStore(path);
  const loaded = await store.load(binding);
  assert.equal(loaded.records[0].phase, "accepted");
  assert.equal(loaded.records[0].transport, "app-server");
  await store.save(binding, loaded);
  assert.equal(JSON.parse(await readFile(path, "utf8")).version, 2);
});

test("Desktop owner wrapper prefers IPC starter and leaves app-server as automatic fallback", async () => {
  const calls = [];
  const appServerDriver = {
    async start(value) { calls.push(["app-start", value.binding]); },
    async deliver(request, { externalStarter }) {
      calls.push(["deliver", request.deliveryId]);
      const started = await externalStarter("trusted-envelope");
      return { accepted: true, deliveryId: request.deliveryId, turnId: started.turnId };
    },
    async stop() { calls.push(["app-stop"]); },
  };
  const ownerClient = {
    featureEnabled: true,
    async start(value) { calls.push(["owner-start", value.threadId]); },
    async startTurn(value) {
      calls.push(["owner-turn", value]);
      return { turnId: "owner-turn-1", completion: Promise.resolve({ status: "completed" }) };
    },
    async stop() { calls.push(["owner-stop"]); },
  };
  const driver = new DesktopOwnerIpcDriver({ appServerDriver, ownerClient });
  await driver.start({ binding, onOutboundReply: async () => {} });
  const receipt = await driver.deliver(deliveryRequest());
  assert.equal(receipt.turnId, "owner-turn-1");
  assert.equal(calls.find(([name]) => name === "owner-turn")[1].deliveryId, "delivery-1");
  await driver.stop();
});

test("Desktop owner IPC framing, discovery, stream snapshot, and structured completion work on an isolated socket", async (t) => {
  if (process.platform !== "darwin") return t.skip("Desktop owner IPC is macOS-only");
  const directory = await mkdtemp(join(tmpdir(), "aichat-owner-ipc-"));
  const appPath = join(directory, "ChatGPT.app");
  const socketPath = join(directory, "ipc.sock");
  await import("node:fs/promises").then(({ mkdir, writeFile }) =>
    mkdir(join(appPath, "Contents"), { recursive: true }).then(() =>
      writeFile(
        join(appPath, "Contents", "Info.plist"),
        `<?xml version="1.0"?><plist><dict><key>CFBundleShortVersionString</key><string>26.730.61639</string></dict></plist>`,
      ),
    ),
  );

  const received = [];
  let serverSocket;
  const server = createServer((socket) => {
    serverSocket = socket;
    readOwnerFrames(socket, (message) => {
      received.push(message);
      if (message.type === "request" && message.method === "initialize") {
        writeOwnerFrame(socket, {
          type: "response",
          requestId: message.requestId,
          resultType: "success",
          method: "initialize",
          handledByClientId: "client-1",
          result: { clientId: "client-1" },
        });
        writeOwnerFrame(socket, {
          type: "client-discovery-request",
          requestId: "discovery-1",
          request: { method: "unknown", version: 1 },
        });
      } else if (message.type === "request" && message.method === "thread-follower-start-turn") {
        writeOwnerFrame(socket, {
          type: "response",
          requestId: message.requestId,
          resultType: "success",
          method: "thread-follower-start-turn",
          result: { result: { turn: { id: "turn-owner-1", status: "inProgress" } } },
        });
        setImmediate(() =>
          writeOwnerFrame(socket, {
            type: "broadcast",
            method: "thread-stream-state-changed",
            version: 11,
            targetClientIds: ["client-1"],
            params: {
              conversationId: "thread-1",
              hostId: "local",
              change: {
                type: "snapshot",
                revision: 21,
                conversationState: {
                  turnHistory: {
                    history: {
                      entitiesByKey: {
                        "dynamic:key": {
                          turnId: "turn-owner-1",
                          status: "completed",
                          items: [
                            {
                              type: "agentMessage",
                              text: JSON.stringify({ aichat_reply: { text: "Owner reply" } }),
                            },
                          ],
                        },
                      },
                    },
                  },
                },
              },
            },
          }),
        );
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  await chmod(socketPath, 0o600);

  const client = new DesktopOwnerIpcClient({
    env: {
      CODEX_DESKTOP_OWNER_IPC_ENABLED: "true",
      CODEX_DESKTOP_APP_PATH: appPath,
      CODEX_DESKTOP_IPC_SOCKET: socketPath,
      CODEX_DESKTOP_IPC_TURN_TIMEOUT_MS: "5000",
    },
    logger: { error() {} },
  });
  await client.start({ threadId: "thread-1" });
  const started = await client.startTurn({
    threadId: "thread-1",
    envelope: "trusted envelope",
    deliveryId: "delivery-1",
  });
  const completed = await started.completion;
  assert.equal(started.turnId, "turn-owner-1");
  assert.equal(completed.status, "completed");
  assert.match(completed.finalText, /Owner reply/);
  await waitFor(
    () => received.some((message) => message.type === "client-discovery-response"),
  );
  assert.equal(
    received.find((message) => message.type === "client-discovery-response").response.canHandle,
    false,
  );
  const startRequest = received.find((message) => message.method === "thread-follower-start-turn");
  assert.deepEqual(startRequest.params.turnStartParams.input[0].text_elements, []);
  assert.equal(startRequest.version, 1);
  assert.ok(received.some((message) => message.method === "thread-stream-following-changed"));

  await client.stop();
  serverSocket?.destroy();
  await new Promise((resolve) => server.close(resolve));
});

test("Desktop owner IPC classifies a post-write start timeout as ambiguous", async (t) => {
  if (process.platform !== "darwin") return t.skip("Desktop owner IPC is macOS-only");
  const directory = await mkdtemp(join(tmpdir(), "aichat-owner-timeout-"));
  const appPath = join(directory, "ChatGPT.app");
  const socketPath = join(directory, "ipc.sock");
  await import("node:fs/promises").then(({ mkdir }) =>
    mkdir(join(appPath, "Contents"), { recursive: true }).then(() =>
      writeFile(
        join(appPath, "Contents", "Info.plist"),
        `<?xml version="1.0"?><plist><dict><key>CFBundleShortVersionString</key><string>26.730.61639</string></dict></plist>`,
      ),
    ),
  );
  const received = [];
  let serverSocket;
  const server = createServer((socket) => {
    serverSocket = socket;
    readOwnerFrames(socket, (message) => {
      received.push(message);
      if (message.type === "request" && message.method === "initialize") {
        writeOwnerFrame(socket, {
          type: "response",
          requestId: message.requestId,
          resultType: "success",
          method: "initialize",
          result: { clientId: "client-timeout" },
        });
      }
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  await chmod(socketPath, 0o600);
  const timers = controllableTimers();
  const client = new DesktopOwnerIpcClient({
    env: {
      CODEX_DESKTOP_OWNER_IPC_ENABLED: "true",
      CODEX_DESKTOP_APP_PATH: appPath,
      CODEX_DESKTOP_IPC_SOCKET: socketPath,
      CODEX_DESKTOP_IPC_REQUEST_TIMEOUT_MS: "1000",
    },
    timers,
    logger: { error() {} },
  });
  await client.start({ threadId: "thread-1" });
  const start = client.startTurn({
    threadId: "thread-1",
    envelope: deliveryRequest().envelope,
    deliveryId: "delivery-1",
  });
  await waitFor(() => received.some((message) => message.method === "thread-follower-start-turn"));
  timers.fireFirst(1_000);
  await assert.rejects(start, (error) => error.outcome === "ambiguous");
  await client.stop();
  serverSocket?.destroy();
  await new Promise((resolve) => server.close(resolve));
});

test("Desktop owner IPC classifies connection failure before start-turn as pre-send", async () => {
  const client = new DesktopOwnerIpcClient({
    env: {
      CODEX_DESKTOP_OWNER_IPC_ENABLED: "true",
      CODEX_DESKTOP_IPC_SOCKET: join(tmpdir(), `missing-owner-${Date.now()}.sock`),
    },
    logger: { error() {} },
  });
  client.threadId = "thread-1";
  await assert.rejects(
    () =>
      client.startTurn({
        threadId: "thread-1",
        envelope: deliveryRequest().envelope,
        deliveryId: "delivery-1",
      }),
    (error) => error.outcome === "pre-send",
  );
  await client.stop();
});

test("stream patch application is ordered, supports arrays, and blocks prototype paths", () => {
  const state = { a: { text: "old", items: ["a", "c"] } };
  applyPatch(state, { op: "replace", path: ["a", "text"], value: "new" });
  applyPatch(state, { op: "add", path: ["a", "items", 1], value: "b" });
  applyPatch(state, { op: "remove", path: ["a", "items", 0] });
  assert.deepEqual(state, { a: { text: "new", items: ["b", "c"] } });
  assert.throws(
    () => applyPatch(state, { op: "add", path: ["__proto__", "polluted"], value: true }),
    /Unsafe/,
  );
});

test("model-declared reply parser and format require deliberate structured output", () => {
  assert.equal(parseModelDeclaredReply("ordinary assistant text"), null);
  assert.equal(parseModelDeclaredReply('{"aichat_reply":null}'), null);
  assert.deepEqual(
    parseModelDeclaredReply(
      '{"aichat_reply":{"text":"ok","message_type":"text","references":[]}}',
    ),
    { text: "ok", messageType: "text", references: [] },
  );
  assert.match(withReplyContract("remote envelope"), /not an independent authorization boundary/);
});

function deliveryRequest(overrides = {}) {
  return {
    deliveryId: "delivery-1",
    threadId: "thread-1",
    hostId: null,
    sourceMessageId: "message-1",
    envelope:
      "delivery_id: delivery-1\n" +
      `source_message_sha256: ${createHash("sha256").update("message-1").digest("hex")}\n` +
      "UNTRUSTED REMOTE PAYLOAD JSON (LENGTH-DELIMITED)\n{\"text\":\"hello\"}\n" +
      "END LENGTH-DELIMITED UNTRUSTED REMOTE PAYLOAD JSON",
    metadata: {},
    ...overrides,
  };
}

function ambiguousRecord(overrides = {}) {
  return {
    deliveryId: "delivery-1",
    sourceMessageId: "message-1",
    threadId: "thread-1",
    hostId: null,
    phase: "ambiguous",
    transport: "app-server",
    turnId: null,
    acceptedAt: null,
    completionStatus: null,
    outboundEvent: null,
    outboundDelivered: false,
    outboundBlocked: false,
    ...overrides,
  };
}

function acceptedRecord(overrides = {}) {
  return ambiguousRecord({
    phase: "accepted",
    turnId: "turn-1",
    acceptedAt: "2026-08-24T00:00:00.000Z",
    ...overrides,
  });
}

function completedTurn(turnId, envelope, replyText) {
  return {
    id: turnId,
    status: "completed",
    items: [
      { type: "userMessage", text: envelope },
      {
        type: "agentMessage",
        text: JSON.stringify({
          aichat_reply: {
            text: replyText,
            message_type: "result",
            references: [],
          },
        }),
      },
    ],
  };
}

function memoryReceiptStore(initial = { records: [] }, options = {}) {
  return {
    state: structuredClone(initial),
    saves: [],
    saveCalls: 0,
    async load() {
      return structuredClone(this.state);
    },
    async save(_binding, state) {
      this.saveCalls += 1;
      if (options.failSaveCalls?.includes(this.saveCalls)) {
        throw new Error(`receipt save ${this.saveCalls}`);
      }
      this.state = structuredClone(state);
      this.saves.push(structuredClone(state));
    },
  };
}

function controllableTimers() {
  let nextId = 1;
  const entries = new Map();
  return {
    setTimeout(fn, milliseconds) {
      const id = nextId++;
      entries.set(id, { fn, milliseconds });
      return id;
    },
    clearTimeout(id) {
      entries.delete(id);
    },
    fireFirst(milliseconds) {
      const match = [...entries].find(([, entry]) => entry.milliseconds === milliseconds);
      if (!match) throw new Error(`No pending ${milliseconds}ms timer`);
      entries.delete(match[0]);
      match[1].fn();
    },
  };
}

function fakeAppServer(handler) {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  let input = "";
  child.stdin = new Writable({
    write(chunk, _encoding, callback) {
      input += chunk.toString("utf8");
      while (input.includes("\n")) {
        const index = input.indexOf("\n");
        const line = input.slice(0, index).trim();
        input = input.slice(index + 1);
        if (line) handler(JSON.parse(line), child);
      }
      callback();
    },
  });
  child.respond = (id, result) => child.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
  child.notify = (method, params) =>
    child.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  child.kill = () => {
    setImmediate(() => child.emit("exit", 0, null));
    return true;
  };
  return child;
}

function readOwnerFrames(socket, onMessage) {
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4) {
      const length = buffer.readUInt32LE(0);
      if (buffer.length < 4 + length) return;
      const payload = buffer.subarray(4, 4 + length);
      buffer = buffer.subarray(4 + length);
      onMessage(JSON.parse(payload.toString("utf8")));
    }
  });
}

function writeOwnerFrame(socket, message) {
  const payload = Buffer.from(JSON.stringify(message));
  const frame = Buffer.alloc(4 + payload.length);
  frame.writeUInt32LE(payload.length, 0);
  payload.copy(frame, 4);
  socket.write(frame);
}

async function waitFor(predicate, timeoutMs = 2_000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("Timed out waiting for test condition");
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
