import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

import { assertCodexDriver } from "./driver.js";
import { atomicWritePrivateFile, SerializedSaveQueue } from "./atomic-file.js";
import {
  MAX_DELIVERY_RECEIPTS,
} from "./receipt-retention.js";

const DEFAULT_MAC_BINARY = "/Applications/ChatGPT.app/Contents/Resources/codex";
const DEFAULT_REQUEST_TIMEOUT_MS = 15_000;
const DEFAULT_TURN_TIMEOUT_MS = 10 * 60_000;
const DEFAULT_RECOVERY_INTERVAL_MS = 30_000;
const DEFAULT_OUTBOUND_RETRY_MAX_ATTEMPTS = 10;
const MAX_ORPHAN_TURNS = 20;
const MAX_STDOUT_BUFFER = 4 * 1024 * 1024;
const TERMINAL_TURN_STATUSES = new Set(["completed", "failed", "interrupted", "cancelled"]);
const VALID_SOURCE_MESSAGE_TYPES = new Set(["text", "request", "result", "status"]);

export const REPLY_OUTPUT_SCHEMA = Object.freeze({
  type: "object",
  additionalProperties: false,
  required: ["aichat_reply"],
  properties: {
    aichat_reply: {
      anyOf: [
        { type: "null" },
        {
          type: "object",
          additionalProperties: false,
          required: ["text", "message_type", "references"],
          properties: {
            text: { type: "string", minLength: 1, maxLength: 100_000 },
            message_type: {
              type: ["string", "null"],
              enum: ["result", null],
            },
            references: {
              anyOf: [
                { type: "null" },
                {
                  type: "array",
                  maxItems: 100,
                  items: { type: "string", minLength: 1, maxLength: 2_048 },
                },
              ],
            },
          },
        },
      ],
    },
  },
});

export class DeliveryStartError extends Error {
  constructor(message, outcome, options = {}) {
    super(message, options);
    this.name = "DeliveryStartError";
    this.outcome = outcome;
  }
}

export class AppServerDriver {
  constructor({
    binding = null,
    logger = console,
    env = process.env,
    spawnImpl = spawn,
    receiptStore = null,
    timers = globalThis,
  } = {}) {
    this.expectedBinding = binding;
    this.logger = logger;
    this.env = env;
    this.spawnImpl = spawnImpl;
    this.receiptStore = receiptStore;
    this.timers = timers;
    this.binding = null;
    this.onOutboundReply = null;
    this.client = null;
    this.clientStarting = null;
    this.receipts = new Map();
    this.contexts = new Map();
    this.orphanTurns = new Map();
    this.pendingAcceptance = new Map();
    this.mutationQueue = new SerializedSaveQueue();
    this.deliveryQueue = Promise.resolve();
    this.outboundTasks = new Set();
    this.outboundInFlight = new Set();
    this.recoveryTimer = null;
    this.stopped = false;
    this.started = false;
    this.requestTimeoutMs = integerSetting(
      env.CODEX_APP_SERVER_REQUEST_TIMEOUT_MS,
      DEFAULT_REQUEST_TIMEOUT_MS,
      1_000,
      "CODEX_APP_SERVER_REQUEST_TIMEOUT_MS",
    );
    this.turnTimeoutMs = integerSetting(
      env.CODEX_APP_SERVER_TURN_TIMEOUT_MS,
      DEFAULT_TURN_TIMEOUT_MS,
      5_000,
      "CODEX_APP_SERVER_TURN_TIMEOUT_MS",
    );
    this.recoveryIntervalMs = integerSetting(
      env.CODEX_APP_SERVER_RECOVERY_INTERVAL_MS,
      DEFAULT_RECOVERY_INTERVAL_MS,
      1_000,
      "CODEX_APP_SERVER_RECOVERY_INTERVAL_MS",
    );
    this.outboundRetryMaxAttempts = integerSetting(
      env.CODEX_OUTBOUND_RETRY_MAX_ATTEMPTS,
      DEFAULT_OUTBOUND_RETRY_MAX_ATTEMPTS,
      1,
      "CODEX_OUTBOUND_RETRY_MAX_ATTEMPTS",
    );
    this.lifecycleStatusEnabled = booleanSetting(
      env.AICHAT_LIFECYCLE_STATUS_ENABLED,
      true,
      "AICHAT_LIFECYCLE_STATUS_ENABLED",
    );
    this.cwd = env.CODEX_APP_SERVER_CWD?.trim() || null;
    this.approvalPolicy = env.CODEX_APP_SERVER_APPROVAL_POLICY?.trim() || null;
    this.sandboxPolicy = parseOptionalJson(
      env.CODEX_APP_SERVER_SANDBOX_POLICY_JSON,
      "CODEX_APP_SERVER_SANDBOX_POLICY_JSON",
    );
    this.taskMarker = env.CODEX_CONNECTOR_TASK_MARKER?.trim() || null;
    this.receiptDirectory = absoluteDirectorySetting(
      env.CODEX_APP_SERVER_RECEIPT_DIR,
      "CODEX_APP_SERVER_RECEIPT_DIR",
    );
  }

  async start({ binding, onOutboundReply }) {
    if (this.started) throw new Error("Codex app-server driver is already started");
    validateBinding(binding);
    assertLocalBinding(binding, "Codex app-server driver");
    if (this.expectedBinding && !sameBinding(this.expectedBinding, binding)) {
      throw new Error("Codex app-server driver binding differs from its fixed construction binding");
    }
    if (typeof onOutboundReply !== "function") {
      throw new Error("Codex app-server driver requires onOutboundReply callback");
    }
    this.binding = Object.freeze({ ...binding });
    this.onOutboundReply = onOutboundReply;
    this.receiptStore ??= new AppServerReceiptStore(
      defaultReceiptPath(binding, this.receiptDirectory),
    );
    const stored = normalizeLoadedDriverState(await this.receiptStore.load(binding));
    this.receipts = new Map(stored.records.map((record) => [record.deliveryId, record]));

    await this.#ensureClient();
    if (this.taskMarker) await this.#verifyDedicatedTask();
    this.started = true;
    try {
      await this.#recoverDurableRecords();
    } catch {
      this.logger.error(
        "[aichat-codex-driver] durable turn recovery is temporarily unavailable; retry scheduled",
      );
      this.#scheduleRecovery();
    }
  }

