import { randomUUID } from "node:crypto";
import { execFile as execFileCallback } from "node:child_process";
import { chmod, lstat, mkdir, open, rename, unlink } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { promisify } from "node:util";

const execFile = promisify(execFileCallback);
const WINDOWS_SYSTEM_SID = "S-1-5-18";
const WINDOWS_SID = /^S-1-(?:\d+-)+\d+$/;

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
    await protectWindowsPrivateFile(temporary);
    await rename(temporary, path);
    if (process.platform !== "win32") await chmod(path, 0o600);
    await syncDirectory(directory);
  } catch (error) {
    await handle?.close().catch(() => {});
    await unlink(temporary).catch(() => {});
    throw error;
  }
}

export async function protectWindowsPrivateFile(
  path,
  {
    platform = process.platform,
    env = process.env,
    execFileImpl = execFile,
  } = {},
) {
  if (platform !== "win32") return;
  const currentSid = env.AICHAT_WINDOWS_PRIVATE_SID?.trim();
  if (!currentSid || !WINDOWS_SID.test(currentSid) || currentSid === WINDOWS_SYSTEM_SID) {
    throw new Error("Windows private-file SID binding is missing or invalid");
  }
  try {
    await execFileImpl(
      "icacls.exe",
      [
        path,
        "/inheritance:r",
        "/grant:r",
        `*${currentSid}:(F)`,
        `*${WINDOWS_SYSTEM_SID}:(F)`,
      ],
      { windowsHide: true },
    );
  } catch {
    throw new Error("Windows private-file ACL protection failed");
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
