const RECEIPT_FIELDS = [
  "accepted",
  "deliveryId",
  "threadId",
  "hostId",
  "turnId",
  "acceptedAt",
  "duplicate",
];

export function validateDeliveryReceipt(value, expectedDeliveryId, expectedBinding) {
  try {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw invalidReceipt();
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) throw invalidReceipt();
    const fields = {};
    for (const field of RECEIPT_FIELDS) {
      const descriptor = Object.getOwnPropertyDescriptor(value, field);
      if (!descriptor) continue;
      if (!("value" in descriptor)) throw invalidReceipt();
      fields[field] = descriptor.value;
    }
    if (
      fields.accepted !== true ||
      !isIdentifier(expectedDeliveryId) ||
      fields.deliveryId !== expectedDeliveryId ||
      !isIdentifier(fields.threadId)
    ) {
      throw invalidReceipt();
    }
    if (fields.hostId != null && !isIdentifier(fields.hostId)) throw invalidReceipt();
    if (expectedBinding !== undefined) {
      if (
        !expectedBinding ||
        !isIdentifier(expectedBinding.threadId) ||
        (expectedBinding.hostId != null && !isIdentifier(expectedBinding.hostId)) ||
        fields.threadId !== expectedBinding.threadId ||
        (fields.hostId ?? null) !== (expectedBinding.hostId ?? null)
      ) {
        throw invalidReceipt();
      }
    }
    if (fields.turnId != null && !isIdentifier(fields.turnId)) throw invalidReceipt();
    if (
      fields.acceptedAt != null &&
      (typeof fields.acceptedAt !== "string" || !Number.isFinite(Date.parse(fields.acceptedAt)))
    ) {
      throw invalidReceipt();
    }
    if (fields.duplicate !== undefined && typeof fields.duplicate !== "boolean") {
      throw invalidReceipt();
    }
    return { ...fields, hostId: fields.hostId ?? null };
  } catch {
    throw invalidReceipt();
  }
}

function isIdentifier(value) {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.trim() === value &&
    !/[\u0000-\u001f\u007f]/u.test(value)
  );
}

function invalidReceipt() {
  const error = new Error("Delivery receipt is invalid or does not match the requested binding");
  error.code = "AICHAT_DELIVERY_RECEIPT_INVALID";
  return error;
}
