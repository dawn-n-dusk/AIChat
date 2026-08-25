import { randomUUID } from "node:crypto";
import { chmod, lstat, mkdir, open, rename, unlink } from "node:fs/promises";
import { basename, dirname, join } from "node:path";

export async function atomicWritePrivateFile(path, payload) {
  const directory = dirname(path);
  const temporary = join(
    directory,
    `.${basename(path)}.${process.pid}.${randomUUID()}.tmp`,
  );
  const createdDirectory = await mkdir(directory, { recursive: true, mode: 0o700 });
  const directoryDetails = await lstat(directory);
  if (!directoryDetails.isDirectory() || directoryDetails.isSymbolicLink()) {
    throw new Error("Atomic private file parent must be a real directory");
  }
  if (createdDirectory != null && process.platform !== "win32") {
    await chmod(directory, 0o700);
  }

  let handle;
  try {
    handle = await open(temporary, "wx", 0o600);
    await handle.writeFile(payload, "utf8");
    await handle.sync();
    await handle.close();
    handle = null;
    await rename(temporary, path);
    if (process.platform !== "win32") await chmod(path, 0o600);
    await syncDirectory(directory);
  } catch (error) {
    await handle?.close().catch(() => {});
    await unlink(temporary).catch(() => {});
    throw error;
  }
}

export class SerializedSaveQueue {
  constructor() {
    this.chain = Promise.resolve();
  }

  run(operation) {
    const task = this.chain.then(operation);
    this.chain = task.catch(() => {});
    return task;
  }
}

async function syncDirectory(directory) {
  if (process.platform === "win32") return;
  let handle;
  try {
    handle = await open(directory, "r");
    await handle.sync();
  } catch (error) {
    if (!["EINVAL", "ENOTSUP", "EISDIR"].includes(error?.code)) throw error;
  } finally {
    await handle?.close().catch(() => {});
  }
}