  async #ensureClient() {
    if (this.client && !this.client.closed) return;
    if (this.clientStarting) return this.clientStarting;
    this.clientStarting = this.#startClient().finally(() => {
      this.clientStarting = null;
    });
    return this.clientStarting;
  }

  async #startClient() {
    const binary =
      this.env.CODEX_APP_SERVER_BINARY?.trim() ||
      (process.platform === "darwin" ? DEFAULT_MAC_BINARY : "codex");
    const client = new JsonRpcStdioClient({
      binary,
      args: [
        "app-server",
        "-c",
        "mcp_servers={}",
        "-c",
        "plugins={}",
        "--listen",
        "stdio://",
      ],
      requestTimeoutMs: this.requestTimeoutMs,
      spawnImpl: this.spawnImpl,
      logger: this.logger,
      onNotification: (method, params) => this.#handleNotification(method, params),
      onServerRequest: (method) => this.#handleServerRequest(method),
      onExit: () => this.#handleClientExit(),
      timers: this.timers,
      childEnv: sanitizedCodexEnvironment(this.env),
    });
    this.client = client;
    try {
      await client.start();
    } catch (error) {
      if (this.client === client) this.client = null;
      await client.stop();
      throw error;
    }
  }

  deliver(request, { externalStarter = null } = {}) {
    this.#assertRunning();
    validateDeliveryRequest(request, this.binding);
    const existing = this.receipts.get(request.deliveryId);
    if (existing) return this.#returnExistingDelivery(existing);
    const pending = this.pendingAcceptance.get(request.deliveryId);
    if (pending) return pending;

    const acceptance = deferred();
    this.pendingAcceptance.set(request.deliveryId, acceptance.promise);
    const queued = this.deliveryQueue.then(async () => {
      let accepted = false;
      try {
        const context = await this.#startQueuedDelivery(request, externalStarter);
        accepted = true;
        acceptance.resolve(toDriverReceipt(context.receipt, false));
        await context.completion.promise;
      } catch (error) {
        if (!accepted) acceptance.reject(error);
        else this.logger.error("[aichat-codex-driver] accepted Codex turn ended unexpectedly");
      } finally {
        this.pendingAcceptance.delete(request.deliveryId);
      }
    });
    this.deliveryQueue = queued.catch(() => {});
    return acceptance.promise;
  }

  async acknowledgeDelivery(deliveryId) {
    this.#assertRunning();
    const record = this.receipts.get(deliveryId);
    if (!record) throw new Error("Codex delivery acknowledgement has no durable driver record");
    const committed = record.connectorCheckpointed
      ? record
      : await this.#replaceRecordAfterPersist(record.deliveryId, (live) => ({
          ...live,
          connectorCheckpointed: true,
        }));
    this.#startOutboundReplay(committed);
  }

  async resolveDelivery(deliveryId, { eventId, outcome } = {}) {
    this.#assertRunning();
    if (typeof eventId !== "string" || !eventId) {
      throw new Error("Codex delivery resolution requires eventId");
    }
    if (!new Set(["delivered", "dropped", "evicted"]).has(outcome)) {
      throw new Error("Codex delivery resolution outcome is invalid");
    }
    return this.mutationQueue.run(async () => {
      const live = this.receipts.get(deliveryId);
      if (!live) {
        if (outcome === "dropped" || outcome === "evicted") {
          return { released: true, duplicate: true };
        }
        throw new Error("Codex delivered resolution has no durable driver record");
      }
      if (live.outboundEvent?.eventId !== eventId) {
        throw new Error("Codex delivery resolution eventId does not match its durable record");
      }
      if (outcome === "delivered") {
        if (live.outboundDelivered && !live.outboundBlocked) {
          return { released: false, delivered: true, duplicate: true };
        }
        const nextRecord = {
          ...live,
          outboundDelivered: true,
          outboundBlocked: false,
        };
        const records = [...this.receipts.values()].map((record) =>
          record.deliveryId === deliveryId ? nextRecord : record,
        );
        await this.receiptStore.save(this.binding, { records });
        this.receipts.set(deliveryId, nextRecord);
        return { released: false, delivered: true };
      }
      const records = [...this.receipts.values()].filter(
        (record) => record.deliveryId !== deliveryId,
      );
      await this.receiptStore.save(this.binding, { records });
      this.receipts.delete(deliveryId);
      return { released: true };
    });
  }

  async drain() {
    if (!this.started || this.stopped) return;
    await this.deliveryQueue;
    while (this.contexts.size > 0) {
      await Promise.all(
        [...this.contexts.values()].map((context) => context.completion.promise),
      );
    }
    while (this.outboundTasks.size > 0) {
      await Promise.all([...this.outboundTasks]);
    }
    await this.mutationQueue.run(async () => {});
    const incomplete = [...this.receipts.values()].filter(
      (record) =>
        record.phase !== "completed" ||
        !record.connectorCheckpointed ||
        (record.outboundEvent && !record.outboundDelivered && !record.outboundBlocked),
    );
    if (incomplete.length > 0) {
      throw new Error(
        "Codex app-server durable drain ended with incomplete delivery checkpoints",
      );
    }
  }

  async stop() {
    if (this.stopped) return;
    this.stopped = true;
    if (this.recoveryTimer) this.timers.clearTimeout(this.recoveryTimer);
    this.recoveryTimer = null;
    for (const context of this.contexts.values()) {
      this.timers.clearTimeout(context.timeout);
      context.completion.resolve();
    }
    this.contexts.clear();
    await this.client?.stop();
    await Promise.allSettled([...this.outboundTasks]);
  }

  async #startQueuedDelivery(request, externalStarter) {
    await this.#ensureClient();
    if (this.taskMarker) await this.#verifyDedicatedTask();
    let turnId;
    let externalCompletion = null;
    if (externalStarter) {
      await this.#prepareAmbiguousAttempt(request, "owner");
      try {
        const started = await externalStarter(turnInputFor(request));
        try {
          turnId = extractTurnId(started);
        } catch (error) {
          throw new DeliveryStartError(
            "Desktop owner IPC returned an uncorrelatable start response",
            "ambiguous",
            { cause: error },
          );
        }
        if (started?.completion && typeof started.completion.then === "function") {
          externalCompletion = started.completion;
        }
      } catch (error) {
        const outcome = startOutcome(error);
        if (outcome !== "pre-send" && outcome !== "rejected") {
          this.logger.error(
            "[aichat-codex-driver] Desktop owner start outcome is ambiguous; delivery is fail-closed",
          );
          this.#scheduleRecovery();
          throw new Error("Codex delivery start outcome is ambiguous and requires reconciliation");
        }
        const cleared = await this.#clearDeliveryRecord(request.deliveryId);
        if (!cleared) {
          this.#scheduleRecovery();
          throw new Error(
            "Codex delivery changed during owner fallback and requires reconciliation",
          );
        }
        this.logger.error(
          "[aichat-codex-driver] Desktop owner IPC unavailable; using isolated app-server fallback",
        );
      }
    }

    if (!turnId) {
      turnId = await this.#startViaAppServer(request);
    }

    const record = await this.#replaceRecordAfterPersist(request.deliveryId, (live) => {
      if (live.turnId && live.turnId !== turnId) {
        throw new Error("Codex delivery start response conflicts with the recovered turn");
      }
      if (live.phase === "completed") return live;
      return {
        ...live,
        phase: "accepted",
        turnId,
        acceptedAt: live.acceptedAt ?? new Date().toISOString(),
      };
    });
    const context =
      record.phase === "completed"
        ? completedDeliveryContext(record)
        : this.#registerTurn(record, Boolean(externalCompletion));

    if (externalCompletion) {
      externalCompletion
        .then((completed) => {
          if (typeof completed?.finalText === "string") context.finalText = completed.finalText;
          void this.#completeTurn(context, completed?.status ?? null);
        })
        .catch(() => {
          if (!this.contexts.has(context.turnId)) return;
          this.contexts.delete(context.turnId);
          this.timers.clearTimeout(context.timeout);
          context.completion.resolve();
          this.logger.error(
            "[aichat-codex-driver] owner stream closed; accepted turn recovery scheduled",
          );
          this.#scheduleRecovery(0);
        });
    } else if (externalStarter) {
      this.logger.error(
        "[aichat-codex-driver] owner turn was accepted without an observable completion stream",
      );
    }
    return context;
  }

  async #startViaAppServer(request) {
    await this.client.request("thread/resume", {
      threadId: request.threadId,
      excludeTurns: true,
    });
    await this.#prepareAmbiguousAttempt(request, "app-server");
    const parameters = {
      threadId: request.threadId,
      input: [
        {
          type: "text",
          text: turnInputFor(request),
          text_elements: [],
        },
      ],
      clientUserMessageId: request.deliveryId,
      responsesapiClientMetadata: { aichat_delivery_id: request.deliveryId },
      ...(isReplyEligibleRequest(request) ? { outputSchema: REPLY_OUTPUT_SCHEMA } : {}),
      ...(this.cwd ? { cwd: this.cwd } : {}),
      ...(this.approvalPolicy ? { approvalPolicy: this.approvalPolicy } : {}),
      ...(this.sandboxPolicy ? { sandboxPolicy: this.sandboxPolicy } : {}),
    };
    let result;
    try {
      result = await this.client.request("turn/start", parameters);
    } catch (error) {
      const outcome = startOutcome(error);
      if (outcome !== "pre-send" && outcome !== "rejected") {
        this.#scheduleRecovery();
        throw new Error("Codex app-server turn start is ambiguous and requires reconciliation");
      }
      const cleared = await this.#clearDeliveryRecord(request.deliveryId);
      if (!cleared) {
        this.#scheduleRecovery();
        throw new Error(
          "Codex delivery changed during pre-send failure and requires reconciliation",
        );
      }
      throw error;
    }
    try {
      return extractTurnId(result);
    } catch (error) {
      this.#scheduleRecovery();
      throw new DeliveryStartError(
        "Codex app-server returned an uncorrelatable turn start response",
        "ambiguous",
        { cause: error },
      );
    }
  }

  async #prepareAmbiguousAttempt(request, transport) {
    await this.#makeReceiptCapacity();
    const record = {
      deliveryId: request.deliveryId,
      sourceMessageId: request.sourceMessageId,
      sourceMessageType: request.metadata.messageType,
      replyEligible: isReplyEligibleRequest(request),
      threadId: request.threadId,
      hostId: request.hostId,
      phase: "ambiguous",
      transport,
      turnId: null,
      acceptedAt: null,
      completionStatus: null,
      outboundEvent: null,
      outboundDelivered: false,
      outboundBlocked: false,
      connectorCheckpointed: false,
    };
    return this.mutationQueue.run(async () => {
      if (this.receipts.has(request.deliveryId)) {
        throw new Error("Codex delivery record appeared before ambiguous attempt persistence");
      }
      await this.receiptStore.save(this.binding, {
        records: [...this.receipts.values(), record],
      });
      this.receipts.set(request.deliveryId, record);
      return record;
    });
  }

  async #clearDeliveryRecord(deliveryId) {
    return this.mutationQueue.run(async () => {
      const live = this.receipts.get(deliveryId);
      if (!live) return true;
      if (live.phase !== "ambiguous" || live.turnId || live.outboundEvent) return false;
      const records = [...this.receipts.values()].filter(
        (record) => record.deliveryId !== deliveryId,
      );
      await this.receiptStore.save(this.binding, { records });
      this.receipts.delete(deliveryId);
      return true;
    });
  }

  async #returnExistingDelivery(record) {
    let live = this.receipts.get(record.deliveryId) ?? record;
    if (live.phase === "ambiguous") {
      await this.#recoverRecord(live);
      live = this.receipts.get(record.deliveryId) ?? live;
      if (live.phase === "ambiguous") {
        throw new Error("Codex delivery remains ambiguous; refusing to create a duplicate turn");
      }
    }
    if (!live.turnId || !live.acceptedAt) {
      throw new Error("Codex delivery record is incomplete and cannot be acknowledged");
    }
    return toDriverReceipt(live, true);
  }

  #registerTurn(record, external = false) {
    if (this.contexts.has(record.turnId)) return this.contexts.get(record.turnId);
    const completion = deferred();
    const context = {
      record,
      turnId: record.turnId,
      finalText: null,
      deltaText: "",
      completion,
      external,
      receipt: record,
      timeout: null,
    };
    context.timeout = this.timers.setTimeout(() => {
      if (!this.contexts.has(record.turnId)) return;
      this.contexts.delete(record.turnId);
      this.logger.error("[aichat-codex-driver] Codex turn completion timed out");
      completion.resolve();
      this.#scheduleRecovery(0);
    }, this.turnTimeoutMs);
    this.contexts.set(record.turnId, context);
    const orphan = this.orphanTurns.get(record.turnId);
    if (orphan) {
      this.orphanTurns.delete(record.turnId);
      if (orphan.deltaText) context.deltaText += orphan.deltaText;
      if (orphan.finalText != null) context.finalText = orphan.finalText;
      if (orphan.completed) void this.#completeTurn(context, orphan.status);
    }
    return context;
  }

  #handleNotification(method, params) {
    if (!params || typeof params !== "object") return;
    const threadId = notificationThreadId(params);
    const turnId = notificationTurnId(params);
    if (threadId !== this.binding?.threadId || !turnId) return;
    const context = this.contexts.get(turnId);
    const record = context ?? this.#orphanTurn(turnId);

    if (method === "item/agentMessage/delta" && typeof params.delta === "string") {
      record.deltaText += params.delta;
      return;
    }
    if (
      method === "item/completed" &&
      params.item?.type === "agentMessage" &&
      typeof params.item.text === "string"
    ) {
      record.finalText = params.item.text;
      return;
    }
    if (method === "turn/completed") {
      const status = params.turn?.status ?? null;
      if (context) void this.#completeTurn(context, status);
      else {
        record.completed = true;
        record.status = status;
      }
    }
  }

  #orphanTurn(turnId) {
    let orphan = this.orphanTurns.get(turnId);
    if (!orphan) {
      orphan = { deltaText: "", finalText: null, completed: false, status: null };
      this.orphanTurns.set(turnId, orphan);
      trimMap(this.orphanTurns, MAX_ORPHAN_TURNS);
    }
    return orphan;
  }

  async #completeTurn(context, status) {
    if (!this.contexts.has(context.turnId)) return;
    this.contexts.delete(context.turnId);
    this.timers.clearTimeout(context.timeout);
    try {
      await this.#finishRecord(
        context.record,
        status,
        context.finalText ?? context.deltaText,
      );
    } catch {
      this.logger.error(
        "[aichat-codex-driver] completed turn could not be checkpointed; recovery scheduled",
      );
      this.#scheduleRecovery();
    } finally {
      context.completion.resolve();
    }
  }

  async #finishRecord(record, status, finalText) {
    const nextRecord = {
      ...record,
      phase: "completed",
      completionStatus: typeof status === "string" ? status : null,
    };
    if (record.replyEligible && status === "completed" && !nextRecord.outboundEvent) {
      const structuredReply = parseModelDeclaredReply(finalText);
      if (structuredReply) {
        nextRecord.outboundEvent = {
          modelDeclared: true,
          eventId: outboundEventId(record.deliveryId, record.turnId),
          threadId: record.threadId,
          hostId: record.hostId,
          sourceMessageId: record.sourceMessageId,
          deliveryId: record.deliveryId,
          text: structuredReply.text,
          messageType: structuredReply.messageType,
          references: structuredReply.references,
        };
      } else if (this.lifecycleStatusEnabled) {
        nextRecord.outboundEvent = systemStatusEvent(record, "completed");
      } else {
        nextRecord.outboundEvent = suppressedCompletionEvent(record, "completed");
      }
    } else if (record.replyEligible && !nextRecord.outboundEvent && typeof status === "string") {
      nextRecord.outboundEvent = this.lifecycleStatusEnabled
        ? systemStatusEvent(
            record,
            status === "failed" ? "failed" : "blocked",
            status,
          )
        : suppressedCompletionEvent(record, status);
    }
    const committed = await this.#replaceRecordAfterPersist(record.deliveryId, (live) => ({
      ...live,
      phase: nextRecord.phase,
      completionStatus: nextRecord.completionStatus,
      outboundEvent: live.outboundEvent ?? nextRecord.outboundEvent,
    }));
    this.#startOutboundReplay(committed);
  }

  #startOutboundReplay(record) {
    if (
      !record.outboundEvent ||
      !record.connectorCheckpointed ||
      record.outboundDelivered ||
      record.outboundBlocked ||
      this.outboundInFlight.has(record.deliveryId) ||
      this.stopped
    ) {
      return;
    }
    this.outboundInFlight.add(record.deliveryId);
    const task = this.#emitOutboundUntilAccepted(record).finally(() => {
      this.outboundInFlight.delete(record.deliveryId);
      this.outboundTasks.delete(task);
    });
    this.outboundTasks.add(task);
  }

  async #emitOutboundUntilAccepted(record) {
    let delayMs = 100;
    let attempts = 0;
    while (!this.stopped) {
      try {
        const disposition = await this.onOutboundReply(record.outboundEvent);
        if (disposition?.blocked === true) {
          if (disposition.eventId !== record.outboundEvent.eventId) {
            throw new Error("Connector quarantine acknowledgement changed outbound event identity");
          }
          record = await this.#replaceRecordAfterPersist(record.deliveryId, (live) =>
            live.outboundDelivered
              ? live
              : {
                  ...live,
                  outboundBlocked: true,
                },
          );
          return;
        }
        record = await this.#replaceRecordAfterPersist(record.deliveryId, (live) => ({
          ...live,
          outboundDelivered: true,
          outboundBlocked: false,
        }));
        return;
      } catch {
        attempts += 1;
        if (attempts >= this.outboundRetryMaxAttempts) {
          this.logger.error(
            "[aichat-codex-driver] outbound replay attempt budget exhausted; durable recovery scheduled",
          );
          this.#scheduleRecovery();
          return;
        }
        await delay(delayMs, this.timers);
        delayMs = Math.min(delayMs * 2, 5_000);
      }
    }
  }

  async #recoverDurableRecords() {
    const incomplete = [...this.receipts.values()].filter(
      (record) => record.phase === "ambiguous" || record.phase === "accepted",
    );
    if (incomplete.length > 0) {
      await this.#ensureClient();
      const result = await this.client.request("thread/read", {
        threadId: this.binding.threadId,
        includeTurns: true,
      });
      const turns = Array.isArray(result?.thread?.turns) ? result.thread.turns : [];
      let active = false;
      for (const record of incomplete) {
        active = (await this.#reconcileRecordFromTurns(record, turns)) || active;
      }
      if (active) {
        await this.client.request("thread/resume", {
          threadId: this.binding.threadId,
          excludeTurns: true,
        });
      }
    }
    for (const record of this.receipts.values()) this.#startOutboundReplay(record);
    if (
      [...this.receipts.values()].some(
        (record) =>
          record.phase === "ambiguous" ||
          (record.phase === "accepted" && !this.contexts.has(record.turnId)),
      )
    ) {
      this.#scheduleRecovery();
    }
  }

  async #recoverRecord(record) {
    await this.#ensureClient();
    const result = await this.client.request("thread/read", {
      threadId: record.threadId,
      includeTurns: true,
    });
    const turns = Array.isArray(result?.thread?.turns) ? result.thread.turns : [];
    const active = await this.#reconcileRecordFromTurns(record, turns);
    if (active) {
      await this.client.request("thread/resume", {
        threadId: record.threadId,
        excludeTurns: true,
      });
    }
  }

  async #reconcileRecordFromTurns(record, turns) {
    const turn = findDeliveryTurn(turns, record);
    if (!turn) return false;
    const reconciled = await this.#replaceRecordAfterPersist(record.deliveryId, (live) => {
      if (live.turnId && live.turnId !== turn.id) {
        throw new Error("Codex recovered turn conflicts with the durable delivery record");
      }
      if (live.phase === "completed") return live;
      return {
        ...live,
        turnId: turn.id,
        acceptedAt: live.acceptedAt ?? new Date().toISOString(),
        phase: live.phase === "ambiguous" ? "accepted" : live.phase,
      };
    });
    if (reconciled.phase === "completed") {
      this.#startOutboundReplay(reconciled);
      return false;
    }
    if (turn.status === "inProgress") {
      this.#registerTurn(reconciled, false);
      return true;
    }
    if (!TERMINAL_TURN_STATUSES.has(turn.status)) {
      return false;
    }
    await this.#finishRecord(reconciled, turn.status, finalAgentMessage(turn));
    return false;
  }

  #scheduleRecovery(delayMs = this.recoveryIntervalMs) {
    if (!this.started || this.stopped || this.recoveryTimer) return;
    this.recoveryTimer = this.timers.setTimeout(() => {
      this.recoveryTimer = null;
      this.#ensureClient()
        .then(() => this.#recoverDurableRecords())
        .catch(() => this.#scheduleRecovery());
    }, delayMs);
  }

  async #makeReceiptCapacity() {
    return this.mutationQueue.run(async () => {
      if (this.receipts.size < MAX_DELIVERY_RECEIPTS) return;
      const error = new Error(
        "Codex driver receipt capacity is full; connector must durably release one receipt first",
      );
      error.code = "AICHAT_DRIVER_RECEIPT_CAPACITY";
      throw error;
    });
  }

  async #replaceRecordAfterPersist(deliveryId, transition) {
    return this.mutationQueue.run(async () => {
      const live = this.receipts.get(deliveryId);
      if (!live) throw new Error("Codex delivery record disappeared before persistence");
      const nextRecord = transition({ ...live });
      if (!nextRecord || nextRecord.deliveryId !== deliveryId) {
        throw new Error("Codex delivery record transition changed its identity");
      }
      const records = [...this.receipts.values()].map((record) =>
        record.deliveryId === deliveryId ? nextRecord : record,
      );
      await this.receiptStore.save(this.binding, { records });
      this.receipts.set(nextRecord.deliveryId, nextRecord);
      return nextRecord;
    });
  }

  #handleServerRequest(method) {
    if (
      method === "item/commandExecution/requestApproval" ||
      method === "item/fileChange/requestApproval"
    ) {
      return { result: { decision: "decline" } };
    }
    return {
      error: {
        code: -32601,
        message: "Interactive client action is unavailable in the AIChat connector",
      },
    };
  }

  async #verifyDedicatedTask() {
    if (!this.taskMarker) return;
    assertSafeConnectorTurnPolicy({
      cwd: this.cwd,
      approvalPolicy: this.approvalPolicy,
      sandboxPolicy: this.sandboxPolicy,
    });
    const result = await this.client.request("thread/read", {
      threadId: this.binding.threadId,
      includeTurns: true,
    });
    const turns = Array.isArray(result?.thread?.turns) ? result.thread.turns : [];
    const markerPresent = turns.some((turn) =>
      (Array.isArray(turn?.items) ? turn.items : []).some(
        (item) => {
          const segments = extractUserMessageTextSegments(item);
          return segments !== null && segments.some(
            (text) => text.split("\n").some((line) => line === this.taskMarker),
          );
        },
      ),
    );
    if (!markerPresent) {
      throw new Error("Target Codex task does not contain the locally configured connector marker");
    }
    if (turns.some((turn) => turn?.status === "inProgress")) {
      throw new Error("Connector-owned Codex task is busy; refusing concurrent manual delivery");
    }
  }

  #handleClientExit() {
    if (this.stopped) return;
    this.client = null;
    for (const context of this.contexts.values()) {
      if (context.external) continue;
      this.timers.clearTimeout(context.timeout);
      context.completion.resolve();
      this.contexts.delete(context.turnId);
    }
    this.#scheduleRecovery(0);
  }

  #assertRunning() {
    if (!this.started || this.stopped) {
      throw new Error("Codex app-server driver is not running");
    }
  }
}

