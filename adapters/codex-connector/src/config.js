import { createHash, randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  statSync,
  unlinkSync,
} from "node:fs";
import { isIP } from "node:net";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_SERVER = "http://127.0.0.1:8000";
const DEFAULT_PAGE_LIMIT = 50;
const DEFAULT_REQUEST_TIMEOUT_MS = 15_000;
const DEFAULT_RECOVERY_INTERVAL_MS = 30_000;
const DEFAULT_RECONNECT_DELAY_MS = 2_000;
const DEFAULT_DELIVER_TYPES = ["request"];
const VALID_MESSAGE_TYPES = new Set(["text", "request", "result", "status"]);
const DEFAULT_MAX_TURNS_PER_SENDER_PER_HOUR = 10;
const DEFAULT_MAX_DELIVERIES_PER_RECOVERY = 20;
const DEFAULT_EGRESS_MAX_TEXT_BYTES = 8_192;
const CASE_INSENSITIVE_DIRECTORY_CACHE = new Map();

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
  const periodicRecoveryEnabled = parseBoolean(
    env.AICHAT_PERIODIC_RECOVERY_ENABLED,
    true,
    "AICHAT_PERIODIC_RECOVERY_ENABLED",
  );
  const autonomousTextEnabled = parseBoolean(
    env.AICHAT_AUTONOMOUS_TEXT_ENABLED,
    false,
    "AICHAT_AUTONOMOUS_TEXT_ENABLED",
  );
  if (deliverTypes.has("text") && !autonomousTextEnabled) {
    throw new Error(
      "Automatic text delivery requires AICHAT_AUTONOMOUS_TEXT_ENABLED=true explicitly",
    );
  }
  const stateFile = canonicalizePrivateStateFile(
    env.AICHAT_STATE_FILE?.trim()
      ? env.AICHAT_STATE_FILE.trim()
      : defaultStateFile(channelId, targetThreadId, targetHostId),
    "AICHAT_STATE_FILE",
  );
  const stateDirectory = dirname(stateFile);
  if (env.AICHAT_INSTANCE_LOCK_METADATA_PATH?.trim()) {
    throw new Error(
      "AICHAT_INSTANCE_LOCK_METADATA_PATH cannot be overridden; it is derived from AICHAT_STATE_FILE",
    );
  }
  const instanceLockMetadataPath = canonicalizePrivateStateFile(
    `${stateFile}.instance-lock.json`,
    "AICHAT_INSTANCE_LOCK_METADATA_PATH",
    stateDirectory,
  );
  assertDistinctStateFiles(stateFile, instanceLockMetadataPath);
  const expectedInstanceLockPort = defaultInstanceLockPort(channelId, targetThreadId, targetHostId);
  const instanceLockPort = parsePositiveInteger(
    env.AICHAT_INSTANCE_LOCK_PORT,
    expectedInstanceLockPort,
    "AICHAT_INSTANCE_LOCK_PORT",
    1_024,
    65_535,
  );
  if (instanceLockPort !== expectedInstanceLockPort) {
    throw new Error(
      "AICHAT_INSTANCE_LOCK_PORT cannot override the deterministic mapping lock port",
    );
  }
  const instanceStateLockPort = defaultStateLockPort(stateFile);
  const instanceLockIdentity = createHash("sha256")
    .update(`${channelId}\0${targetThreadId}\0${targetHostId ?? ""}\0${stateFile}`)
    .digest("hex");
  const maxTurnsPerSenderPerHour = parsePositiveInteger(
    env.AICHAT_MAX_TURNS_PER_SENDER_PER_HOUR,
    DEFAULT_MAX_TURNS_PER_SENDER_PER_HOUR,
    "AICHAT_MAX_TURNS_PER_SENDER_PER_HOUR",
    1,
    1_000,
  );
  const maxDeliveriesPerRecovery = parsePositiveInteger(
    env.AICHAT_MAX_DELIVERIES_PER_RECOVERY,
    DEFAULT_MAX_DELIVERIES_PER_RECOVERY,
    "AICHAT_MAX_DELIVERIES_PER_RECOVERY",
    1,
    200,
  );
  const autoReplyEnabled = parseBoolean(
    env.AICHAT_AUTO_REPLY_ENABLED,
    false,
    "AICHAT_AUTO_REPLY_ENABLED",
  );
  const lifecycleStatusEnabled = parseBoolean(
    env.AICHAT_LIFECYCLE_STATUS_ENABLED,
    true,
    "AICHAT_LIFECYCLE_STATUS_ENABLED",
  );
  const egressAudienceAcknowledged = parseBoolean(
    env.AICHAT_EGRESS_CHANNEL_AUDIENCE_ACK,
    false,
    "AICHAT_EGRESS_CHANNEL_AUDIENCE_ACK",
  );
  if (autoReplyEnabled && !egressAudienceAcknowledged) {
    throw new Error(
      "Automatic egress requires AICHAT_EGRESS_CHANNEL_AUDIENCE_ACK=true because replies are channel broadcasts",
    );
  }
  const egressAllowedReferenceHosts = new Set(
    splitCsv(env.AICHAT_EGRESS_ALLOWED_REFERENCE_HOSTS).map((value) => value.toLowerCase()),
  );
  const egressMaxTextBytes = parsePositiveInteger(
    env.AICHAT_EGRESS_MAX_TEXT_BYTES,
    DEFAULT_EGRESS_MAX_TEXT_BYTES,
    "AICHAT_EGRESS_MAX_TEXT_BYTES",
    1,
    100_000,
  );
  const egressCanary = autoReplyEnabled
    ? loadPrivateCanary(requireValue(env, "AICHAT_EGRESS_CANARY_FILE"))
    : null;

  const builtInSecurity = validateBuiltInSecurity(env, driver);

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
    periodicRecoveryEnabled,
    autonomousTextEnabled,
    stateFile,
    instanceLockMetadataPath,
    instanceLockPort,
    instanceStateLockPort,
    instanceLockIdentity,
    maxTurnsPerSenderPerHour,
    maxDeliveriesPerRecovery,
    autoReplyEnabled,
    lifecycleStatusEnabled,
    egressAudienceAcknowledged,
    egressAllowedReferenceHosts,
    egressMaxTextBytes,
    egressCanary,
    ...builtInSecurity,
  });
}

