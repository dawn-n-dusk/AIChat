import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { StateStore } from "../src/state-store.js";

test("StateStore atomically round-trips cursor and seen IDs", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-channel-"));
  const path = join(directory, "nested", "cursor.json");
  const store = new StateStore(path);

  assert.deepEqual(await store.load(), { cursor: null, seenIds: [] });
  await store.save({ cursor: "message-2", seenIds: new Set(["message-1", "message-2"]) });
  assert.deepEqual(await store.load(), {
    cursor: "message-2",
    seenIds: ["message-1", "message-2"],
  });
  assert.match(await readFile(path, "utf8"), /"version": 1/);
  if (process.platform !== "win32") {
    assert.equal((await stat(path)).mode & 0o777, 0o600);
  }
});
