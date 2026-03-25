import {
  chatRequestSchema,
  profileInsightsRequestSchema,
  snapshotSyncRequestSchema,
  snapshotSyncResponseSchema,
  stateDeleteRequestSchema,
} from "./schemas";
import {
  CoachInferenceServiceError,
  DEFAULT_AI_MODEL,
  createWorkersAICoachService,
  type CoachInferenceService,
  type Env,
} from "./openai";
import {
  CoachStateRepository,
  jsonByteLength,
  normalizeChatTurns,
  type SnapshotResolution,
} from "./state";

interface AppDependencies {
  createInferenceService: (env: Env) => CoachInferenceService;
  createStateRepository: (env: Env) => CoachStateRepository;
  now: () => number;
  requestId: () => string;
}

export function createApp(
  overrides: Partial<AppDependencies> = {}
): { fetch: (request: Request, env: Env) => Promise<Response> } {
  const deps: AppDependencies = {
    createInferenceService: createWorkersAICoachService,
    createStateRepository: (env) =>
      new CoachStateRepository(
        mustGetStateKV(env),
        env.COACH_PROMPT_VERSION?.trim() || "2026-03-25.v1",
        env.AI_MODEL?.trim() || DEFAULT_AI_MODEL
      ),
    now: () => Date.now(),
    requestId: () => crypto.randomUUID(),
    ...overrides,
  };

  return {
    async fetch(request: Request, env: Env): Promise<Response> {
      const requestID = deps.requestId();
      const startedAt = deps.now();
      const pathname = new URL(request.url).pathname;

      try {
        if (pathname === "/health" && request.method === "GET") {
          const body = buildHealthPayload(env);
          const status = body.status === "ok" ? 200 : 503;
          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status,
            durationMs: deps.now() - startedAt,
          });
          return json(body, status);
        }

        assertRuntimeSecrets(env);
        assertAuthorization(request, env);

        const inferenceService = deps.createInferenceService(env);
        const stateRepository = deps.createStateRepository(env);

        if (pathname === "/v1/coach/snapshot" && request.method === "PUT") {
          const body = snapshotSyncRequestSchema.parse(await readJSON(request));
          const response = snapshotSyncResponseSchema.parse(
            await stateRepository.storeSnapshot(body)
          );

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            snapshotStored: true,
            snapshotBytes: jsonByteLength(body.snapshot),
          });
          return json(response, 200);
        }

        if (pathname === "/v1/coach/state" && request.method === "DELETE") {
          const body = stateDeleteRequestSchema.parse(await readJSON(request));
          await stateRepository.deleteInstallState(body.installID);

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
          });
          return json({}, 200);
        }

        if (pathname === "/v1/coach/profile-insights" && request.method === "POST") {
          const body = profileInsightsRequestSchema.parse(await readJSON(request));
          const snapshotResolution = await stateRepository.resolveSnapshot(body);
          const snapshot = requireSnapshot(snapshotResolution);
          const resolvedSnapshotHash =
            snapshotResolution.acceptedHash ?? body.snapshotHash;

          const cachedResponse = await stateRepository.getInsightsCache(
            body.installID,
            resolvedSnapshotHash
          );
          if (cachedResponse) {
            logRequest({
              requestID,
              route: pathname,
              method: request.method,
              status: 200,
              durationMs: deps.now() - startedAt,
              snapshotHit: snapshotResolution.snapshotHit,
              snapshotStored: snapshotResolution.snapshotStored,
              insightsCacheHit: true,
              snapshotBytes: snapshotResolution.snapshotBytes,
            });
            return json(cachedResponse, 200);
          }

          const inferenceStartedAt = deps.now();
          const result = await inferenceService.generateProfileInsights({
            ...body,
            snapshotHash: resolvedSnapshotHash,
            snapshot,
            snapshotUpdatedAt:
              snapshotResolution.storedAt ?? body.snapshotUpdatedAt,
          });
          const modelDurationMs = deps.now() - inferenceStartedAt;

          await stateRepository.storeInsightsCache(
            body.installID,
            resolvedSnapshotHash,
            result.data
          );

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            model: result.model,
            responseID: result.responseId,
            usage: result.usage,
            snapshotHit: snapshotResolution.snapshotHit,
            snapshotStored: snapshotResolution.snapshotStored,
            insightsCacheHit: false,
            snapshotBytes: snapshotResolution.snapshotBytes,
            promptBytes: result.promptBytes,
            modelDurationMs,
          });
          return json(result.data, 200);
        }

        if (pathname === "/v1/coach/chat" && request.method === "POST") {
          const body = chatRequestSchema.parse(await readJSON(request));
          const snapshotResolution = await stateRepository.resolveSnapshot(body);
          const snapshot = requireSnapshot(snapshotResolution);
          const storedMemory = await stateRepository.getChatMemory(body.installID);
          const recentTurns = normalizeChatTurns(
            storedMemory?.recentTurns?.length
              ? storedMemory.recentTurns
              : body.clientRecentTurns
          );

          const inferenceStartedAt = deps.now();
          const result = await inferenceService.generateChat({
            ...body,
            snapshotHash: snapshotResolution.acceptedHash ?? body.snapshotHash,
            snapshot,
            snapshotUpdatedAt:
              snapshotResolution.storedAt ?? body.snapshotUpdatedAt,
            clientRecentTurns: recentTurns,
          });
          const modelDurationMs = deps.now() - inferenceStartedAt;

          await stateRepository.appendChatMemory(
            body.installID,
            recentTurns,
            body.question,
            result.data.answerMarkdown
          );

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            model: result.model,
            responseID: result.responseId,
            usage: result.usage,
            snapshotHit: snapshotResolution.snapshotHit,
            snapshotStored: snapshotResolution.snapshotStored,
            chatMemoryHit: Boolean(storedMemory?.recentTurns?.length),
            snapshotBytes: snapshotResolution.snapshotBytes,
            promptBytes: result.promptBytes,
            modelDurationMs,
          });
          return json(result.data, 200);
        }

        throw new RequestError(404, "not_found", "Route not found");
      } catch (error) {
        const mapped = mapError(error, requestID);
        const errorDetails =
          error instanceof CoachInferenceServiceError
            ? error.details
            : error instanceof RequestError
              ? error.details
              : undefined;
        logRequest({
          requestID,
          route: pathname,
          method: request.method,
          status: mapped.status,
          durationMs: deps.now() - startedAt,
          errorCode: mapped.body.error.code,
          errorDetails,
        });
        return json(mapped.body, mapped.status);
      }
    },
  };
}