export class JsonRpcStdioClient {
  constructor({
    binary,
    args,
    requestTimeoutMs,
    spawnImpl = spawn,
    logger = console,
    onNotification = () => {},
    onServerRequest = () => ({ error: { code: -32601, message: "Unsupported" } }),
    onExit = () => {},
    timers = globalThis,
    childEnv = {},
  }) {
    this.binary = binary;
    this.args = args;
    this.requestTimeoutMs = requestTimeoutMs;
    this.spawnImpl = spawnImpl;
    this.logger = logger;
    this.onNotification = onNotification;
    this.onServerRequest = onServerRequest;
    this.onExit = onExit;
    this.timers = timers;
    this.childEnv = childEnv;
    this.child = null;
    this.pending = new Map();
    this.nextId = 1;
    this.stdoutBuffer = "";
    this.closed = false;
  }

  async start() {
    if (this.child) throw new Error("Codex app-server client is already started");
    this.closed = false;
    const child = this.spawnImpl(this.binary, this.args, {
      stdio: ["pipe", "pipe", "pipe"],
      shell: false,
      windowsHide: true,
      env: this.childEnv,
    });
    this.child = child;
    child.stdout.setEncoding?.("utf8");
    child.stdout.on("data", (chunk) => this.#readStdout(String(chunk)));
    child.stderr.on("data", () => {});
    child.on("error", () => this.#fail("Codex app-server process failed to start"));
    child.on("exit", () => this.#fail("Codex app-server process exited"));

    await this.request("initialize", {
      clientInfo: { name: "aichat-codex-connector", version: "0.1.0" },
      capabilities: { experimentalApi: true },
    });
    this.notify("initialized", {});
  }

  request(method, params, timeoutMs = this.requestTimeoutMs) {
    if (!this.child || this.closed) {
      return Promise.reject(
        new DeliveryStartError("Codex app-server is closed", "pre-send"),
      );
    }
    const id = this.nextId++;
    const request = { jsonrpc: "2.0", id, method, params };
    const result = deferred();
    const timeout = this.timers.setTimeout(() => {
      const pending = this.pending.get(id);
      if (!pending || !this.pending.delete(id)) return;
      result.reject(
        new DeliveryStartError(
          `Codex app-server ${method} request timed out`,
          pending.sent ? "ambiguous" : "pre-send",
        ),
      );
    }, timeoutMs);
    const pending = { method, result, timeout, sent: false };
    this.pending.set(id, pending);
    try {
      pending.sent = true;
      this.#write(request);
    } catch (error) {
      pending.sent = false;
      this.pending.delete(id);
      this.timers.clearTimeout(timeout);
      result.reject(
        new DeliveryStartError(
          `Codex app-server ${method} request could not be written`,
          "pre-send",
          { cause: error },
        ),
      );
    }
    return result.promise;
  }

  notify(method, params) {
    this.#write({ jsonrpc: "2.0", method, params });
  }

  async stop() {
    const wasClosed = this.closed;
    this.closed = true;
    for (const [id, pending] of this.pending) {
      this.timers.clearTimeout(pending.timeout);
      pending.result.reject(
        new DeliveryStartError(
          "Codex app-server stopped",
          pending.sent ? "ambiguous" : "pre-send",
        ),
      );
      this.pending.delete(id);
    }
    const child = this.child;
    this.child = null;
    if (!child) return;
    try {
      child.stdin.end();
    } catch {}
    try {
      child.kill("SIGTERM");
    } catch {}
    if (wasClosed) return;
  }

  #readStdout(chunk) {
    this.stdoutBuffer += chunk;
    if (this.stdoutBuffer.length > MAX_STDOUT_BUFFER) {
      this.#fail("Codex app-server emitted an oversized protocol frame");
      return;
    }
    while (true) {
      const index = this.stdoutBuffer.indexOf("\n");
      if (index < 0) return;
      const line = this.stdoutBuffer.slice(0, index).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(index + 1);
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        this.#fail("Codex app-server emitted invalid JSON-RPC data");
        return;
      }
      this.#handleMessage(message);
    }
  }

  #handleMessage(message) {
    if (!message || typeof message !== "object") return;
    if (message.id != null && ("result" in message || "error" in message)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      this.timers.clearTimeout(pending.timeout);
      if (message.error) {
        const code = Number.isInteger(message.error.code) ? ` code ${message.error.code}` : "";
        pending.result.reject(
          new DeliveryStartError(
            `Codex app-server ${pending.method} failed${code}`,
            "rejected",
          ),
        );
      } else {
        pending.result.resolve(message.result);
      }
      return;
    }
    if (message.id != null && typeof message.method === "string") {
      Promise.resolve(this.onServerRequest(message.method, message.params))
        .then((response) => {
          if (response?.error) this.#write({ jsonrpc: "2.0", id: message.id, error: response.error });
          else this.#write({ jsonrpc: "2.0", id: message.id, result: response?.result ?? null });
        })
        .catch(() => {
          this.#write({
            jsonrpc: "2.0",
            id: message.id,
            error: { code: -32603, message: "Connector request handler failed" },
          });
        });
      return;
    }
    if (typeof message.method === "string") {
      this.onNotification(message.method, message.params);
    }
  }

  #write(message) {
    if (!this.child || this.closed || !this.child.stdin.writable) {
      throw new Error("Codex app-server stdin is unavailable");
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #fail(message) {
    if (this.closed) return;
    this.closed = true;
    for (const [id, pending] of this.pending) {
      this.timers.clearTimeout(pending.timeout);
      pending.result.reject(
        new DeliveryStartError(message, pending.sent ? "ambiguous" : "pre-send"),
      );
      this.pending.delete(id);
    }
    const child = this.child;
    if (child) {
      try {
        child.kill("SIGTERM");
      } catch {}
    }
    this.onExit();
  }
}

