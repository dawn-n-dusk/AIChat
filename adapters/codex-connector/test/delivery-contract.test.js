import assert from "node:assert/strict";
import test from "node:test";

import { validateDeliveryReceipt } from "../src/delivery-contract.js";

const binding = { threadId: "thread-1", hostId: null };
const accepted = { accepted: true, deliveryId: "opaque-delivery-1", threadId: "thread-1" };
const validate = (value, expectedBinding = binding) =>
  validateDeliveryReceipt(value, accepted.deliveryId, expectedBinding);

test("minimal accepted evidence has no turn or completion claim", () => {
  const receipt = validate(accepted);
  assert.deepEqual(receipt, { ...accepted, hostId: null });
  assert.notEqual(receipt, accepted);
  assert.equal(receipt.turnId, undefined);
  assert.equal(receipt.status, undefined);
  assert.equal(receipt.completed, undefined);
});

test("correlated turn evidence is copied without inventing a completion or current status", () => {
  const value = {
    ...accepted,
    hostId: null,
    turnId: "opaque-turn-1",
    acceptedAt: "2026-09-05T00:00:00.000Z",
    duplicate: true,
  };
  assert.deepEqual(validate(value), value);
  assert.deepEqual(validate({ ...value, duplicate: false }), { ...value, duplicate: false });
});

test("null optional evidence remains acceptance-only", () => {
  assert.deepEqual(validate({ ...accepted, turnId: null, acceptedAt: null }), {
    ...accepted, hostId: null, turnId: null, acceptedAt: null,
  });
});

test("opaque identifiers are compared exactly without parsing or normalization", () => {
  const value = { ...accepted, deliveryId: "opaque:/case-Sensitive", hostId: "host-1" };
  assert.deepEqual(
    validateDeliveryReceipt(value, value.deliveryId, { ...binding, hostId: "host-1" }),
    value,
  );
  assert.throws(
    () => validateDeliveryReceipt(value, "opaque:/case-sensitive", { ...binding, hostId: "host-1" }),
    { code: "AICHAT_DELIVERY_RECEIPT_INVALID" },
  );
});

const invalidValues = [
  ["null", null],
  ["array", []],
  ["string", "accepted"],
  ["class instance", new Date()],
  ["inherited receipt fields", Object.create(accepted)],
  ["missing acceptance", { ...accepted, accepted: undefined }],
  ["false acceptance", { ...accepted, accepted: false }],
  ["string acceptance", { ...accepted, accepted: "true" }],
  ["missing delivery", { ...accepted, deliveryId: undefined }],
  ["wrong delivery", { ...accepted, deliveryId: "other" }],
  ["missing thread", { ...accepted, threadId: undefined }],
  ["null thread", { ...accepted, threadId: null }],
  ["wrong thread", { ...accepted, threadId: "other" }],
  ["empty thread", { ...accepted, threadId: "" }],
  ["numeric thread", { ...accepted, threadId: 7 }],
  ["wrong host", { ...accepted, hostId: "other" }],
  ["empty host", { ...accepted, hostId: "" }],
  ["numeric host", { ...accepted, hostId: 7 }],
  ["empty turn", { ...accepted, turnId: "" }],
  ["blank turn", { ...accepted, turnId: " \t" }],
  ["padded turn", { ...accepted, turnId: " turn-1" }],
  ["control character turn", { ...accepted, turnId: "turn\u0000-1" }],
  ["numeric turn", { ...accepted, turnId: 7 }],
  ["object turn", { ...accepted, turnId: {} }],
  ["invalid timestamp", { ...accepted, acceptedAt: "not-a-timestamp" }],
  ["empty timestamp", { ...accepted, acceptedAt: "" }],
  ["numeric timestamp", { ...accepted, acceptedAt: 7 }],
  ["string duplicate", { ...accepted, duplicate: "true" }],
  ["null duplicate", { ...accepted, duplicate: null }],
];

for (const [name, value] of invalidValues) {
  test(`receipt validation rejects ${name}`, () => {
    assert.throws(() => validate(value), { code: "AICHAT_DELIVERY_RECEIPT_INVALID" });
  });
}

test("missing or null host cannot satisfy a nonlocal expected binding", () => {
  for (const hostId of [undefined, null]) {
    assert.throws(() => validate({ ...accepted, hostId }, { ...binding, hostId: "host-1" }), {
      code: "AICHAT_DELIVERY_RECEIPT_INVALID",
    });
  }
});

test("malformed expected identifiers fail closed even when echoed exactly", () => {
  for (const identifier of [undefined, null, "", " ", "bad\nvalue", 7]) {
    assert.throws(
      () => validateDeliveryReceipt({ ...accepted, deliveryId: identifier }, identifier, binding),
      { code: "AICHAT_DELIVERY_RECEIPT_INVALID" },
    );
    assert.throws(() => validate(accepted, { ...binding, threadId: identifier }), {
      code: "AICHAT_DELIVERY_RECEIPT_INVALID",
    });
  }
  assert.throws(() => validate(accepted, null), { code: "AICHAT_DELIVERY_RECEIPT_INVALID" });
});

test("unknown fields and accessors are never forwarded or evaluated", () => {
  const value = {
    ...accepted,
    status: "running",
    completed: true,
    token: "receipt-secret-canary",
    [Symbol("private")]: "symbol-secret-canary",
  };
  Object.defineProperty(value, "extension", {
    enumerable: true,
    get() { throw new Error("extension-secret-canary"); },
  });
  Object.defineProperty(value, "__proto__", { enumerable: true, value: { injected: true } });
  const receipt = validate(value);
  assert.deepEqual(receipt, { ...accepted, hostId: null });
  assert.deepEqual(Object.getOwnPropertySymbols(receipt), []);
  assert.equal(Object.getPrototypeOf(receipt), Object.prototype);
  value.threadId = "changed";
  assert.equal(receipt.threadId, binding.threadId);
});

test("recognized accessors are rejected without invoking them", () => {
  let reads = 0;
  const value = { ...accepted };
  Object.defineProperty(value, "turnId", { get() { reads += 1; return "turn-1"; } });
  assert.throws(() => validate(value), { code: "AICHAT_DELIVERY_RECEIPT_INVALID" });
  assert.equal(reads, 0);
});

test("proxy failures do not escape as raw diagnostics", () => {
  const value = new Proxy({}, { getPrototypeOf() { throw new Error("proxy-secret-canary"); } });
  assert.throws(() => validate(value), (error) => {
    assert.equal(error.code, "AICHAT_DELIVERY_RECEIPT_INVALID");
    assert.doesNotMatch(String(error), /proxy-secret-canary/);
    assert.equal(error.cause, undefined);
    return true;
  });
});

test("own data fields in a null-prototype record are supported", () => {
  assert.deepEqual(validate(Object.assign(Object.create(null), accepted)), {
    ...accepted, hostId: null,
  });
});
