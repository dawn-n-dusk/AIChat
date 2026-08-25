import { isIP } from "node:net";

const COMMON_SECRET_PATTERNS = [
  /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/i,
  /\b(?:sk|rk|pk)-[A-Za-z0-9_-]{16,}\b/,
  /\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
  /\bAKIA[A-Z0-9]{16}\b/,
  /\bAuthorization\s*:\s*Bearer\s+\S+/i,
  /\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[:=]\s*\S{8,}/i,
];

export function assertEgressAllowed(event, config) {
  if (!config.autoReplyEnabled) {
    throw policyError("Automatic AIChat egress is disabled", "AICHAT_EGRESS_DISABLED");
  }
  if (!config.egressAudienceAcknowledged) {
    throw policyError(
      "AIChat channel broadcast audience was not acknowledged",
      "AICHAT_EGRESS_AUDIENCE",
    );
  }
  if (event.messageType !== "result" && event.messageType !== "status") {
    throw policyError(
      "Automatic AIChat replies must be terminal result or lifecycle status messages",
      "AICHAT_EGRESS_TYPE",
    );
  }
  if (Buffer.byteLength(event.text, "utf8") > config.egressMaxTextBytes) {
    throw policyError("Automatic AIChat reply exceeds the local byte limit", "AICHAT_EGRESS_SIZE");
  }
  if (
    containsSecret(event.text, config, true) ||
    event.references.some((value) => containsSecret(value, config, false))
  ) {
    throw policyError(
      "Automatic AIChat reply was blocked by the local secret-isolation policy",
      "AICHAT_OUTBOUND_DLP",
    );
  }
  for (const reference of event.references) validateReference(reference, config);
}

function validateReference(value, config) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw policyError("Automatic AIChat reference is not a valid URL", "AICHAT_EGRESS_REFERENCE");
  }
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
    throw policyError(
      "Automatic AIChat references require credential-free HTTPS URLs without query or fragment data",
      "AICHAT_EGRESS_REFERENCE",
    );
  }
  const hostname = url.hostname.toLowerCase();
  if (
    !hostname ||
    hostname === "localhost" ||
    hostname.endsWith(".localhost") ||
    isIP(hostname) !== 0 ||
    !config.egressAllowedReferenceHosts.has(hostname)
  ) {
    throw policyError(
      "Automatic AIChat reference host is not on the local allowlist",
      "AICHAT_EGRESS_REFERENCE",
    );
  }
}

function containsSecret(value, config, scanEntropy) {
  if (containsSecretVariant(value, config.token)) return true;
  if (containsSecretVariant(value, config.egressCanary)) return true;
  if (COMMON_SECRET_PATTERNS.some((pattern) => pattern.test(value))) return true;
  return scanEntropy && value
    .split(/[^A-Za-z0-9_+\/=.-]+/)
    .some((token) => looksLikeHighEntropySecret(token));
}

function containsSecretVariant(value, secret) {
  if (typeof secret !== "string" || !secret || !value) return false;
  if (value.includes(secret)) return true;
  if (Buffer.byteLength(secret, "utf8") < 8) return false;

  const bytes = Buffer.from(secret, "utf8");
  const base64 = bytes.toString("base64");
  const base64Url = bytes.toString("base64url");
  const caseSensitive = new Set([
    base64,
    base64.replace(/=+$/, ""),
    base64Url,
    encodeURIComponent(secret),
  ]);
  for (const encoded of caseSensitive) {
    if (encoded && encoded !== secret && value.includes(encoded)) return true;
  }

  const lowerValue = value.toLowerCase();
  const hex = bytes.toString("hex");
  const percentEncoded = [...bytes].map((byte) => `%${byte.toString(16).padStart(2, "0")}`).join("");
  return lowerValue.includes(hex) || lowerValue.includes(percentEncoded);
}

function looksLikeHighEntropySecret(value) {
  if (value.length < 32 || value.length > 512) return false;
  if (!/[a-z]/.test(value) || !/[A-Z]/.test(value) || !/\d/.test(value)) return false;
  const counts = new Map();
  for (const character of value) counts.set(character, (counts.get(character) ?? 0) + 1);
  let entropy = 0;
  for (const count of counts.values()) {
    const probability = count / value.length;
    entropy -= probability * Math.log2(probability);
  }
  return entropy >= 4.25;
}

function policyError(message, code) {
  const error = new Error(message);
  error.code = code;
  return error;
}