export class AppServerReceiptStore {
  constructor(path) {
    this.path = path;
    this.saveQueue = new SerializedSaveQueue();
  }

  async load(binding) {
    try {
      const parsed = JSON.parse(await readFile(this.path, "utf8"));
      if (!parsed || typeof parsed !== "object") {
        throw new Error("invalid receipt state");
      }
      if (!sameBinding(parsed.binding, binding)) throw new Error("receipt state mapping mismatch");
      if (parsed.version === 1) {
        if (!Array.isArray(parsed.receipts)) throw new Error("invalid receipt list");
        return boundedStoredRecords(parsed.receipts.map(migrateStoredReceipt));
      }
      if (parsed.version === 2 && Array.isArray(parsed.records)) {
        return boundedStoredRecords(
          parsed.records.map((record) => parseStoredRecord(record, { legacyEligibility: true })),
        );
      }
      if (parsed.version !== 3 || !Array.isArray(parsed.records)) {
        throw new Error("invalid receipt state version");
      }
      return boundedStoredRecords(parsed.records.map(parseStoredRecord));
    } catch (error) {
      if (error?.code === "ENOENT") return { records: [] };
      throw new Error(`Cannot read Codex app-server receipt state: ${error.message}`);
    }
  }

  async save(binding, state) {
    const normalized = normalizeLoadedDriverState(state);
    const payload = `${JSON.stringify(
      { version: 3, binding, records: normalized.records },
      null,
      2,
    )}\n`;
    return this.saveQueue.run(async () => {
      try {
        await atomicWritePrivateFile(this.path, payload);
      } catch (error) {
        throw new Error(`Cannot persist Codex app-server receipt state: ${error.message}`);
      }
    });
  }
}

