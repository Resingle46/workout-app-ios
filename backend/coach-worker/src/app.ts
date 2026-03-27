import { jsonByteLength, type CoachExecutionMetadata } from "./context";
import {
  backupDownloadResponseSchema,
  backupReconcileRequestSchema,
  backupReconcileResponseSchema,
  backupUploadRequestSchema,
  backupUploadResponseSchema,
  chatJobCreateRequestSchema,
  chatJobCreateResponseSchema,
  chatJobStatusResponseSchema,
  chatRequestSchema,
  coachPreferencesUpdateRequestSchema,
  coachPreferencesUpdateResponseSchema,
  profileInsightsRequestSchema,
  snapshotSyncRequestSchema,
  snapshotSyncResponseSchema,
  stateDeleteRequestSchema,
  workoutSummaryJobCreateRequestSchema,
  workoutSummaryJobCreateResponseSchema,
  workoutSummaryJobStatusResponseSchema,
  type CoachConversationTurn,
  type CoachProfileInsightsResponse,
} from "./schemas";
import {
  CoachInferenceServiceError,
  buildOpaqueResponseID,
  createWorkersAICoachService,
  type CoachInferenceService,
  type Env,
} from "./openai";
import {
  DEFAULT_AI_MODEL,
  buildChatRoutingDecision,
  buildProfileInsightsRoutingDecision,
  buildWorkoutSummaryRoutingDecision,
  isModelRoutingEnabled,
  resolveModelForRole,
  resolveModelRoutingVersion,
  resolvePrimaryChatExecutionProfile,
} from "./routing";
import {
  ActiveCoachChatJobError,
  CloudflareCoachStateRepository,
  MissingCoachContextError,
  MissingRemoteBackupError,
  StaleRemoteStateError,
  normalizeChatTurns,
  storageKeyFromMetadata,
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

const CHAT_JOB_INITIAL_POLL_AFTER_MS = 1_500;
const ASYNC_CHAT_JOB_TTL_MS = 20 * 60 * 1_000;
const ASYNC_WORKOUT_SUMMARY_JOB_TTL_MS = 10 * 60 * 1_000;

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
      let validationRequestPreview: Record<string, unknown> | undefined;

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
          const rawBody = await readJSON(request);
          const normalized = normalizeBackupUploadPayload(rawBody);
          routeDiagnostics = buildBackupUploadDiagnostics(
            normalized.body,
            normalized.migratedLegacyCategoryIDs
          );
          const body = backupUploadRequestSchema.parse(normalized.body);
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
          const contextResolveStartedAt = deps.now();
          const context = await stateRepository.resolveCoachContext(body);
          const contextResolveMs = deps.now() - contextResolveStartedAt;
          const routingDecision = buildProfileInsightsRoutingDecision(env, {
            ...body,
            snapshotHash: context.contextHash,
            snapshot: context.snapshot,
            snapshotUpdatedAt:
              context.backupHead?.uploadedAt ?? body.snapshotUpdatedAt,
          });
          const executionMetadata = buildExecutionMetadata({
            contextProfile: "compact_sync_v2",
            promptProfile: "profile_compact_context_v2",
            contextVersion: context.contextVersion,
            analyticsVersion: context.analyticsVersion,
            memoryProfile: "compact_v1",
            derivedAnalytics: context.derivedAnalytics,
            useCase: routingDecision.useCase,
            modelRole: routingDecision.modelRole,
            selectedModel: routingDecision.selectedModel,
            allowedContextProfiles: routingDecision.allowedContextProfiles,
            payloadTier: routingDecision.payloadTier,
            routingVersion: routingDecision.routingVersion,
            memoryCompatibilityKey: routingDecision.memoryCompatibilityKey,
            promptFamily: routingDecision.promptFamily,
            contextFamily: routingDecision.contextFamily,
            routingReasonTags: routingDecision.routingReasonTags,
          });
          const storageKey = storageKeyFromMetadata(
            context.contextHash,
            executionMetadata,
            resolvePromptVersion(env),
            routingDecision.selectedModel
          );
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
            profileContextVariant: executionMetadata.promptProfile,
            useCase: routingDecision.useCase,
            modelRole: routingDecision.modelRole,
            selectedModel: routingDecision.selectedModel,
            routingVersion: routingDecision.routingVersion,
            routingReasonTags: routingDecision.routingReasonTags,
            forceRefresh: body.forceRefresh,
            snapshotBytes,
            programCommentChars,
            recentPrCount,
            relativeStrengthCount,
            preferredProgramWorkoutCount,
          };
          const cacheLookupStartedAt = deps.now();
          const cachedResponse = !body.forceRefresh && context.cacheAllowed
            ? await stateRepository.getInsightsCache(
                body.installID,
                storageKey
              )
            : null;
          const cacheLookupMs = deps.now() - cacheLookupStartedAt;
          const reusableCachedResponse = normalizeReusableProfileInsightsCacheEntry(
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
              profileContextVariant: executionMetadata.promptProfile,
              forceRefresh: body.forceRefresh,
              insightsCacheHit: true,
              cacheLookupMs,
              contextResolveMs,
              insightSource: reusableCachedResponse.insightSource,
              modelInferenceExecuted: false,
              useCase: routingDecision.useCase,
              modelRole: routingDecision.modelRole,
              selectedModel: routingDecision.selectedModel,
              routingVersion: routingDecision.routingVersion,
              routingReasonTags: routingDecision.routingReasonTags,
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
          }, {
            contextProfile: executionMetadata.contextProfile,
            promptProfile: executionMetadata.promptProfile,
            derivedAnalytics: executionMetadata.derivedAnalytics,
          });
          const modelDurationMs = deps.now() - inferenceStartedAt;
          const cacheStoreStartedAt = deps.now();
          let cacheStoreMs = 0;
          const cacheMissReason = resolveInsightsCacheMissReason(
            body.forceRefresh,
            context.cacheAllowed
          );

          if (
            context.cacheAllowed &&
            result.data.generationStatus === "model"
          ) {
            await stateRepository.storeInsightsCache(
              body.installID,
              storageKey,
              result.data
            );
          }
          cacheStoreMs = deps.now() - cacheStoreStartedAt;

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            installID: body.installID,
            model: result.model,
            useCase: result.useCase ?? routingDecision.useCase,
            modelRole: result.modelRole ?? routingDecision.modelRole,
            selectedModel: result.selectedModel ?? routingDecision.selectedModel,
            routingVersion:
              result.routingVersion ?? routingDecision.routingVersion,
            routingReasonTags:
              result.routingReasonTags ?? routingDecision.routingReasonTags,
            fallbackHopCount: result.fallbackHopCount,
            fallbackReason: result.fallbackReason,
            responseID: result.responseId,
            usage: result.usage,
            inferenceMode: result.mode,
            contextSource: context.source,
            forceRefresh: body.forceRefresh,
            insightsCacheHit: false,
            cacheMissReason,
            cacheLookupMs,
            cacheStoreMs,
            contextResolveMs,
            insightSource: result.data.insightSource,
            modelInferenceExecuted: true,
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

        if (pathname === "/v2/coach/chat-jobs" && request.method === "POST") {
          const rawBody = await readJSON(request);
          validationRequestPreview = buildChatRequestPreview(rawBody);
          const body = chatJobCreateRequestSchema.parse(rawBody);
          validationRequestPreview = undefined;
          const context = await stateRepository.resolveCoachContext(body);
          const routingDecision = buildChatRoutingDecision(
            env,
            {
              ...body,
              snapshotHash: context.contextHash,
              snapshot: context.snapshot,
              snapshotUpdatedAt:
                context.backupHead?.uploadedAt ?? body.snapshotUpdatedAt,
            },
            { timeoutProfile: "async_job" }
          );
          const primaryChatExecution = resolvePrimaryChatExecutionProfile(
            routingDecision
          );
          const executionMetadata = buildExecutionMetadata({
            contextProfile: primaryChatExecution.contextProfile,
            promptProfile: primaryChatExecution.promptProfile,
            contextVersion: context.contextVersion,
            analyticsVersion: context.analyticsVersion,
            memoryProfile: "rich_async_v1",
            jobDeadlineAt: new Date(deps.now() + ASYNC_CHAT_JOB_TTL_MS).toISOString(),
            derivedAnalytics: context.derivedAnalytics,
            useCase: routingDecision.useCase,
            modelRole: routingDecision.modelRole,
            selectedModel: routingDecision.selectedModel,
            allowedContextProfiles: routingDecision.allowedContextProfiles,
            payloadTier: routingDecision.payloadTier,
            routingVersion: routingDecision.routingVersion,
            memoryCompatibilityKey: routingDecision.memoryCompatibilityKey,
            promptFamily: routingDecision.promptFamily,
            contextFamily: routingDecision.contextFamily,
            routingReasonTags: routingDecision.routingReasonTags,
          });
          const storageKey = storageKeyFromMetadata(
            context.contextHash,
            executionMetadata,
            resolvePromptVersion(env),
            routingDecision.selectedModel
          );
          const storedMemory = context.cacheAllowed
            ? await stateRepository.getChatMemory(body.installID, storageKey)
            : null;
          const recentTurns = mergeRecentTurns(
            storedMemory?.recentTurns ?? [],
            body.clientRecentTurns
          );
          const chatMemoryHit = Boolean(storedMemory?.recentTurns?.length);
          const snapshotBytes = jsonByteLength(context.snapshot);
          const recentTurnCount = recentTurns.length;
          const recentTurnChars = totalChatTurnChars(recentTurns);
          const questionChars = body.question.trim().length;
          const createdAt = new Date(deps.now()).toISOString();
          const jobID = buildChatJobID();
          const responseID = buildOpaqueResponseID();

          routeDiagnostics = {
            installID: body.installID,
            contextSource: context.source,
            chatMemoryHit,
            snapshotBytes,
            recentTurnCount,
            recentTurnChars,
            questionChars,
            clientRequestID: body.clientRequestID,
            useCase: routingDecision.useCase,
            modelRole: routingDecision.modelRole,
            selectedModel: routingDecision.selectedModel,
            routingVersion: routingDecision.routingVersion,
            routingReasonTags: routingDecision.routingReasonTags,
          };

          const job = await stateRepository.createChatJob({
            jobID,
            installID: body.installID,
            clientRequestID: body.clientRequestID,
            createdAt,
            model: routingDecision.selectedModel,
            preparedRequest: {
              ...body,
              snapshotHash: context.contextHash,
              snapshot: context.snapshot,
              snapshotUpdatedAt:
                context.backupHead?.uploadedAt ?? body.snapshotUpdatedAt,
              clientRecentTurns: recentTurns,
              responseID,
              metadata: executionMetadata,
            },
            contextHash: context.contextHash,
            contextSource: context.source,
            chatMemoryHit,
            snapshotBytes,
            recentTurnCount,
            recentTurnChars,
            questionChars,
          });

          if (job.jobID === jobID) {
            try {
              const chatWorkflow = mustGetChatWorkflow(env);
              await chatWorkflow.create({
                id: job.jobID,
                params: { jobID: job.jobID },
              });
            } catch (error) {
              const failedAt = new Date(deps.now()).toISOString();
              try {
                await stateRepository.failChatJob(job.jobID, {
                  completedAt: failedAt,
                  error: {
                    code: "workflow_start_failed",
                    message: "Chat workflow failed to start.",
                    retryable: true,
                  },
                  totalJobDurationMs: Math.max(
                    deps.now() - Date.parse(job.createdAt),
                    0
                  ),
                });
              } catch (persistError) {
                console.error(
                  JSON.stringify({
                    event: "terminal_state_persist_failed",
                    phase: "persist_failure",
                    route: pathname,
                    jobID: job.jobID,
                    installID: job.installID,
                    clientRequestID: job.clientRequestID,
                    errorCode: "workflow_start_failed",
                    persistErrorMessage:
                      persistError instanceof Error
                        ? persistError.message.slice(0, 200)
                        : "Unknown persistence error",
                  })
                );
              }
              throw new RequestError(
                500,
                "workflow_start_failed",
                "Coach backend is not configured.",
                {
                  ...routeDiagnostics,
                  providerMessage:
                    error instanceof Error
                      ? error.message.slice(0, 200)
                      : "Unknown workflow start error",
                }
              );
            }
          }

          const response = chatJobCreateResponseSchema.parse({
            jobID: job.jobID,
            status: job.status,
            createdAt: job.createdAt,
            pollAfterMs: CHAT_JOB_INITIAL_POLL_AFTER_MS,
            metadata: publicJobMetadata(job.preparedRequest.metadata),
          });

          console.log(
            JSON.stringify({
              event: "coach_chat_job_created",
              requestID,
              jobID: job.jobID,
              installID: job.installID,
              clientRequestID: job.clientRequestID,
              contextHash: job.contextHash,
              contextSource: job.contextSource,
              chatMemoryHit: job.chatMemoryHit,
              snapshotBytes: job.snapshotBytes,
              recentTurnCount: job.recentTurnCount,
              recentTurnChars: job.recentTurnChars,
              questionChars: job.questionChars,
              promptVersion: job.promptVersion,
              model: job.model,
              useCase: job.preparedRequest.metadata?.useCase,
              modelRole: job.preparedRequest.metadata?.modelRole,
              selectedModel: job.preparedRequest.metadata?.selectedModel,
              routingVersion: job.preparedRequest.metadata?.routingVersion,
            })
          );

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 202,
            durationMs: deps.now() - startedAt,
            jobID: job.jobID,
            installID: body.installID,
            contextSource: context.source,
            chatMemoryHit,
            snapshotBytes,
            recentTurnCount,
            recentTurnChars,
            questionChars,
            useCase: routingDecision.useCase,
            modelRole: routingDecision.modelRole,
            selectedModel: routingDecision.selectedModel,
            routingVersion: routingDecision.routingVersion,
          });
          return json(response, 202);
        }

        if (pathname === "/v1/coach/chat" && request.method === "POST") {
          const rawBody = await readJSON(request);
          validationRequestPreview = buildChatRequestPreview(rawBody);
          const body = chatRequestSchema.parse(rawBody);
          validationRequestPreview = undefined;
          const context = await stateRepository.resolveCoachContext(body);
          const routingDecision = buildChatRoutingDecision(
            env,
            {
              ...body,
              snapshotHash: context.contextHash,
              snapshot: context.snapshot,
              snapshotUpdatedAt:
                context.backupHead?.uploadedAt ?? body.snapshotUpdatedAt,
            },
            { timeoutProfile: "sync" }
          );
          const executionMetadata = buildExecutionMetadata({
            contextProfile: "compact_sync_v2",
            promptProfile: "chat_compact_sync_v2",
            contextVersion: context.contextVersion,
            analyticsVersion: context.analyticsVersion,
            memoryProfile: "compact_v1",
            derivedAnalytics: context.derivedAnalytics,
            useCase: routingDecision.useCase,
            modelRole: routingDecision.modelRole,
            selectedModel: routingDecision.selectedModel,
            allowedContextProfiles: routingDecision.allowedContextProfiles,
            payloadTier: routingDecision.payloadTier,
            routingVersion: routingDecision.routingVersion,
            memoryCompatibilityKey: routingDecision.memoryCompatibilityKey,
            promptFamily: routingDecision.promptFamily,
            contextFamily: routingDecision.contextFamily,
            routingReasonTags: routingDecision.routingReasonTags,
          });
          const storageKey = storageKeyFromMetadata(
            context.contextHash,
            executionMetadata,
            resolvePromptVersion(env),
            routingDecision.selectedModel
          );
          const storedMemory = context.cacheAllowed
            ? await stateRepository.getChatMemory(body.installID, storageKey)
            : null;
          const recentTurns = mergeRecentTurns(
            storedMemory?.recentTurns ?? [],
            body.clientRecentTurns
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
            useCase: routingDecision.useCase,
            modelRole: routingDecision.modelRole,
            selectedModel: routingDecision.selectedModel,
            routingVersion: routingDecision.routingVersion,
            routingReasonTags: routingDecision.routingReasonTags,
          };

          const inferenceStartedAt = deps.now();
          const result = await inferenceService.generateChat({
            ...body,
            snapshotHash: context.contextHash,
            snapshot: context.snapshot,
            snapshotUpdatedAt:
              context.backupHead?.uploadedAt ?? body.snapshotUpdatedAt,
            clientRecentTurns: recentTurns,
          }, {
            contextProfile: executionMetadata.contextProfile,
            promptProfile: executionMetadata.promptProfile,
            derivedAnalytics: executionMetadata.derivedAnalytics,
          });
          const modelDurationMs = deps.now() - inferenceStartedAt;

          if (context.cacheAllowed) {
            await stateRepository.appendChatMemory(
              body.installID,
              storageKey,
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
            useCase: result.useCase ?? routingDecision.useCase,
            modelRole: result.modelRole ?? routingDecision.modelRole,
            selectedModel: result.selectedModel ?? routingDecision.selectedModel,
            routingVersion:
              result.routingVersion ?? routingDecision.routingVersion,
            routingReasonTags:
              result.routingReasonTags ?? routingDecision.routingReasonTags,
            fallbackHopCount: result.fallbackHopCount,
            fallbackReason: result.fallbackReason,
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

        if (pathname === "/v2/coach/workout-summary-jobs" && request.method === "POST") {
          const body = workoutSummaryJobCreateRequestSchema.parse(
            await readJSON(request)
          );
          const routingDecision = buildWorkoutSummaryRoutingDecision(env, body);
          const executionMetadata = buildExecutionMetadata({
            contextProfile: "rich_async_v1",
            promptProfile: "workout_summary_rich_async_v1",
            contextVersion: "2026-03-27.context.v1",
            analyticsVersion: "2026-03-27.analytics.v1",
            memoryProfile: "rich_async_v1",
            jobDeadlineAt: new Date(
              deps.now() + ASYNC_WORKOUT_SUMMARY_JOB_TTL_MS
            ).toISOString(),
            useCase: routingDecision.useCase,
            modelRole: routingDecision.modelRole,
            selectedModel: routingDecision.selectedModel,
            allowedContextProfiles: routingDecision.allowedContextProfiles,
            payloadTier: routingDecision.payloadTier,
            routingVersion: routingDecision.routingVersion,
            promptFamily: routingDecision.promptFamily,
            contextFamily: routingDecision.contextFamily,
            routingReasonTags: routingDecision.routingReasonTags,
          });
          const currentExerciseCount = body.currentWorkout.exerciseCount;
          const historyExerciseCount = body.recentExerciseHistory.length;
          const historySessionCount = totalWorkoutSummaryHistorySessionCount(
            body.recentExerciseHistory
          );
          const createdAt = new Date(deps.now()).toISOString();
          const jobID = buildWorkoutSummaryJobID();

          routeDiagnostics = {
            installID: body.installID,
            sessionID: body.sessionID,
            fingerprint: body.fingerprint,
            requestMode: body.requestMode,
            trigger: body.trigger,
            inputMode: body.inputMode,
            currentExerciseCount,
            historyExerciseCount,
            historySessionCount,
            useCase: routingDecision.useCase,
            modelRole: routingDecision.modelRole,
            selectedModel: routingDecision.selectedModel,
            routingVersion: routingDecision.routingVersion,
          };

          const job = await stateRepository.createWorkoutSummaryJob({
            jobID,
            installID: body.installID,
            clientRequestID: body.clientRequestID,
            sessionID: body.sessionID,
            fingerprint: body.fingerprint,
            createdAt,
            model: routingDecision.selectedModel,
            preparedRequest: {
              ...body,
              metadata: executionMetadata,
            },
            requestMode: body.requestMode,
            trigger: body.trigger,
            inputMode: body.inputMode,
            currentExerciseCount,
            historyExerciseCount,
            historySessionCount,
          });
          const reusedExistingJob = job.jobID !== jobID;

          if (!reusedExistingJob) {
            try {
              const workflow = mustGetWorkoutSummaryWorkflow(env);
              await workflow.create({
                id: job.jobID,
                params: { jobID: job.jobID },
              });
            } catch (error) {
              const failedAt = new Date(deps.now()).toISOString();
              await stateRepository.failWorkoutSummaryJob(job.jobID, {
                completedAt: failedAt,
                error: {
                  code: "workflow_start_failed",
                  message: "Workout summary workflow failed to start.",
                  retryable: true,
                },
                totalJobDurationMs: Math.max(
                  deps.now() - Date.parse(job.createdAt),
                  0
                ),
              });
              throw new RequestError(
                500,
                "workflow_start_failed",
                "Coach backend is not configured.",
                {
                  ...routeDiagnostics,
                  providerMessage:
                    error instanceof Error
                      ? error.message.slice(0, 200)
                      : "Unknown workflow start error",
                }
              );
            }
          }

          const response = workoutSummaryJobCreateResponseSchema.parse({
            jobID: job.jobID,
            sessionID: job.sessionID,
            fingerprint: job.fingerprint,
            status: job.status,
            createdAt: job.createdAt,
            pollAfterMs: isTerminalJobStatus(job.status)
              ? 0
              : CHAT_JOB_INITIAL_POLL_AFTER_MS,
            reusedExistingJob,
            metadata: publicJobMetadata(job.preparedRequest.metadata),
          });

          console.log(
            JSON.stringify({
              event: "workout_summary_job_created",
              requestID,
              jobID: job.jobID,
              installID: job.installID,
              sessionID: job.sessionID,
              fingerprint: job.fingerprint,
              requestMode: job.requestMode,
              trigger: job.trigger,
              inputMode: job.inputMode,
              currentExerciseCount: job.currentExerciseCount,
              historyExerciseCount: job.historyExerciseCount,
              historySessionCount: job.historySessionCount,
              promptVersion: job.promptVersion,
              model: job.model,
              useCase: job.preparedRequest.metadata?.useCase,
              modelRole: job.preparedRequest.metadata?.modelRole,
              selectedModel: job.preparedRequest.metadata?.selectedModel,
              routingVersion: job.preparedRequest.metadata?.routingVersion,
              reusedExistingJob,
            })
          );

          const statusCode = isTerminalJobStatus(job.status) ? 200 : 202;

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: statusCode,
            durationMs: deps.now() - startedAt,
            jobID: job.jobID,
            installID: body.installID,
            sessionID: body.sessionID,
            fingerprint: body.fingerprint,
            requestMode: body.requestMode,
            trigger: body.trigger,
            inputMode: body.inputMode,
            currentExerciseCount,
            historyExerciseCount,
            historySessionCount,
            useCase: routingDecision.useCase,
            modelRole: routingDecision.modelRole,
            selectedModel: routingDecision.selectedModel,
            routingVersion: routingDecision.routingVersion,
            reusedExistingJob,
          });
          return json(response, statusCode);
        }

        const chatJobPath = parseChatJobPath(pathname);
        if (chatJobPath && request.method === "GET") {
          const installID = parseInstallIDQuery(request);
          const job = await stateRepository.getChatJob(chatJobPath.jobID, installID);
          if (!job) {
            throw new RequestError(404, "chat_job_not_found", "Chat job not found.");
          }

          const response = chatJobStatusResponseSchema.parse({
            jobID: job.jobID,
            status: job.status,
            createdAt: job.createdAt,
            startedAt: job.startedAt,
            completedAt: job.completedAt,
            result: job.result,
            error: job.error,
            metadata: publicJobMetadata(job.preparedRequest.metadata),
          });

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            jobID: job.jobID,
            installID: job.installID,
            contextSource: job.contextSource,
            chatMemoryHit: job.chatMemoryHit,
            snapshotBytes: job.snapshotBytes,
            recentTurnCount: job.recentTurnCount,
            recentTurnChars: job.recentTurnChars,
            questionChars: job.questionChars,
            inferenceMode: job.inferenceMode,
            promptBytes: job.promptBytes,
            modelDurationMs: job.modelDurationMs,
            totalJobDurationMs: job.totalJobDurationMs,
          });
          return json(response, 200);
        }

        const workoutSummaryJobPath = parseWorkoutSummaryJobPath(pathname);
        if (workoutSummaryJobPath && request.method === "GET") {
          const installID = parseInstallIDQuery(request);
          const job = await stateRepository.getWorkoutSummaryJob(
            workoutSummaryJobPath.jobID,
            installID
          );
          if (!job) {
            throw new RequestError(
              404,
              "workout_summary_job_not_found",
              "Workout summary job not found."
            );
          }

          const response = workoutSummaryJobStatusResponseSchema.parse({
            jobID: job.jobID,
            sessionID: job.sessionID,
            fingerprint: job.fingerprint,
            status: job.status,
            createdAt: job.createdAt,
            startedAt: job.startedAt,
            completedAt: job.completedAt,
            result: job.result,
            error: job.error,
            metadata: publicJobMetadata(job.preparedRequest.metadata),
          });

          logRequest({
            requestID,
            route: pathname,
            method: request.method,
            status: 200,
            durationMs: deps.now() - startedAt,
            jobID: job.jobID,
            installID: job.installID,
            sessionID: job.sessionID,
            fingerprint: job.fingerprint,
            requestMode: job.requestMode,
            trigger: job.trigger,
            inputMode: job.inputMode,
            currentExerciseCount: job.currentExerciseCount,
            historyExerciseCount: job.historyExerciseCount,
            historySessionCount: job.historySessionCount,
            inferenceMode: job.inferenceMode,
            promptBytes: job.promptBytes,
            modelDurationMs: job.modelDurationMs,
            totalJobDurationMs: job.totalJobDurationMs,
          });
          return json(response, 200);
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
        const validationIssues = extractValidationIssues(error);
        const loggedErrorDetails =
          validationIssues && validationRequestPreview
            ? mergeErrorDetails(errorDetails, {
                requestPreview: validationRequestPreview,
              })
            : errorDetails;

        logRequest({
          requestID,
          route: pathname,
          method: request.method,
          status: mapped.status,
          durationMs: deps.now() - startedAt,
          errorCode: extractMappedErrorCode(mapped.body),
          errorDetails: loggedErrorDetails,
          validationIssues,
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
  modelRoutingEnabled: boolean;
  modelRoutingVersion: string;
  chatFastModel: string;
  chatBalancedModel: string;
  summaryFastModel: string;
  insightsBalancedModel: string;
  missing?: string[];
} {
  const missing = missingSecrets(env);
  return {
    status: missing.length === 0 ? "ok" : "error",
    model: resolveModel(env),
    promptVersion: resolvePromptVersion(env),
    modelRoutingEnabled: isModelRoutingEnabled(env),
    modelRoutingVersion: resolveModelRoutingVersion(env),
    chatFastModel: resolveModelForRole(env, "chat_fast"),
    chatBalancedModel: resolveModelForRole(env, "chat_balanced"),
    summaryFastModel: resolveModelForRole(env, "summary_fast"),
    insightsBalancedModel: resolveModelForRole(env, "insights_balanced"),
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
  if (!env.COACH_CHAT_WORKFLOW) {
    missing.push("COACH_CHAT_WORKFLOW");
  }
  if (!env.WORKOUT_SUMMARY_WORKFLOW) {
    missing.push("WORKOUT_SUMMARY_WORKFLOW");
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

function mustGetChatWorkflow(env: Env): NonNullable<Env["COACH_CHAT_WORKFLOW"]> {
  const workflow = env.COACH_CHAT_WORKFLOW;
  if (!workflow) {
    throw new RequestError(
      500,
      "server_misconfigured",
      "Coach backend is not configured.",
      { missing: ["COACH_CHAT_WORKFLOW"] }
    );
  }

  return workflow;
}

function mustGetWorkoutSummaryWorkflow(
  env: Env
): NonNullable<Env["WORKOUT_SUMMARY_WORKFLOW"]> {
  const workflow = env.WORKOUT_SUMMARY_WORKFLOW;
  if (!workflow) {
    throw new RequestError(
      500,
      "server_misconfigured",
      "Coach backend is not configured.",
      { missing: ["WORKOUT_SUMMARY_WORKFLOW"] }
    );
  }

  return workflow;
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

function buildBackupUploadDiagnostics(
  rawBody: unknown,
  migratedLegacyCategoryIDs = 0
): Record<string, unknown> | undefined {
  if (!isRecord(rawBody)) {
    return undefined;
  }

  const diagnostics: Record<string, unknown> = {};
  const installID = readNonEmptyString(rawBody.installID);
  if (installID) {
    diagnostics.installID = installID;
  }

  diagnostics.hasExpectedRemoteVersion = hasOwn(rawBody, "expectedRemoteVersion");
  diagnostics.hasBackupHash = hasOwn(rawBody, "backupHash");
  diagnostics.hasSnapshot = hasOwn(rawBody, "snapshot");

  const snapshotCounts = extractBackupSnapshotCounts(rawBody.snapshot);
  if (snapshotCounts) {
    diagnostics.snapshotCounts = snapshotCounts;
  }
  if (migratedLegacyCategoryIDs > 0) {
    diagnostics.migratedLegacyCategoryIDs = migratedLegacyCategoryIDs;
  }

  return Object.keys(diagnostics).length > 0 ? diagnostics : undefined;
}

const LEGACY_CATEGORY_ID_MAP: Readonly<Record<string, string>> = {
  "A1000000-0000-0000-0000-000000000001": "A1000000-0000-4000-8000-000000000001",
  "A1000000-0000-0000-0000-000000000002": "A1000000-0000-4000-8000-000000000002",
  "A1000000-0000-0000-0000-000000000003": "A1000000-0000-4000-8000-000000000003",
  "A1000000-0000-0000-0000-000000000004": "A1000000-0000-4000-8000-000000000004",
  "A1000000-0000-0000-0000-000000000005": "A1000000-0000-4000-8000-000000000005",
  "A1000000-0000-0000-0000-000000000006": "A1000000-0000-4000-8000-000000000006",
};

function normalizeBackupUploadPayload(rawBody: unknown): {
  body: unknown;
  migratedLegacyCategoryIDs: number;
} {
  if (!isRecord(rawBody) || !isRecord(rawBody.snapshot)) {
    return { body: rawBody, migratedLegacyCategoryIDs: 0 };
  }

  const snapshot = rawBody.snapshot;
  if (!Array.isArray(snapshot.exercises)) {
    return { body: rawBody, migratedLegacyCategoryIDs: 0 };
  }

  let migratedLegacyCategoryIDs = 0;
  const normalizedExercises = snapshot.exercises.map((exercise) => {
    if (!isRecord(exercise) || typeof exercise.categoryID !== "string") {
      return exercise;
    }

    const canonicalCategoryID = LEGACY_CATEGORY_ID_MAP[exercise.categoryID];
    if (!canonicalCategoryID) {
      return exercise;
    }

    migratedLegacyCategoryIDs += 1;
    return {
      ...exercise,
      categoryID: canonicalCategoryID,
    };
  });

  if (migratedLegacyCategoryIDs === 0) {
    return { body: rawBody, migratedLegacyCategoryIDs: 0 };
  }

  return {
    body: {
      ...rawBody,
      snapshot: {
        ...snapshot,
        exercises: normalizedExercises,
      },
    },
    migratedLegacyCategoryIDs,
  };
}

function extractBackupSnapshotCounts(
  snapshot: unknown
):
  | {
      programs?: number;
      exercises?: number;
      history?: number;
    }
  | undefined {
  if (!isRecord(snapshot)) {
    return undefined;
  }

  const counts: {
    programs?: number;
    exercises?: number;
    history?: number;
  } = {};

  if (Array.isArray(snapshot.programs)) {
    counts.programs = snapshot.programs.length;
  }

  if (Array.isArray(snapshot.exercises)) {
    counts.exercises = snapshot.exercises.length;
  }

  if (Array.isArray(snapshot.history)) {
    counts.history = snapshot.history.length;
  }

  return Object.keys(counts).length > 0 ? counts : undefined;
}

function resolveInsightsCacheMissReason(
  forceRefresh: boolean | undefined,
  cacheAllowed: boolean
): "force_refresh" | "cache_disallowed_active_workout" | "cache_key_miss" {
  if (forceRefresh) {
    return "force_refresh";
  }
  if (!cacheAllowed) {
    return "cache_disallowed_active_workout";
  }
  return "cache_key_miss";
}

function mapError(
  error: unknown,
  requestID: string
): {
  status: number;
  body: Record<string, unknown>;
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

  if (error instanceof ActiveCoachChatJobError) {
    return {
      status: 409,
      body: {
        error: {
          code: "chat_job_in_progress",
          message: "Coach chat job already in progress.",
          requestID,
        },
        jobID: error.jobID,
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

function isZodLikeError(
  error: unknown
): error is { name: string; issues: unknown[] } {
  return (
    typeof error === "object" &&
    error !== null &&
    "name" in error &&
    "issues" in error &&
    Array.isArray((error as { issues: unknown[] }).issues) &&
    (error as { name: string }).name === "ZodError"
  );
}

function extractValidationIssues(
  error: unknown
):
  | Array<{
      code?: string;
      path: Array<string | number>;
      message: string;
      expected?: unknown;
      received?: unknown;
    }>
  | undefined {
  if (!isZodLikeError(error)) {
    return undefined;
  }

  return error.issues.map((issue) => buildValidationIssueLog(issue));
}

function buildValidationIssueLog(issue: unknown): {
  code?: string;
  path: Array<string | number>;
  message: string;
  expected?: unknown;
  received?: unknown;
} {
  const record = isRecord(issue) ? issue : {};
  const message =
    typeof record.message === "string" ? record.message : "Invalid input.";
  const received =
    hasOwn(record, "received") && record.received !== undefined
      ? record.received
      : inferReceivedFromValidationMessage(message);

  return {
    ...(typeof record.code === "string" ? { code: record.code } : {}),
    path: normalizeValidationIssuePath(record.path),
    message,
    ...(hasOwn(record, "expected") ? { expected: record.expected } : {}),
    ...(received !== undefined ? { received } : {}),
  };
}

function normalizeValidationIssuePath(path: unknown): Array<string | number> {
  if (!Array.isArray(path)) {
    return [];
  }

  return path.filter(
    (segment): segment is string | number =>
      typeof segment === "string" || typeof segment === "number"
  );
}

function inferReceivedFromValidationMessage(message: string): string | undefined {
  const match = /, received ([^,]+)$/i.exec(message);
  return match?.[1];
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
  if (isFiniteStatusCode(payload.status) && payload.status >= 500) {
    console.error(serialized);
    return;
  }

  if (isFiniteStatusCode(payload.status) && payload.status >= 400) {
    console.warn(serialized);
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

function extractMappedErrorCode(body: Record<string, unknown>): string | undefined {
  const error = body.error;
  if (typeof error !== "object" || error === null) {
    return undefined;
  }

  const code = (error as { code?: unknown }).code;
  return typeof code === "string" ? code : undefined;
}

function isFiniteStatusCode(status: unknown): status is number {
  return typeof status === "number" && Number.isFinite(status);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasOwn<T extends object>(
  value: T,
  key: PropertyKey
): key is keyof T {
  return Object.prototype.hasOwnProperty.call(value, key);
}

function readNonEmptyString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }

  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function buildChatJobID(): string {
  return `coach-job_${crypto.randomUUID()}`;
}

function buildWorkoutSummaryJobID(): string {
  return `workout-summary-job_${crypto.randomUUID()}`;
}

function parseChatJobPath(
  pathname: string
): {
  jobID: string;
} | null {
  const match = pathname.match(/^\/v2\/coach\/chat-jobs\/([^/]+)$/);
  if (!match?.[1]) {
    return null;
  }

  return {
    jobID: decodeURIComponent(match[1]),
  };
}

function parseWorkoutSummaryJobPath(
  pathname: string
): {
  jobID: string;
} | null {
  const match = pathname.match(/^\/v2\/coach\/workout-summary-jobs\/([^/]+)$/);
  if (!match?.[1]) {
    return null;
  }

  return {
    jobID: decodeURIComponent(match[1]),
  };
}

function parseInstallIDQuery(request: Request): string {
  const installID = new URL(request.url).searchParams.get("installID")?.trim();
  if (!installID) {
    throw new RequestError(
      400,
      "invalid_request",
      "Request body does not match the coach contract.",
      { field: "installID" }
    );
  }

  return installID;
}

function totalChatTurnChars(
  turns: Array<{ content: string }>
): number {
  return turns.reduce((total, turn) => total + turn.content.length, 0);
}

function totalWorkoutSummaryHistorySessionCount(
  history: Array<{ sessions: unknown[] }>
): number {
  return history.reduce((total, exerciseHistory) => total + exerciseHistory.sessions.length, 0);
}

function buildChatRequestPreview(rawBody: unknown): Record<string, unknown> {
  if (!isRecord(rawBody)) {
    return {
      bodyType: describeValueType(rawBody),
    };
  }

  const allowedKeys = new Set([
    "locale",
    "question",
    "installID",
    "snapshotHash",
    "snapshot",
    "snapshotUpdatedAt",
    "runtimeContextDelta",
    "clientRecentTurns",
    "capabilityScope",
    "clientRequestID",
  ]);
  const question = typeof rawBody.question === "string" ? rawBody.question : undefined;
  const turns = Array.isArray(rawBody.clientRecentTurns)
    ? rawBody.clientRecentTurns.slice(0, 4).map((turn, index) => {
        if (!isRecord(turn)) {
          return {
            index,
            turnType: describeValueType(turn),
          };
        }

        const content =
          typeof turn.content === "string" ? turn.content : undefined;
        return {
          index,
          role:
            typeof turn.role === "string" ? turn.role : undefined,
          roleType: describeValueType(turn.role),
          contentType: describeValueType(turn.content),
          ...(content
            ? {
                contentChars: content.length,
                contentPreview: sanitizeTextPreview(content, 120),
              }
            : {}),
        };
      })
    : undefined;

  return {
    installID: readNonEmptyString(rawBody.installID),
    installIDType: describeValueType(rawBody.installID),
    clientRequestID: readNonEmptyString(rawBody.clientRequestID),
    clientRequestIDType: describeValueType(rawBody.clientRequestID),
    localeType: describeValueType(rawBody.locale),
    capabilityScopeType: describeValueType(rawBody.capabilityScope),
    questionType: describeValueType(rawBody.question),
    ...(question
      ? {
          questionChars: question.length,
          questionPreview: sanitizeTextPreview(question, 160),
        }
      : {}),
    clientRecentTurnsType: describeValueType(rawBody.clientRecentTurns),
    ...(Array.isArray(rawBody.clientRecentTurns)
      ? {
          clientRecentTurnsCount: rawBody.clientRecentTurns.length,
          clientRecentTurns: turns,
        }
      : {}),
    hasSnapshot: hasOwn(rawBody, "snapshot"),
    hasRuntimeContextDelta: hasOwn(rawBody, "runtimeContextDelta"),
    extraKeys: Object.keys(rawBody).filter((key) => !allowedKeys.has(key)).slice(0, 8),
  };
}

function resolvePromptVersion(env: Env): string {
  return env.COACH_PROMPT_VERSION?.trim() || "2026-03-25.v1";
}

function resolveModel(env: Env): string {
  return env.AI_MODEL?.trim() || DEFAULT_AI_MODEL;
}

function describeValueType(value: unknown): string {
  if (value === null) {
    return "null";
  }
  if (Array.isArray(value)) {
    return "array";
  }
  return typeof value;
}

function sanitizeTextPreview(value: string, maxLength: number): string {
  return value.replace(/\s+/g, " ").trim().slice(0, maxLength);
}

function mergeRecentTurns(
  storedTurns: CoachConversationTurn[],
  clientTurns: CoachConversationTurn[]
): CoachConversationTurn[] {
  if (storedTurns.length === 0) {
    return normalizeChatTurns(clientTurns);
  }
  if (clientTurns.length === 0) {
    return normalizeChatTurns(storedTurns);
  }

  const overlap = sharedTurnSuffixPrefixLength(storedTurns, clientTurns);
  return normalizeChatTurns([
    ...storedTurns,
    ...clientTurns.slice(overlap),
  ]);
}

function sharedTurnSuffixPrefixLength(
  left: CoachConversationTurn[],
  right: CoachConversationTurn[]
): number {
  const maxOverlap = Math.min(left.length, right.length);
  for (let overlap = maxOverlap; overlap > 0; overlap -= 1) {
    let matches = true;
    for (let index = 0; index < overlap; index += 1) {
      const leftTurn = left[left.length - overlap + index];
      const rightTurn = right[index];
      if (
        leftTurn?.role !== rightTurn?.role ||
        leftTurn?.content.trim() !== rightTurn?.content.trim()
      ) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return overlap;
    }
  }

  return 0;
}

function buildExecutionMetadata(input: {
  contextProfile: CoachExecutionMetadata["contextProfile"];
  promptProfile: string;
  contextVersion: string;
  analyticsVersion: string;
  memoryProfile: CoachExecutionMetadata["memoryProfile"];
  jobDeadlineAt?: string;
  derivedAnalytics?: CoachExecutionMetadata["derivedAnalytics"];
  useCase?: CoachExecutionMetadata["useCase"];
  modelRole?: CoachExecutionMetadata["modelRole"];
  selectedModel?: CoachExecutionMetadata["selectedModel"];
  allowedContextProfiles?: CoachExecutionMetadata["allowedContextProfiles"];
  payloadTier?: CoachExecutionMetadata["payloadTier"];
  routingVersion?: CoachExecutionMetadata["routingVersion"];
  memoryCompatibilityKey?: CoachExecutionMetadata["memoryCompatibilityKey"];
  promptFamily?: CoachExecutionMetadata["promptFamily"];
  contextFamily?: CoachExecutionMetadata["contextFamily"];
  routingReasonTags?: CoachExecutionMetadata["routingReasonTags"];
}): CoachExecutionMetadata {
  return {
    contextProfile: input.contextProfile,
    promptProfile: input.promptProfile,
    contextVersion: input.contextVersion,
    analyticsVersion: input.analyticsVersion,
    memoryProfile: input.memoryProfile,
    jobDeadlineAt: input.jobDeadlineAt,
    derivedAnalytics: input.derivedAnalytics,
    useCase: input.useCase,
    modelRole: input.modelRole,
    selectedModel: input.selectedModel,
    allowedContextProfiles: input.allowedContextProfiles,
    payloadTier: input.payloadTier,
    routingVersion: input.routingVersion,
    memoryCompatibilityKey: input.memoryCompatibilityKey,
    promptFamily: input.promptFamily,
    contextFamily: input.contextFamily,
    routingReasonTags: input.routingReasonTags,
  };
}

function publicJobMetadata(
  metadata: Partial<CoachExecutionMetadata> | undefined
):
  | {
      jobDeadlineAt?: string;
      contextProfile?: string;
      promptProfile?: string;
      contextVersion?: string;
      analyticsVersion?: string;
      memoryProfile?: string;
    }
  | undefined {
  if (!metadata) {
    return undefined;
  }

  return {
    jobDeadlineAt: metadata.jobDeadlineAt,
    contextProfile: metadata.contextProfile,
    promptProfile: metadata.promptProfile,
    contextVersion: metadata.contextVersion,
    analyticsVersion: metadata.analyticsVersion,
    memoryProfile: metadata.memoryProfile,
  };
}

function isTerminalJobStatus(status: string): boolean {
  return status === "completed" || status === "failed" || status === "canceled";
}

function normalizeReusableProfileInsightsCacheEntry(
  response: CoachProfileInsightsResponse | null
): CoachProfileInsightsResponse | null {
  if (!response) {
    return null;
  }

  if (response.generationStatus !== "model") {
    return null;
  }

  return {
    ...response,
    insightSource: "cached_model",
  };
}
