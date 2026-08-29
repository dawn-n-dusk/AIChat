import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";

import { ConnectorRuntime, isRelevantWakeEvent } from "../src/runtime.js";

class FakeWebSocket extends EventEmitter {
  static instances = [];

  constructor(url) {
    super();
    this.url = url;
    this.closed = false;
    FakeWebSocket.instances.push(this);
  }

  close() {
    this.closed = true;
    this.emit("close");
  }
}

function manualTimers() {
  return {
    interval: null,
    timeout: null,
    setInterval(fn) {
      this.interval = fn;
      return { type: "interval" };
    },
    clearInterval() {
      this.interval = null;
    },
    setTimeout(fn) {
      this.timeout = fn;
      return { type: "timeout" };
    },
    clearTimeout() {
      this.timeout = null;
    },
  };
}

test("runtime uses WebSocket only as a wake signal for serialized ordered recovery", async () => {
  FakeWebSocket.instances.length = 0;
  let initialized = 0;
  let recovered = 0;
  let stopped = 0;
  let stopOptions = null;
  const connector = {
    async initialize() {
      initialized += 1;
    },
    async requestRecovery() {
      recovered += 1;
    },
    async stop(options) {
      stopped += 1;
      stopOptions = options;
    },
  };
  const timers = manualTimers();
  const runtime = new ConnectorRuntime({
    config: {
      channelId: "channel-1",
      websocketEnabled: true,
      recoveryIntervalMs: 30_000,
      reconnectDelayMs: 2_000,
    },
    relay: { websocketUrl: () => "ws://relay.test/v1/ws?token=secret" },
    connector,
    WebSocketImpl: FakeWebSocket,
    timers,
    logger: { error() {} },
  });
  await runtime.start();
  assert.equal(initialized, 1);
  assert.equal(recovered, 1);
  const socket = FakeWebSocket.instances[0];
  socket.emit("open");
  await tick();
  assert.equal(recovered, 2);

  socket.emit("message", "not-json");
  socket.emit(
    "message",
    JSON.stringify({ event: "message.created", message: { id: "m-x", channel_id: "other" } }),
  );
  await tick();
  assert.equal(recovered, 2);
  socket.emit(
    "message",
    Buffer.from(
      JSON.stringify({
        event: "message.created",
        message: { id: "message-1", channel_id: "channel-1" },
      }),
    ),
  );
  await tick();
  assert.equal(recovered, 3);

  await timers.interval();
  assert.equal(recovered, 4);
  socket.emit("close");
  assert.equal(typeof timers.timeout, "function");
  timers.timeout();
  assert.equal(FakeWebSocket.instances.length, 2);
  await runtime.stop({ drain: true });
  assert.equal(stopped, 1);
  assert.deepEqual(stopOptions, { drain: true });
});

test("runtime never logs token-bearing WebSocket constructor errors", async () => {
  const secret = "secret-token";
  const logs = [];
  class ThrowingWebSocket {
    constructor(url) {
      throw new Error(`cannot connect ${url}`);
    }
  }
  const timers = manualTimers();
  const runtime = new ConnectorRuntime({
    config: {
      channelId: "channel-1",
      websocketEnabled: true,
      recoveryIntervalMs: 30_000,
      reconnectDelayMs: 2_000,
    },
    relay: { websocketUrl: () => `ws://relay.test/v1/ws?token=${secret}` },
    connector: {
      async initialize() {},
      async requestRecovery() {},
      async stop() {},
    },
    WebSocketImpl: ThrowingWebSocket,
    timers,
    logger: { error(value) { logs.push(value); } },
  });
  await runtime.start();
  assert.ok(logs.length > 0);
  assert.equal(logs.join("\n").includes(secret), false);
  await runtime.stop();
});

test("isRelevantWakeEvent validates event, channel, and message identity", () => {
  assert.equal(
    isRelevantWakeEvent(
      JSON.stringify({ event: "message.created", message: { id: "m", channel_id: "c" } }),
      "c",
    ),
    true,
  );
  assert.equal(isRelevantWakeEvent("{}", "c"), false);
  assert.equal(
    isRelevantWakeEvent(
      JSON.stringify({ event: "message.created", message: { id: "", channel_id: "c" } }),
      "c",
    ),
    false,
  );
});

function tick() {
  return new Promise((resolve) => setImmediate(resolve));
}
