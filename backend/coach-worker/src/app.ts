import { jsonByteLength } from "./context";
import {
  backupDownloadResponseSchema,
  backupReconcileRequestSchema,
  backupReconcileResponseSchema,
  backupUploadRequestSchema,
  backupUploadResponseSchema,
  chatRequestSchema,
  coachPreferencesUpdateRequestSchema,
  coachPreferencesUpdateResponseSchema,
  profileInsightsRequestSchema,
  snapshotSyncRequestSchema,
  snapshotSyncResponseSchema,
  stateDeleteRequestSchema,
  type CoachProfileInsightsResponse,
} from "./schemas";
import {
  CoachInferenceServiceError,
  DEFAULT_AI_MODEL,
  createWorkersAICoachService,
  type CoachInferenceService,
  type Env,
} from "./openai";
import {
  CloudflareCoachStateRepository,
  MissingCoachContextError,
  MissingRemoteBackupError,
  StaleRemoteStateError,
  normalizeChatTurns,
  type CoachD1Database,
  type CoachKVNamespace,
  type CoachR2Bucket,
  type CoachStateStore,
} from "./state";

interface AppDependencies {
  createInferenceService: (env: Env) => CoachInferenceService;
  createStateRepository: (env: Env) => CoachStateStore;
  now: () => number;
  requestId: () => string;
}

