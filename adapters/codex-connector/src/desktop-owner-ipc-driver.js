import { randomUUID } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { connect } from "node:net";

import {
  AppServerDriver,
  DeliveryStartError,
  REPLY_OUTPUT_SCHEMA,
} from "./app-server-driver.js";
import { assertCodexDriver } from "./driver.js";

const SUPPORTED_DESKTOP_VERSION = "26.730.61639";
const FOLLOWING_VERSION = 1;
const STREAM_STATE_VERSION = 11;
const START_TURN_VERSION = 1;
const DEFAULT_MAX_FRAME_BYTES = 4 * 1024 * 1024;
const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;
const DEFAULT_RECONNECT_DELAY_MS = 1_000;
const DEFAULT_TURN_TIMEOUT_MS = 10 * 60_000;
const PROHIBITED_PATH_KEYS = new Set(["__proto__", "prototype", "constructor"]);

export class DesktopOwnerIpcDriver {
  constructor(options = {}) {
    this.options = options;
    this.logger = options.logger ?? console;
    this.env = options.env ?? process.env;
    this.appServer =
      options.appServerDriver ??
      new AppServerDriver({
        ...options,
        env: this.env,
        logger: this.logger,
      });
    this.ownerClient =
      options.ownerClient ??
      new DesktopOwnerIpcClient({
        env: this.env,
        logger: this.logger,
        connectImpl: options.connectImpl,
        timers: options.timers,
      });
    this.binding = null;
    this.started = false;
  }

  async start({ binding, onOutboundReply }) {
    if (this.started) throw new Error("Desktop owner IPC driver is already started");
    if (binding?.hostId != null) {
      throw new Error(
        "Desktop owner IPC driver is local-only; use CODEX_DRIVER=module for a remote host",
      );
    }
    this.binding = Object.freeze({ ...binding });
    await this.appServer.start({ binding, onOutboundReply });
    await this.ownerClient.start({ threadId: binding.threadId });
    this.started = true;
  }

  deliver(request) {
    if (!this.started) throw new Error("Desktop owner IPC driver is not running");
    const externalStarter = this.ownerClient.featureEnabled
      ? (envelope) =>
          this.ownerClient.startTurn({
            threadId: request.threadId,
            envelope,
            deliveryId: request.deliveryId,
          })
      : null;
    return this.appServer.deliver(request, { externalStarter });
  }

  async stop() {
    await Promise.allSettled([this.ownerClient.stop(), this.appServer.stop()]);
  }
}

export class DesktopOwnerIpcClient {
  constructor({
    env = process.env,
    logger = console,
    connectImpl = connect,
    timers = globalThis,
  } = {}) {
    this.env = env;
    this.logger = logger;
    this.connectImpl = connectImpl ?? connect;
    this.timers = timers;
    this.featureEnabled = parseBoolean(env.CODEX_DESKTOP_OWNER_IPC_ENABLED, true);
    this.expectedVersion =
      env.CODEX_DESKTOP_EXPECTED_VERSION?.trim() || SUPPORTED_DESKTOP_VERSION;
    this.appPath = env.CODEX_DESKTOP_APP_PATH?.trim() || "/Applications/ChatGPT.app";
    this.socketPath =
      env.CODEX_DESKTOP_IPC_SOCKET?.trim() || join(homedir(), ".codex", "ipc", "ipc.sock");
    this.hostId = env.CODEX_DESKTOP_OWNER_HOST_ID?.trim() || "local";
    this.maxFrameBytes = integerSetting(
      env.CODEX_DESKTOP_IPC_MAX_FRAME_BYTES,
      DEFAULT_MAX_FRAME_BYTES,
      1_024,
      16 * 1024 * 1024,
      "CODEX_DESKTOP_IPC_MAX_FRAME_BYTES",
    );
    this.requestTimeoutMs = integerSetting(
      env.CODEX_DESKTOP_IPC_REQUEST_TIMEOUT_MS,
      DEFAULT_REQUEST_TIMEOUT_MS,
      1_000,
      5 * 60_000,
      "CODEX_DESKTOP_IPC_REQUEST_TIMEOUT_MS",
    );
    this.reconnectDelayMs = integerSetting(
      env.CODEX_DESKTOP_IPC_RECONNECT_DELAY_MS,
      DEFAULT_RECONNECT_DELAY_MS,
      100,
      60_000,
      "CODEX_DESKTOP_IPC_RECONNECT_DELAY_MS",
    );
    this.turnTimeoutMs = integerSetting(
      env.CODEX_DESKTOP_IPC_TURN_TIMEOUT_MS,
      DEFAULT_TURN_TIMEOUT_MS,
      5_000,
      24 * 60 * 60_000,
      "CODEX_DESKTOP_IPC_TURN_TIMEOUT_MS",
    );
    this.threadId = null;
    this.socket = null;
    this.clientId = null;
    this.pending = new Map();
    this.turnWaiters = new Map();
    this.buffer = Buffer.alloc(0);
    this.connecting = null;
    this.reconnectTimer = null;
    this.stopped = false;
    this.streamState = null;
    this.streamRevision = null;
    this.following = false;
  }

