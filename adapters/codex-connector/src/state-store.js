import { readFile } from "node:fs/promises";

import { atomicWritePrivateFile, SerializedSaveQueue } from "./atomic-file.js";
import {
  MAX_DELIVERY_RECEIPTS,
} from "./receipt-retention.js";

const MAX_SEEN_IDS = 1_000;
const MAX_PENDING_STATUSES = 1_000;
const MAX_BLOCKED_OUTBOUND = 1_000;
const MAX_TURN_BUDGET = 10_000;

export class StateStore {
  constructor(path) {
    this.path = path;
    this.saveQueue = new SerializedSaveQueue();
  }

  async load() {
    try {
      const parsed = JSON.parse(await readFile(this.path, "utf8"));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error("state must be a JSON object");
      }
      if (!Number.isInteger(parsed.version) || parsed.version < 1 || parsed.version > 4) {
        throw new Error("unsupported connector state version");
      }
      const receipts = boundReceipts(parseReceipts(parsed.delivery_receipts));
      const pendingStatuses = parsePendingStatuses(parsed.pending_statuses);
      const blockedOutbound = parseBlockedOutbound(parsed.blocked_outbound);
      const turnBudget = parseTurnBudget(parsed.turn_budget);
      assertCapacity(pendingStatuses, MAX_PENDING_STATUSES, "pending_statuses");
      assertCapacity(blockedOutbound, MAX_BLOCKED_OUTBOUND, "blocked_outbound");
      assertCapacity(turnBudget, MAX_TURN_BUDGET, "turn_budget");
      return {
        cursor: optionalString(parsed.cursor),
        seenIds: parseStringArray(parsed.seen_ids).slice(-MAX_SEEN_IDS),
        outboundSeenIds: parseStringArray(parsed.outbound_seen_ids).slice(-MAX_SEEN_IDS),
        receipts,
        pendingOutbound: parsePendingOutbound(parsed.pending_outbound),
        pendingStatuses,
        blockedOutbound,
        turnBudget,
      };
    } catch (error) {
      if (error?.code === "ENOENT") return emptyState();
      throw new Error(`Cannot read Codex connector state at ${this.path}: ${error.message}`);
    }
  }

  async save({
    cursor,
    seenIds,
    outboundSeenIds,
    receipts,
    pendingOutbound,
    pendingStatuses = [],
    blockedOutbound = [],
    turnBudget = [],
  }) {
    return this.saveQueue.run(async () => {
      try {
        const boundedReceipts = boundReceipts([...receipts.values()]);
        assertCapacity(pendingStatuses, MAX_PENDING_STATUSES, "pending_statuses");
        assertCapacity(blockedOutbound, MAX_BLOCKED_OUTBOUND, "blocked_outbound");
        assertCapacity(turnBudget, MAX_TURN_BUDGET, "turn_budget");
        const payload = `${JSON.stringify(
          {
            version: 4,
            cursor,
            seen_ids: [...seenIds].slice(-MAX_SEEN_IDS),
            outbound_seen_ids: [...outboundSeenIds].slice(-MAX_SEEN_IDS),
            delivery_receipts: boundedReceipts.map(toStoredReceipt),
            pending_outbound: pendingOutbound ? toStoredPending(pendingOutbound) : null,
            pending_statuses: pendingStatuses.map(toStoredPending),
            blocked_outbound: blockedOutbound.map(toStoredBlocked),
            turn_budget: turnBudget.map((entry) => ({
              message_id: entry.messageId,
              sender_id: entry.senderId,
              started_at: entry.startedAt,
            })),
          },
          null,
          2,
        )}\n`;
        await atomicWritePrivateFile(this.path, payload);
      } catch (error) {
        const wrapped = new Error(
          `Cannot persist Codex connector state at ${this.path}: ${error.message}`,
        );
        if (typeof error?.code === "string") wrapped.code = error.code;
        throw wrapped;
      }
    });
  }
}

export function emptyState() {
  return {
    cursor: null,
    seenIds: [],
    outboundSeenIds: [],
    receipts: [],
    pendingOutbound: null,
    pendingStatuses: [],
    blockedOutbound: [],
    turnBudget: [],
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
      outboundEventId: optionalString(item.outbound_event_id),
      driverReleasePending: optionalReleaseOutcome(item.driver_release_pending),
    };
    if (receipt.replied && !receipt.outboundMessageId) {
      throw new Error("replied delivery receipt must contain outbound_message_id");
    }
    if (receipt.driverReleasePending && !receipt.outboundEventId) {
      throw new Error("driver release pending receipt must contain outbound_event_id");
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

function parsePendingStatuses(value) {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new Error("pending_statuses must be an array");
  return value.map(parsePendingOutbound);
}

function parseBlockedOutbound(value) {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new Error("blocked_outbound must be an array");
  return value.map((item) => ({
    ...parsePendingOutbound(item),
    blockedAt: requiredString(item.blocked_at, "blocked_outbound blocked_at"),
    reasonCode: requiredString(item.reason_code, "blocked_outbound reason_code"),
  }));
}

function parseTurnBudget(value) {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new Error("turn_budget must be an array");
  return value.map((entry) => {
    assertObject(entry, "turn budget entry");
    return {
      messageId: requiredString(entry.message_id, "turn budget message_id"),
      senderId: requiredString(entry.sender_id, "turn budget sender_id"),
      startedAt: requiredString(entry.started_at, "turn budget started_at"),
    };
  });
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
    outbound_event_id: receipt.outboundEventId ?? null,
    driver_release_pending: receipt.driverReleasePending ?? null,
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

function toStoredBlocked(pending) {
  return {
    ...toStoredPending(pending),
    blocked_at: pending.blockedAt,
    reason_code: pending.reasonCode,
  };
}

function boundReceipts(receipts) {
  const sourceIds = new Set();
  for (const receipt of receipts) {
    if (sourceIds.has(receipt.sourceMessageId)) {
      throw new Error("delivery_receipts contains duplicate source_message_id values");
    }
    sourceIds.add(receipt.sourceMessageId);
  }
  if (receipts.length > MAX_DELIVERY_RECEIPTS) {
    const error = new Error(
      "delivery_receipts exceeds capacity; refusing eviction without a durable driver release",
    );
    error.code = "AICHAT_RECEIPT_CAPACITY";
    throw error;
  }
  return [...receipts];
}

function optionalReleaseOutcome(value) {
  if (value == null) return null;
  if (value !== "dropped" && value !== "evicted") {
    throw new Error("delivery receipt driver_release_pending is invalid");
  }
  return value;
}

function assertCapacity(value, maximum, name) {
  if (value.length <= maximum) return;
  const error = new Error(`${name} exceeds the durable state capacity of ${maximum}`);
  error.code = "AICHAT_STATE_CAPACITY";
  throw error;
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
