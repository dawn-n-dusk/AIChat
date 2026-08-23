import assert from "node:assert/strict";
import test from "node:test";

import { RelayClient } from "../src/relay-client.js";

test("RelayClient authenticates, encodes cursors, and posts fixed relay shapes", async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return new Response(JSON.stringify({ id: "ok", items: [] }), {
      status: options.method === "POST" ? 201 : 200,
      headers: { "Content-Type": "application/json" },
    });
  };
  const client = new RelayClient({
    server: "http://relay.test",
    token: "token-value",
    requestTimeoutMs: 1_000,
    fetchImpl,
  });

  await client.listMessages({ channelId: "channel/a", after: "message?1", limit: 50 });
  await client.sendMessage({
    channelId: "channel/a",
    text: "hello",
    replyTo: "message?1",
    idempotencyKey: "key-1",
  });

  assert.match(calls[0].url, /channel_id=channel%2Fa/);
  assert.match(calls[0].url, /after=message%3F1/);
  assert.equal(calls[0].options.headers.Authorization, "Bearer token-value");
  assert.deepEqual(JSON.parse(calls[1].options.body), {
    channel_id: "channel/a",
    type: "text",
    text: "hello",
    reply_to: "message?1",
    idempotency_key: "key-1",
    hop_count: 0,
  });
});

test("RelayClient redacts the bearer token from transport errors", async () => {
  const client = new RelayClient({
    server: "http://relay.test",
    token: "very-secret-token",
    requestTimeoutMs: 1_000,
    fetchImpl: async () => {
      throw new Error("failed with very-secret-token");
    },
  });
  await assert.rejects(
    () => client.whoAmI(),
    (error) => !error.message.includes("very-secret-token") && error.message.includes("[REDACTED]"),
  );
});