export function defaultStateFile(channelId, threadId, hostId) {
  const digest = createHash("sha256")
    .update(`${channelId}\0${threadId}\0${hostId ?? ""}`)
    .digest("hex")
    .slice(0, 24);
  return join(homedir(), ".aichat", "codex-connector", `${digest}.json`);
}

export function defaultInstanceLockPort(channelId, threadId, hostId) {
  const value = createHash("sha256")
    .update(`${channelId}\0${threadId}\0${hostId ?? ""}`)
    .digest()
    .readUInt32BE(0);
  return 42_000 + (value % 20_000);
}

export function defaultStateLockPort(stateFile) {
  const value = createHash("sha256").update(resolve(stateFile)).digest().readUInt32BE(0);
  return 20_000 + (value % 20_000);
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
  if (url.protocol === "http:" && !isLoopbackHostname(url.hostname)) {
    throw new Error("AICHAT_SERVER must use https outside localhost or loopback addresses");
  }
  if (url.username || url.password) throw new Error("AICHAT_SERVER must not contain credentials");
  if (url.search || url.hash) throw new Error("AICHAT_SERVER must not contain query or fragment data");
  url.pathname = url.pathname.replace(/\/+$/, "");
  return url.toString().replace(/\/$/, "");
}

function isLoopbackHostname(value) {
  const hostname = value.toLowerCase().replace(/^\[|\]$/g, "");
  if (hostname === "localhost" || hostname.endsWith(".localhost")) return true;
  const family = isIP(hostname);
  if (family === 4) return hostname.startsWith("127.");
  return family === 6 && hostname === "::1";
}