  async start({ threadId }) {
    this.threadId = threadId;
    if (!this.featureEnabled) return;
    if (process.platform !== "darwin") {
      this.featureEnabled = false;
      this.logger.error(
        "[aichat-codex-driver] Desktop owner IPC is macOS-only; app-server fallback is active",
      );
      return;
    }
    try {
      await this.#verifyDesktopBuild();
      await this.#ensureConnected();
    } catch {
      this.logger.error(
        "[aichat-codex-driver] Desktop owner IPC probe failed; app-server fallback is active",
      );
      this.#scheduleReconnect();
    }
  }

  async startTurn({ threadId, envelope, deliveryId }) {
    if (!this.featureEnabled) throw new Error("Desktop owner IPC feature is disabled");
    if (threadId !== this.threadId) throw new Error("Desktop owner IPC thread mapping mismatch");
    try {
      await this.#ensureConnected();
      this.#setFollowing(true);
    } catch (error) {
      throw new DeliveryStartError(
        "Desktop owner IPC was unavailable before the turn-start request was written",
        "pre-send",
        { cause: error },
      );
    }
    let response;
    try {
      response = await this.#request(
        "thread-follower-start-turn",
        {
          conversationId: threadId,
          turnStartParams: {
            input: [{ type: "text", text: envelope, text_elements: [] }],
            clientUserMessageId: deliveryId,
            outputSchema: REPLY_OUTPUT_SCHEMA,
            responsesapiClientMetadata: { aichat_delivery_id: deliveryId },
          },
        },
        { version: START_TURN_VERSION, timeoutMs: this.requestTimeoutMs },
      );
    } catch (error) {
      try {
        this.#setFollowing(false);
      } catch {}
      throw error;
    }
    const turnId = response?.result?.result?.turn?.id;
    if (typeof turnId !== "string" || !turnId) {
      throw new DeliveryStartError(
        "Desktop owner IPC start-turn response is missing turn ID",
        "ambiguous",
      );
    }
    const completion = this.#waitForTurn(turnId);
    this.#inspectTurnWaiters();
    return { turnId, completion };
  }

  async stop() {
    if (this.stopped) return;
    this.stopped = true;
    if (this.reconnectTimer) this.timers.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    if (this.socket?.writable && this.following) {
      try {
        this.#setFollowing(false);
      } catch {}
    }
    this.#dropConnection("Desktop owner IPC stopped");
  }

  async #verifyDesktopBuild() {
    const plist = await readFile(join(this.appPath, "Contents", "Info.plist"), "utf8");
    const current = plistValue(plist, "CFBundleShortVersionString");
    if (!current || current !== this.expectedVersion) {
      this.featureEnabled = false;
      throw new Error("Desktop build is not compatible with the private owner IPC driver");
    }
  }

  async #ensureConnected() {
    if (this.stopped) throw new Error("Desktop owner IPC client is stopped");
    if (this.socket?.writable && this.clientId) return;
    if (this.connecting) return this.connecting;
    this.connecting = this.#connectAndInitialize().finally(() => {
      this.connecting = null;
    });
    return this.connecting;
  }

  async #connectAndInitialize() {
    await validateSocket(this.socketPath);
    const socket = await new Promise((resolve, reject) => {
      let settled = false;
      const candidate = this.connectImpl(this.socketPath, () => {
        if (settled) return;
        settled = true;
        resolve(candidate);
      });
      candidate.once("error", () => {
        if (settled) return;
        settled = true;
        reject(new Error("Desktop owner IPC connection failed"));
      });
    });
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => this.#readFrames(Buffer.from(chunk)));
    socket.on("error", () => this.#dropConnection("Desktop owner IPC transport error"));
    socket.on("close", () => {
      this.#dropConnection("Desktop owner IPC connection closed");
      this.#scheduleReconnect();
    });
    let response;
    try {
      response = await this.#request(
        "initialize",
        { clientType: "aichat-codex-connector" },
        { includeVersion: false, timeoutMs: 10_000 },
      );
    } catch (error) {
      this.#dropConnection("Desktop owner IPC initialize failed");
      throw error;
    }
    const clientId = response?.result?.clientId;
    if (typeof clientId !== "string" || !clientId) {
      throw new Error("Desktop owner IPC initialize response is missing clientId");
    }
    this.clientId = clientId;
  }

  #request(method, params, { version, includeVersion = true, timeoutMs }) {
    if (!this.socket?.writable) {
      return Promise.reject(
        new DeliveryStartError("Desktop owner IPC is disconnected", "pre-send"),
      );
    }
    const requestId = randomUUID();
    const result = deferred();
    const timeout = this.timers.setTimeout(() => {
      const pending = this.pending.get(requestId);
      if (!pending || !this.pending.delete(requestId)) return;
      result.reject(
        new DeliveryStartError(
          `Desktop owner IPC ${method} request timed out`,
          pending.sent ? "ambiguous" : "pre-send",
        ),
      );
    }, timeoutMs);
    const pending = { method, result, timeout, sent: false };
    this.pending.set(requestId, pending);
    const message = {
      type: "request",
      requestId,
      ...(this.clientId ? { sourceClientId: this.clientId } : {}),
      method,
      ...(includeVersion ? { version } : {}),
      params,
      timeoutMs,
    };
    try {
      pending.sent = true;
      this.#writeFrame(message);
    } catch (error) {
      pending.sent = false;
      this.pending.delete(requestId);
      this.timers.clearTimeout(timeout);
      result.reject(
        new DeliveryStartError(
          `Desktop owner IPC ${method} request could not be written`,
          "pre-send",
          { cause: error },
        ),
      );
    }
    return result.promise;
  }

  #setFollowing(following) {
    if (!this.socket?.writable || !this.clientId) {
      throw new Error("Desktop owner IPC is not initialized");
    }
    this.following = following;
    if (!following) {
      this.streamState = null;
      this.streamRevision = null;
    }
    this.#writeFrame({
      type: "broadcast",
      method: "thread-stream-following-changed",
      version: FOLLOWING_VERSION,
      sourceClientId: this.clientId,
      params: {
        conversationId: this.threadId,
        hostId: this.hostId,
        following,
      },
    });
  }

  #readFrames(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 4) {
      const length = this.buffer.readUInt32LE(0);
      if (length <= 0 || length > this.maxFrameBytes) {
        this.#dropConnection("Desktop owner IPC frame exceeded the configured limit");
        return;
      }
      if (this.buffer.length < 4 + length) return;
      const payload = this.buffer.subarray(4, 4 + length);
      this.buffer = this.buffer.subarray(4 + length);
      let message;
      try {
        message = JSON.parse(payload.toString("utf8"));
      } catch {
        this.#dropConnection("Desktop owner IPC sent invalid JSON");
        return;
      }
      this.#handleMessage(message);
    }
  }

  #handleMessage(message) {
    if (!message || typeof message !== "object") return;
    if (message.type === "client-discovery-request" && typeof message.requestId === "string") {
      this.#writeFrame({
        type: "client-discovery-response",
        requestId: message.requestId,
        response: { canHandle: false },
      });
      return;
    }
    if (message.type === "response" && typeof message.requestId === "string") {
      const pending = this.pending.get(message.requestId);
      if (!pending) return;
      this.pending.delete(message.requestId);
      this.timers.clearTimeout(pending.timeout);
      if (message.resultType === "success") pending.result.resolve(message);
      else {
        pending.result.reject(
          new DeliveryStartError(
            `Desktop owner IPC ${pending.method} failed`,
            "rejected",
          ),
        );
      }
      return;
    }
    if (
      message.type === "broadcast" &&
      message.method === "thread-stream-state-changed" &&
      message.version === STREAM_STATE_VERSION
    ) {
      this.#handleStreamChange(message);
    }
  }

  #handleStreamChange(message) {
    if (
      message.targetClientIds != null &&
      (!Array.isArray(message.targetClientIds) || !message.targetClientIds.includes(this.clientId))
    ) {
      return;
    }
    const params = message.params;
    if (
      params?.conversationId !== this.threadId ||
      params?.hostId !== this.hostId ||
      !params.change ||
      typeof params.change !== "object"
    ) {
      return;
    }
    const change = params.change;
    if (
      change.type === "snapshot" &&
      Number.isInteger(change.revision) &&
      change.conversationState &&
      typeof change.conversationState === "object"
    ) {
      this.streamState = structuredClone(change.conversationState);
      this.streamRevision = change.revision;
      this.#inspectTurnWaiters();
      return;
    }
    if (
      change.type === "patches" &&
      Number.isInteger(change.baseRevision) &&
      Number.isInteger(change.revision) &&
      Array.isArray(change.patches)
    ) {
      if (this.streamState == null || change.baseRevision !== this.streamRevision) {
        this.streamState = null;
        this.streamRevision = null;
        try {
          this.#setFollowing(true);
        } catch {}
        return;
      }
      try {
        for (const patch of change.patches) applyPatch(this.streamState, patch);
      } catch {
        this.streamState = null;
        this.streamRevision = null;
        try {
          this.#setFollowing(true);
        } catch {}
        return;
      }
      this.streamRevision = change.revision;
      this.#inspectTurnWaiters();
    }
  }

  #waitForTurn(turnId) {
    const completion = deferred();
    const timeout = this.timers.setTimeout(() => {
      if (!this.turnWaiters.delete(turnId)) return;
      completion.reject(new Error("Desktop owner IPC turn completion timed out"));
      try {
        this.#setFollowing(false);
      } catch {}
    }, this.turnTimeoutMs);
    this.turnWaiters.set(turnId, { completion, timeout });
    return completion.promise;
  }

  #inspectTurnWaiters() {
    const entities = this.streamState?.turnHistory?.history?.entitiesByKey;
    if (!entities || typeof entities !== "object") return;
    for (const [turnId, waiter] of this.turnWaiters) {
      const entity = Object.values(entities).find((candidate) => candidate?.turnId === turnId);
      if (!entity || entity.status === "inProgress") continue;
      const items = Array.isArray(entity.items) ? entity.items : [];
      let finalText = null;
      for (let index = items.length - 1; index >= 0; index -= 1) {
        if (items[index]?.type === "agentMessage" && typeof items[index].text === "string") {
          finalText = items[index].text;
          break;
        }
      }
      this.turnWaiters.delete(turnId);
      this.timers.clearTimeout(waiter.timeout);
      waiter.completion.resolve({ status: entity.status, finalText });
      try {
        this.#setFollowing(false);
      } catch {}
    }
  }

  #writeFrame(message) {
    if (!this.socket?.writable) throw new Error("Desktop owner IPC socket is unavailable");
    const payload = Buffer.from(JSON.stringify(message), "utf8");
    if (payload.length <= 0 || payload.length > this.maxFrameBytes) {
      throw new Error("Desktop owner IPC outbound frame exceeded the configured limit");
    }
    const frame = Buffer.allocUnsafe(4 + payload.length);
    frame.writeUInt32LE(payload.length, 0);
    payload.copy(frame, 4);
    this.socket.write(frame);
  }

  #dropConnection(message) {
    const socket = this.socket;
    this.socket = null;
    this.clientId = null;
    this.following = false;
    this.streamState = null;
    this.streamRevision = null;
    this.buffer = Buffer.alloc(0);
    for (const [requestId, pending] of this.pending) {
      this.timers.clearTimeout(pending.timeout);
      pending.result.reject(
        new DeliveryStartError(message, pending.sent ? "ambiguous" : "pre-send"),
      );
      this.pending.delete(requestId);
    }
    for (const [turnId, waiter] of this.turnWaiters) {
      this.timers.clearTimeout(waiter.timeout);
      waiter.completion.reject(new Error(message));
      this.turnWaiters.delete(turnId);
    }
    if (socket && !socket.destroyed) socket.destroy();
  }

  #scheduleReconnect() {
    if (this.stopped || !this.featureEnabled || this.reconnectTimer) return;
    this.reconnectTimer = this.timers.setTimeout(() => {
      this.reconnectTimer = null;
      this.#ensureConnected().catch(() => this.#scheduleReconnect());
    }, this.reconnectDelayMs);
  }
}

