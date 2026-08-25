export async function loadCodexDriver(moduleSpecifier, options) {
  let loaded;
  try {
    loaded = await import(moduleSpecifier);
  } catch (error) {
    throw new Error(`Cannot load Codex driver module: ${errorMessage(error)}`);
  }
  if (typeof loaded.createCodexDriver !== "function") {
    throw new Error("Codex driver module must export createCodexDriver(options)");
  }
  const driver = await loaded.createCodexDriver(options);
  assertCodexDriver(driver);
  return driver;
}

export function assertCodexDriver(driver) {
  if (!driver || typeof driver !== "object") throw new Error("Codex driver must be an object");
  for (const method of ["start", "deliver", "stop"]) {
    if (typeof driver[method] !== "function") {
      throw new Error(`Codex driver is missing ${method}()`);
    }
  }
  for (const method of ["acknowledgeDelivery", "resolveDelivery"]) {
    if (driver[method] != null && typeof driver[method] !== "function") {
      throw new Error(`Codex driver optional ${method} must be a function when provided`);
    }
  }
  return driver;
}

export function validateDriverReceipt(value, expectedDeliveryId) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Codex driver returned an invalid delivery receipt");
  }
  if (value.accepted !== true) throw new Error("Codex driver did not accept the delivery");
  if (value.deliveryId !== expectedDeliveryId) {
    throw new Error("Codex driver receipt deliveryId does not match the requested delivery");
  }
  if (value.threadId != null && typeof value.threadId !== "string") {
    throw new Error("Codex driver receipt threadId must be a string when present");
  }
  if (value.hostId != null && typeof value.hostId !== "string") {
    throw new Error("Codex driver receipt hostId must be a string when present");
  }
  return value;
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
