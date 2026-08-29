import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough, Writable } from "node:stream";
import test from "node:test";

import {
  AppServerDriver,
  AppServerReceiptStore,
  DeliveryStartError,
  JsonRpcStdioClient,
  extractUserMessageTextSegments,
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
    () =>
      assertCodexDriver({
        async start() {},
        async deliver() {},
        async stop() {},
        resolveDelivery: true,
      }),
    /optional resolveDelivery must be a function/,
  );
  assert.throws(
    () =>
      assertCodexDriver({
        async start() {},
        async deliver() {},
        async stop() {},
        drain: true,
      }),
    /optional drain must be a function/,
  );
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
  await driver.acknowledgeDelivery(receipt.deliveryId);
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
  assert.deepEqual(replyObject.properties.message_type.enum, ["result", null]);

  const duplicate = await driver.deliver(deliveryRequest());
  assert.equal(duplicate.duplicate, true);
  assert.equal(protocol.filter((message) => message.method === "turn/start").length, 1);
  await driver.stop();
});

test("AppServerDriver drain waits for accepted turn completion and durable outbound handling", async () => {
  let child;
  const store = memoryReceiptStore();
  const process = fakeAppServer((message, current) => {
    child = current;
    if (message.method === "initialize") current.respond(message.id, {});
    else if (message.method === "thread/resume") {
      current.respond(message.id, { thread: { id: "thread-1" } });
    } else if (message.method === "turn/start") {
      current.respond(message.id, { turn: { id: "turn-drain-1", status: "inProgress" } });
    }
  });
  const outbound = [];
  const driver = new AppServerDriver({
    binding,
    env: { AICHAT_LIFECYCLE_STATUS_ENABLED: "false" },
    spawnImpl: () => process,
    receiptStore: store,
    logger: { error() {} },
  });
  await driver.start({
    binding,
    onOutboundReply: async (event) => {
      outbound.push(event);
      return { suppressed: true };
    },
  });
  const receipt = await driver.deliver(deliveryRequest());
  await driver.acknowledgeDelivery(receipt.deliveryId);

  let drained = false;
  const drain = driver.drain().then(() => {
    drained = true;
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(drained, false);

  child.notify("item/completed", {
    threadId: "thread-1",
    turnId: "turn-drain-1",
    item: {
      type: "agentMessage",
      text: JSON.stringify({ aichat_reply: null }),
    },
  });
  child.notify("turn/completed", {
    threadId: "thread-1",
    turn: { id: "turn-drain-1", status: "completed" },
  });
  await drain;

  assert.equal(store.state.records[0].phase, "completed");
  assert.equal(store.state.records[0].connectorCheckpointed, true);
  assert.equal(store.state.records[0].outboundDelivered, true);
  assert.equal(outbound.length, 1);
  await driver.stop();
});

test("AppServerDriver pins receipts to an explicit absolute directory", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-driver-receipts-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  assert.throws(
    () =>
      new AppServerDriver({
        binding,
        env: { CODEX_APP_SERVER_RECEIPT_DIR: "relative-receipts" },
      }),
    /must be an absolute path/,
  );

  let child;
  const process = fakeAppServer((message, current) => {
    child = current;
    if (message.method === "initialize") current.respond(message.id, {});
    else if (message.method === "thread/resume") {
      current.respond(message.id, { thread: { id: "thread-1" } });
    } else if (message.method === "turn/start") {
      current.respond(message.id, { turn: { id: "turn-explicit-receipt", status: "inProgress" } });
    }
  });
  const driver = new AppServerDriver({
    binding,
    env: {
      CODEX_APP_SERVER_RECEIPT_DIR: directory,
      AICHAT_LIFECYCLE_STATUS_ENABLED: "false",
    },
    spawnImpl: () => process,
    logger: { error() {} },
  });
  await driver.start({ binding, onOutboundReply: async () => ({ suppressed: true }) });
  const receipt = await driver.deliver(deliveryRequest());
  await driver.acknowledgeDelivery(receipt.deliveryId);
  child.notify("turn/completed", {
    threadId: "thread-1",
    turn: { id: "turn-explicit-receipt", status: "completed" },
  });
  await driver.drain();

  const digest = createHash("sha256")
    .update("channel-1\0thread-1\0")
    .digest("hex")
    .slice(0, 24);
  const persisted = JSON.parse(
    await readFile(join(directory, `app-server-${digest}.json`), "utf8"),
  );
  assert.equal(persisted.records[0].phase, "completed");
  assert.equal(persisted.records[0].connectorCheckpointed, true);
  assert.equal(persisted.records[0].outboundDelivered, true);
  await driver.stop();
});

test("JsonRpcStdioClient stop waits for the app-server child to exit", async () => {
  const signals = [];
  const process = fakeAppServer((message, child) => {
    if (message.method === "initialize") child.respond(message.id, {});
  });
  process.kill = (signal) => {
    signals.push(signal);
    return true;
  };
  const client = new JsonRpcStdioClient({
    binary: "codex",
    args: [],
    requestTimeoutMs: 1_000,
    spawnImpl: () => process,
    logger: { error() {} },
  });
  await client.start();

  let stopped = false;
  const stopping = client.stop().then(() => {
    stopped = true;
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(stopped, false);
  assert.deepEqual(signals, ["SIGTERM"]);

  process.emit("exit", 0, "SIGTERM");
  await stopping;
  assert.equal(stopped, true);
});

test("JsonRpcStdioClient stop force-terminates a child that ignores graceful shutdown", async () => {
  const signals = [];
  const timers = controllableTimers();
  const process = fakeAppServer((message, child) => {
    if (message.method === "initialize") child.respond(message.id, {});
  });
  process.kill = (signal) => {
    signals.push(signal);
    return true;
  };
  const client = new JsonRpcStdioClient({
    binary: "codex",
    args: [],
    requestTimeoutMs: 1_000,
    spawnImpl: () => process,
    timers,
    logger: { error() {} },
  });
  await client.start();

  const stopping = client.stop();
  assert.deepEqual(signals, ["SIGTERM"]);
  timers.fireFirst(5_000);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(signals, ["SIGTERM", "SIGKILL"]);

  process.emit("exit", 0, "SIGKILL");
  await stopping;
});

test("AppServerDriver persists source type and never creates outbound events for result input", async () => {
  const protocol = [];
  const process = fakeAppServer((message, child) => {
    protocol.push(message);
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/resume") {
      child.respond(message.id, { thread: { id: "thread-1" } });
    } else if (message.method === "turn/start") {
      child.respond(message.id, { turn: { id: "turn-result-input", status: "inProgress" } });
      setImmediate(() => {
        child.notify("item/completed", {
          threadId: "thread-1",
          turnId: "turn-result-input",
          item: {
            type: "agentMessage",
            text: JSON.stringify({
              aichat_reply: { text: "loop candidate", message_type: "result", references: [] },
            }),
          },
        });
        child.notify("turn/completed", {
          threadId: "thread-1",
          turn: { id: "turn-result-input", status: "completed" },
        });
      });
    }
  });
  const store = memoryReceiptStore();
  const outbound = [];
  const driver = new AppServerDriver({
    binding,
    env: {},
    spawnImpl: () => process,
    receiptStore: store,
    logger: { error() {} },
  });
  await driver.start({ binding, onOutboundReply: async (event) => outbound.push(event) });
  const receipt = await driver.deliver(
    deliveryRequest({ metadata: { messageType: "result" } }),
  );
  await driver.acknowledgeDelivery(receipt.deliveryId);
  await waitFor(() => store.state.records[0]?.phase === "completed");
  assert.equal(store.state.records[0].sourceMessageType, "result");
  assert.equal(store.state.records[0].replyEligible, false);
  assert.equal(store.state.records[0].outboundEvent, null);
  assert.equal(outbound.length, 0);
  const turnStart = protocol.find((message) => message.method === "turn/start");
  assert.equal("outputSchema" in turnStart.params, false);
  assert.doesNotMatch(turnStart.params.input[0].text, /MODEL-DECLARED STRUCTURED REPLY/);
  await driver.stop();
});

test("lifecycle-off request completion and failure emit only local suppression events", async () => {
  for (const [status, finalText] of [
    ["completed", JSON.stringify({ aichat_reply: null })],
    ["failed", null],
    ["interrupted", null],
  ]) {
    const turnId = `turn-lifecycle-off-${status}`;
    const process = fakeAppServer((message, child) => {
      if (message.method === "initialize") child.respond(message.id, {});
      else if (message.method === "thread/resume") {
        child.respond(message.id, { thread: { id: "thread-1" } });
      } else if (message.method === "turn/start") {
        child.respond(message.id, { turn: { id: turnId, status: "inProgress" } });
        setImmediate(() => {
          if (finalText != null) {
            child.notify("item/completed", {
              threadId: "thread-1",
              turnId,
              item: { type: "agentMessage", text: finalText },
            });
          }
          child.notify("turn/completed", {
            threadId: "thread-1",
            turn: { id: turnId, status },
          });
        });
      }
    });
    const store = memoryReceiptStore();
    const outbound = [];
    const driver = new AppServerDriver({
      binding,
      env: { AICHAT_LIFECYCLE_STATUS_ENABLED: "false" },
      spawnImpl: () => process,
      receiptStore: store,
      logger: { error() {} },
    });
    await driver.start({ binding, onOutboundReply: async (event) => outbound.push(event) });
    const receipt = await driver.deliver(deliveryRequest());
    await driver.acknowledgeDelivery(receipt.deliveryId);
    await waitFor(() => outbound.length === 1);
    assert.equal(outbound[0].suppressRelay, true);
    assert.equal(outbound[0].messageType, "status");
    assert.equal(outbound[0].text, JSON.stringify({ status: "suppressed" }));
    await waitFor(() => store.state.records[0].outboundDelivered === true);
    await driver.stop();
  }
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
  await driver.acknowledgeDelivery("delivery-1");

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
  await driver.acknowledgeDelivery("delivery-1");
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
  await firstDriver.acknowledgeDelivery("delivery-1");
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

test("driver acknowledgement before completion preserves completed outbound state", async () => {
  const harness = acknowledgementRaceHarness();
  await harness.driver.start({
    binding,
    onOutboundReply: async (event) => harness.outbound.push(event),
  });
  const receipt = await harness.driver.deliver(deliveryRequest());
  await harness.driver.acknowledgeDelivery(receipt.deliveryId);
  harness.complete();
  await waitFor(() => harness.outbound.length === 1);
  const record = harness.store.state.records[0];
  assert.equal(record.phase, "completed");
  assert.equal(record.connectorCheckpointed, true);
  assert.equal(record.outboundEvent.text, "Race result");
  await harness.driver.stop();
});

test("driver completion before acknowledgement never regresses the completed record", async () => {
  const harness = acknowledgementRaceHarness();
  await harness.driver.start({
    binding,
    onOutboundReply: async (event) => harness.outbound.push(event),
  });
  const receipt = await harness.driver.deliver(deliveryRequest());
  harness.complete();
  await waitFor(() => harness.store.state.records[0]?.phase === "completed");
  assert.equal(harness.outbound.length, 0);
  await harness.driver.acknowledgeDelivery(receipt.deliveryId);
  await waitFor(() => harness.outbound.length === 1);
  const record = harness.store.state.records[0];
  assert.equal(record.phase, "completed");
  assert.equal(record.connectorCheckpointed, true);
  assert.equal(record.outboundEvent.text, "Race result");
  await harness.driver.stop();
});

test("late turn/start response cannot regress a recovery-completed receipt", async () => {
  const timers = controllableTimers();
  let childProcess;
  let delayedTurnStart;
  let readCount = 0;
  const process = fakeAppServer((message, child) => {
    childProcess = child;
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/resume") {
      child.respond(message.id, { thread: { id: "thread-1" } });
    } else if (message.method === "thread/read") {
      readCount += 1;
      child.respond(message.id, {
        thread: {
          id: "thread-1",
          turns:
            readCount >= 2
              ? [
                  completedTurn(
                    "turn-late-response",
                    deliveryRequest().envelope,
                    "Recovered before start response",
                  ),
                ]
              : [],
        },
      });
    } else if (message.method === "turn/start") {
      delayedTurnStart = message;
    }
  });
  const store = memoryReceiptStore({
    records: [
      ambiguousRecord({
        deliveryId: "stale-delivery",
        sourceMessageId: "stale-message",
      }),
    ],
  });
  const outbound = [];
  const driver = new AppServerDriver({
    binding,
    env: {
      CODEX_APP_SERVER_REQUEST_TIMEOUT_MS: "5000",
      CODEX_APP_SERVER_RECOVERY_INTERVAL_MS: "1000",
    },
    spawnImpl: () => process,
    receiptStore: store,
    timers,
    logger: { error() {} },
  });
  await driver.start({
    binding,
    onOutboundReply: async (event) => outbound.push(event),
  });

  const delivery = driver.deliver(deliveryRequest());
  await waitFor(() => delayedTurnStart != null);
  timers.fireFirst(1_000);
  await waitFor(
    () =>
      store.state.records.find((record) => record.deliveryId === "delivery-1")?.phase ===
      "completed",
  );

  childProcess.respond(delayedTurnStart.id, {
    turn: { id: "turn-late-response", status: "completed" },
  });
  const receipt = await delivery;
  assert.equal(receipt.turnId, "turn-late-response");
  const completed = store.state.records.find((record) => record.deliveryId === "delivery-1");
  assert.equal(completed.phase, "completed");
  assert.equal(completed.outboundEvent.text, "Recovered before start response");
  assert.equal(outbound.length, 0);

  await driver.acknowledgeDelivery(receipt.deliveryId);
  await waitFor(() => outbound.length === 1);
  assert.equal(outbound[0].text, "Recovered before start response");
  assert.equal(
    store.state.records.find((record) => record.deliveryId === "delivery-1").phase,
    "completed",
  );
  await driver.stop();
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

test("durable connector quarantine acknowledgement blocks driver replay without retry", async () => {
  const process = fakeAppServer((message, child) => {
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/resume") {
      child.respond(message.id, { thread: { id: "thread-1" } });
    } else if (message.method === "turn/start") {
      child.respond(message.id, { turn: { id: "turn-policy", status: "inProgress" } });
      setImmediate(() => {
        child.notify("item/completed", {
          threadId: "thread-1",
          turnId: "turn-policy",
          item: {
            type: "agentMessage",
            text: JSON.stringify({
              aichat_reply: { text: "Blocked reply", message_type: "result", references: [] },
            }),
          },
        });
        child.notify("turn/completed", {
          threadId: "thread-1",
          turn: { id: "turn-policy", status: "completed" },
        });
      });
    }
  });
  const store = memoryReceiptStore();
  let attempts = 0;
  const driver = new AppServerDriver({
    binding,
    env: { CODEX_OUTBOUND_RETRY_MAX_ATTEMPTS: "2" },
    spawnImpl: () => process,
    receiptStore: store,
    logger: { error() {} },
  });
  await driver.start({
    binding,
    onOutboundReply: async (event) => {
      attempts += 1;
      return { blocked: true, eventId: event.eventId, reasonCode: "AICHAT_EGRESS_DISABLED" };
    },
  });
  const receipt = await driver.deliver(deliveryRequest());
  await driver.acknowledgeDelivery(receipt.deliveryId);
  await waitFor(() => store.state.records[0]?.outboundBlocked === true);
  assert.equal(attempts, 1);
  const eventId = store.state.records[0].outboundEvent.eventId;
  await driver.resolveDelivery(receipt.deliveryId, { eventId, outcome: "delivered" });
  assert.equal(store.state.records[0].outboundDelivered, true);
  assert.equal(store.state.records[0].outboundBlocked, false);
  await driver.resolveDelivery(receipt.deliveryId, { eventId, outcome: "evicted" });
  assert.equal(store.state.records.length, 0);
  assert.deepEqual(
    await driver.resolveDelivery(receipt.deliveryId, { eventId, outcome: "evicted" }),
    { released: true, duplicate: true },
  );
  await driver.stop();
});

test("late quarantine acknowledgement cannot regress an operator-confirmed delivery", async () => {
  const process = fakeAppServer((message, child) => {
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/resume") {
      child.respond(message.id, { thread: { id: "thread-1" } });
    } else if (message.method === "turn/start") {
      child.respond(message.id, { turn: { id: "turn-late-block", status: "inProgress" } });
      setImmediate(() => {
        child.notify("item/completed", {
          threadId: "thread-1",
          turnId: "turn-late-block",
          item: {
            type: "agentMessage",
            text: JSON.stringify({
              aichat_reply: { text: "Eventually delivered", message_type: "result", references: [] },
            }),
          },
        });
        child.notify("turn/completed", {
          threadId: "thread-1",
          turn: { id: "turn-late-block", status: "completed" },
        });
      });
    }
  });
  const store = memoryReceiptStore();
  const callbackGate = deferred();
  const eventSeen = deferred();
  const driver = new AppServerDriver({
    binding,
    env: {},
    spawnImpl: () => process,
    receiptStore: store,
    logger: { error() {} },
  });
  await driver.start({
    binding,
    onOutboundReply: async (event) => {
      eventSeen.resolve(event);
      await callbackGate.promise;
      return { blocked: true, eventId: event.eventId, reasonCode: "late-policy" };
    },
  });
  const receipt = await driver.deliver(deliveryRequest());
  await driver.acknowledgeDelivery(receipt.deliveryId);
  const event = await eventSeen.promise;
  await driver.resolveDelivery(receipt.deliveryId, {
    eventId: event.eventId,
    outcome: "delivered",
  });
  callbackGate.resolve();
  await driver.stop();
  assert.equal(store.state.records[0].outboundDelivered, true);
  assert.equal(store.state.records[0].outboundBlocked, false);
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

test("Desktop owner version gate cannot be overridden without a development risk acknowledgement", () => {
  assert.throws(
    () =>
      new DesktopOwnerIpcClient({
        env: {
          CODEX_DESKTOP_OWNER_IPC_ENABLED: "true",
          CODEX_DESKTOP_EXPECTED_VERSION: "99.0.0",
        },
      }),
    /DEVELOPMENT_OVERRIDE_ACK=true/,
  );
  assert.equal(
    new DesktopOwnerIpcClient({
      env: {
        CODEX_DESKTOP_OWNER_IPC_ENABLED: "true",
        CODEX_DESKTOP_EXPECTED_VERSION: "99.0.0",
        CODEX_DESKTOP_DEVELOPMENT_OVERRIDE_ACK: "true",
      },
    }).expectedVersion,
    "99.0.0",
  );
});

test("user-message text extraction accepts only explicit text schema variants", () => {
  const marker = "AICHAT_CONNECTOR_TASK_MARKER_TEST";
  const accepted = [
    [{ type: "userMessage", text: marker }, [marker]],
    [{ type: "userMessage", content: marker }, [marker]],
    [
      { type: "userMessage", content: { type: "text", text: marker, text_elements: [] } },
      [marker],
    ],
    [
      {
        type: "userMessage",
        content: [{ type: "text", text: marker, text_elements: [] }],
      },
      [marker],
    ],
    [
      {
        type: "userMessage",
        content: [
          { type: "text", text: "AICHAT_CONNECTOR_" },
          { type: "text", text: "TASK_MARKER_TEST", text_elements: [] },
        ],
      },
      ["AICHAT_CONNECTOR_", "TASK_MARKER_TEST"],
    ],
    [
      { type: "userMessage", text: `before\r\n${marker}`, content: `before\n${marker}` },
      [`before\n${marker}`],
    ],
  ];
  for (const [item, expected] of accepted) {
    assert.deepEqual(extractUserMessageTextSegments(item), expected);
  }

  const rejected = [
    null,
    [],
    { type: "agentMessage", text: marker },
    { type: "commandExecution", content: marker },
    { type: "userMessage" },
    { type: "userMessage", text: null },
    { type: "userMessage", text: { nested: marker } },
    { type: "userMessage", content: null },
    { type: "userMessage", content: [] },
    { type: "userMessage", content: [[{ type: "text", text: marker }]] },
    { type: "userMessage", content: { type: "image", url: marker } },
    { type: "userMessage", content: [{ type: "image", url: marker }] },
    { type: "userMessage", content: [{ type: "input_text", text: marker }] },
    { type: "userMessage", content: [{ type: "text", text: { nested: marker } }] },
    { type: "userMessage", content: [{ type: "text", text: marker, future: true }] },
    { type: "userMessage", content: [{ type: "text", text: marker, text_elements: {} }] },
    {
      type: "userMessage",
      content: [
        { type: "text", text: marker },
        { type: "image", url: "https://example.test/image" },
      ],
    },
    { type: "userMessage", text: marker, content: `different\n${marker}` },
    {
      type: "userMessage",
      text: marker,
      content: [
        { type: "text", text: marker },
        { type: "text", text: "" },
      ],
    },
    { type: "userMessage", text: marker, content: [{ type: "image", url: marker }] },
  ];
  for (const item of rejected) assert.equal(extractUserMessageTextSegments(item), null);
});

test("app-server marker scan remains exact, user-only, and fail-closed across turns", async (t) => {
  const marker = "AICHAT_CONNECTOR_TASK_MARKER_BOUNDARY_TEST";
  const passCases = [
    ["legacy text", [{ status: "completed", items: [{ type: "userMessage", text: marker }] }]],
    [
      "content string with CR line ending",
      [{ status: "completed", items: [{ type: "userMessage", content: `before\r${marker}\rafter` }] }],
    ],
    [
      "current content blocks with CRLF line ending",
      [
        { status: "completed", items: [{ type: "userMessage", content: "unrelated" }] },
        {
          status: "completed",
          items: [
            {
              type: "userMessage",
              content: [
                { type: "text", text: `before\r\n${marker}`, text_elements: [] },
                { type: "text", text: "\r\nafter", text_elements: [] },
              ],
            },
          ],
        },
      ],
    ],
  ];
  for (const [name, turns] of passCases) {
    await t.test(name, async () => {
      const driver = markerPreflightDriver(marker, turns);
      await driver.start({ binding, onOutboundReply: async () => {} });
      await driver.stop();
    });
  }

  const failCases = [
    ["empty turns", []],
    ["malformed turns", { future: true }],
    ["empty user message", [{ status: "completed", items: [{ type: "userMessage", content: [] }] }]],
    [
      "assistant and tool injection",
      [
        {
          status: "completed",
          items: [
            { type: "agentMessage", text: marker },
            { type: "commandExecution", aggregatedOutput: marker },
            { type: "mcpToolCall", result: { content: marker } },
            { type: "outputSchema", content: marker },
          ],
          metadata: { marker },
        },
      ],
    ],
    [
      "substring",
      [{ status: "completed", items: [{ type: "userMessage", content: `prefix ${marker} suffix` }] }],
    ],
    [
      "unicode line separator",
      [{ status: "completed", items: [{ type: "userMessage", content: `before\u2028${marker}` }] }],
    ],
    [
      "zero width prefix",
      [{ status: "completed", items: [{ type: "userMessage", content: `\u200b${marker}` }] }],
    ],
    [
      "non-breaking-space suffix",
      [{ status: "completed", items: [{ type: "userMessage", content: `${marker}\u00a0` }] }],
    ],
    [
      "unknown content block invalidates whole user item",
      [
        {
          status: "completed",
          items: [
            {
              type: "userMessage",
              content: [
                { type: "text", text: marker, text_elements: [] },
                { type: "image", url: "https://example.test/image" },
              ],
            },
          ],
        },
      ],
    ],
    [
      "marker split across text blocks",
      [
        {
          status: "completed",
          items: [
            {
              type: "userMessage",
              content: [
                { type: "text", text: "AICHAT_CONNECTOR_TASK_MARKER_" },
                { type: "text", text: "BOUNDARY_TEST" },
              ],
            },
          ],
        },
      ],
    ],
  ];
  for (const [name, turns] of failCases) {
    await t.test(name, async () => {
      const driver = markerPreflightDriver(marker, turns);
      await assert.rejects(
        () => driver.start({ binding, onOutboundReply: async () => {} }),
        /does not contain.*connector marker/,
      );
      await driver.stop();
    });
  }

  await t.test("unicode composed and decomposed forms remain distinct", async () => {
    const composedMarker = "AICHAT_CONNECTOR_TASK_MARKER_\u00c9_TEST";
    const driver = markerPreflightDriver(composedMarker, [
      {
        status: "completed",
        items: [
          {
            type: "userMessage",
            content: "AICHAT_CONNECTOR_TASK_MARKER_E\u0301_TEST",
          },
        ],
      },
    ]);
    await assert.rejects(
      () => driver.start({ binding, onOutboundReply: async () => {} }),
      /does not contain.*connector marker/,
    );
    await driver.stop();
  });
});

test("app-server verifies the dedicated marker and applies fixed low-privilege turn policy", async () => {
  const marker = "AICHAT_CONNECTOR_TASK_MARKER_TEST";
  const protocol = [];
  let childArgs;
  const process = fakeAppServer((message, child) => {
    protocol.push(message);
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/read") {
      child.respond(message.id, {
        thread: {
          id: "thread-1",
          turns: [
            {
              id: "setup-turn",
              status: "completed",
              items: [
                {
                  type: "userMessage",
                  content: [{ type: "text", text: marker, text_elements: [] }],
                },
              ],
            },
          ],
        },
      });
    } else if (message.method === "thread/resume") {
      child.respond(message.id, { thread: { id: "thread-1" } });
    } else if (message.method === "turn/start") {
      child.respond(message.id, { turn: { id: "turn-safe", status: "inProgress" } });
    }
  });
  const driver = new AppServerDriver({
    binding,
    env: {
      CODEX_CONNECTOR_TASK_MARKER: marker,
      CODEX_APP_SERVER_CWD: "/tmp",
      CODEX_APP_SERVER_APPROVAL_POLICY: "never",
      CODEX_APP_SERVER_SANDBOX_POLICY_JSON: JSON.stringify({
        type: "readOnly",
        networkAccess: false,
      }),
    },
    spawnImpl: (_binary, args) => {
      childArgs = args;
      return process;
    },
    receiptStore: memoryReceiptStore(),
    logger: { error() {} },
  });
  await driver.start({ binding, onOutboundReply: async () => {} });
  const receipt = await driver.deliver(deliveryRequest());
  assert.equal(receipt.turnId, "turn-safe");
  const start = protocol.find((message) => message.method === "turn/start");
  assert.equal(start.params.cwd, "/tmp");
  assert.equal(start.params.approvalPolicy, "never");
  assert.deepEqual(start.params.sandboxPolicy, { type: "readOnly", networkAccess: false });
  assert.ok(childArgs.includes("mcp_servers={}"));
  assert.ok(childArgs.includes("plugins={}"));
  await driver.stop();
});

test("app-server rejects a task marker embedded inside a larger line", async () => {
  const marker = "AICHAT_CONNECTOR_TASK_MARKER_EXACT_TEST";
  const process = fakeAppServer((message, child) => {
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/read") {
      child.respond(message.id, {
        thread: {
          id: "thread-1",
          turns: [
            {
              id: "setup-turn",
              status: "completed",
              items: [{ type: "userMessage", text: `prefix ${marker} suffix` }],
            },
          ],
        },
      });
    }
  });
  const driver = new AppServerDriver({
    binding,
    env: {
      CODEX_CONNECTOR_TASK_MARKER: marker,
      CODEX_APP_SERVER_CWD: "/tmp",
      CODEX_APP_SERVER_APPROVAL_POLICY: "never",
      CODEX_APP_SERVER_SANDBOX_POLICY_JSON: JSON.stringify({
        type: "readOnly",
        networkAccess: false,
      }),
    },
    spawnImpl: () => process,
    receiptStore: memoryReceiptStore(),
    logger: { error() {} },
  });
  await assert.rejects(
    () => driver.start({ binding, onOutboundReply: async () => {} }),
    /does not contain.*connector marker/,
  );
  await driver.stop();
});

test("AppServerReceiptStore migrates v1 receipts to fail-closed durable v3 records", async () => {
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
  assert.equal(loaded.records[0].sourceMessageType, null);
  assert.equal(loaded.records[0].replyEligible, false);
  await store.save(binding, loaded);
  assert.equal(JSON.parse(await readFile(path, "utf8")).version, 3);
});

test("AppServerReceiptStore loads v2 outbound records as reply-ineligible without replay", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-app-server-v2-state-"));
  const path = join(directory, "receipts.json");
  const legacy = acceptedRecord({
    phase: "completed",
    completionStatus: "completed",
    outboundEvent: {
      modelDeclared: true,
      eventId: `app-server-event-${createHash("sha256")
        .update("delivery-1\0turn-1")
        .digest("hex")}`,
      threadId: "thread-1",
      hostId: null,
      sourceMessageId: "message-1",
      deliveryId: "delivery-1",
      text: "legacy result",
      messageType: "result",
      references: [],
    },
    outboundDelivered: false,
    outboundBlocked: false,
    connectorCheckpointed: true,
  });
  delete legacy.sourceMessageType;
  delete legacy.replyEligible;
  await writeFile(path, JSON.stringify({ version: 2, binding, records: [legacy] }));
  const loaded = await new AppServerReceiptStore(path).load(binding);
  assert.equal(loaded.records[0].sourceMessageType, null);
  assert.equal(loaded.records[0].replyEligible, false);
  assert.equal(loaded.records[0].outboundEvent, null);
  assert.equal(loaded.records[0].outboundDelivered, false);
});

test("driver refuses receipt state above capacity instead of evicting incomplete records", async () => {
  const records = Array.from({ length: 1_001 }, (_, index) =>
    acceptedRecord({
      deliveryId: `delivery-${index}`,
      sourceMessageId: `message-${index}`,
      turnId: `turn-${index}`,
    }),
  );
  const driver = new AppServerDriver({
    binding,
    env: {},
    spawnImpl: () => {
      throw new Error("must not spawn");
    },
    receiptStore: memoryReceiptStore({ records }),
  });
  await assert.rejects(
    () => driver.start({ binding, onOutboundReply: async () => {} }),
    /exceeds 1000/,
  );
});

test("driver does not evict checkpointed receipts whose outbound event was only blocked", async () => {
  const records = Array.from({ length: 1_000 }, (_, index) =>
    blockedCompletedRecord(index),
  );
  const process = fakeAppServer((message, child) => {
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/resume") {
      child.respond(message.id, { thread: { id: "thread-1" } });
    }
  });
  const driver = new AppServerDriver({
    binding,
    env: {},
    spawnImpl: () => process,
    receiptStore: memoryReceiptStore({ records }),
    logger: { error() {} },
  });
  await driver.start({ binding, onOutboundReply: async () => {} });
  await assert.rejects(
    () => driver.deliver(deliveryRequest({ deliveryId: "delivery-over-capacity" })),
    (error) => error.code === "AICHAT_DRIVER_RECEIPT_CAPACITY",
  );
  await driver.stop();
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

test("Desktop owner IPC revalidates the Desktop build before reconnecting after a runtime upgrade", async (t) => {
  if (process.platform !== "darwin") return t.skip("Desktop owner IPC is macOS-only");
  const directory = await mkdtemp(join(tmpdir(), "aichat-owner-upgrade-"));
  const appPath = join(directory, "ChatGPT.app");
  const socketPath = join(directory, "ipc.sock");
  await writeDesktopVersion(appPath, "26.730.61639");
  let connectionCount = 0;
  let serverSocket;
  const server = createServer((socket) => {
    connectionCount += 1;
    serverSocket = socket;
    readOwnerFrames(socket, (message) => {
      if (message.type === "request" && message.method === "initialize") {
        writeOwnerFrame(socket, {
          type: "response",
          requestId: message.requestId,
          resultType: "success",
          method: "initialize",
          result: { clientId: `client-${connectionCount}` },
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
      CODEX_DESKTOP_IPC_RECONNECT_DELAY_MS: "100",
    },
    timers,
    logger: { error() {} },
  });
  await client.start({ threadId: "thread-1" });
  assert.equal(connectionCount, 1);

  serverSocket.destroy();
  await waitFor(() => client.socket === null);
  await writeDesktopVersion(appPath, "99.0.0");
  timers.fireFirst(100);
  await waitFor(() => client.featureEnabled === false);
  assert.equal(connectionCount, 1);
  await assert.rejects(
    () =>
      client.startTurn({
        threadId: "thread-1",
        envelope: deliveryRequest().envelope,
        deliveryId: "delivery-after-upgrade",
      }),
    /feature is disabled/,
  );

  await client.stop();
  await new Promise((resolve) => server.close(resolve));
});

test("Desktop owner IPC revalidates socket mode on restart before opening a new peer", async (t) => {
  if (process.platform !== "darwin") return t.skip("Desktop owner IPC is macOS-only");
  const directory = await mkdtemp(join(tmpdir(), "aichat-owner-restart-"));
  const appPath = join(directory, "ChatGPT.app");
  const socketPath = join(directory, "ipc.sock");
  await writeDesktopVersion(appPath, "26.730.61639");
  let connectionCount = 0;
  let serverSocket;
  const server = createServer((socket) => {
    connectionCount += 1;
    serverSocket = socket;
    readOwnerFrames(socket, (message) => {
      if (message.type === "request" && message.method === "initialize") {
        writeOwnerFrame(socket, {
          type: "response",
          requestId: message.requestId,
          resultType: "success",
          method: "initialize",
          result: { clientId: `client-${connectionCount}` },
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
      CODEX_DESKTOP_IPC_RECONNECT_DELAY_MS: "100",
    },
    timers,
    logger: { error() {} },
  });
  await client.start({ threadId: "thread-1" });
  serverSocket.destroy();
  await waitFor(() => client.socket === null);

  await chmod(socketPath, 0o666);
  await assert.rejects(
    () =>
      client.startTurn({
        threadId: "thread-1",
        envelope: deliveryRequest().envelope,
        deliveryId: "delivery-insecure-socket",
      }),
    (error) => error.outcome === "pre-send",
  );
  assert.equal(connectionCount, 1);

  await chmod(socketPath, 0o600);
  await client.start({ threadId: "thread-1" });
  assert.equal(connectionCount, 2);
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
      '{"aichat_reply":{"text":"ok","message_type":"result","references":[]}}',
    ),
    { text: "ok", messageType: "result", references: [] },
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
    metadata: { messageType: "request" },
    ...overrides,
  };
}

function ambiguousRecord(overrides = {}) {
  return {
    deliveryId: "delivery-1",
    sourceMessageId: "message-1",
    sourceMessageType: "request",
    replyEligible: true,
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

function blockedCompletedRecord(index) {
  const suffix = String(index).padStart(4, "0");
  const deliveryId = `blocked-delivery-${suffix}`;
  const sourceMessageId = `blocked-message-${suffix}`;
  const turnId = `blocked-turn-${suffix}`;
  return acceptedRecord({
    deliveryId,
    sourceMessageId,
    turnId,
    phase: "completed",
    completionStatus: "completed",
    outboundEvent: {
      systemGenerated: true,
      eventId: `app-server-status-${createHash("sha256").update(deliveryId).digest("hex")}`,
      threadId: "thread-1",
      hostId: null,
      sourceMessageId,
      deliveryId,
      text: JSON.stringify({ status: "blocked" }),
      messageType: "status",
      references: [],
    },
    outboundDelivered: false,
    outboundBlocked: true,
    connectorCheckpointed: true,
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

function markerPreflightDriver(marker, turns) {
  const process = fakeAppServer((message, child) => {
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/read") {
      child.respond(message.id, { thread: { id: "thread-1", turns } });
    }
  });
  return new AppServerDriver({
    binding,
    env: {
      CODEX_CONNECTOR_TASK_MARKER: marker,
      CODEX_APP_SERVER_CWD: "/tmp",
      CODEX_APP_SERVER_APPROVAL_POLICY: "never",
      CODEX_APP_SERVER_SANDBOX_POLICY_JSON: JSON.stringify({
        type: "readOnly",
        networkAccess: false,
      }),
    },
    spawnImpl: () => process,
    receiptStore: memoryReceiptStore(),
    logger: { error() {} },
  });
}

function acknowledgementRaceHarness() {
  let childProcess;
  let turnStarted = false;
  const process = fakeAppServer((message, child) => {
    childProcess = child;
    if (message.method === "initialize") child.respond(message.id, {});
    else if (message.method === "thread/resume") {
      child.respond(message.id, { thread: { id: "thread-1" } });
    } else if (message.method === "turn/start") {
      turnStarted = true;
      child.respond(message.id, { turn: { id: "turn-race", status: "inProgress" } });
    }
  });
  const store = memoryReceiptStore();
  const outbound = [];
  const driver = new AppServerDriver({
    binding,
    env: {},
    spawnImpl: () => process,
    receiptStore: store,
    logger: { error() {} },
  });
  return {
    driver,
    store,
    outbound,
    complete() {
      assert.equal(turnStarted, true);
      childProcess.notify("item/completed", {
        threadId: "thread-1",
        turnId: "turn-race",
        item: {
          type: "agentMessage",
          text: JSON.stringify({
            aichat_reply: {
              text: "Race result",
              message_type: "result",
              references: [],
            },
          }),
        },
      });
      childProcess.notify("turn/completed", {
        threadId: "thread-1",
        turn: { id: "turn-race", status: "completed" },
      });
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

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

async function writeDesktopVersion(appPath, version) {
  await mkdir(join(appPath, "Contents"), { recursive: true });
  await writeFile(
    join(appPath, "Contents", "Info.plist"),
    `<?xml version="1.0"?><plist><dict><key>CFBundleShortVersionString</key><string>${version}</string></dict></plist>`,
  );
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
