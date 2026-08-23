import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_SERVER = "http://127.0.0.1:8000";
const DEFAULT_PAGE_LIMIT = 50;
const DEFAULT_REQUEST_TIMEOUT_MS = 15_000;
const DEFAULT_RECOVERY_INTERVAL_MS = 30_000;
const DEFAULT_RECONNECT_DELAY_MS = 2_000;
const DEFAULT_DELIVER_TYPES = ["text", "request"];
const VALID_MESSAGE_TYPES = new Set(["text", "request", "result", "status"]);

export function loadConfig(env = process.env, { cwd = process.cwd() } = {}) {
  if (env.AICHAT_CODEX_CONNECTOR_ENABLED?.trim().toLowerCase() !== "true") {
    throw new Error(
      "AIChat Codex connector is disabled; set AICHAT_CODEX_CONNECTOR_ENABLED=true explicitly",
    );
  }

  const server = parseServer(env.AICHAT_SERVER ?? DEFAULT_SERVER);
  const token = requireValue(env, "AICHAT_TOKEN");
  const channelId = requireValue(env, "AICHAT_CHANNEL_ID");
  const targetThreadId = requireValue(env, "CODEX_TARGET_THREAD_ID");
  const targetHostId = env.CODEX_TARGET_HOST_ID?.trim() || null;
  const driver = parseDriver(env.CODEX_DRIVER, env.CODEX_DRIVER_MODULE, cwd);
  if (targetHostId && driver.mode !== "module") {
    throw new Error(
      "Built-in Codex drivers are local-only; use CODEX_DRIVER=module for CODEX_TARGET_HOST_ID",
    );
  }
  const allowedSenderIds = parseAllowedSenders(env.AICHAT_ALLOWED_SENDER_IDS);
  const deliverTypes = parseDeliverTypes(env.AICHAT_DELIVER_TYPES);
  const pageLimit = parsePositiveInteger(
    env.AICHAT_PAGE_LIMIT,
    DEFAULT_PAGE_LIMIT,
    "AICHAT_PAGE_LIMIT",
    1,
    200,
  );
  const requestTimeoutMs = parsePositiveInteger(
    env.AICHAT_REQUEST_TIMEOUT_MS,
    DEFAULT_REQUEST_TIMEOUT_MS,
    "AICHAT_REQUEST_TIMEOUT_MS",
    1_000,
  );
  const recoveryIntervalMs = parsePositiveInteger(
    env.AICHAT_RECOVERY_INTERVAL_MS,
    DEFAULT_RECOVERY_INTERVAL_MS,
    "AICHAT_RECOVERY_INTERVAL_MS",
    1_000,
  );
  const reconnectDelayMs = parsePositiveInteger(
    env.AICHAT_WS_RECONNECT_DELAY_MS,
    DEFAULT_RECONNECT_DELAY_MS,
    "AICHAT_WS_RECONNECT_DELAY_MS",
    100,
  );
  const websocketEnabled = parseBoolean(env.AICHAT_WEBSOCKET_ENABLED, true, "AICHAT_WEBSOCKET_ENABLED");
  const stateFile = env.AICHAT_STATE_FILE?.trim()
    ? resolve(env.AICHAT_STATE_FILE.trim())
    : defaultStateFile(channelId, targetThreadId, targetHostId);

  return Object.freeze({
    server,
    token,
    channelId,
    targetThreadId,
    targetHostId,
    driverMode: driver.mode,
    driverModule: driver.module,
    allowedSenderIds,
    deliverTypes,
    pageLimit,
    requestTimeoutMs,
    recoveryIntervalMs,
    reconnectDelayMs,
    websocketEnabled,
    stateFile,
  });
}

export function defaultStateFile(channelId, threadId, hostId) {
  const digest = createHash("sha256")
    .update(`${channelId}\0${threadId}\0${hostId ?? ""}`)
    .digest("hex")
    .slice(0, 24);
  return join(homedir(), ".aichat", "codex-connector", `${digest}.json`);
}

function requireValue(env, name) {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function parseServer(value) {
  let url;
  try {
    url = new URL(value.trim());
  } catch {
    throw new Error("AICHAT_SERVER must be a valid http(s) URL");
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("AICHAT_SERVER must use http or https");
  }
  if (url.username || url.password) throw new Error("AICHAT_SERVER must not contain credentials");
  if (url.search || url.hash) throw new Error("AICHAT_SERVER must not contain query or fragment data");
  url.pathname = url.pathname.replace(/\/+$/, "");
  return url.toString().replace(/\/$/, "");
}

function parseAllowedSenders(value) {
  const senders = new Set(splitCsv(value));
  if (senders.size === 0) {
    throw new Error(
      "AICHAT_ALLOWED_SENDER_IDS is required and must contain at least one relay agent ID",
    );
  }
  if (senders.has("*")) throw new Error("AICHAT_ALLOWED_SENDER_IDS cannot contain wildcard '*'");
  return senders;
}

function parseDeliverTypes(value) {
  const values = value == null || value.trim() === "" ? DEFAULT_DELIVER_TYPES : splitCsv(value);
  const types = new Set(values);
  if (types.size === 0) throw new Error("AICHAT_DELIVER_TYPES cannot be empty");
  for (const type of types) {
    if (!VALID_MESSAGE_TYPES.has(type)) {
      throw new Error(`AICHAT_DELIVER_TYPES contains unsupported message type: ${type}`);
    }
  }
  return types;
}

function parseDriverModule(value, cwd) {
  if (value.startsWith("file:")) return value;
  if (value.startsWith(".") || isAbsolute(value)) {
    return pathToFileURL(resolve(cwd, value)).href;
  }
  return value;
}

function parseDriver(value, moduleValue, cwd) {
  const mode = value?.trim().toLowerCase() || (moduleValue?.trim() ? "module" : "auto");
  if (mode === "auto") {
    if (moduleValue?.trim()) {
      throw new Error("CODEX_DRIVER_MODULE can only be used with CODEX_DRIVER=module");
    }
    return {
      mode,
      module: new URL("./desktop-owner-ipc-driver.js", import.meta.url).href,
    };
  }
  if (mode === "app-server") {
    if (moduleValue?.trim()) {
      throw new Error("CODEX_DRIVER_MODULE can only be used with CODEX_DRIVER=module");
    }
    return { mode, module: new URL("./app-server-driver.js", import.meta.url).href };
  }
  if (mode === "module") {
    return { mode, module: parseDriverModule(requireValue({ CODEX_DRIVER_MODULE: moduleValue }, "CODEX_DRIVER_MODULE"), cwd) };
  }
  throw new Error("CODEX_DRIVER must be auto, app-server, or module");
}

function splitCsv(value) {
  if (!value) return [];
  return [...new Set(value.split(",").map((item) => item.trim()).filter(Boolean))];
}

function parseBoolean(value, fallback, name) {
  if (value == null || value.trim() === "") return fallback;
  const normalized = value.trim().toLowerCase();
  if (normalized === "true") return true;
  if (normalized === "false") return false;
  throw new Error(`${name} must be true or false`);
}

function parsePositiveInteger(value, fallback, name, minimum, maximum = Number.MAX_SAFE_INTEGER) {
  if (value == null || value.trim() === "") return fallback;
  if (!/^\d+$/.test(value.trim())) throw new Error(`${name} must be an integer`);
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw new Error(`${name} must be between ${minimum} and ${maximum}`);
  }
  return number;
}
