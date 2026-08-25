import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, symlink, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";

import { loadConfig } from "../src/config.js";
import { MappingInstanceLock } from "../src/instance-lock.js";

test("mapping lock allows exactly one concurrent owner and releases with process lifetime", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-lock-race-"));
  const port = await freePort();
  const first = new MappingInstanceLock({
    port,
    metadataPath: join(directory, "first.json"),
    logger: { error() {} },
  });
  const second = new MappingInstanceLock({
    port,
    metadataPath: join(directory, "second.json"),
    logger: { error() {} },
  });
  const results = await Promise.allSettled([first.acquire(), second.acquire()]);
  assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
  assert.equal(results.filter((result) => result.status === "rejected").length, 1);
  const owner = results[0].status === "fulfilled" ? first : second;
  await owner.assertOwned();
  await owner.release();

  const replacement = new MappingInstanceLock({
    port,
    metadataPath: join(directory, "replacement.json"),
  });
  await replacement.acquire();
  await replacement.release();
});

test("metadata failure rolls back the OS lock before reporting failure", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-lock-rollback-"));
  const notDirectory = join(directory, "plain-file");
  await writeFile(notDirectory, "x");
  const port = await freePort();
  const broken = new MappingInstanceLock({
    port,
    metadataPath: join(notDirectory, "owner.json"),
  });
  await assert.rejects(() => broken.acquire(), /metadata/);

  const replacement = new MappingInstanceLock({
    port,
    metadataPath: join(directory, "owner.json"),
  });
  await replacement.acquire();
  await replacement.release();
});

test("state lock prevents different mappings from sharing one durable state file", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-lock-state-binding-"));
  const [firstMappingPort, secondMappingPort, statePort] = await uniqueFreePorts(3);
  const first = new MappingInstanceLock({
    port: firstMappingPort,
    statePort,
    metadataPath: join(directory, "first.json"),
    bindingId: "mapping-a",
    statePath: join(directory, "shared-state.json"),
  });
  await first.acquire();
  const second = new MappingInstanceLock({
    port: secondMappingPort,
    statePort,
    metadataPath: join(directory, "second.json"),
    bindingId: "mapping-b",
    statePath: join(directory, "shared-state.json"),
  });
  await assert.rejects(
    () => second.acquire(),
    (error) => error.code === "AICHAT_CONNECTOR_LOCKED" && /state lock port/.test(error.message),
  );
  await first.release();
});

