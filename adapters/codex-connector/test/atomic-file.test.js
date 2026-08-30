import assert from "node:assert/strict";
import { test } from "node:test";

import { protectWindowsPrivateFile } from "../src/atomic-file.js";

test("Windows private writes remove inheritance and allow only the user and LocalSystem", async () => {
  const calls = [];
  await protectWindowsPrivateFile("C:\\private\\state.tmp", {
    platform: "win32",
    env: { AICHAT_WINDOWS_PRIVATE_SID: "S-1-5-21-100-200-300-400" },
    execFileImpl: async (...args) => calls.push(args),
  });
  assert.deepEqual(calls, [
    [
      "icacls.exe",
      [
        "C:\\private\\state.tmp",
        "/inheritance:r",
        "/grant:r",
        "*S-1-5-21-100-200-300-400:(F)",
        "*S-1-5-18:(F)",
      ],
      { windowsHide: true },
    ],
  ]);
});

test("Windows private writes fail closed on an invalid launcher SID binding", async () => {
  await assert.rejects(
    protectWindowsPrivateFile("C:\\private\\state.tmp", {
      platform: "win32",
      env: { AICHAT_WINDOWS_PRIVATE_SID: "Everyone" },
      execFileImpl: async () => {},
    }),
    /SID binding is missing or invalid/,
  );
});

test("Windows private writes fail before rename when ACL protection fails", async () => {
  await assert.rejects(
    protectWindowsPrivateFile("C:\\private\\state.tmp", {
      platform: "win32",
      env: { AICHAT_WINDOWS_PRIVATE_SID: "S-1-5-21-100-200-300-400" },
      execFileImpl: async () => {
        throw new Error("synthetic icacls failure");
      },
    }),
    /ACL protection failed/,
  );
});
