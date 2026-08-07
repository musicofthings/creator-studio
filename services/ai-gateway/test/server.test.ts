import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildServer, canonicalTranscriptHash } from "../src/server.js";

const CONSENT = {
  id: "3e142055-d5dd-4fab-8c15-dd0ff499901a",
  purpose: "Create edit suggestions",
  dataClasses: ["transcript"],
  policyVersion: "1",
  grantedAt: "2026-08-07T00:00:00Z",
};

function requestBody(overrides: Record<string, unknown> = {}) {
  return {
    schemaVersion: 1,
    requestId: "f4b0e531-0418-4161-b636-691f15c79751",
    inputHash: `sha256:${"a".repeat(64)}`,
    kinds: ["title", "chapter"],
    transcript: [{ startUs: 0, endUs: 1_000_000, text: "Build a focused tutorial quickly" }],
    consent: CONSENT,
    ...overrides,
  };
}

describe("AI gateway", () => {
  it("reports health", async () => {
    const app = buildServer({ authToken: null });
    const response = await app.inject({ method: "GET", url: "/health" });
    assert.equal(response.statusCode, 200);
    assert.deepEqual(response.json(), { status: "ok", version: "0.1.0" });
    await app.close();
  });

  it("returns typed deterministic suggestions with transcript consent", async () => {
    const app = buildServer({ authToken: null });
    const response = await app.inject({
      method: "POST",
      url: "/v1/suggestions",
      payload: requestBody(),
    });

    assert.equal(response.statusCode, 200);
    assert.equal(response.json().suggestions.length, 2);
    await app.close();
  });

  it("rejects transcript processing without matching consent", async () => {
    const app = buildServer({ authToken: null });
    const response = await app.inject({
      method: "POST",
      url: "/v1/suggestions",
      payload: requestBody({
        transcript: [],
        kinds: ["title"],
        consent: { ...CONSENT, dataClasses: ["projectMetadata"] },
      }),
    });

    assert.equal(response.statusCode, 400);
    assert.equal(response.headers["content-type"]?.toString().includes("application/problem+json"), true);
    await app.close();
  });

  it("rejects a malformed transcript instead of failing inside the provider", async () => {
    const app = buildServer({ authToken: null });
    for (const transcript of [
      [null],
      [{ startUs: 0, endUs: 10, text: 123 }],
      [{ startUs: 0, text: "missing end" }],
      [{ startUs: -1, endUs: 10, text: "negative" }],
    ]) {
      const response = await app.inject({
        method: "POST",
        url: "/v1/suggestions",
        payload: requestBody({ transcript }),
      });
      assert.equal(response.statusCode, 400, JSON.stringify(transcript));
    }
    await app.close();
  });

  it("rejects an unordered transcript range", async () => {
    const app = buildServer({ authToken: null });
    const response = await app.inject({
      method: "POST",
      url: "/v1/suggestions",
      payload: requestBody({ transcript: [{ startUs: 500, endUs: 500, text: "empty range" }] }),
    });
    assert.equal(response.statusCode, 400);
    await app.close();
  });

  it("requires the bearer token when one is configured", async () => {
    const app = buildServer({ authToken: "s3cret" });

    const anonymous = await app.inject({
      method: "POST",
      url: "/v1/suggestions",
      payload: requestBody(),
    });
    assert.equal(anonymous.statusCode, 401);

    const wrong = await app.inject({
      method: "POST",
      url: "/v1/suggestions",
      headers: { authorization: "Bearer nope" },
      payload: requestBody(),
    });
    assert.equal(wrong.statusCode, 401);

    const authorized = await app.inject({
      method: "POST",
      url: "/v1/suggestions",
      headers: { authorization: "Bearer s3cret" },
      payload: requestBody(),
    });
    assert.equal(authorized.statusCode, 200);

    // /health stays reachable so a load balancer does not need the token.
    const health = await app.inject({ method: "GET", url: "/health" });
    assert.equal(health.statusCode, 200);

    // A query string must not be a way around the auth hook.
    const smuggled = await app.inject({ method: "GET", url: "/health?x=1" });
    assert.equal(smuggled.statusCode, 200);

    await app.close();
  });

  it("verifies inputHash against the transcript when asked to", async () => {
    const app = buildServer({ authToken: null, verifyInputHash: true });
    const transcript = [{ startUs: 0, endUs: 1_000_000, text: "Build a focused tutorial quickly" }];

    const mismatch = await app.inject({
      method: "POST",
      url: "/v1/suggestions",
      payload: requestBody({ transcript }),
    });
    assert.equal(mismatch.statusCode, 400);

    const matching = await app.inject({
      method: "POST",
      url: "/v1/suggestions",
      payload: requestBody({ transcript, inputHash: canonicalTranscriptHash(transcript) }),
    });
    assert.equal(matching.statusCode, 200);
    await app.close();
  });

  it("echoes an allowed origin and never a wildcard", async () => {
    const app = buildServer({ authToken: null, allowedOrigins: ["http://localhost:5173"] });

    const allowed = await app.inject({
      method: "GET",
      url: "/health",
      headers: { origin: "http://localhost:5173" },
    });
    assert.equal(allowed.headers["access-control-allow-origin"], "http://localhost:5173");

    const denied = await app.inject({
      method: "GET",
      url: "/health",
      headers: { origin: "https://evil.example" },
    });
    assert.equal(denied.headers["access-control-allow-origin"], undefined);
    await app.close();
  });

  it("rate limits a noisy caller", async () => {
    const app = buildServer({ authToken: null, rateLimit: { limit: 2, windowMs: 60_000 } });
    assert.equal((await app.inject({ method: "GET", url: "/health" })).statusCode, 200);
    assert.equal((await app.inject({ method: "GET", url: "/health" })).statusCode, 200);
    assert.equal((await app.inject({ method: "GET", url: "/health" })).statusCode, 429);
    await app.close();
  });
});
