import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const DEFAULT_SERVER = "http://127.0.0.1:8000";
const DEFAULT_POLL_INTERVAL_MS = 2_000;
const DEFAULT_REQUEST_TIMEOUT_MS = 15_000;
const DEFAULT_GROK_TIMEOUT_MS = 600_000;
const DEFAULT_PAGE_LIMIT = 100;
const DEFAULT_MAX_OUTPUT_BYTES = 1_048_576;
const DEFAULT_MAX_PROMPT_CHARS = 24_000;

export function loadConfig(env = process.env, { cwd = process.cwd() } = {}) {
  if (env.AICHAT_GROK_BRIDGE_ENABLED?.trim().toLowerCase() !== "true") {
    throw new Error(
      "AIChat Grok bridge is disabled; set AICHAT_GROK_BRIDGE_ENABLED=true to run it explicitly",
    );
  }

  const server = parseServer(env.AICHAT_SERVER ?? DEFAULT_SERVER);
  const token = requireValue(env, "AICHAT_TOKEN");
  const channelId = requireValue(env, "AICHAT_CHANNEL_ID");
  const allowedSenderIds = parseAllowedSenders(env.AICHAT_ALLOWED_SENDER_IDS);
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
  const grokTimeoutMs = parsePositiveInteger(
    env.GROK_TIMEOUT_MS,
    DEFAULT_GROK_TIMEOUT_MS,
    "GROK_TIMEOUT_MS",
    1_000,
  );
  const pageLimit = parsePositiveInteger(
    env.AICHAT_PAGE_LIMIT,
    DEFAULT_PAGE_LIMIT,
    "AICHAT_PAGE_LIMIT",
    1,
    200,
  );
  const maxOutputBytes = parsePositiveInteger(
    env.GROK_MAX_OUTPUT_BYTES,
    DEFAULT_MAX_OUTPUT_BYTES,
    "GROK_MAX_OUTPUT_BYTES",
    1_024,
    20 * 1_048_576,
  );
  const maxPromptChars = parsePositiveInteger(
    env.GROK_MAX_PROMPT_CHARS,
    DEFAULT_MAX_PROMPT_CHARS,
    "GROK_MAX_PROMPT_CHARS",
    1_000,
    100_000,
  );
  const stateFile = env.AICHAT_STATE_FILE?.trim()
    ? resolve(env.AICHAT_STATE_FILE.trim())
    : defaultStateFile(channelId);
  const grokCommand = env.GROK_COMMAND?.trim() || "grok";
  const grokBaseArgs = parseStringArray(env.GROK_BASE_ARGS_JSON, "GROK_BASE_ARGS_JSON");
  const grokWorkingDirectory = resolve(env.GROK_WORKDIR?.trim() || cwd);

  return Object.freeze({
    server,
    token,
    channelId,
    allowedSenderIds,
    pollIntervalMs,
    requestTimeoutMs,
    grokTimeoutMs,
    pageLimit,
    maxOutputBytes,
    maxPromptChars,
    stateFile,
    grokCommand,
    grokBaseArgs,
    grokWorkingDirectory,
  });
}

export function defaultStateFile(channelId) {
  const digest = createHash("sha256").update(channelId).digest("hex").slice(0, 24);
  return join(homedir(), ".aichat", "grok-bridge", `${digest}.json`);
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

function splitCsv(value) {
  if (!value) return [];
  return [...new Set(value.split(",").map((item) => item.trim()).filter(Boolean))];
}

function parseStringArray(value, name) {
  if (value == null || value.trim() === "") return [];
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error(`${name} must be a JSON array of strings`);
  }
  if (!Array.isArray(parsed) || parsed.some((item) => typeof item !== "string")) {
    throw new Error(`${name} must be a JSON array of strings`);
  }
  return parsed;
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