export function createApp(
  overrides: Partial<AppDependencies> = {}
): { fetch: (request: Request, env: Env) => Promise<Response> } {
  const deps: AppDependencies = {
    createInferenceService: createWorkersAICoachService,
    createStateRepository: (env) =>
      new CloudflareCoachStateRepository(
        mustGetStateKV(env),
        mustGetBackupsR2(env),
        mustGetMetaDB(env),
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
      let routeDiagnostics: Record<string, unknown> | undefined;

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

        if (pathname === "/v1/backup/reconcile" && request.method === "POST") {
          const body = backupReconcileRequestSchema.parse(await readJSON(request));
          const response = backupReconcileResponseSchema.parse(
            await stateRepository.reconcileBackup(body)
          );

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            reconcileAction: response.action,
            installID: body.installID,
          });
          return json(response, 200);
        }

        if (pathname === "/v1/backup" && request.method === "PUT") {
          const body = backupUploadRequestSchema.parse(await readJSON(request));
          const response = backupUploadResponseSchema.parse(
            await stateRepository.uploadBackup(body)
          );

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            installID: body.installID,
            backupVersion: response.backupVersion,
            backupBytes: jsonByteLength(body.snapshot),
          });
          return json(response, 200);
        }

        if (pathname === "/v1/backup/download" && request.method === "GET") {
          const input = parseBackupDownloadRequest(request);
          const response = backupDownloadResponseSchema.parse(
            await stateRepository.downloadBackup(input)
          );

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            installID: input.installID,
            backupVersion: response.remote.backupVersion,
          });
          return json(response, 200);
        }

        if (pathname === "/v1/coach/preferences" && request.method === "PATCH") {
          const body = coachPreferencesUpdateRequestSchema.parse(
            await readJSON(request)
          );
          const response = coachPreferencesUpdateResponseSchema.parse(
            await stateRepository.updateCoachPreferences(body)
          );

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            installID: body.installID,
            coachStateVersion: response.coachStateVersion,
          });
          return json(response, 200);
        }

        if (pathname === "/v1/coach/snapshot" && request.method === "PUT") {
          const body = snapshotSyncRequestSchema.parse(await readJSON(request));
          const response = snapshotSyncResponseSchema.parse(
            await stateRepository.storeLegacySnapshot(body)
          );

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            installID: body.installID,
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
            installID: body.installID,
          });
          return json({}, 200);
        }

        if (pathname === "/v1/coach/profile-insights" && request.method === "POST") {
          const body = profileInsightsRequestSchema.parse(await readJSON(request));
          const context = await stateRepository.resolveCoachContext(body);
          const snapshotBytes = jsonByteLength(context.snapshot);
          const programCommentChars =
            context.snapshot.coachAnalysisSettings.programComment.trim().length;
          const recentPrCount =
            context.snapshot.analytics.recentPersonalRecords.length;
          const relativeStrengthCount =
            context.snapshot.analytics.relativeStrength.length;
          const preferredProgramWorkoutCount =
            context.snapshot.preferredProgram?.workouts.length ?? 0;
          routeDiagnostics = {
            installID: body.installID,
            contextSource: context.source,
            profileContextVariant: "compact_profile_v1",
            snapshotBytes,
            programCommentChars,
            recentPrCount,
            relativeStrengthCount,
            preferredProgramWorkoutCount,
          };
          const cachedResponse = context.cacheAllowed
            ? await stateRepository.getInsightsCache(
                body.installID,
                context.contextHash
              )
            : null;
          const reusableCachedResponse = isReusableProfileInsightsCacheEntry(
            cachedResponse
          );

          if (reusableCachedResponse) {
            logRequest({
              requestID,
              route: pathname,
              method: request.method,
              status: 200,
              durationMs: deps.now() - startedAt,
              installID: body.installID,
              contextSource: context.source,
              profileContextVariant: "compact_profile_v1",
              insightsCacheHit: true,
              snapshotBytes,
              programCommentChars,
              recentPrCount,
              relativeStrengthCount,
              preferredProgramWorkoutCount,
            });
            return json(reusableCachedResponse, 200);
          }

          const inferenceStartedAt = deps.now();
          const result = await inferenceService.generateProfileInsights({
            ...body,
            snapshotHash: context.contextHash,
            snapshot: context.snapshot,
            snapshotUpdatedAt:
              context.backupHead?.uploadedAt ?? body.snapshotUpdatedAt,
          });
          const modelDurationMs = deps.now() - inferenceStartedAt;

          if (
            context.cacheAllowed &&
            result.data.generationStatus === "model"
          ) {
            await stateRepository.storeInsightsCache(
              body.installID,
              context.contextHash,
              result.data
            );
          }

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            installID: body.installID,
            model: result.model,
            responseID: result.responseId,
            usage: result.usage,
            inferenceMode: result.mode,
            contextSource: context.source,
            insightsCacheHit: false,
            snapshotBytes,
            programCommentChars,
            recentPrCount,
            relativeStrengthCount,
            preferredProgramWorkoutCount,
            promptBytes: result.promptBytes,
            modelDurationMs,
          });
          return json(result.data, 200);
        }

        if (pathname === "/v1/coach/chat" && request.method === "POST") {
          const body = chatRequestSchema.parse(await readJSON(request));
          const context = await stateRepository.resolveCoachContext(body);
          const storedMemory = context.cacheAllowed
            ? await stateRepository.getChatMemory(body.installID, context.contextHash)
            : null;
          const recentTurns = normalizeChatTurns(
            storedMemory?.recentTurns?.length
              ? storedMemory.recentTurns
              : body.clientRecentTurns
          );
          const chatMemoryHit = Boolean(storedMemory?.recentTurns?.length);
          const snapshotBytes = jsonByteLength(context.snapshot);
          const recentTurnCount = recentTurns.length;
          const recentTurnChars = totalChatTurnChars(recentTurns);
          const questionChars = body.question.trim().length;
          routeDiagnostics = {
            installID: body.installID,
            contextSource: context.source,
            chatMemoryHit,
            snapshotBytes,
            recentTurnCount,
            recentTurnChars,
            questionChars,
          };

          const inferenceStartedAt = deps.now();
          const result = await inferenceService.generateChat({
            ...body,
            snapshotHash: context.contextHash,
            snapshot: context.snapshot,
            snapshotUpdatedAt:
              context.backupHead?.uploadedAt ?? body.snapshotUpdatedAt,
            clientRecentTurns: recentTurns,
          });
          const modelDurationMs = deps.now() - inferenceStartedAt;

          if (context.cacheAllowed) {
            await stateRepository.appendChatMemory(
              body.installID,
              context.contextHash,
              recentTurns,
              body.question,
              result.data.answerMarkdown
            );
          }

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            installID: body.installID,
            model: result.model,
            responseID: result.responseId,
            usage: result.usage,
            inferenceMode: result.mode,
            contextSource: context.source,
            chatMemoryHit,
            snapshotBytes,
            recentTurnCount,
            recentTurnChars,
            questionChars,
            promptBytes: result.promptBytes,
            modelDurationMs,
          });
          return json(result.data, 200);
        }

        throw new RequestError(404, "not_found", "Route not found");
      } catch (error) {
        const mapped = mapError(error, requestID);
        const rawErrorDetails =
          error instanceof CoachInferenceServiceError
            ? error.details
            : error instanceof RequestError
              ? error.details
              : error instanceof StaleRemoteStateError
                ? { currentRemoteVersion: error.currentRemoteVersion }
                : undefined;
        const errorDetails = mergeErrorDetails(routeDiagnostics, rawErrorDetails);

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
  if (!env.BACKUPS_R2) {
    missing.push("BACKUPS_R2");
  }
  if (!env.APP_META_DB) {
    missing.push("APP_META_DB");
  }
  if (!env.COACH_INTERNAL_TOKEN?.trim()) {
    missing.push("COACH_INTERNAL_TOKEN");
  }
  return missing;
}

