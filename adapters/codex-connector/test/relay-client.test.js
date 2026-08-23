import assert from "node:assert/strict";
import test from "node:test";

import { RelayClient } from "../src/relay-client.js";

test("RelayClient uses bearer auth, ordered cursor query, and stable outbound fields", async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    return new Response(
      JSON.stringify(url.includes("/v1/me") ? { agent_id: "agent-self" } : { id: "message-out" }),
      { status: url.includes("/v1/me") ? 200 : 201, headers: { "Content-Type": "application/json" } },
    );
  };
  const client = new RelayClient({
    server: "https://relay.test/base",
    token: "secret token",
    requestTimeoutMs: 1_000,
    fetchImpl,
  });
  assert.equal((await client.whoAmI()).agent_id, "agent-self");
  await client.listMessages({ channelId: "channel 1", after: "message-1", limit: 50 });
  await client.sendMessage({
    channelId: "channel 1",
    text: "result",
    replyTo: "message-1",
    references: ["https://example.test"],
    messageType: "result",
    idempotencyKey: "stable",
    hopCount: 2,
  });

  assert.equal(calls[0].options.headers.Authorization, "Bearer secret token");
  assert.match(calls[1].url, /channel_id=channel\+1/);
  assert.match(calls[1].url, /after=message-1/);
  assert.deepEqual(JSON.parse(calls[2].options.body), {
    channel_id: "channel 1",
    type: "result",
    text: "result",
    reply_to: "message-1",
    references: ["https://example.test"],
    idempotency_key: "stable",
    hop_count: 2,
  });
  assert.equal(client.websocketUrl(), "wss://relay.test/base/v1/ws?token=secret+token");
});

test("RelayClient redacts tokens from transport and HTTP diagnostics", async () => {
  const token = "top-secret-token";
  const network = new RelayClient({
    server: "http://relay.test",
    token,
    requestTimeoutMs: 1_000,
    fetchImpl: async () => {
      throw new Error(`failed at ws://relay.test/v1/ws?token=${token}`);
    },
  });
  await assert.rejects(
    () => network.whoAmI(),
    (error) => !error.message.includes(token) && error.message.includes("[REDACTED]"),
  );

  const http = new RelayClient({
    server: "http://relay.test",
    token,
    requestTimeoutMs: 1_000,
    fetchImpl: async () => new Response(JSON.stringify({ detail: token }), { status: 401 }),
  });
  await assert.rejects(
    () => http.whoAmI(),
    (error) => !error.message.includes(token) && error.message.includes("[REDACTED]"),
  );
});
