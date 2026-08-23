import assert from "node:assert/strict";
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { StateStore } from "../src/state-store.js";

test("StateStore round-trips cursor, deduplication, receipts, and pending outbound atomically", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-codex-state-"));
  const path = join(directory, "nested", "state.json");
  const store = new StateStore(path);
  assert.deepEqual(await store.load(), {
    cursor: null,
    seenIds: [],
    outboundSeenIds: [],
    receipts: [],
    pendingOutbound: null,
  });

  await store.save({
    cursor: "message-1",
    seenIds: new Set(["message-1"]),
    outboundSeenIds: new Set(["event-1"]),
    receipts: new Map([
      [
        "message-1",
        {
          sourceMessageId: "message-1",
          deliveryId: "delivery-1",
          senderId: "agent-remote",
          hopCount: 0,
          replied: false,
          outboundMessageId: null,
          acceptedAt: "2026-08-24T00:00:00Z",
        },
      ],
    ]),
    pendingOutbound: {
      eventId: "event-1",
      sourceMessageId: "message-1",
      deliveryId: "delivery-1",
      channelId: "channel-1",
      text: "reply",
      messageType: "result",
      references: ["https://example.test/result"],
      hopCount: 1,
      idempotencyKey: "stable-key",
    },
  });

  const loaded = await store.load();
  assert.equal(loaded.cursor, "message-1");
  assert.deepEqual(loaded.seenIds, ["message-1"]);
  assert.equal(loaded.receipts[0].deliveryId, "delivery-1");
  assert.equal(loaded.pendingOutbound.idempotencyKey, "stable-key");
  if (process.platform !== "win32") assert.equal((await stat(path)).mode & 0o777, 0o600);
  assert.equal(JSON.parse(await readFile(path, "utf8")).version, 1);
});

test("StateStore fails closed on malformed persisted state", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-codex-state-bad-"));
  const path = join(directory, "state.json");
  await writeFile(path, '{"delivery_receipts":[{"replied":true}]}');
  await assert.rejects(() => new StateStore(path).load(), /Cannot read Codex connector state/);
});
