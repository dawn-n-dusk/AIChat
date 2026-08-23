import assert from "node:assert/strict";
import test from "node:test";

import { AIChatClaudeBridge, toChannelNotification } from "../src/bridge.js";

function message(overrides = {}) {
  return {
    id: "message-1",
    channel_id: "channel-1",
    sender_id: "agent-remote",
    type: "request",
    text: "Review this change",
    reply_to: null,
    references: [],
    hop_count: 0,
    created_at: "2026-08-24T00:00:00Z",
    ...overrides,
  };
}

function harness(items) {
  const notifications = [];
  const sent = [];
  const saved = [];
  const relay = {
    async whoAmI() {
      return { agent_id: "agent-self" };
    },
    async listMessages() {
      return { items, next_after: items.at(-1)?.id ?? null };
    },
    async sendMessage(payload) {
      sent.push(payload);
      return { id: "outbound-1", ...payload };
    },
  };
  const stateStore = {
    async load() {
      return { cursor: null, seenIds: [] };
    },
    async save(value) {
      saved.push({ cursor: value.cursor, seenIds: [...value.seenIds] });
    },
  };
  const config = {
    channelId: "channel-1",
    allowedSenderIds: new Set(["agent-remote"]),
    deliverTypes: new Set(["text", "request"]),
    pageLimit: 100,
    pollIntervalMs: 1,
  };
  const bridge = new AIChatClaudeBridge({
    config,
    relay,
    stateStore,
    notify: async (value) => notifications.push(value),
    logger: { error() {} },
  });
  return { bridge, notifications, sent, saved };
}

test("delivers an allowed remote request with an explicit untrusted warning", async () => {
  const ctx = harness([message()]);
  await ctx.bridge.initialize();
  await ctx.bridge.pollOnce();

  assert.equal(ctx.notifications.length, 1);
  assert.equal(ctx.notifications[0].method, "notifications/claude/channel");
  assert.match(ctx.notifications[0].params.content, /UNTRUSTED REMOTE AICHAT MESSAGE/);
  assert.equal(ctx.notifications[0].params.meta.message_id, "message-1");
  assert.equal(ctx.saved.at(-1).cursor, "message-1");
});

test("self, disallowed sender, wrong channel, status, result, and duplicate do not notify", async () => {
  const ctx = harness([
    message({ id: "self", sender_id: "agent-self" }),
    message({ id: "blocked", sender_id: "agent-other" }),
    message({ id: "other-channel", channel_id: "channel-other" }),
    message({ id: "status", type: "status" }),
    message({ id: "result", type: "result" }),
    message({ id: "status", type: "request" }),
  ]);
  await ctx.bridge.initialize();
  await ctx.bridge.pollOnce();

  assert.equal(ctx.notifications.length, 0);
  assert.equal(ctx.saved.at(-1).cursor, "status");
});

test("reply is gated to a delivered inbound message and fixed channel", async () => {
  const ctx = harness([message()]);
  await ctx.bridge.initialize();

  await assert.rejects(
    () => ctx.bridge.reply({ replyTo: "invented", text: "No" }),
    /not delivered to this Claude session/,
  );

  await ctx.bridge.pollOnce();
  const response = await ctx.bridge.reply({ replyTo: "message-1", text: "Done" });
  assert.equal(response.id, "outbound-1");
  assert.equal(ctx.sent[0].channelId, "channel-1");
  assert.equal(ctx.sent[0].replyTo, "message-1");
  assert.equal(ctx.sent[0].hopCount, 1);
  assert.match(ctx.sent[0].idempotencyKey, /^claude-channel-reply-[a-f0-9]{64}$/);

  await ctx.bridge.reply({ replyTo: "message-1", text: "Done" });
  assert.equal(ctx.sent[0].idempotencyKey, ctx.sent[1].idempotencyKey);
});

test("reply refuses to exceed the relay hop limit", async () => {
  const ctx = harness([message({ hop_count: 8 })]);
  await ctx.bridge.initialize();
  await ctx.bridge.pollOnce();
  await assert.rejects(
    () => ctx.bridge.reply({ replyTo: "message-1", text: "Loop" }),
    /hop_count limit/,
  );
  assert.equal(ctx.sent.length, 0);
});

test("notification metadata uses channel-compatible identifier keys", () => {
  const value = toChannelNotification(message({ references: ["https://example.test/run/1"] }));
  assert.deepEqual(Object.keys(value.params.meta), [
    "message_id",
    "channel_id",
    "sender_id",
    "message_type",
    "hop_count",
    "created_at",
  ]);
  assert.match(value.params.content, /unverified/);
});

test("invalid relay hop counts are rejected before notification", async () => {
  for (const hop_count of [-1, 9]) {
    const ctx = harness([message({ hop_count })]);
    await ctx.bridge.initialize();
    await assert.rejects(() => ctx.bridge.pollOnce(), /from 0 through 8/);
    assert.equal(ctx.notifications.length, 0);
  }
});
