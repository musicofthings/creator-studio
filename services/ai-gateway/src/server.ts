import { createHash, timingSafeEqual } from "node:crypto";
import { pathToFileURL } from "node:url";
import Fastify, {
  type FastifyError,
  type FastifyInstance,
  type FastifyReply,
  type FastifyRequest,
} from "fastify";
import { DeterministicSuggestionProvider } from "./provider.js";
import type { SuggestionProvider, SuggestionRequest, TranscriptSegment } from "./types.js";

const UUID_PATTERN =
  "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$";

const SUGGESTION_KINDS = [
  "chapter",
  "socialClip",
  "focus",
  "title",
  "showNotes",
  "tutorialStep",
] as const;

/**
 * Mirrors `SuggestionRequest` in contracts/openapi.yaml. Declaring the shape lets
 * Fastify reject malformed bodies before any handler touches them — hand-rolled
 * checks let a non-string `text` or a null transcript entry through as a 500.
 */
const suggestionRequestSchema = {
  type: "object",
  additionalProperties: false,
  required: ["schemaVersion", "requestId", "inputHash", "kinds", "transcript", "consent"],
  properties: {
    schemaVersion: { const: 1 },
    requestId: { type: "string", pattern: UUID_PATTERN },
    inputHash: { type: "string", pattern: "^sha256:[0-9a-f]{64}$" },
    kinds: {
      type: "array",
      minItems: 1,
      maxItems: SUGGESTION_KINDS.length,
      items: { type: "string", enum: SUGGESTION_KINDS },
    },
    transcript: {
      type: "array",
      maxItems: 20000,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["startUs", "endUs", "text"],
        properties: {
          startUs: { type: "integer", minimum: 0, maximum: Number.MAX_SAFE_INTEGER },
          endUs: { type: "integer", minimum: 1, maximum: Number.MAX_SAFE_INTEGER },
          text: { type: "string", maxLength: 10000 },
          speaker: { type: "string", maxLength: 200 },
        },
      },
    },
    consent: {
      type: "object",
      additionalProperties: false,
      required: ["id", "purpose", "dataClasses", "policyVersion", "grantedAt"],
      properties: {
        id: { type: "string", pattern: UUID_PATTERN },
        purpose: { type: "string", minLength: 1, maxLength: 500 },
        // The consent gate is the whole point of this boundary, so it lives in
        // the schema rather than in a handler that could be reordered away.
        dataClasses: {
          type: "array",
          minItems: 1,
          items: { type: "string" },
          contains: { const: "transcript" },
        },
        policyVersion: { type: "string", minLength: 1, maxLength: 50 },
        grantedAt: { type: "string", minLength: 1, maxLength: 50 },
        signature: { type: "string", maxLength: 4000 },
      },
    },
  },
} as const;

export interface ServerOptions {
  provider?: SuggestionProvider;
  /**
   * Bearer token required on every route except `/health`. Pass `null` to state
   * explicitly that this instance is unauthenticated — there is deliberately no
   * default, so a missing environment variable cannot silently open the service.
   */
  authToken: string | null;
  verifyInputHash?: boolean;
  allowedOrigins?: string[];
  logger?: boolean;
  rateLimit?: { limit: number; windowMs: number } | null;
}

