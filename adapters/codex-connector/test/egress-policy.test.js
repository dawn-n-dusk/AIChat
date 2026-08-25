import assert from "node:assert/strict";
import test from "node:test";

import { assertEgressAllowed } from "../src/egress-policy.js";

const config = {
  autoReplyEnabled: true,
  egressAudienceAcknowledged: true,
  egressMaxTextBytes: 8_192,
  egressAllowedReferenceHosts: new Set(["github.com"]),
  token: "relay-secret-value",
  egressCanary: "private-canary-value-1234",
};

function event(overrides = {}) {
  return {
    text: "Verified result",
    messageType: "result",
    references: [],
    ...overrides,
  };
}

test("egress accepts only exact allowlisted HTTPS references without query data", () => {
  assert.doesNotThrow(() =>
    assertEgressAllowed(
      event({ references: ["https://github.com/dawn-n-dusk/AIChat/commit/abc123"] }),
      config,
    ),
  );
  for (const reference of [
    "https://github.com/dawn-n-dusk/AIChat?token=x",
    "https://127.0.0.1/result",
    "file:///Users/example/secret",
    "https://example.com/result",
  ]) {
    assert.throws(
      () => assertEgressAllowed(event({ references: [reference] }), config),
      (error) => error.code === "AICHAT_EGRESS_REFERENCE",
    );
  }
});

test("egress blocks exact canaries and common or high-entropy credential shapes", () => {
  const blocked = [
    `leak ${config.egressCanary}`,
    "-----BEGIN PRIVATE KEY-----",
    "api_key=super-secret-password-value",
    "AbCDefGhIJklMNopQRstUVwxYZ0123456789+/=_AbCDefGh",
  ];
  for (const text of blocked) {
    assert.throws(
      () => assertEgressAllowed(event({ text }), config),
      (error) => error.code === "AICHAT_OUTBOUND_DLP" && !error.message.includes(text),
    );
  }
});

test("egress blocks common reversible encodings of the relay token and canary", () => {
  const encoded = [
    Buffer.from(config.egressCanary, "utf8").toString("hex"),
    Buffer.from(config.egressCanary, "utf8").toString("base64"),
    Buffer.from(config.token, "utf8").toString("base64url"),
    [...Buffer.from(config.token, "utf8")]
      .map((byte) => `%${byte.toString(16).padStart(2, "0")}`)
      .join(""),
  ];
  for (const text of encoded) {
    assert.throws(
      () => assertEgressAllowed(event({ text: `encoded:${text}` }), config),
      (error) => error.code === "AICHAT_OUTBOUND_DLP" && !error.message.includes(text),
    );
  }
  assert.throws(
    () =>
      assertEgressAllowed(
        event({ references: [`https://github.com/aichat/${encoded[0]}`] }),
        config,
      ),
    (error) => error.code === "AICHAT_OUTBOUND_DLP",
  );
});

test("automatic egress is fail-closed unless explicitly enabled and audience-acknowledged", () => {
  assert.throws(
    () => assertEgressAllowed(event(), { ...config, autoReplyEnabled: false }),
    (error) => error.code === "AICHAT_EGRESS_DISABLED",
  );
  assert.throws(
    () => assertEgressAllowed(event(), { ...config, egressAudienceAcknowledged: false }),
    (error) => error.code === "AICHAT_EGRESS_AUDIENCE",
  );
});
