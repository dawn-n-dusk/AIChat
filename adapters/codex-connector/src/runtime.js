import WebSocket from "ws";

export class ConnectorRuntime {
  constructor({
    config,
    relay,
    connector,
    logger = console,
    WebSocketImpl = WebSocket,
    timers = globalThis,
  }) {
    this.config = config;
    this.relay = relay;
    this.connector = connector;
    this.logger = logger;
    this.WebSocketImpl = WebSocketImpl;
    this.timers = timers;
    this.websocket = null;
    this.recoveryTimer = null;
    this.reconnectTimer = null;
    this.started = false;
    this.stopped = false;
  }

  async start({
    websocketEnabled = this.config.websocketEnabled,
    periodicRecovery = this.config.periodicRecoveryEnabled !== false,
  } = {}) {
    if (this.started) throw new Error("Codex connector runtime is already started");
    this.started = true;
    await this.connector.initialize();
    await this.connector.requestRecovery();
    if (this.stopped) return;

    if (periodicRecovery) {
      this.recoveryTimer = this.timers.setInterval(
        () => this.#wake("periodic recovery"),
        this.config.recoveryIntervalMs,
      );
    }
    if (websocketEnabled) this.#connectWebSocket();
  }

  async stop({ drain = false } = {}) {
    if (this.stopped) return;
    this.stopped = true;
    if (this.recoveryTimer) this.timers.clearInterval(this.recoveryTimer);
    if (this.reconnectTimer) this.timers.clearTimeout(this.reconnectTimer);
    this.recoveryTimer = null;
    this.reconnectTimer = null;

    const socket = this.websocket;
    this.websocket = null;
    if (socket) {
      try {
        socket.close();
      } catch {
        // WebSocket shutdown is best-effort and must never expose its token-bearing URL.
      }
    }
    if (this.started) await this.connector.stop({ drain });
  }

  #wake(reason) {
    if (this.stopped) return;
    this.connector.requestRecovery().catch(() => {
      this.logger.error(`[aichat-codex-connector] ${reason} failed; ordered polling will retry`);
    });
  }

  #connectWebSocket() {
    if (this.stopped || this.websocket) return;
    let socket;
    try {
      socket = new this.WebSocketImpl(this.relay.websocketUrl());
    } catch {
      this.logger.error(
        "[aichat-codex-connector] WebSocket connection setup failed; ordered polling remains active",
      );
      this.#scheduleReconnect();
      return;
    }
    this.websocket = socket;

    socket.on("open", () => {
      if (this.stopped || this.websocket !== socket) return;
      this.#wake("WebSocket-open recovery");
    });
    socket.on("message", (raw) => {
      if (this.stopped || this.websocket !== socket) return;
      if (isRelevantWakeEvent(raw, this.config.channelId)) {
        this.#wake("WebSocket wake recovery");
      }
    });
    socket.on("error", () => {
      // Some WebSocket errors include the credential-bearing request URL. Never log them.
      this.logger.error(
        "[aichat-codex-connector] WebSocket transport error; ordered polling remains active",
      );
    });
    socket.on("close", () => {
      if (this.websocket === socket) this.websocket = null;
      if (!this.stopped) this.#scheduleReconnect();
    });
  }

  #scheduleReconnect() {
    if (this.stopped || this.reconnectTimer) return;
    this.reconnectTimer = this.timers.setTimeout(() => {
      this.reconnectTimer = null;
      this.#connectWebSocket();
    }, this.config.reconnectDelayMs);
  }
}

export function isRelevantWakeEvent(raw, channelId) {
  let parsed;
  try {
    const text =
      typeof raw === "string"
        ? raw
        : Buffer.isBuffer(raw)
          ? raw.toString("utf8")
          : raw instanceof ArrayBuffer
            ? Buffer.from(raw).toString("utf8")
            : ArrayBuffer.isView(raw)
              ? Buffer.from(raw.buffer, raw.byteOffset, raw.byteLength).toString("utf8")
              : "";
    if (!text) return false;
    parsed = JSON.parse(text);
  } catch {
    return false;
  }
  return (
    parsed?.event === "message.created" &&
    parsed.message?.channel_id === channelId &&
    typeof parsed.message?.id === "string" &&
    parsed.message.id.length > 0
  );
}
