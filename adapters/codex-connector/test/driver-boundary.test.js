import assert from "node:assert/strict";
import test from "node:test";

import { AIChatCodexConnector } from "../src/connector.js";
import {
  driverFailureDiagnostic,
  loadCodexDriver,
  validateDriverReceipt,
} from "../src/driver.js";

const binding = { channelId: "channel-1", threadId: "thread-1", hostId: null };
const canary = "BOUNDARY_SECRET /private/fixture S-1-5-21-123 D:(A;;FA;;;SY)";
const moduleUrl = (source) => `data:text/javascript,${encodeURIComponent(source)}`;

test("the existing two-argument receipt API returns a validated copy", () => {
  const value = { accepted: true, deliveryId: "delivery-1", threadId: "thread-1" };
  assert.deepEqual(validateDriverReceipt(value, value.deliveryId), { ...value, hostId: null });
  assert.notEqual(validateDriverReceipt(value, value.deliveryId), value);
  assert.throws(() => validateDriverReceipt(value, value.deliveryId, { ...binding, hostId: "other" }), {
    code: "AICHAT_DELIVERY_RECEIPT_INVALID",
  });
});

test("driver loading preserves the factory options and required API", async () => {
  const options = { binding, logger: { error() {} } };
  const driver = await loadCodexDriver(moduleUrl(`
    export function createCodexDriver(options) {
      return { options, async start() {}, async deliver() {}, async stop() {} };
    }
  `), options);
  assert.equal(driver.options, options);
  assert.equal(typeof driver.deliver, "function");
});

const loaderFailures = [
  ["missing module", new URL("./BOUNDARY_SECRET-missing.mjs", import.meta.url).href, "driver-import", "AICHAT_DRIVER_IMPORT_FAILED"],
  ["module evaluation", moduleUrl(`throw new Error(${JSON.stringify(canary)});`), "driver-import", "AICHAT_DRIVER_IMPORT_FAILED"],
  ["missing factory", moduleUrl("export const other = true;"), "driver-contract", "AICHAT_DRIVER_CONTRACT_INVALID"],
  ["factory exception", moduleUrl(`export function createCodexDriver() { throw new Error(${JSON.stringify(canary)}); }`), "driver-create", "AICHAT_DRIVER_CREATE_FAILED"],
  ["non-error rejection", moduleUrl(`export async function createCodexDriver() { throw { token: ${JSON.stringify(canary)} }; }`), "driver-create", "AICHAT_DRIVER_CREATE_FAILED"],
  ["invalid driver", moduleUrl("export function createCodexDriver() { return {}; }"), "driver-contract", "AICHAT_DRIVER_CONTRACT_INVALID"],
  ["contract accessor", moduleUrl(`export function createCodexDriver() { return { get start() { throw new Error(${JSON.stringify(canary)}); } }; }`), "driver-contract", "AICHAT_DRIVER_CONTRACT_INVALID"],
];

