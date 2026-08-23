import assert from "node:assert/strict";
import test from "node:test";

import { RelayClient } from "../src/relay-client.js";

test("RelayClient posts a text reply with the fixed channel fields", async () => {
  const calls = [];
  const client = new RelayClient({
    server: "https://relay.example.test",
    token: "secret-token",
    requestTimeoutMs: 1_000,
    async fetchImpl(url, options) {
      calls.push({ url, options });
      return new Response(JSON.stringify({ id: "outbound-1" }), {
        status: 201,
        headers: { "Content-Type": "application/json" },
      });
    },
  });

  await client.sendMessage({
    channelId: "channel-1",
    text: "Done",
    replyTo: "message-1",
    idempotencyKey: "stable-key",
    hopCount: 2,
  });
  assert.equal(calls[0].url, "https://relay.example.test/v1/messages");
  assert.equal(calls[0].options.headers.Authorization, "Bearer secret-token");
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    channel_id: "channel-1",
    type: "text",
    text: "Done",
    reply_to: "message-1",
    idempotency_key: "stable-key",
    hop_count: 2,
  });
});

test("RelayClient redacts its bearer token from transport errors", async () => {
  const client = new RelayClient({
    server: "https://relay.example.test",
    token: "secret-token",
    requestTimeoutMs: 1_000,
    async fetchImpl() {
      throw new Error("failed with secret-token");
    },
  });
  await assert.rejects(
    () => client.whoAmI(),
    (error) => error.message.includes("[REDACTED]") && !error.message.includes("secret-token"),
  );
});