function canonicalizePrivateStateFile(pathValue, name, requiredParent = null) {
  const candidate = resolve(pathValue);
  let fileDetails = null;
  try {
    fileDetails = lstatSync(candidate);
  } catch (error) {
    if (error?.code !== "ENOENT") throw new Error(`${name} could not be inspected safely`);
  }
  if (fileDetails?.isSymbolicLink()) {
    throw new Error(`${name} must not be a symlink or reparse-point file`);
  }
  if (fileDetails && !fileDetails.isFile()) {
    throw new Error(`${name} must identify a regular file`);
  }

  const lexicalParent = dirname(candidate);
  try {
    mkdirSync(lexicalParent, { recursive: true, mode: 0o700 });
  } catch {
    throw new Error(`${name} parent directory could not be created safely`);
  }
  let canonicalParent;
  let parentDetails;
  try {
    canonicalParent = realpathSync(lexicalParent);
    parentDetails = statSync(canonicalParent);
  } catch {
    throw new Error(`${name} parent directory could not be canonicalized safely`);
  }
  if (!parentDetails.isDirectory()) throw new Error(`${name} parent must be a directory`);
  if (typeof process.getuid === "function" && parentDetails.uid !== process.getuid()) {
    throw new Error(`${name} parent directory must be owned by the current user`);
  }
  if (
    process.platform !== "win32" &&
    ((parentDetails.mode & 0o077) !== 0 || (parentDetails.mode & 0o700) !== 0o700)
  ) {
    throw new Error(`${name} parent directory permissions must be 0700`);
  }
  if (requiredParent && canonicalParent !== requiredParent) {
    throw new Error(`${name} must stay beside AICHAT_STATE_FILE in its private directory`);
  }

  const canonicalName = canonicalStateBasename(canonicalParent, basename(candidate));
  const canonical = join(canonicalParent, canonicalName);
  if (fileDetails) {
    let actual;
    let actualDetails;
    try {
      actual = realpathSync(candidate);
      actualDetails = statSync(actual);
    } catch {
      throw new Error(`${name} existing file could not be canonicalized safely`);
    }
    if (
      !actualDetails.isFile() ||
      dirname(actual) !== canonicalParent ||
      canonicalStateBasename(canonicalParent, basename(actual)) !== canonicalName
    ) {
      throw new Error(`${name} existing file has an unsafe alias or type`);
    }
    if (actualDetails.nlink !== 1) {
      throw new Error(`${name} existing file must not have hardlink aliases`);
    }
    if (typeof process.getuid === "function" && actualDetails.uid !== process.getuid()) {
      throw new Error(`${name} existing file must be owned by the current user`);
    }
    if (process.platform !== "win32" && (actualDetails.mode & 0o077) !== 0) {
      throw new Error(`${name} existing file permissions must be 0600 or stricter`);
    }
    return actual;
  }
  return canonical;
}

function canonicalStateBasename(directory, value) {
  if (!/^[A-Za-z0-9._-]+$/.test(value)) {
    throw new Error(
      "AICHAT_STATE_FILE basename must use only ASCII letters, digits, dot, underscore, or hyphen",
    );
  }
  return isCaseInsensitiveDirectory(directory) ? value.toLowerCase() : value;
}

