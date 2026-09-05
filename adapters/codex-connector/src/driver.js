import { validateDeliveryReceipt } from "./delivery-contract.js";

const DRIVER_FAILURES = new WeakMap();
const DRIVER_FAILURE_CODES = {
  "driver-import": "AICHAT_DRIVER_IMPORT_FAILED",
  "driver-create": "AICHAT_DRIVER_CREATE_FAILED",
  "driver-contract": "AICHAT_DRIVER_CONTRACT_INVALID",
};

export async function loadCodexDriver(moduleSpecifier, options) {
  let loaded;
  try {
    loaded = await import(moduleSpecifier);
  } catch {
    throw driverFailure("driver-import");
  }
  if (typeof loaded.createCodexDriver !== "function") {
    throw driverFailure("driver-contract");
  }
  let driver;
  try {
    driver = await loaded.createCodexDriver(options);
  } catch {
    throw driverFailure("driver-create");
  }
  try {
    assertCodexDriver(driver);
  } catch {
    throw driverFailure("driver-contract");
  }
  return driver;
}

export function driverFailureDiagnostic(error) {
  return DRIVER_FAILURES.get(error) ?? null;
}

export function assertCodexDriver(driver) {
  if (!driver || typeof driver !== "object") throw new Error("Codex driver must be an object");
  for (const method of ["start", "deliver", "stop"]) {
    if (typeof driver[method] !== "function") {
      throw new Error(`Codex driver is missing ${method}()`);
    }
  }
  for (const method of ["acknowledgeDelivery", "resolveDelivery", "drain"]) {
    if (driver[method] != null && typeof driver[method] !== "function") {
      throw new Error(`Codex driver optional ${method} must be a function when provided`);
    }
  }
  return driver;
}

export function validateDriverReceipt(value, expectedDeliveryId, expectedBinding) {
  return validateDeliveryReceipt(value, expectedDeliveryId, expectedBinding);
}

function driverFailure(phase) {
  const code = DRIVER_FAILURE_CODES[phase];
  const error = new Error(code);
  error.code = code;
  error.phase = phase;
  DRIVER_FAILURES.set(error, Object.freeze({ code, phase }));
  return error;
}
