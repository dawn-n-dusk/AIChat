export class RelayClient {
  constructor({ server, token, requestTimeoutMs, fetchImpl = globalThis.fetch }) {
    this.server = server;
    this.token = token;
    this.requestTimeoutMs = requestTimeoutMs;
    this.fetchImpl = fetchImpl;
  }

  async whoAmI() {
    return this.#request("GET", "/v1/me");
  }

  async listMessages({ channelId, after, limit }) {
    const query = new URLSearchParams({ channel_id: channelId, limit: String(limit) });
    if (after) query.set("after", after);
    return this.#request("GET", `/v1/messages?${query}`);
  }

  async sendMessage({
    channelId,
    text,
    replyTo,
    references = [],
    messageType = "text",
    idempotencyKey,
    hopCount,
  }) {
    return this.#request("POST", "/v1/messages", {
      channel_id: channelId,
      type: messageType,
      text,
      reply_to: replyTo,
      references,
      idempotency_key: idempotencyKey,
      hop_count: hopCount,
    });
  }

  websocketUrl() {
    const url = new URL(this.server);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    url.pathname = `${url.pathname.replace(/\/+$/, "")}/v1/ws`;
    url.search = new URLSearchParams({ token: this.token }).toString();
    return url.toString();
  }

  async #request(method, path, body) {
    let response;
    try {
      response = await this.fetchImpl(`${this.server}${path}`, {
        method,
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${this.token}`,
          ...(body ? { "Content-Type": "application/json" } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
        signal: AbortSignal.timeout(this.requestTimeoutMs),
      });
    } catch (error) {
      throw new Error(`AIChat relay request failed: ${redact(errorMessage(error), this.token)}`);
    }

    if (!response.ok) {
      const detail = await safeErrorDetail(response);
      throw new Error(
        `AIChat relay ${method} ${path.split("?")[0]} failed with HTTP ${response.status}${
          detail ? `: ${redact(detail, this.token)}` : ""
        }`,
      );
    }

    let data;
    try {
      data = await response.json();
    } catch {
      throw new Error(`AIChat relay ${method} ${path.split("?")[0]} returned invalid JSON`);
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw new Error(`AIChat relay ${method} ${path.split("?")[0]} returned invalid data`);
    }
    return data;
  }
}

async function safeErrorDetail(response) {
  const text = (await response.text()).trim();
  if (!text) return "";
  try {
    const parsed = JSON.parse(text);
    if (typeof parsed?.detail === "string") return parsed.detail.slice(0, 500);
  } catch {
    // Fall through to a bounded plain-text diagnostic.
  }
  return text.slice(0, 500);
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function redact(value, secret) {
  return secret ? value.split(secret).join("[REDACTED]") : value;
}