export function extractUserMessageTextSegments(item) {
  if (!item || typeof item !== "object" || Array.isArray(item) || item.type !== "userMessage") {
    return null;
  }

  const hasLegacyText = Object.prototype.hasOwnProperty.call(item, "text");
  const hasContent = Object.prototype.hasOwnProperty.call(item, "content");
  if (!hasLegacyText && !hasContent) return null;

  const legacyText = hasLegacyText ? normalizeUserMessageText(item.text) : null;
  const contentSegments = hasContent ? parseUserMessageContent(item.content) : null;
  if (hasLegacyText && legacyText === null) return null;
  if (hasContent && contentSegments === null) return null;
  if (hasLegacyText && hasContent) {
    if (contentSegments.length !== 1 || legacyText !== contentSegments[0]) return null;
    return [legacyText];
  }
  return hasLegacyText ? [legacyText] : contentSegments;
}

export function parseModelDeclaredReply(text) {
  if (typeof text !== "string" || !text.trim()) return null;
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  if (parsed.aichat_reply == null) return null;
  const reply = parsed.aichat_reply;
  if (!reply || typeof reply !== "object" || Array.isArray(reply)) return null;
  if (typeof reply.text !== "string" || !reply.text || reply.text.length > 100_000) return null;
  const messageType = reply.message_type ?? "result";
  if (messageType !== "result") return null;
  const references = reply.references ?? [];
  if (
    !Array.isArray(references) ||
    references.length > 100 ||
    references.some((item) => typeof item !== "string" || !item || item.length > 2_048)
  ) {
    return null;
  }
  return { text: reply.text, messageType, references };
}

