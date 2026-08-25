import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
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
    pendingStatuses: [],
    blockedOutbound: [],
    turnBudget: [],
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
    pendingStatuses: [],
    blockedOutbound: [
      {
        eventId: "blocked-1",
        sourceMessageId: "message-1",
        deliveryId: "delivery-1",
        channelId: "channel-1",
        text: "blocked reply",
        messageType: "result",
        references: [],
        hopCount: 1,
        idempotencyKey: "blocked-key",
        blockedAt: "2026-08-24T00:01:00Z",
        reasonCode: "AICHAT_OUTBOUND_DLP",
      },
    ],
    turnBudget: [
      {
        messageId: "message-1",
        senderId: "agent-remote",
        startedAt: "2026-08-24T00:00:00Z",
      },
    ],
  });

  const loaded = await store.load();
  assert.equal(loaded.cursor, "message-1");
  assert.deepEqual(loaded.seenIds, ["message-1"]);
  assert.equal(loaded.receipts[0].deliveryId, "delivery-1");
  assert.equal(loaded.pendingOutbound.idempotencyKey, "stable-key");
  assert.equal(loaded.blockedOutbound[0].reasonCode, "AICHAT_OUTBOUND_DLP");
  if (process.platform !== "win32") assert.equal((await stat(path)).mode & 0o777, 0o600);
  assert.equal(loaded.turnBudget[0].senderId, "agent-remote");
  assert.equal(JSON.parse(await readFile(path, "utf8")).version, 4);
});

test("StateStore fails closed on malformed persisted state", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-codex-state-bad-"));
  const path = join(directory, "state.json");
  await writeFile(path, '{"delivery_receipts":[{"replied":true}]}');
  await assert.rejects(() => new StateStore(path).load(), /Cannot read Codex connector state/);
});

test("StateStore accepts version 1 receipts and rejects unknown future versions", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-codex-state-version-"));
  const path = join(directory, "state.json");
  await writeFile(
    path,
    JSON.stringify({ version: 1, delivery_receipts: [storedReceipt(1, false)] }),
  );
  const migrated = await new StateStore(path).load();
  assert.equal(migrated.receipts[0].deliveryId, "delivery-1");
  assert.equal(migrated.receipts[0].outboundEventId, null);

  await writeFile(path, JSON.stringify({ version: 999, delivery_receipts: [] }));
  await assert.rejects(
    () => new StateStore(path).load(),
    /unsupported connector state version/,
  );
});

test("StateStore atomic writes preserve an existing parent directory mode", async (t) => {
  if (process.platform === "win32") return t.skip("POSIX mode check is not available");
  const directory = await mkdtemp(join(tmpdir(), "aichat-codex-state-parent-mode-"));
  const shared = join(directory, "existing-parent");
  await mkdir(shared, { mode: 0o755 });
  await chmod(shared, 0o755);
  await new StateStore(join(shared, "state.json")).save({
    cursor: null,
    seenIds: new Set(),
    outboundSeenIds: new Set(),
    receipts: new Map(),
    pendingOutbound: null,
    pendingStatuses: [],
    blockedOutbound: [],
    turnBudget: [],
  });
  assert.equal((await stat(shared)).mode & 0o777, 0o755);
});

test("StateStore never silently evicts unreplied receipts above capacity", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-codex-state-capacity-"));
  const path = join(directory, "state.json");
  const receipts = Array.from({ length: 1_001 }, (_, index) => storedReceipt(index, false));
  await writeFile(
    path,
    JSON.stringify({
      version: 3,
      delivery_receipts: receipts,
    }),
  );
  await assert.rejects(
    () => new StateStore(path).load(),
    /refusing eviction without a durable driver release/,
  );

  const store = new StateStore(join(directory, "save.json"));
  await assert.rejects(
    () =>
      store.save({
        cursor: null,
        seenIds: new Set(),
        outboundSeenIds: new Set(),
        receipts: new Map(
          receipts.map((receipt) => [
            receipt.source_message_id,
            {
              sourceMessageId: receipt.source_message_id,
              deliveryId: receipt.delivery_id,
              senderId: receipt.sender_id,
              hopCount: receipt.hop_count,
              replied: receipt.replied,
              outboundMessageId: receipt.outbound_message_id,
              acceptedAt: receipt.accepted_at,
            },
          ]),
        ),
        pendingOutbound: null,
        pendingStatuses: [],
        blockedOutbound: [],
        turnBudget: [],
      }),
    (error) => error.code === "AICHAT_RECEIPT_CAPACITY",
  );
});

test("StateStore refuses receipt eviction without a durable driver release", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-codex-state-safe-bound-"));
  const path = join(directory, "state.json");
  const receipts = Array.from({ length: 1_001 }, (_, index) => storedReceipt(index, index === 0));
  await writeFile(path, JSON.stringify({ version: 3, delivery_receipts: receipts }));
  await assert.rejects(
    () => new StateStore(path).load(),
    (error) => error.cause?.code === "AICHAT_RECEIPT_CAPACITY" || /durable driver release/.test(error.message),
  );
});

test("StateStore round-trips outbound event identity and pending driver release", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-codex-state-release-fields-"));
  const path = join(directory, "state.json");
  const receipt = {
    ...storedReceipt(1, true),
    outbound_event_id: "event-1",
    driver_release_pending: "evicted",
  };
  await writeFile(path, JSON.stringify({ version: 4, delivery_receipts: [receipt] }));
  const loaded = await new StateStore(path).load();
  assert.equal(loaded.receipts[0].outboundEventId, "event-1");
  assert.equal(loaded.receipts[0].driverReleasePending, "evicted");
});

function storedReceipt(index, replied) {
  return {
    source_message_id: `message-${index}`,
    delivery_id: `delivery-${index}`,
    sender_id: "agent-remote",
    hop_count: 0,
    replied,
    outbound_message_id: replied ? `outbound-${index}` : null,
    accepted_at: "2026-08-24T00:00:00Z",
  };
}