export function buildServer(options: ServerOptions): FastifyInstance {
  const {
    provider = new DeterministicSuggestionProvider(),
    authToken,
    verifyInputHash = false,
    allowedOrigins = [],
    logger = false,
    rateLimit = { limit: 60, windowMs: 60_000 },
  } = options;

  const app = Fastify({
    logger,
    bodyLimit: 1_000_000,
    // Fastify enables Ajv type coercion by default, which would quietly turn a
    // numeric `text` into a string rather than rejecting it. A contract boundary
    // should say no.
    ajv: { customOptions: { coerceTypes: false } },
  });
  const withinRateLimit = rateLimit ? createRateLimiter(rateLimit.limit, rateLimit.windowMs) : null;

  // Explicit allow-list, never a wildcard. No browser client ships in this repo,
  // so the default is to permit no cross-origin request at all.
  app.addHook("onRequest", async (request, reply) => {
    const origin = request.headers.origin;
    if (typeof origin === "string" && allowedOrigins.includes(origin)) {
      reply.header("Access-Control-Allow-Origin", origin);
      reply.header("Vary", "Origin");
      reply.header("Access-Control-Allow-Credentials", "true");
      reply.header("Access-Control-Allow-Headers", "authorization,content-type");
      reply.header("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
    }
    if (request.method === "OPTIONS") {
      return reply.code(204).send();
    }
  });

  app.addHook("onRequest", async (request, reply) => {
    if (withinRateLimit && !withinRateLimit(request.ip, Date.now())) {
      return problem(reply, 429, "rate-limited", "Too many requests", request);
    }
    if (routePath(request) === "/health") return;
    if (authToken === null) return;
    if (!matchesBearerToken(request.headers.authorization, authToken)) {
      return problem(reply, 401, "unauthorized", "Unauthorized", request);
    }
  });

  app.setErrorHandler((error: FastifyError, request, reply) => {
    if (error.validation) {
      return problem(reply, 400, "invalid-request", "Invalid suggestion request", request, error.message);
    }
    request.log.error({ err: error }, "Unhandled gateway error");
    return problem(reply, error.statusCode ?? 500, "internal-error", "Internal error", request);
  });

  app.get("/health", async () => ({ status: "ok", version: "0.1.0" }));

  app.post<{ Body: SuggestionRequest }>(
    "/v1/suggestions",
    { schema: { body: suggestionRequestSchema } },
    async (request, reply) => {
      const body = request.body;
      const ordering = body.transcript.find((segment) => segment.endUs <= segment.startUs);
      if (ordering) {
        return problem(
          reply,
          400,
          "invalid-request",
          "Invalid suggestion request",
          request,
          "Transcript segment ranges must be ordered.",
        );
      }
      if (verifyInputHash && canonicalTranscriptHash(body.transcript) !== body.inputHash) {
        return problem(
          reply,
          400,
          "invalid-request",
          "Invalid suggestion request",
          request,
          "inputHash does not match the submitted transcript.",
        );
      }
      return provider.suggest(body);
    },
  );

  return app;
}

/**
 * Canonical form for `inputHash`: a JSON array of `[startUs, endUs, text, speaker]`
 * tuples in submission order. Documented here because a client has to reproduce
 * it byte for byte; verification stays opt-in until one does.
 */
export function canonicalTranscriptHash(transcript: TranscriptSegment[]): string {
  const canonical = JSON.stringify(
    transcript.map((segment) => [segment.startUs, segment.endUs, segment.text, segment.speaker ?? null]),
  );
  return `sha256:${createHash("sha256").update(canonical, "utf8").digest("hex")}`;
}

function matchesBearerToken(header: string | undefined, expected: string): boolean {
  if (typeof header !== "string") return false;
  const presented = Buffer.from(header, "utf8");
  const candidate = Buffer.from(`Bearer ${expected}`, "utf8");
  // Compare a fixed-width digest so the comparison does not leak the token
  // length, which `timingSafeEqual` would reject outright anyway.
  return timingSafeEqual(
    createHash("sha256").update(presented).digest(),
    createHash("sha256").update(candidate).digest(),
  );
}

function createRateLimiter(limit: number, windowMs: number) {
  const windows = new Map<string, { count: number; resetAt: number }>();
  return (key: string, now: number): boolean => {
    for (const [existing, window] of windows) {
      if (window.resetAt <= now) windows.delete(existing);
    }
    const window = windows.get(key);
    if (!window || window.resetAt <= now) {
      windows.set(key, { count: 1, resetAt: now + windowMs });
      return true;
    }
    window.count += 1;
    return window.count <= limit;
  };
}

function routePath(request: FastifyRequest): string {
  const index = request.url.indexOf("?");
  return index === -1 ? request.url : request.url.slice(0, index);
}

function problem(
  reply: FastifyReply,
  status: number,
  type: string,
  title: string,
  request: FastifyRequest,
  detail?: string,
) {
  return reply
    .code(status)
    .type("application/problem+json")
    .send({ type, title, status, ...(detail ? { detail } : {}), requestId: request.id });
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : undefined;
if (invokedPath === import.meta.url) {
  const authToken = process.env.GATEWAY_AUTH_TOKEN;
  if (!authToken) {
    // Fail closed. This service exists to gate consented transcripts; starting
    // it wide open because an environment variable is missing is the one
    // failure mode it must not have.
    console.error("GATEWAY_AUTH_TOKEN is required. Refusing to start an unauthenticated gateway.");
    process.exit(1);
  }

  const app = buildServer({
    authToken,
    logger: true,
    verifyInputHash: process.env.GATEWAY_VERIFY_INPUT_HASH === "1",
    allowedOrigins: (process.env.ALLOWED_ORIGINS ?? "")
      .split(",")
      .map((origin) => origin.trim())
      .filter(Boolean),
  });

  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.once(signal, () => {
      app.close().then(
        () => process.exit(0),
        () => process.exit(1),
      );
    });
  }

  await app.listen({ port: Number(process.env.PORT ?? 8787), host: "127.0.0.1" });
}