test("canonical state lock blocks a cross-process connector using a symlinked parent alias", async (t) => {
  if (process.platform === "win32") return t.skip("directory symlink setup is platform-specific");
  const directory = await mkdtemp(join(tmpdir(), "aichat-lock-alias-process-"));
  const privateDirectory = join(directory, "private");
  const aliasDirectory = join(directory, "alias");
  await mkdir(privateDirectory, { mode: 0o700 });
  await chmod(privateDirectory, 0o700);
  await symlink(privateDirectory, aliasDirectory, "dir");
  const firstConfig = loadConfig(connectorEnv(join(privateDirectory, "state.json"), "channel-a"));
  let secondConfig;
  for (let index = 0; index < 100; index += 1) {
    const candidate = loadConfig(
      connectorEnv(join(aliasDirectory, "state.json"), `channel-b-${index}`),
    );
    if (candidate.instanceLockPort !== firstConfig.instanceLockPort) {
      secondConfig = candidate;
      break;
    }
  }
  assert.ok(secondConfig);
  assert.equal(firstConfig.stateFile, secondConfig.stateFile);
  assert.equal(firstConfig.instanceStateLockPort, secondConfig.instanceStateLockPort);

  const moduleUrl = pathToFileURL(join(process.cwd(), "src", "instance-lock.js")).href;
  const child = spawn(
    process.execPath,
    [
      "--input-type=module",
      "-e",
      `import { MappingInstanceLock } from ${JSON.stringify(moduleUrl)};
       const options = JSON.parse(process.argv[1]);
       const lock = new MappingInstanceLock(options);
       await lock.acquire();
       process.stdout.write("READY\\n");
       setInterval(() => {}, 1000);`,
      JSON.stringify({
        port: firstConfig.instanceLockPort,
        statePort: firstConfig.instanceStateLockPort,
        metadataPath: firstConfig.instanceLockMetadataPath,
        bindingId: firstConfig.instanceLockIdentity,
        statePath: firstConfig.stateFile,
      }),
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  await waitForLine(child, "READY");
  const contender = new MappingInstanceLock({
    port: secondConfig.instanceLockPort,
    statePort: secondConfig.instanceStateLockPort,
    metadataPath: secondConfig.instanceLockMetadataPath,
    bindingId: secondConfig.instanceLockIdentity,
    statePath: secondConfig.stateFile,
  });
  await assert.rejects(
    () => contender.acquire(),
    (error) => error.code === "AICHAT_CONNECTOR_LOCKED" && /state lock port/.test(error.message),
  );
  child.kill("SIGKILL");
  await new Promise((resolve) => child.once("exit", resolve));
});

test("Unicode filesystem-fold aliases are rejected before a cross-process lock can start", async (t) => {
  if (process.platform === "win32") return t.skip("POSIX private-directory setup is not available");
  const directory = await mkdtemp(join(tmpdir(), "aichat-lock-unicode-fold-process-"));
  const privateDirectory = join(directory, "private");
  await mkdir(privateDirectory, { mode: 0o700 });
  await chmod(privateDirectory, 0o700);
  const configUrl = pathToFileURL(join(process.cwd(), "src", "config.js")).href;
  const child = spawn(
    process.execPath,
    [
      "--input-type=module",
      "-e",
      `import { loadConfig } from ${JSON.stringify(configUrl)};
       try {
         loadConfig(JSON.parse(process.argv[1]));
         process.stdout.write("ACCEPTED\\n");
       } catch (error) {
         process.stdout.write("REJECTED:" + error.message + "\\n");
       }`,
      JSON.stringify(connectorEnv(join(privateDirectory, "Straße.json"), "channel-unicode")),
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  const output = await collectChildOutput(child);
  assert.match(output, /REJECTED:.*basename must use only ASCII/);

  const asciiConfig = loadConfig(
    connectorEnv(join(privateDirectory, "STRASSE.json"), "channel-ascii"),
  );
  const lock = new MappingInstanceLock({
    port: asciiConfig.instanceLockPort,
    statePort: asciiConfig.instanceStateLockPort,
    metadataPath: asciiConfig.instanceLockMetadataPath,
    bindingId: asciiConfig.instanceLockIdentity,
    statePath: asciiConfig.stateFile,
  });
  await lock.acquire();
  await lock.release();
});

test("OS lock is released after an ungraceful owner process exit", async () => {
  const directory = await mkdtemp(join(tmpdir(), "aichat-lock-crash-"));
  const port = await freePort();
  const moduleUrl = pathToFileURL(
    join(process.cwd(), "src", "instance-lock.js"),
  ).href;
  const child = spawn(
    process.execPath,
    [
      "--input-type=module",
      "-e",
      `import { MappingInstanceLock } from ${JSON.stringify(moduleUrl)};
       const lock = new MappingInstanceLock({ port: Number(process.argv[1]), metadataPath: process.argv[2] });
       await lock.acquire();
       process.stdout.write("READY\\n");
       setInterval(() => {}, 1000);`,
      String(port),
      join(directory, "child-owner.json"),
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );
  await waitForLine(child, "READY");

  const contender = new MappingInstanceLock({
    port,
    metadataPath: join(directory, "contender.json"),
  });
  await assert.rejects(() => contender.acquire(), /port is already in use/);
  child.kill("SIGKILL");
  await new Promise((resolve) => child.once("exit", resolve));

  const replacement = new MappingInstanceLock({
    port,
    metadataPath: join(directory, "replacement.json"),
  });
  await replacement.acquire();
  await replacement.release();
});

function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen({ host: "127.0.0.1", port: 0 }, () => {
      const address = server.address();
      server.close(() => resolve(address.port));
    });
  });
}

async function uniqueFreePorts(count) {
  const ports = new Set();
  while (ports.size < count) ports.add(await freePort());
  return [...ports];
}

function connectorEnv(stateFile, channelId) {
  return {
    AICHAT_CODEX_CONNECTOR_ENABLED: "true",
    AICHAT_TOKEN: "relay-secret",
    AICHAT_CHANNEL_ID: channelId,
    AICHAT_ALLOWED_SENDER_IDS: "agent-remote",
    AICHAT_STATE_FILE: stateFile,
    CODEX_TARGET_THREAD_ID: "thread-1",
    CODEX_DRIVER: "module",
    CODEX_DRIVER_MODULE: "./driver.js",
  };
}

function waitForLine(child, expected) {
  return new Promise((resolve, reject) => {
    let output = "";
    const timeout = setTimeout(() => reject(new Error("Timed out waiting for lock child")), 5_000);
    child.stdout.on("data", (chunk) => {
      output += chunk.toString("utf8");
      if (!output.includes(expected)) return;
      clearTimeout(timeout);
      resolve();
    });
    child.once("exit", (code) => {
      clearTimeout(timeout);
      reject(new Error(`Lock child exited early with ${code}`));
    });
  });
}

function collectChildOutput(child) {
  return new Promise((resolve, reject) => {
    let output = "";
    let errors = "";
    child.stdout.on("data", (chunk) => {
      output += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk) => {
      errors += chunk.toString("utf8");
    });
    child.once("error", reject);
    child.once("exit", (code) => {
      if (code === 0) resolve(output);
      else reject(new Error(`Child exited with ${code}: ${errors}`));
    });
  });
}
