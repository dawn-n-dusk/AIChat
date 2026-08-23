import { spawn } from "node:child_process";

const OUTPUT_TEXT_KEYS = ["result", "response", "output", "text", "content", "message"];
const SESSION_ID_KEYS = ["sessionId", "session_id", "sessionID"];

export class GrokRunner {
  constructor({
    command,
    baseArgs = [],
    cwd,
    timeoutMs,
    maxOutputBytes,
    spawnImpl = spawn,
  }) {
    this.command = command;
    this.baseArgs = baseArgs;
    this.cwd = cwd;
    this.timeoutMs = timeoutMs;
    this.maxOutputBytes = maxOutputBytes;
    this.spawnImpl = spawnImpl;
  }

  async run({ prompt, sessionId }) {
    const args = buildGrokArgs({ baseArgs: this.baseArgs, prompt, sessionId });
    const { stdout, stderr } = await runProcess({
      command: this.command,
      args,
      cwd: this.cwd,
      timeoutMs: this.timeoutMs,
      maxOutputBytes: this.maxOutputBytes,
      spawnImpl: this.spawnImpl,
    });
    const parsed = parseGrokJson(stdout);
    const output = findOutputText(parsed);
    const parsedSessionId = findSessionId(parsed);

    if (!output) {
      throw new Error("Grok JSON output did not contain a non-empty response text");
    }
    if (!sessionId && !parsedSessionId) {
      throw new Error("Grok JSON output did not contain a sessionId for the new session");
    }
    if (sessionId && parsedSessionId && parsedSessionId !== sessionId) {
      throw new Error("Grok resumed with an unexpected sessionId");
    }

    return {
      output,
      sessionId: parsedSessionId ?? sessionId,
      stderr,
    };
  }
}

export function buildGrokArgs({ baseArgs = [], prompt, sessionId }) {
  const common = ["--no-auto-update"];
  if (sessionId) {
    return [...baseArgs, ...common, "-r", sessionId, "-p", prompt, "--output-format", "json"];
  }
  return [...baseArgs, ...common, "-p", prompt, "--output-format", "json"];
}

export function parseGrokJson(stdout) {
  const value = stdout.trim();
  if (!value) throw new Error("Grok returned empty stdout");
  try {
    return JSON.parse(value);
  } catch {
    // Some launchers print diagnostics before the final JSON object. The official
    // format promises one object at the end, so accept a final pretty-printed
    // object or the last parseable line after a launcher diagnostic.
    const objectStarts = [];
    const pattern = /(?:^|\n)\s*([{[])/g;
    for (let match = pattern.exec(value); match; match = pattern.exec(value)) {
      objectStarts.push(match.index + match[0].lastIndexOf(match[1]));
    }
    for (let index = objectStarts.length - 1; index >= 0; index -= 1) {
      try {
        return JSON.parse(value.slice(objectStarts[index]).trim());
      } catch {
        // A nested pretty-printed object may begin on this line; keep walking back.
      }
    }
    const lines = value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    for (let index = lines.length - 1; index >= 0; index -= 1) {
      try {
        return JSON.parse(lines[index]);
      } catch {
        // Continue looking for the final JSON object.
      }
    }
    throw new Error("Grok stdout was not valid JSON");
  }
}

export function findSessionId(value) {
  return findStringByKeys(value, SESSION_ID_KEYS, 0);
}

export function findOutputText(value) {
  if (typeof value === "string") return value.trim() || null;
  return findStringByKeys(value, OUTPUT_TEXT_KEYS, 0);
}

function findStringByKeys(value, keys, depth) {
  if (depth > 5 || !value || typeof value !== "object") return null;
  if (Array.isArray(value)) {
    for (let index = value.length - 1; index >= 0; index -= 1) {
      const found = findStringByKeys(value[index], keys, depth + 1);
      if (found) return found;
    }
    return null;
  }
  for (const key of keys) {
    const candidate = value[key];
    if (typeof candidate === "string" && candidate.trim()) return candidate.trim();
  }
  for (const candidate of Object.values(value)) {
    const found = findStringByKeys(candidate, keys, depth + 1);
    if (found) return found;
  }
  return null;
}

function runProcess({ command, args, cwd, timeoutMs, maxOutputBytes, spawnImpl }) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawnImpl(command, args, {
        cwd,
        env: buildGrokEnvironment(process.env),
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
      });
    } catch (error) {
      reject(new Error(`Cannot start Grok command: ${errorMessage(error)}`));
      return;
    }

    let stdout = "";
    let stderr = "";
    let totalBytes = 0;
    let settled = false;
    const timer = setTimeout(() => {
      child.kill();
      finish(new Error(`Grok command timed out after ${timeoutMs} ms`));
    }, timeoutMs);

    const append = (target, chunk) => {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
      totalBytes += buffer.length;
      if (totalBytes > maxOutputBytes) {
        child.kill();
        finish(new Error(`Grok command exceeded ${maxOutputBytes} output bytes`));
        return target;
      }
      return target + buffer.toString("utf8");
    };

    child.stdout?.on("data", (chunk) => {
      stdout = append(stdout, chunk);
    });
    child.stderr?.on("data", (chunk) => {
      stderr = append(stderr, chunk);
    });
    child.on("error", (error) => finish(new Error(`Cannot start Grok command: ${errorMessage(error)}`)));
    child.on("close", (code, signal) => {
      if (code === 0) {
        finish(null, { stdout, stderr });
        return;
      }
      finish(
        new Error(
          `Grok command failed (${signal ? `signal ${signal}` : `exit ${code}`}); ` +
            "stderr omitted from bridge logs",
        ),
      );
    });

    function finish(error, result) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve(result);
    }
  });
}

export function buildGrokEnvironment(source) {
  return Object.fromEntries(
    Object.entries(source).filter(([name, value]) => {
      return !name.startsWith("AICHAT_") && typeof value === "string";
    }),
  );
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}
