import { randomUUID } from "node:crypto";
import { readFile, unlink } from "node:fs/promises";
import { createServer } from "node:net";

import { atomicWritePrivateFile } from "./atomic-file.js";

export class MappingInstanceLock {
  constructor({
    port,
    statePort = null,
    metadataPath,
    bindingId = null,
    statePath = null,
    host = "127.0.0.1",
    createServerImpl = createServer,
    logger = console,
    onLost = () => {},
  }) {
    this.port = port;
    this.statePort = statePort;
    this.metadataPath = metadataPath;
    this.bindingId = bindingId;
    this.statePath = statePath;
    this.host = host;
    this.createServerImpl = createServerImpl;
    this.logger = logger;
    this.onLost = onLost;
    this.token = randomUUID();
    this.server = null;
    this.servers = [];
    this.acquired = false;
    this.lost = false;
  }

  async acquire() {
    if (this.acquired) throw new Error("AIChat connector mapping lock is already acquired");
    const targets = [{ role: "mapping", port: this.port }];
    if (this.statePort != null && this.statePort !== this.port) {
      targets.push({ role: "state", port: this.statePort });
    }
    const acquired = [];
    for (const target of targets) {
      const server = this.createServerImpl((socket) => socket.destroy());
      server.unref?.();
      try {
        await listen(server, { host: this.host, port: target.port, exclusive: true });
      } catch (error) {
        server.close?.();
        await Promise.all(acquired.map(({ server: owned }) => close(owned)));
        const lockError = new Error(
          error?.code === "EADDRINUSE"
            ? `AIChat ${target.role} lock port is already in use; another connector or an unrelated local service may own it`
            : `AIChat ${target.role} lock could not be acquired`,
        );
        lockError.code =
          error?.code === "EADDRINUSE"
            ? "AICHAT_CONNECTOR_LOCKED"
            : "AICHAT_CONNECTOR_LOCK_FAILED";
        throw lockError;
      }
      acquired.push({ ...target, server });
    }
    this.servers = acquired.map((entry) => entry.server);
    this.server = this.servers[0] ?? null;
    this.acquired = true;
    for (const { role, server } of acquired) {
      server.once("close", () => {
        if (!this.acquired || this.lost) return;
        this.lost = true;
        this.logger.error(
          `[aichat-codex-connector] OS ${role} lock was lost; shutting down`,
        );
        this.onLost();
      });
    }
    try {
      await atomicWritePrivateFile(
        this.metadataPath,
        `${JSON.stringify({
          version: 2,
          token: this.token,
          pid: process.pid,
          host: this.host,
          binding_id: this.bindingId,
          state_path: this.statePath,
          locks: acquired.map(({ role, port }) => ({ role, port })),
          started_at: new Date().toISOString(),
        })}\n`,
      );
    } catch (error) {
      this.acquired = false;
      this.server = null;
      this.servers = [];
      await Promise.all(acquired.map(({ server }) => close(server)));
      throw new Error(`AIChat mapping lock metadata could not be persisted: ${error.message}`);
    }
  }

  async assertOwned() {
    if (
      !this.acquired ||
      this.lost ||
      this.servers.length === 0 ||
      this.servers.some((server) => !server.listening)
    ) {
      const error = new Error("AIChat connector mapping lock is not owned");
      error.code = "AICHAT_CONNECTOR_LOCK_LOST";
      throw error;
    }
  }

  async release() {
    if (!this.acquired) return;
    this.acquired = false;
    const servers = this.servers;
    this.server = null;
    this.servers = [];
    await Promise.all(servers.map((server) => close(server)));
    const owner = await readOwner(this.metadataPath);
    if (owner?.token === this.token) await unlink(this.metadataPath).catch(() => {});
  }
}

function listen(server, options) {
  return new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      server.off("error", onError);
      resolve();
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(options);
  });
}

function close(server) {
  return new Promise((resolve) => {
    try {
      server.close(() => resolve());
    } catch {
      resolve();
    }
  });
}

async function readOwner(path) {
  try {
    const value = JSON.parse(await readFile(path, "utf8"));
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}
