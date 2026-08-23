import { chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

const MAX_SEEN_IDS = 1_000;

export class StateStore {
  constructor(path) {
    this.path = path;
  }

  async load() {
    try {
      const parsed = JSON.parse(await readFile(this.path, "utf8"));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error("state must be a JSON object");
      }
      return {
        cursor: nonEmptyString(parsed.cursor),
        sessionId: nonEmptyString(parsed.session_id),
        pendingReply: parsePendingReply(parsed.pending_reply),
        seenIds: Array.isArray(parsed.seen_ids)
          ? parsed.seen_ids.filter((item) => typeof item === "string" && item).slice(-MAX_SEEN_IDS)
          : [],
      };
    } catch (error) {
      if (error?.code === "ENOENT") {
        return { cursor: null, sessionId: null, pendingReply: null, seenIds: [] };
      }
      throw new Error(`Cannot read Grok bridge state at ${this.path}: ${error.message}`);
    }
  }

  async save({ cursor, sessionId, pendingReply, seenIds }) {
    const directory = dirname(this.path);
    const temporary = `${this.path}.${process.pid}.tmp`;
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const payload = `${JSON.stringify(
      {
        version: 2,
        cursor,
        session_id: sessionId,
        pending_reply: pendingReply
          ? {
              source_message_id: pendingReply.sourceMessageId,
              channel_id: pendingReply.channelId,
              output: pendingReply.output,
              hop_count: pendingReply.hopCount,
              idempotency_key: pendingReply.idempotencyKey,
            }
          : null,
        seen_ids: [...seenIds].slice(-MAX_SEEN_IDS),
      },
      null,
      2,
    )}\n`;
    try {
      await writeFile(temporary, payload, { encoding: "utf8", mode: 0o600 });
      await rename(temporary, this.path);
      if (process.platform !== "win32") await chmod(this.path, 0o600);
    } catch (error) {
      await unlink(temporary).catch(() => {});
      throw new Error(`Cannot persist Grok bridge state at ${this.path}: ${error.message}`);
    }
  }
}

function nonEmptyString(value) {
  return typeof value === "string" && value ? value : null;
}

function parsePendingReply(value) {
  if (value == null) return null;
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("pending_reply must be an object or null");
  }
  const sourceMessageId = nonEmptyString(value.source_message_id);
  const channelId = nonEmptyString(value.channel_id);
  const output = nonEmptyString(value.output);
  const idempotencyKey = nonEmptyString(value.idempotency_key);
  const hopCount = value.hop_count;
  if (!sourceMessageId || !channelId || !output || !idempotencyKey) {
    throw new Error("pending_reply is missing a required string field");
  }
  if (!Number.isInteger(hopCount) || hopCount < 1 || hopCount > 8) {
    throw new Error("pending_reply hop_count must be an integer from 1 through 8");
  }
  return { sourceMessageId, channelId, output, hopCount, idempotencyKey };
}