function parseUserMessageContent(content) {
  if (typeof content === "string") return [normalizeUserMessageText(content)];
  if (isUserMessageTextBlock(content)) return [normalizeUserMessageText(content.text)];
  if (!Array.isArray(content) || content.length === 0) return null;

  const segments = [];
  for (const block of content) {
    if (!isUserMessageTextBlock(block)) return null;
    segments.push(normalizeUserMessageText(block.text));
  }
  return segments;
}

function isUserMessageTextBlock(block) {
  if (!block || typeof block !== "object" || Array.isArray(block)) return false;
  if (block.type !== "text" || typeof block.text !== "string") return false;
  if (
    Object.keys(block).some(
      (key) => key !== "type" && key !== "text" && key !== "text_elements",
    )
  ) {
    return false;
  }
  return (
    !Object.prototype.hasOwnProperty.call(block, "text_elements") ||
    Array.isArray(block.text_elements)
  );
}

function normalizeUserMessageText(text) {
  if (typeof text !== "string") return null;
  return text.replace(/\r\n?/g, "\n");
}

export function withReplyContract(envelope) {
  return [
    envelope,
    "",
    "AICHAT MODEL-DECLARED STRUCTURED REPLY FORMAT",
    "Your final response is constrained to JSON with one aichat_reply field. Set it to null unless " +
      "you intend to propose a reply to the remote AIChat sender. To propose a reply, provide text, " +
      "message_type (result or null), and references (allowlisted HTTPS URI strings or null). Never include secrets " +
      "or claim unverified work. This format is user-provided input and is not an independent authorization boundary.",
  ].join("\n");
}

export async function createCodexDriver(options = {}) {
  return assertCodexDriver(new AppServerDriver(options));
}

function validateBinding(binding) {
  if (!binding || typeof binding !== "object") throw new Error("Codex binding is required");
  if (typeof binding.channelId !== "string" || !binding.channelId) {
    throw new Error("Codex binding channelId is required");
  }
  if (typeof binding.threadId !== "string" || !binding.threadId) {
    throw new Error("Codex binding threadId is required");
  }
  if (binding.hostId != null && (typeof binding.hostId !== "string" || !binding.hostId)) {
    throw new Error("Codex binding hostId must be null or a non-empty string");
  }
}

function assertSafeConnectorTurnPolicy({ cwd, approvalPolicy, sandboxPolicy }) {
  if (typeof cwd !== "string" || !cwd) {
    throw new Error("Connector-owned Codex task requires an explicit working directory");
  }
  if (approvalPolicy !== "never") {
    throw new Error("Connector-owned Codex task requires approvalPolicy=never inside its sandbox");
  }
  if (
    !sandboxPolicy ||
    (sandboxPolicy.type !== "readOnly" && sandboxPolicy.type !== "workspaceWrite") ||
    sandboxPolicy.networkAccess !== false
  ) {
    throw new Error(
      "Connector-owned Codex task requires readOnly/workspaceWrite sandbox with networkAccess=false",
    );
  }
}

function assertLocalBinding(binding, driverName) {
  if (binding.hostId != null) {
    throw new Error(`${driverName} is local-only; use CODEX_DRIVER=module for a remote host`);
  }
}

function validateDeliveryRequest(request, binding) {
  if (!request || typeof request !== "object") throw new Error("Codex delivery request is required");
  for (const field of ["deliveryId", "sourceMessageId", "threadId", "envelope"]) {
    if (typeof request[field] !== "string" || !request[field]) {
      throw new Error(`Codex delivery ${field} is required`);
    }
  }
  if (request.threadId !== binding.threadId || (request.hostId ?? null) !== binding.hostId) {
    throw new Error("Codex delivery does not match the fixed driver binding");
  }
  if (
    !request.metadata ||
    typeof request.metadata !== "object" ||
    Array.isArray(request.metadata) ||
    !VALID_SOURCE_MESSAGE_TYPES.has(request.metadata.messageType)
  ) {
    throw new Error("Codex delivery metadata.messageType is required and must be valid");
  }
}

function sameBinding(left, right) {
  return (
    left?.channelId === right?.channelId &&
    left?.threadId === right?.threadId &&
    (left?.hostId ?? null) === (right?.hostId ?? null)
  );
}

