export const MAX_DELIVERY_RECEIPTS = 1_000;

export function selectReceiptEvictionCandidate(records, isSafe) {
  let selected = null;
  for (const record of records) {
    if (!isSafe(record)) continue;
    if (!selected || compareDeliveryIds(record.deliveryId, selected.deliveryId) < 0) {
      selected = record;
    }
  }
  return selected;
}

function compareDeliveryIds(left, right) {
  if (left === right) return 0;
  return left < right ? -1 : 1;
}