export function applyPatch(root, patch) {
  if (!patch || typeof patch !== "object") throw new Error("Invalid Desktop stream patch");
  if (!Array.isArray(patch.path) || patch.path.length === 0 || patch.path.length > 100) {
    throw new Error("Invalid Desktop stream patch path");
  }
  const path = patch.path.map(validatePathSegment);
  let target = root;
  for (let index = 0; index < path.length - 1; index += 1) {
    const segment = path[index];
    if (target == null || typeof target !== "object" || !(segment in target)) {
      throw new Error("Desktop stream patch parent does not exist");
    }
    target = target[segment];
  }
  if (target == null || typeof target !== "object") {
    throw new Error("Desktop stream patch target is invalid");
  }
  const key = path.at(-1);
  if (Array.isArray(target)) {
    const index = arrayIndex(key, target.length, patch.op === "add");
    if (patch.op === "add") target.splice(index, 0, structuredClone(patch.value));
    else if (patch.op === "replace") {
      if (index >= target.length) throw new Error("Desktop stream replace index is missing");
      target[index] = structuredClone(patch.value);
    } else if (patch.op === "remove") {
      if (index >= target.length) throw new Error("Desktop stream remove index is missing");
      target.splice(index, 1);
    } else throw new Error("Unsupported Desktop stream patch operation");
    return root;
  }
  if (patch.op === "add" || patch.op === "replace") {
    target[key] = structuredClone(patch.value);
  } else if (patch.op === "remove") {
    if (!(key in target)) throw new Error("Desktop stream remove key is missing");
    delete target[key];
  } else throw new Error("Unsupported Desktop stream patch operation");
  return root;
}

