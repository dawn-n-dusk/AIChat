import { chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

const MAX_SEEN_IDS = 1_000;

export class StateStore {
  constructor(path) {
    this.path = path;
  }

  async load() {
    try {
      const parsed = JSON.parse(await readFile(this.path, "utf8"));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error("state must be a JSON object");
      }
      return {
        cursor: typeof parsed.cursor === "string" && parsed.cursor ? parsed.cursor : null,
        seenIds: Array.isArray(parsed.seen_ids)
          ? parsed.seen_ids.filter((item) => typeof item === "string" && item).slice(-MAX_SEEN_IDS)
          : [],
      };
    } catch (error) {
      if (error?.code === "ENOENT") return { cursor: null, seenIds: [] };
      throw new Error(`Cannot read cursor state at ${this.path}: ${error.message}`);
    }
  }

  async save({ cursor, seenIds }) {
    const directory = dirname(this.path);
    const temporary = `${this.path}.${process.pid}.tmp`;
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const payload = `${JSON.stringify(
      { version: 1, cursor, seen_ids: [...seenIds].slice(-MAX_SEEN_IDS) },
      null,
      2,
    )}\n`;
    try {
      await writeFile(temporary, payload, { encoding: "utf8", mode: 0o600 });
      await rename(temporary, this.path);
      if (process.platform !== "win32") await chmod(this.path, 0o600);
    } catch (error) {
      await unlink(temporary).catch(() => {});
      throw new Error(`Cannot persist cursor state at ${this.path}: ${error.message}`);
    }
  }
}