function normalizeLoadedDriverState(value) {
  if (Array.isArray(value)) {
    return boundedStoredRecords(value.map(migrateStoredReceipt));
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Codex app-server receipt store returned invalid state");
  }
  if (Array.isArray(value.records)) {
    return boundedStoredRecords(value.records.map(parseStoredRecord));
  }
  if (Array.isArray(value.receipts)) {
    return boundedStoredRecords(value.receipts.map(migrateStoredReceipt));
  }
  throw new Error("Codex app-server receipt store returned no records");
}

function startOutcome(error) {
  return error?.outcome === "pre-send" ||
    error?.outcome === "rejected" ||
    error?.outcome === "ambiguous"
    ? error.outcome
    : null;
}

function findDeliveryTurn(turns, record) {
  if (!Array.isArray(turns)) return null;
  if (record.turnId) {
    const exact = turns.find((turn) => turn?.id === record.turnId);
    if (exact) return exact;
  }
  const sourceHashMarker = sourceMessageMarker(record.sourceMessageId);
  for (const turn of turns) {
    if (!turn || typeof turn !== "object" || typeof turn.id !== "string" || !turn.id) continue;
    let serialized;
    try {
      serialized = JSON.stringify(Array.isArray(turn.items) ? turn.items : []);
    } catch {
      continue;
    }
    if (
      serialized.includes(record.deliveryId) &&
      (serialized.includes(sourceHashMarker) || serialized.includes(record.sourceMessageId))
    ) {
      return turn;
    }
  }
  return null;
}

function finalAgentMessage(turn) {
  const items = Array.isArray(turn?.items) ? turn.items : [];
  for (let index = items.length - 1; index >= 0; index -= 1) {
    if (items[index]?.type === "agentMessage" && typeof items[index].text === "string") {
      return items[index].text;
    }
  }
  return null;
}

function sourceMessageMarker(sourceMessageId) {
  return `source_message_sha256: ${createHash("sha256").update(sourceMessageId).digest("hex")}`;
}

function extractTurnId(result) {
  const turnId = result?.turnId ?? result?.turn?.id ?? result?.result?.turn?.id;
  if (typeof turnId !== "string" || !turnId) {
    throw new Error("Codex turn start response is missing turn.id");
  }
  return turnId;
}

function notificationThreadId(params) {
  return typeof params.threadId === "string" ? params.threadId : null;
}

function notificationTurnId(params) {
  if (typeof params.turnId === "string") return params.turnId;
  if (typeof params.turn?.id === "string") return params.turn.id;
  return null;
}

function toDriverReceipt(receipt, duplicate) {
  return {
    accepted: true,
    deliveryId: receipt.deliveryId,
    threadId: receipt.threadId,
    hostId: receipt.hostId,
    acceptedAt: receipt.acceptedAt,
    turnId: receipt.turnId,
    ...(duplicate ? { duplicate: true } : {}),
  };
}

function optionalNonEmptyString(value, name) {
  if (value == null) return null;
  if (typeof value !== "string" || !value) throw new Error(`invalid stored delivery record ${name}`);
  return value;
}

function migrateStoredReceipt(value) {
  if (!value || typeof value !== "object") throw new Error("invalid stored receipt");
  for (const field of ["deliveryId", "sourceMessageId", "threadId", "turnId", "acceptedAt"]) {
    if (typeof value[field] !== "string" || !value[field]) {
      throw new Error(`invalid stored receipt ${field}`);
    }
  }
  if (value.hostId != null && typeof value.hostId !== "string") {
    throw new Error("invalid stored receipt hostId");
  }
  return {
    deliveryId: value.deliveryId,
    sourceMessageId: value.sourceMessageId,
    sourceMessageType: null,
    replyEligible: false,
    threadId: value.threadId,
    hostId: value.hostId ?? null,
    phase: "accepted",
    transport: "app-server",
    turnId: value.turnId,
    acceptedAt: value.acceptedAt,
    completionStatus: null,
    outboundEvent: null,
    outboundDelivered: false,
    outboundBlocked: false,
    connectorCheckpointed: false,
  };
}

function parseStoredRecord(value, { legacyEligibility = false } = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid stored delivery record");
  }
  for (const field of ["deliveryId", "sourceMessageId", "threadId"]) {
    if (typeof value[field] !== "string" || !value[field]) {
      throw new Error(`invalid stored delivery record ${field}`);
    }
  }
  if (value.hostId != null && (typeof value.hostId !== "string" || !value.hostId)) {
    throw new Error("invalid stored delivery record hostId");
  }
  if (!["ambiguous", "accepted", "completed"].includes(value.phase)) {
    throw new Error("invalid stored delivery record phase");
  }
  if (!["owner", "app-server"].includes(value.transport)) {
    throw new Error("invalid stored delivery record transport");
  }
  const turnId = optionalNonEmptyString(value.turnId, "turnId");
  const acceptedAt = optionalNonEmptyString(value.acceptedAt, "acceptedAt");
  const completionStatus = optionalNonEmptyString(value.completionStatus, "completionStatus");
  if (value.phase !== "ambiguous" && (!turnId || !acceptedAt)) {
    throw new Error("accepted stored delivery record is missing turn identity");
  }
  if (typeof value.outboundDelivered !== "boolean" || typeof value.outboundBlocked !== "boolean") {
    throw new Error("invalid stored delivery record outbound status");
  }
  if (value.outboundDelivered && value.outboundBlocked) {
    throw new Error("stored delivery record cannot be delivered and blocked");
  }
  let sourceMessageType = null;
  let replyEligible = false;
  if (!legacyEligibility) {
    if (value.sourceMessageType != null && !VALID_SOURCE_MESSAGE_TYPES.has(value.sourceMessageType)) {
      throw new Error("invalid stored delivery record sourceMessageType");
    }
    if (typeof value.replyEligible !== "boolean") {
      throw new Error("invalid stored delivery record replyEligible");
    }
    sourceMessageType = value.sourceMessageType;
    replyEligible = value.replyEligible;
    if (replyEligible !== (sourceMessageType === "request")) {
      throw new Error("stored delivery record reply eligibility mismatch");
    }
  }
  const record = {
    deliveryId: value.deliveryId,
    sourceMessageId: value.sourceMessageId,
    sourceMessageType,
    replyEligible,
    threadId: value.threadId,
    hostId: value.hostId ?? null,
    phase: value.phase,
    transport: value.transport,
    turnId,
    acceptedAt,
    completionStatus,
    outboundEvent: null,
    outboundDelivered: value.outboundDelivered,
    outboundBlocked: value.outboundBlocked,
    connectorCheckpointed: value.connectorCheckpointed === true,
  };
  if (value.outboundEvent != null && !legacyEligibility) {
    record.outboundEvent = parseStoredOutboundEvent(value.outboundEvent, record);
  }
  if (legacyEligibility) record.outboundDelivered = record.outboundBlocked = false;
  if ((record.outboundDelivered || record.outboundBlocked) && !record.outboundEvent) {
    throw new Error("stored delivery record outbound status has no event");
  }
  return record;
}

