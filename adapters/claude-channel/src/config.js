import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const DEFAULT_SERVER = "http://127.0.0.1:8000";
const DEFAULT_POLL_INTERVAL_MS = 2_000;
const DEFAULT_REQUEST_TIMEOUT_MS = 15_000;
const DEFAULT_PAGE_LIMIT = 100;
const DEFAULT_DELIVER_TYPES = ["text", "request"];
const VALID_MESSAGE_TYPES = new Set(["text", "request", "result", "status"]);

export function loadConfig(env = process.env) {
  const server = parseServer(env.AICHAT_SERVER ?? DEFAULT_SERVER);
  const token = requireValue(env, "AICHAT_TOKEN");
  const channelId = requireValue(env, "AICHAT_CHANNEL_ID");
  const allowedSenderIds = parseAllowedSenders(env.AICHAT_ALLOWED_SENDER_IDS);
  const deliverTypes = parseDeliverTypes(env.AICHAT_DELIVER_TYPES);
  const pollIntervalMs = parsePositiveInteger(
    env.AICHAT_POLL_INTERVAL_MS,
    DEFAULT_POLL_INTERVAL_MS,
    "AICHAT_POLL_INTERVAL_MS",
    100,
  );
  const requestTimeoutMs = parsePositiveInteger(
    env.AICHAT_REQUEST_TIMEOUT_MS,
    DEFAULT_REQUEST_TIMEOUT_MS,
    "AICHAT_REQUEST_TIMEOUT_MS",
    1_000,
  );
  const pageLimit = parsePositiveInteger(
    env.AICHAT_PAGE_LIMIT,
    DEFAULT_PAGE_LIMIT,
    "AICHAT_PAGE_LIMIT",
    1,
    200,
  );

  const cursorFile = env.AICHAT_CURSOR_FILE?.trim()
    ? resolve(env.AICHAT_CURSOR_FILE.trim())
    : defaultCursorFile(channelId);

  return Object.freeze({
    server,
    token,
    channelId,
    allowedSenderIds,
    deliverTypes,
    pollIntervalMs,
    requestTimeoutMs,
    pageLimit,
    cursorFile,
  });
}

export function defaultCursorFile(channelId) {
  const digest = createHash("sha256").update(channelId).digest("hex").slice(0, 24);
  return join(homedir(), ".aichat", "claude-channel", `${digest}.json`);
}

function requireValue(env, name) {
  const value = env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is required`);
  }
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
  url.pathname = url.pathname.replace(/\/+$/, "");
  url.search = "";
  url.hash = "";
  return url.toString().replace(/\/$/, "");
}

function parseAllowedSenders(value) {
  const senders = new Set(splitCsv(value));
  if (senders.size === 0) {
    throw new Error(
      "AICHAT_ALLOWED_SENDER_IDS is required and must contain at least one relay agent ID",
    );
  }
  if (senders.has("*")) {
    throw new Error("AICHAT_ALLOWED_SENDER_IDS cannot contain wildcard '*'");
  }
  return senders;
}

function parseDeliverTypes(value) {
  const values = value == null || value.trim() === "" ? DEFAULT_DELIVER_TYPES : splitCsv(value);
  const types = new Set(values);
  if (types.size === 0) {
    throw new Error("AICHAT_DELIVER_TYPES cannot be empty");
  }
  for (const type of types) {
    if (!VALID_MESSAGE_TYPES.has(type)) {
      throw new Error(`AICHAT_DELIVER_TYPES contains unsupported message type: ${type}`);
    }
  }
  return types;
}

function splitCsv(value) {
  if (!value) return [];
  return [...new Set(value.split(",").map((item) => item.trim()).filter(Boolean))];
}

function parsePositiveInteger(value, fallback, name, minimum, maximum = Number.MAX_SAFE_INTEGER) {
  if (value == null || value.trim() === "") return fallback;
  if (!/^\d+$/.test(value.trim())) {
    throw new Error(`${name} must be an integer`);
  }
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < minimum || number > maximum) {
    throw new Error(`${name} must be between ${minimum} and ${maximum}`);
  }
  return number;
}