export async function validateSocket(path) {
  const details = await stat(path);
  if (!details.isSocket()) throw new Error("Desktop owner IPC path is not a socket");
  if (typeof process.getuid === "function" && details.uid !== process.getuid()) {
    throw new Error("Desktop owner IPC socket is owned by a different user");
  }
  if ((details.mode & 0o777) !== 0o600) {
    throw new Error("Desktop owner IPC socket permissions must be 0600");
  }
}

export async function createCodexDriver(options = {}) {
  return assertCodexDriver(new DesktopOwnerIpcDriver(options));
}

function parseBoolean(value, fallback) {
  if (value == null || value.trim() === "") return fallback;
  const normalized = value.trim().toLowerCase();
  if (normalized === "true") return true;
  if (normalized === "false") return false;
  throw new Error("CODEX_DESKTOP_OWNER_IPC_ENABLED must be true or false");
}

function integerSetting(value, fallback, minimum, maximum, name) {
  if (value == null || value.trim() === "") return fallback;
  if (!/^\d+$/.test(value.trim())) throw new Error(`${name} must be an integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${name} must be between ${minimum} and ${maximum}`);
  }
  return parsed;
}

function plistValue(plist, key) {
  const expression = new RegExp(
    `<key>\\s*${escapeRegExp(key)}\\s*</key>\\s*<string>\\s*([^<]+?)\\s*</string>`,
  );
  return plist.match(expression)?.[1]?.trim() ?? null;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function validatePathSegment(value) {
  if (typeof value !== "string" && !Number.isInteger(value)) {
    throw new Error("Invalid Desktop stream patch path segment");
  }
  const normalized = String(value);
  if (!normalized || PROHIBITED_PATH_KEYS.has(normalized)) {
    throw new Error("Unsafe Desktop stream patch path segment");
  }
  return normalized;
}

function arrayIndex(value, length, allowEnd) {
  if (!/^\d+$/.test(String(value))) throw new Error("Invalid Desktop stream array index");
  const index = Number(value);
  if (!Number.isSafeInteger(index) || index < 0 || index > length || (!allowEnd && index === length)) {
    throw new Error("Desktop stream array index is out of bounds");
  }
  return index;
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}
