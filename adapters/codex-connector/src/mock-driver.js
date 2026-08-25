import { assertCodexDriver } from "./driver.js";

export class MockCodexDriver {
  constructor() {
    this.binding = null;
    this.onOutboundReply = null;
    this.deliveries = [];
    this.receipts = new Map();
    this.stopped = false;
  }

  async start({ binding, onOutboundReply }) {
    if (this.binding) throw new Error("MockCodexDriver is already started");
    this.binding = { ...binding };
    this.onOutboundReply = onOutboundReply;
  }

  async deliver(request) {
    if (!this.binding || this.stopped) throw new Error("MockCodexDriver is not running");
    const existing = this.receipts.get(request.deliveryId);
    if (existing) return { ...existing, duplicate: true };
    this.deliveries.push(structuredClone(request));
    const receipt = {
      accepted: true,
      deliveryId: request.deliveryId,
      threadId: request.threadId,
      hostId: request.hostId,
      acceptedAt: "2026-08-24T00:00:00.000Z",
    };
    this.receipts.set(request.deliveryId, receipt);
    return { ...receipt };
  }

  async emitOutboundReply(event) {
    if (!this.onOutboundReply || this.stopped) throw new Error("MockCodexDriver is not running");
    return this.onOutboundReply(structuredClone(event));
  }

  async resolveDelivery(deliveryId, { eventId, outcome } = {}) {
    if (!this.binding || this.stopped) throw new Error("MockCodexDriver is not running");
    const receipt = this.receipts.get(deliveryId);
    if (!receipt) {
      return outcome === "delivered"
        ? { delivered: true, duplicate: true }
        : { released: true, duplicate: true };
    }
    if (typeof eventId !== "string" || !eventId) throw new Error("Mock resolution requires eventId");
    if (outcome === "dropped" || outcome === "evicted") {
      this.receipts.delete(deliveryId);
      return { released: true };
    }
    if (outcome !== "delivered") throw new Error("Mock resolution outcome is invalid");
    this.receipts.set(deliveryId, { ...receipt, outboundEventId: eventId, delivered: true });
    return { delivered: true };
  }

  async stop() {
    this.stopped = true;
  }
}

export async function createCodexDriver() {
  return assertCodexDriver(new MockCodexDriver());
}