for (const [name, module, phase, code] of loaderFailures) {
  test(`loader projects ${name} onto a fixed diagnostic`, async () => {
    await assert.rejects(() => loadCodexDriver(module, { binding }), (error) => {
      assert.equal(error.message, code);
      assert.equal(error.code, code);
      assert.equal(error.phase, phase);
      assert.equal(error.cause, undefined);
      assert.deepEqual(driverFailureDiagnostic(error), { phase, code });
      assert.doesNotMatch(`${error.stack}\n${JSON.stringify(error)}`, /BOUNDARY_SECRET|S-1-5-21|D:\(A;;/);
      return true;
    });
  });
}

test("untrusted phase and code properties cannot impersonate loader diagnostics", () => {
  const error = { code: "AICHAT_DRIVER_IMPORT_FAILED", phase: "driver-import" };
  assert.equal(driverFailureDiagnostic(error), null);
  assert.equal(driverFailureDiagnostic(null), null);
  assert.equal(driverFailureDiagnostic(canary), null);
});

function harness({ receipt, failSaveAt, initialReceipts = [], autoReplyEnabled = true, lifecycleStatusEnabled = true } = {}) {
  const saved = [];
  const sent = [];
  const acknowledged = [];
  const requests = [];
  let saveCalls = 0;
  const message = {
    id: "message-1", channel_id: binding.channelId, sender_id: "agent-remote",
    type: "request", text: "Review this fixture", reply_to: null, references: [], hop_count: 0,
  };
  const driver = {
    async start() {},
    async stop() {},
    async deliver(request) {
      requests.push(request);
      return receipt ? receipt(request) : {
        accepted: true, deliveryId: request.deliveryId, threadId: request.threadId, hostId: request.hostId,
      };
    },
    async acknowledgeDelivery(deliveryId) {
      acknowledged.push({ deliveryId, cursor: connector.status().cursor, statuses: sent.map(statusKind) });
    },
  };
  const connector = new AIChatCodexConnector({
    config: {
      channelId: binding.channelId, targetThreadId: binding.threadId, targetHostId: binding.hostId,
      token: "synthetic-relay-secret", allowedSenderIds: new Set([message.sender_id]),
      deliverTypes: new Set(["request"]), pageLimit: 10, maxDeliveriesPerRecovery: 10,
      maxTurnsPerSenderPerHour: 10, autoReplyEnabled, lifecycleStatusEnabled,
      egressAudienceAcknowledged: true, egressCanary: "synthetic-egress-canary",
      egressAllowedReferenceHosts: new Set(), egressMaxTextBytes: 8192,
    },
    relay: {
      async whoAmI() { return { agent_id: "agent-self" }; },
      async listMessages({ after }) { return { items: after ? [] : [message], next_after: message.id }; },
      async sendMessage(payload) { sent.push(payload); return { id: `outbound-${sent.length}` }; },
    },
    stateStore: {
      async load() {
        return {
          cursor: null, seenIds: [], outboundSeenIds: [], receipts: initialReceipts, pendingOutbound: null,
          pendingStatuses: [], blockedOutbound: [], turnBudget: [],
        };
      },
      async save(value) {
        saveCalls += 1;
        if (saveCalls === failSaveAt) throw new Error("synthetic checkpoint failure");
        saved.push(structuredClone(value));
      },
    },
    driver,
    logger: { error() {} },
  });
  return { connector, driver, saved, sent, acknowledged, requests };
}

function statusKind(payload) {
  return JSON.parse(payload.text).status;
}

for (const turnId of [undefined, null, "turn-1"]) {
  test(`connector projects ${String(turnId)} turn evidence without claiming completion`, async () => {
    const context = harness({ receipt: (request) => ({
      accepted: true, deliveryId: request.deliveryId, threadId: request.threadId,
      turnId, status: "completed", completed: true,
    }) });
    await context.connector.initialize();
    await context.connector.recoverPage();
    const expected = turnId ? ["accepted", "running"] : ["accepted"];
    assert.deepEqual(context.sent.map(statusKind), expected);
    assert.deepEqual(context.acknowledged, [{
      deliveryId: context.requests[0].deliveryId, cursor: "message-1", statuses: expected,
    }]);
    assert.equal(context.connector.getDeliveryReceipt("message-1").replied, false);
    assert.ok(context.sent.every((payload) => JSON.parse(payload.text).correlation.delivery_id === context.requests[0].deliveryId));
    assert.ok(context.sent.every((payload) => payload.replyTo === "message-1"));
  });
}

for (const [name, overrides] of [
  ["delivery mismatch", { deliveryId: "other" }],
  ["thread mismatch", { threadId: "other" }],
  ["missing thread", { threadId: undefined }],
  ["host mismatch", { hostId: "other" }],
  ["invalid turn", { turnId: " " }],
  ["invalid timestamp", { acceptedAt: {} }],
  ["unaccepted delivery", { accepted: false }],
]) {
  test(`${name} refuses inbound checkpoint and driver acknowledgement`, async () => {
    const context = harness({ receipt: (request) => ({
      accepted: true, deliveryId: request.deliveryId, threadId: request.threadId, hostId: request.hostId,
      turnId: "turn-1",
      ...overrides,
    }) });
    await context.connector.initialize();
    await assert.rejects(() => context.connector.recoverPage(), { code: "AICHAT_DELIVERY_RECEIPT_INVALID" });
    assert.equal(context.connector.status().cursor, null);
    assert.equal(context.connector.getDeliveryReceipt("message-1"), null);
    assert.deepEqual(context.acknowledged, []);
    assert.ok(context.saved.every((state) => state.cursor === null && state.seenIds.size === 0 && state.receipts.size === 0));
    assert.deepEqual(context.sent.map(statusKind), ["blocked"]);
    assert.equal(JSON.parse(context.sent[0].text).reason, "aichat_delivery_receipt_invalid");
  });
}

test("failed delivery checkpoint cannot acknowledge otherwise valid turn evidence", async () => {
  const context = harness({ failSaveAt: 2, receipt: (request) => ({
    accepted: true, deliveryId: request.deliveryId, threadId: request.threadId, turnId: "turn-1",
  }) });
  await context.connector.initialize();
  await assert.rejects(() => context.connector.recoverPage(), /synthetic checkpoint failure/);
  assert.equal(context.connector.status().cursor, null);
  assert.deepEqual(context.acknowledged, []);
  assert.deepEqual(context.sent, []);
});

test("capacity-release failures cannot forward driver exception codes into lifecycle status", async () => {
  const initialReceipts = Array.from({ length: 1000 }, (unused, index) => ({
    sourceMessageId: `prior-message-${index}`, deliveryId: `prior-delivery-${index}`,
    sourceMessageType: "request", replyEligible: true, senderId: "agent-remote", hopCount: 0,
    replied: true, outboundMessageId: `prior-outbound-${index}`, outboundEventId: `prior-event-${index}`,
    acceptedAt: "2026-09-05T00:00:00.000Z", driverReleasePending: null,
  }));
  const context = harness({ initialReceipts });
  await context.connector.initialize();
  context.acknowledged.length = 0;
  context.driver.resolveDelivery = async () => { throw { code: "AICHAT_CANARY_SECRET" }; };
  await assert.rejects(() => context.connector.recoverPage());
  assert.equal(context.connector.status().cursor, null);
  assert.deepEqual(context.requests, []);
  assert.deepEqual(context.acknowledged, []);
  assert.deepEqual(context.sent.map(statusKind), ["blocked"]);
  assert.equal(JSON.parse(context.sent[0].text).reason, "delivery_failed");
  assert.doesNotMatch(JSON.stringify(context.sent), /CANARY_SECRET/);
});

for (const options of [{ autoReplyEnabled: false }, { lifecycleStatusEnabled: false }]) {
  test(`receipt evidence cannot bypass ${Object.keys(options)[0]}`, async () => {
    const context = harness({ ...options, receipt: (request) => ({
      accepted: true, deliveryId: request.deliveryId, threadId: request.threadId, turnId: "turn-1",
    }) });
    await context.connector.initialize();
    await context.connector.recoverPage();
    assert.deepEqual(context.sent, []);
    assert.equal(context.acknowledged.length, 1);
  });
}

for (const [name, error, expected] of [
  ["unknown prefixed code", { code: "AICHAT_CANARY_SECRET" }, "delivery_failed"],
  ["known code", { code: "AICHAT_RECEIPT_CAPACITY" }, "aichat_receipt_capacity"],
  ["ambiguous outcome", { outcome: "ambiguous" }, "delivery_ambiguous"],
  ["rejected outcome", { outcome: "rejected" }, "delivery_rejected"],
  ["throwing code accessor", { get code() { throw new Error(canary); } }, "delivery_failed"],
]) {
  test(`failure projection allowlists ${name}`, async () => {
    const context = harness({ receipt() { throw error; } });
    await context.connector.initialize();
    await assert.rejects(() => context.connector.recoverPage());
    assert.equal(JSON.parse(context.sent[0].text).reason, expected);
    assert.doesNotMatch(JSON.stringify(context.sent), /CANARY_SECRET|BOUNDARY_SECRET|S-1-5-21/);
    assert.deepEqual(context.acknowledged, []);
  });
}