function mustGetStateKV(env: Env): CoachKVNamespace {
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

function mustGetBackupsR2(env: Env): CoachR2Bucket {
  const r2 = env.BACKUPS_R2;
  if (!r2) {
    throw new RequestError(
      500,
      "server_misconfigured",
      "Coach backend is not configured.",
      { missing: ["BACKUPS_R2"] }
    );
  }

  return r2;
}

function mustGetMetaDB(env: Env): CoachD1Database {
  const db = env.APP_META_DB;
  if (!db) {
    throw new RequestError(
      500,
      "server_misconfigured",
      "Coach backend is not configured.",
      { missing: ["APP_META_DB"] }
    );
  }

  return db;
}

function assertAuthorization(request: Request, env: Env): void {
  const token = env.COACH_INTERNAL_TOKEN.trim();
  const header = request.headers.get("authorization");
  if (header !== `Bearer ${token}`) {
    throw new RequestError(401, "unauthorized", "Unauthorized.");
  }
}

function parseBackupDownloadRequest(request: Request): {
  installID: string;
  version?: number;
} {
  const url = new URL(request.url);
  const installID = url.searchParams.get("installID")?.trim();
  if (!installID) {
    throw new RequestError(
      400,
      "invalid_request",
      "Request body does not match the coach contract.",
      { field: "installID" }
    );
  }

  const versionParam = url.searchParams.get("version")?.trim();
  if (!versionParam || versionParam === "current") {
    return { installID };
  }

  const version = Number.parseInt(versionParam, 10);
  if (!Number.isFinite(version) || version < 1) {
    throw new RequestError(
      400,
      "invalid_request",
      "Request body does not match the coach contract.",
      { field: "version" }
    );
  }

  return { installID, version };
}

async function readJSON(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    throw new RequestError(400, "invalid_json", "Malformed JSON body.");
  }
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

  if (error instanceof MissingCoachContextError) {
    return {
      status: 409,
      body: {
        error: {
          code: "snapshot_required",
          message: "Coach snapshot sync required.",
          requestID,
        },
      },
    };
  }

  if (error instanceof MissingRemoteBackupError) {
    return {
      status: 404,
      body: {
        error: {
          code: "remote_backup_not_found",
          message: "Remote backup not found.",
          requestID,
        },
      },
    };
  }

  if (error instanceof StaleRemoteStateError) {
    return {
      status: 409,
      body: {
        error: {
          code: "remote_head_changed",
          message: "Remote backup head changed.",
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

function logRequest(payload: Record<string, unknown>) {
  const serialized = JSON.stringify(payload);
  if (
    typeof payload.status === "number" &&
    Number.isFinite(payload.status) &&
    payload.status >= 400
  ) {
    console.error(serialized);
    return;
  }

  console.log(serialized);
}

function mergeErrorDetails(
  routeDiagnostics?: Record<string, unknown>,
  errorDetails?: Record<string, unknown>
): Record<string, unknown> | undefined {
  if (!routeDiagnostics && !errorDetails) {
    return undefined;
  }

  return {
    ...(routeDiagnostics ?? {}),
    ...(errorDetails ?? {}),
  };
}

function totalChatTurnChars(
  turns: Array<{ content: string }>
): number {
  return turns.reduce((total, turn) => total + turn.content.length, 0);
}

function isReusableProfileInsightsCacheEntry(
  response: CoachProfileInsightsResponse | null
): CoachProfileInsightsResponse | null {
  if (!response) {
    return null;
  }

  return response.generationStatus === "model" ? response : null;
}
