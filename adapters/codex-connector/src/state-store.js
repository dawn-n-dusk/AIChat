import { chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

const MAX_SEEN_IDS = 1_000;
const MAX_RECEIPTS = 1_000;

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
        cursor: optionalString(parsed.cursor),
        seenIds: parseStringArray(parsed.seen_ids).slice(-MAX_SEEN_IDS),
        outboundSeenIds: parseStringArray(parsed.outbound_seen_ids).slice(-MAX_SEEN_IDS),
        receipts: parseReceipts(parsed.delivery_receipts).slice(-MAX_RECEIPTS),
        pendingOutbound: parsePendingOutbound(parsed.pending_outbound),
      };
    } catch (error) {
      if (error?.code === "ENOENT") return emptyState();
      throw new Error(`Cannot read Codex connector state at ${this.path}: ${error.message}`);
    }
  }

  async save({ cursor, seenIds, outboundSeenIds, receipts, pendingOutbound }) {
    const directory = dirname(this.path);
    const temporary = `${this.path}.${process.pid}.tmp`;
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const payload = `${JSON.stringify(
      {
        version: 1,
        cursor,
        seen_ids: [...seenIds].slice(-MAX_SEEN_IDS),
        outbound_seen_ids: [...outboundSeenIds].slice(-MAX_SEEN_IDS),
        delivery_receipts: [...receipts.values()].slice(-MAX_RECEIPTS).map(toStoredReceipt),
        pending_outbound: pendingOutbound ? toStoredPending(pendingOutbound) : null,
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
      throw new Error(`Cannot persist Codex connector state at ${this.path}: ${error.message}`);
    }
  }
}

export function emptyState() {
  return {
    cursor: null,
    seenIds: [],
    outboundSeenIds: [],
    receipts: [],
    pendingOutbound: null,
  };
}

function parseReceipts(value) {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new Error("delivery_receipts must be an array");
  return value.map((item) => {
    assertObject(item, "delivery receipt");
    const receipt = {
      sourceMessageId: requiredString(item.source_message_id, "delivery receipt source_message_id"),
      deliveryId: requiredString(item.delivery_id, "delivery receipt delivery_id"),
      senderId: requiredString(item.sender_id, "delivery receipt sender_id"),
      hopCount: boundedInteger(item.hop_count, 0, 8, "delivery receipt hop_count"),
      replied: item.replied === true,
      outboundMessageId: optionalString(item.outbound_message_id),
      acceptedAt: optionalString(item.accepted_at),
    };
    if (receipt.replied && !receipt.outboundMessageId) {
      throw new Error("replied delivery receipt must contain outbound_message_id");
    }
    return receipt;
  });
}

function parsePendingOutbound(value) {
  if (value == null) return null;
  assertObject(value, "pending_outbound");
  const references = parseStringArray(value.references);
  return {
    eventId: requiredString(value.event_id, "pending_outbound event_id"),
    sourceMessageId: requiredString(value.source_message_id, "pending_outbound source_message_id"),
    deliveryId: requiredString(value.delivery_id, "pending_outbound delivery_id"),
    channelId: requiredString(value.channel_id, "pending_outbound channel_id"),
    text: requiredString(value.text, "pending_outbound text"),
    messageType: requiredString(value.message_type, "pending_outbound message_type"),
    references,
    hopCount: boundedInteger(value.hop_count, 1, 8, "pending_outbound hop_count"),
    idempotencyKey: requiredString(value.idempotency_key, "pending_outbound idempotency_key"),
  };
}

function toStoredReceipt(receipt) {
  return {
    source_message_id: receipt.sourceMessageId,
    delivery_id: receipt.deliveryId,
    sender_id: receipt.senderId,
    hop_count: receipt.hopCount,
    replied: receipt.replied,
    outbound_message_id: receipt.outboundMessageId,
    accepted_at: receipt.acceptedAt,
  };
}

function toStoredPending(pending) {
  return {
    event_id: pending.eventId,
    source_message_id: pending.sourceMessageId,
    delivery_id: pending.deliveryId,
    channel_id: pending.channelId,
    text: pending.text,
    message_type: pending.messageType,
    references: pending.references,
    hop_count: pending.hopCount,
    idempotency_key: pending.idempotencyKey,
  };
}

function parseStringArray(value) {
  if (value == null) return [];
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string" || !item)) {
    throw new Error("state string list contains an invalid item");
  }
  return value;
}

function requiredString(value, name) {
  if (typeof value !== "string" || !value) throw new Error(`${name} must be a non-empty string`);
  return value;
}

function optionalString(value) {
  return typeof value === "string" && value ? value : null;
}

function boundedInteger(value, minimum, maximum, name) {
  if (!Number.isInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be an integer from ${minimum} through ${maximum}`);
  }
  return value;
}

function assertObject(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${name} must be an object`);
  }
}