function isCaseInsensitiveDirectory(directory) {
  if (CASE_INSENSITIVE_DIRECTORY_CACHE.has(directory)) {
    return CASE_INSENSITIVE_DIRECTORY_CACHE.get(directory);
  }
  const token = randomUUID();
  const probeName = `.aichat-case-probe-${token}-Aa`;
  const probePath = join(directory, probeName);
  const aliasPath = join(directory, probeName.toLowerCase());
  let descriptor;
  let insensitive = false;
  try {
    descriptor = openSync(probePath, "wx", 0o600);
    insensitive = existsSync(aliasPath);
  } catch {
    throw new Error("Private state directory case semantics could not be verified safely");
  } finally {
    if (descriptor != null) closeSync(descriptor);
    try {
      unlinkSync(probePath);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  CASE_INSENSITIVE_DIRECTORY_CACHE.set(directory, insensitive);
  return insensitive;
}

function assertDistinctStateFiles(stateFile, metadataFile) {
  if (stateFile === metadataFile) {
    throw new Error("Connector state and instance-lock metadata must use distinct files");
  }
  if (!existsSync(stateFile) || !existsSync(metadataFile)) return;
  const stateDetails = statSync(stateFile);
  const metadataDetails = statSync(metadataFile);
  if (stateDetails.dev === metadataDetails.dev && stateDetails.ino === metadataDetails.ino) {
    throw new Error("Connector state and instance-lock metadata must not be hardlink aliases");
  }
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
  const mode = value?.trim().toLowerCase() || (moduleValue?.trim() ? "module" : "app-server");
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

function validateBuiltInSecurity(env, driver) {
  if (driver.mode === "module") {
    return {
      connectorTaskOwned: null,
      connectorTaskMarker: null,
      appServerCwd: null,
      appServerApprovalPolicy: null,
      appServerSandboxPolicy: null,
      ownerIpcEnabled: null,
    };
  }
  if (!parseBoolean(env.CODEX_CONNECTOR_TASK_OWNED, false, "CODEX_CONNECTOR_TASK_OWNED")) {
    throw new Error("Built-in Codex drivers require CODEX_CONNECTOR_TASK_OWNED=true");
  }
  const connectorTaskMarker = requireValue(env, "CODEX_CONNECTOR_TASK_MARKER");
  if (connectorTaskMarker.length < 16 || connectorTaskMarker.length > 200) {
    throw new Error("CODEX_CONNECTOR_TASK_MARKER must contain 16 through 200 characters");
  }
  const rawCwd = requireValue(env, "CODEX_APP_SERVER_CWD");
  if (!isAbsolute(rawCwd)) throw new Error("CODEX_APP_SERVER_CWD must be absolute");
  let appServerCwd;
  let cwdDetails;
  try {
    appServerCwd = realpathSync(rawCwd);
    cwdDetails = statSync(appServerCwd);
  } catch {
    throw new Error("CODEX_APP_SERVER_CWD must exist before the connector starts");
  }
  if (!cwdDetails.isDirectory()) throw new Error("CODEX_APP_SERVER_CWD must be a directory");
  const appServerApprovalPolicy = requireValue(env, "CODEX_APP_SERVER_APPROVAL_POLICY");
  if (appServerApprovalPolicy !== "never") {
    throw new Error("Connector-owned Codex turns require CODEX_APP_SERVER_APPROVAL_POLICY=never");
  }
  const appServerSandboxPolicy = parseRequiredSafeSandbox(
    requireValue(env, "CODEX_APP_SERVER_SANDBOX_POLICY_JSON"),
    appServerCwd,
  );
  const ownerIpcEnabled = parseBoolean(
    env.CODEX_DESKTOP_OWNER_IPC_ENABLED,
    false,
    "CODEX_DESKTOP_OWNER_IPC_ENABLED",
  );
  if (
    ownerIpcEnabled &&
    !parseBoolean(env.CODEX_CONNECTOR_OWNER_RISK_ACK, false, "CODEX_CONNECTOR_OWNER_RISK_ACK")
  ) {
    throw new Error(
      "Desktop owner IPC requires CODEX_CONNECTOR_OWNER_RISK_ACK=true for the fixed experimental build",
    );
  }
  return {
    connectorTaskOwned: true,
    connectorTaskMarker,
    appServerCwd,
    appServerApprovalPolicy,
    appServerSandboxPolicy,
    ownerIpcEnabled,
  };
}

function parseRequiredSafeSandbox(value, cwd) {
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error("CODEX_APP_SERVER_SANDBOX_POLICY_JSON must be valid JSON");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("CODEX_APP_SERVER_SANDBOX_POLICY_JSON must be a JSON object");
  }
  if (parsed.type !== "readOnly" && parsed.type !== "workspaceWrite") {
    throw new Error("Connector sandbox must be readOnly or workspaceWrite");
  }
  if (parsed.networkAccess !== false) {
    throw new Error("Connector sandbox networkAccess must be false");
  }
  if (parsed.type === "workspaceWrite") {
    const roots = parsed.writableRoots ?? [];
    if (!Array.isArray(roots) || roots.some((root) => typeof root !== "string" || !root)) {
      throw new Error("Connector workspaceWrite writableRoots must be an array of absolute paths");
    }
    const normalizedCwd = realpathSync(cwd);
    for (const root of roots) {
      if (!isAbsolute(root)) throw new Error("Connector writableRoots must be absolute");
      let normalizedRoot;
      try {
        normalizedRoot = realpathSync(root);
      } catch {
        throw new Error("Connector writableRoots must exist and resolve without symlink ambiguity");
      }
      const relation = relative(normalizedCwd, normalizedRoot);
      if (relation === ".." || relation.startsWith(`..${sep}`) || isAbsolute(relation)) {
        throw new Error("Connector writableRoots must stay inside CODEX_APP_SERVER_CWD");
      }
    }
  }
  return Object.freeze(structuredClone(parsed));
}

function loadPrivateCanary(pathValue) {
  const path = resolve(pathValue);
  let details;
  let value;
  try {
    details = statSync(path);
    value = readFileSync(path, "utf8").trim();
  } catch {
    throw new Error("AICHAT_EGRESS_CANARY_FILE must be a readable private file");
  }
  if (!details.isFile()) throw new Error("AICHAT_EGRESS_CANARY_FILE must be a regular file");
  if (process.platform !== "win32" && (details.mode & 0o077) !== 0) {
    throw new Error("AICHAT_EGRESS_CANARY_FILE permissions must be 0600 or stricter");
  }
  if (value.length < 16 || value.length > 512 || value.includes("\n")) {
    throw new Error("AICHAT_EGRESS_CANARY_FILE must contain one 16 through 512 character canary");
  }
  return value;
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