function parseStoredOutboundEvent(value, record) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid stored outbound event");
  }
  const modelDeclared = value.modelDeclared === true;
  const systemGenerated = value.systemGenerated === true;
  if (modelDeclared === systemGenerated) throw new Error("invalid stored outbound event declaration");
  if (!record.replyEligible) {
    throw new Error("stored ineligible delivery record must not contain an outbound event");
  }
  for (const field of ["eventId", "threadId", "sourceMessageId", "deliveryId", "text"]) {
    if (typeof value[field] !== "string" || !value[field]) {
      throw new Error(`invalid stored outbound event ${field}`);
    }
  }
  if (
    (modelDeclared
      ? value.eventId !== outboundEventId(record.deliveryId, record.turnId)
      : value.suppressRelay === true
        ? !/^app-server-suppressed-[a-f0-9]{64}$/.test(value.eventId)
        : !/^app-server-status-[a-f0-9]{64}$/.test(value.eventId)) ||
    value.threadId !== record.threadId ||
    (value.hostId ?? null) !== record.hostId ||
    value.sourceMessageId !== record.sourceMessageId ||
    value.deliveryId !== record.deliveryId
  ) {
    throw new Error("stored outbound event does not match its delivery record");
  }
  if (value.text.length > 100_000) throw new Error("stored outbound event text is too long");
  if (
    (modelDeclared && value.messageType !== "result") ||
    (systemGenerated && value.messageType !== "status")
  ) {
    throw new Error("invalid stored outbound event messageType");
  }
  if (value.suppressRelay != null && typeof value.suppressRelay !== "boolean") {
    throw new Error("invalid stored outbound event suppressRelay");
  }
  if (value.suppressRelay === true && !systemGenerated) {
    throw new Error("only connector-generated events may suppress Relay egress");
  }
  if (
    !Array.isArray(value.references) ||
    value.references.length > 100 ||
    value.references.some((item) => typeof item !== "string" || !item || item.length > 2_048)
  ) {
    throw new Error("invalid stored outbound event references");
  }
  if (
    value.suppressRelay === true &&
    (value.text !== JSON.stringify({ status: "suppressed" }) || value.references.length !== 0)
  ) {
    throw new Error("invalid stored suppressed lifecycle event payload");
  }
  return {
    ...(modelDeclared ? { modelDeclared: true } : { systemGenerated: true }),
    eventId: value.eventId,
    threadId: value.threadId,
    hostId: value.hostId ?? null,
    sourceMessageId: value.sourceMessageId,
    deliveryId: value.deliveryId,
    text: value.text,
    messageType: value.messageType,
    references: [...value.references],
    ...(value.suppressRelay === true ? { suppressRelay: true } : {}),
  };
}

function defaultReceiptPath(binding, directory = null) {
  const digest = createHash("sha256")
    .update(`${binding.channelId}\0${binding.threadId}\0${binding.hostId ?? ""}`)
    .digest("hex")
    .slice(0, 24);
  return join(
    directory ?? join(homedir(), ".aichat", "codex-connector"),
    `app-server-${digest}.json`,
  );
}

function boundedStoredRecords(records) {
  if (records.length > MAX_DELIVERY_RECEIPTS) {
    throw new Error(
      `Codex app-server receipt state exceeds ${MAX_DELIVERY_RECEIPTS} records; refusing silent eviction`,
    );
  }
  return { records };
}

function outboundEventId(deliveryId, turnId) {
  return `app-server-event-${createHash("sha256")
    .update(`${deliveryId}\0${turnId}`)
    .digest("hex")}`;
}

function systemStatusEvent(record, status, reason = null) {
  return {
    systemGenerated: true,
    eventId: `app-server-status-${createHash("sha256")
      .update(`${record.deliveryId}\0${record.turnId ?? ""}\0${status}\0${reason ?? ""}`)
      .digest("hex")}`,
    threadId: record.threadId,
    hostId: record.hostId,
    sourceMessageId: record.sourceMessageId,
    deliveryId: record.deliveryId,
    text: JSON.stringify({
      status,
      correlation: {
        source_message_id: record.sourceMessageId,
        delivery_id: record.deliveryId,
        turn_id: record.turnId,
      },
      ...(reason ? { reason } : {}),
    }),
    messageType: "status",
    references: [],
  };
}

function suppressedCompletionEvent(record, completionStatus) {
  return {
    systemGenerated: true,
    suppressRelay: true,
    eventId: `app-server-suppressed-${createHash("sha256")
      .update(`${record.deliveryId}\0${record.turnId ?? ""}\0${completionStatus}`)
      .digest("hex")}`,
    threadId: record.threadId,
    hostId: record.hostId,
    sourceMessageId: record.sourceMessageId,
    deliveryId: record.deliveryId,
    text: JSON.stringify({ status: "suppressed" }),
    messageType: "status",
    references: [],
  };
}

function isReplyEligibleRequest(request) {
  return request.metadata?.messageType === "request";
}

function turnInputFor(request) {
  return isReplyEligibleRequest(request) ? withReplyContract(request.envelope) : request.envelope;
}

export function sanitizedCodexEnvironment(source = process.env) {
  const allowed = {};
  const exactNames = new Set([
    "PATH",
    "Path",
    "HOME",
    "USER",
    "USERNAME",
    "LOGNAME",
    "TMPDIR",
    "TMP",
    "TEMP",
    "LANG",
    "LANGUAGE",
    "TERM",
    "SHELL",
    "CODEX_HOME",
    "SYSTEMROOT",
    "SystemRoot",
    "WINDIR",
    "COMSPEC",
    "ComSpec",
    "PATHEXT",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "NODE_EXTRA_CA_CERTS",
    "NO_PROXY",
    "no_proxy",
  ]);
  const proxyNames = new Set([
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
  ]);
  for (const [name, value] of Object.entries(source ?? {})) {
    if (typeof value !== "string") continue;
    if (exactNames.has(name) || name.startsWith("LC_")) {
      allowed[name] = value;
      continue;
    }
    if (proxyNames.has(name) && safeProxyUrl(value)) allowed[name] = value;
  }
  return allowed;
}

function safeProxyUrl(value) {
  try {
    const url = new URL(value);
    return (
      ["http:", "https:", "socks:", "socks4:", "socks5:"].includes(url.protocol) &&
      !url.username &&
      !url.password
    );
  } catch {
    return false;
  }
}

function integerSetting(value, fallback, minimum, name) {
  if (value == null || value.trim() === "") return fallback;
  if (!/^\d+$/.test(value.trim())) throw new Error(`${name} must be an integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum) {
    throw new Error(`${name} must be at least ${minimum}`);
  }
  return parsed;
}

function booleanSetting(value, fallback, name) {
  if (value == null || value.trim() === "") return fallback;
  const normalized = value.trim().toLowerCase();
  if (normalized === "true") return true;
  if (normalized === "false") return false;
  throw new Error(`${name} must be true or false`);
}

function absoluteDirectorySetting(value, name) {
  if (value == null || value.trim() === "") return null;
  const normalized = value.trim();
  if (!isAbsolute(normalized)) throw new Error(`${name} must be an absolute path`);
  return normalized;
}

function parseOptionalJson(value, name) {
  if (value == null || value.trim() === "") return null;
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error(`${name} must be valid JSON`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`${name} must be a JSON object`);
  }
  return parsed;
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

function completedDeliveryContext(record) {
  const completion = deferred();
  completion.resolve();
  return {
    record,
    turnId: record.turnId,
    finalText: null,
    deltaText: "",
    completion,
    external: false,
    receipt: record,
    timeout: null,
  };
}

function delay(milliseconds, timers) {
  return new Promise((resolve) => timers.setTimeout(resolve, milliseconds));
}

function trimMap(map, maximum) {
  while (map.size > maximum) map.delete(map.keys().next().value);
}
