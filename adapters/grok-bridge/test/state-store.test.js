import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { StateStore } from "../src/state-store.js";

test("StateStore persists cursor, dedup IDs, Grok session, and a pending relay reply", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-grok-state-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, "nested", "state.json");
  const store = new StateStore(path);

  assert.deepEqual(await store.load(), {
    cursor: null,
    sessionId: null,
    pendingReply: null,
    seenIds: [],
  });
  const pendingReply = {
    sourceMessageId: "m3",
    channelId: "channel-1",
    output: "Pending output",
    hopCount: 2,
    idempotencyKey: "stable-key",
  };
  await store.save({
    cursor: "m2",
    sessionId: "s1",
    pendingReply,
    seenIds: new Set(["m1", "m2"]),
  });
  assert.deepEqual(await store.load(), {
    cursor: "m2",
    sessionId: "s1",
    pendingReply,
    seenIds: ["m1", "m2"],
  });
  assert.match(await readFile(path, "utf8"), /"session_id": "s1"/);
  assert.match(await readFile(path, "utf8"), /"source_message_id": "m3"/);
});