class RequestError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly publicMessage: string,
    readonly details?: Record<string, unknown>
  ) {
    super(publicMessage);
  }
}

function buildHealthPayload(env: Env): {
  status: "ok" | "error";
  model: string;
  promptVersion: string;
  missing?: string[];
} {
  const missing = missingSecrets(env);
  return {
    status: missing.length === 0 ? "ok" : "error",
    model: env.AI_MODEL?.trim() || DEFAULT_AI_MODEL,
    promptVersion: env.COACH_PROMPT_VERSION?.trim() || "2026-03-25.v1",
    ...(missing.length > 0 ? { missing } : {}),
  };
}

function assertRuntimeSecrets(env: Env): void {
  const missing = missingSecrets(env);
  if (missing.length > 0) {
    throw new RequestError(
      500,
      "server_misconfigured",
      "Coach backend is not configured.",
      { missing }
    );
  }
}

function missingSecrets(env: Env): string[] {
  const missing: string[] = [];
  if (!env.AI) {
    missing.push("AI");
  }
  if (!env.COACH_STATE_KV) {
    missing.push("COACH_STATE_KV");
  }
  if (!env.COACH_INTERNAL_TOKEN?.trim()) {
    missing.push("COACH_INTERNAL_TOKEN");
  }
  return missing;
}

function mustGetStateKV(env: Env) {
  const stateKV = env.COACH_STATE_KV;
  if (!stateKV) {
    throw new RequestError(
      500,
      "server_misconfigured",
      "Coach backend is not configured.",
      { missing: ["COACH_STATE_KV"] }
    );
  }

  return stateKV;
}

function assertAuthorization(request: Request, env: Env): void {
  const token = env.COACH_INTERNAL_TOKEN.trim();
  const header = request.headers.get("authorization");
  if (header !== `Bearer ${token}`) {
    throw new RequestError(401, "unauthorized", "Unauthorized.");
  }
}

async function readJSON(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    throw new RequestError(400, "invalid_json", "Malformed JSON body.");
  }
}

function requireSnapshot(resolution: SnapshotResolution) {
  if (!resolution.snapshot) {
    throw new RequestError(
      409,
      "snapshot_required",
      "Coach snapshot sync required."
    );
  }

  return resolution.snapshot;
}

function mapError(
  error: unknown,
  requestID: string
): {
  status: number;
  body: { error: { code: string; message: string; requestID: string } };
} {
  if (error instanceof RequestError) {
    return {
      status: error.status,
      body: {
        error: {
          code: error.code,
          message: error.publicMessage,
          requestID,
        },
      },
    };
  }

  if (error instanceof CoachInferenceServiceError) {
    return {
      status: error.status,
      body: {
        error: {
          code: error.code,
          message: "Coach upstream request failed.",
          requestID,
        },
      },
    };
  }

  if (isZodLikeError(error)) {
    return {
      status: 400,
      body: {
        error: {
          code: "invalid_request",
          message: "Request body does not match the coach contract.",
          requestID,
        },
      },
    };
  }

  return {
    status: 500,
    body: {
      error: {
        code: "internal_error",
        message: "Internal server error.",
        requestID,
      },
    },
  };
}

function isZodLikeError(error: unknown): error is { name: string } {
  return (
    typeof error === "object" &&
    error !== null &&
    "name" in error &&
    (error as { name: string }).name === "ZodError"
  );
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function logRequest(payload: {
  requestID: string;
  route: string;
  method: string;
  status: number;
  durationMs: number;
  model?: string;
  responseID?: string;
  usage?: unknown;
  errorCode?: string;
  errorDetails?: unknown;
  snapshotHit?: boolean;
  snapshotStored?: boolean;
  insightsCacheHit?: boolean;
  chatMemoryHit?: boolean;
  snapshotBytes?: number;
  promptBytes?: number;
  modelDurationMs?: number;
}) {
  const serialized = JSON.stringify(payload);
  if (payload.status >= 400) {
    console.error(serialized);
    return;
  }

  console.log(serialized);
}
