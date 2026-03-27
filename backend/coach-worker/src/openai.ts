import {
  chatResponseModelOutputSchema,
  profileInsightsModelOutputSchema,
  type CoachAIProvider,
  type CoachChatRequest,
  type CoachChatResponse,
  type CoachProfileInsightsRequest,
  type CoachProfileInsightsResponse,
  type CoachWorkoutSummaryJobCreateRequest,
  type CoachWorkoutSummaryResponse,
  workoutSummaryModelOutputSchema,
} from "./schemas";
import {
  buildProfileInsightsMessages,
  buildChatMessages,
  buildFallbackChatMessages,
  buildFallbackProfileInsightsMessages,
  buildWorkoutSummaryMessages,
  buildFallbackWorkoutSummaryMessages,
} from "./prompts";
import {
  buildDerivedCoachAnalyticsFromCompactSnapshot,
  extractProgramCommentConstraints,
  type CoachContextProfile,
  type CoachDerivedAnalytics,
  type CoachExecutionMetadata,
  type ProgramCommentConstraints,
} from "./context";
import type {
  CoachD1Database,
  CoachKVNamespace,
  CoachR2Bucket,
} from "./state";
import {
  DEFAULT_AI_MODEL,
  DEFAULT_GEMINI_CHAT_BALANCED_MODEL,
  buildChatRoutingAttempts,
  buildChatRoutingDecision,
  buildProfileInsightsRoutingAttempts,
  buildProfileInsightsRoutingDecision,
  buildWorkoutSummaryRoutingAttempts,
  buildWorkoutSummaryRoutingDecision,
  resolveProvider,
  type ChatRoutingAttempt,
  type CoachModelRole,
  type CoachPayloadTier,
  type CoachRoutingUseCase,
  type ProfileInsightsRoutingAttempt,
  type StructuredAdapter,
  type WorkoutSummaryRoutingAttempt,
} from "./routing";

export { DEFAULT_AI_MODEL } from "./routing";
const PROFILE_INSIGHTS_STRUCTURED_MAX_TOKENS = 550;
const PROFILE_INSIGHTS_ASYNC_STRUCTURED_MAX_TOKENS = 1_000;
const PROFILE_INSIGHTS_PLAIN_TEXT_MAX_TOKENS = 260;
const PROFILE_INSIGHTS_ASYNC_PLAIN_TEXT_MAX_TOKENS = 500;
const CHAT_STRUCTURED_MAX_TOKENS = 700;
const CHAT_ASYNC_STRUCTURED_MAX_TOKENS = 1_400;
const CHAT_FALLBACK_MAX_TOKENS = 450;
const CHAT_ASYNC_FALLBACK_MAX_TOKENS = 900;
const WORKOUT_SUMMARY_STRUCTURED_MAX_TOKENS = 420;
const WORKOUT_SUMMARY_ASYNC_STRUCTURED_MAX_TOKENS = 700;
const WORKOUT_SUMMARY_PLAIN_TEXT_MAX_TOKENS = 320;
const WORKOUT_SUMMARY_ASYNC_PLAIN_TEXT_MAX_TOKENS = 520;
const GEMINI_MAX_RATE_LIMIT_RETRIES = 2;
const GEMINI_BASE_RETRY_DELAY_MS = 1_250;
const GEMINI_MAX_RETRY_DELAY_MS = 6_000;
type ProfileInsightsTimeoutBudget = {
  totalBudgetMs: number;
  structuredTimeoutMs: number;
  fallbackTimeoutMs: number;
  fallbackMinTimeoutMs: number;
};

const PROFILE_INSIGHTS_TIMEOUTS: ProfileInsightsTimeoutBudget = {
  totalBudgetMs: 25_000,
  structuredTimeoutMs: 18_000,
  fallbackTimeoutMs: 5_000,
  fallbackMinTimeoutMs: 3_000,
};
const GEMINI_PROFILE_INSIGHTS_TIMEOUTS: ProfileInsightsTimeoutBudget = {
  totalBudgetMs: 30_000,
  structuredTimeoutMs: 24_000,
  fallbackTimeoutMs: 6_000,
  fallbackMinTimeoutMs: 3_000,
};
const PROFILE_INSIGHTS_STRUCTURED_MIN_TIMEOUT_MS = 1_500;
const PROFILE_INSIGHTS_STRUCTURED_SAFETY_BUFFER_MS = 750;
const ASYNC_LONG_TIMEOUTS = {
  totalBudgetMs: 570_000,
  structuredTimeoutMs: 510_000,
  fallbackTimeoutMs: 45_000,
  fallbackMinTimeoutMs: 15_000,
} as const;
const SYNC_CHAT_TIMEOUTS = {
  totalBudgetMs: 25_000,
  structuredTimeoutMs: 18_000,
  fallbackTimeoutMs: 5_000,
  fallbackMinTimeoutMs: 3_000,
} as const;

interface WorkersAI {
  run(model: string, inputs: Record<string, unknown>): Promise<unknown>;
}

interface WorkflowInstanceBinding {
  id: string;
  status(): Promise<unknown>;
}

interface WorkflowBinding<TParams = unknown> {
  create(options?: { id?: string; params?: TParams }): Promise<WorkflowInstanceBinding>;
  get(id: string): Promise<WorkflowInstanceBinding>;
}

export interface Env {
  AI?: WorkersAI;
  COACH_STATE_KV?: CoachKVNamespace;
  BACKUPS_R2?: CoachR2Bucket;
  APP_META_DB?: CoachD1Database;
  COACH_CHAT_WORKFLOW?: WorkflowBinding<{ jobID: string }>;
  WORKOUT_SUMMARY_WORKFLOW?: WorkflowBinding<{ jobID: string }>;
  COACH_INTERNAL_TOKEN: string;
  AI_MODEL?: string;
  COACH_PROMPT_VERSION?: string;
  MODEL_ROUTING_ENABLED?: string;
  MODEL_ROUTING_VERSION?: string;
  CHAT_FAST_MODEL?: string;
  CHAT_BALANCED_MODEL?: string;
  CHAT_REDUCED_CONTEXT_MODEL?: string;
  SUMMARY_FAST_MODEL?: string;
  SUMMARY_BALANCED_MODEL?: string;
  INSIGHTS_BALANCED_MODEL?: string;
  INSIGHTS_FAST_MODEL?: string;
  SYNC_FALLBACK_MODEL?: string;
  QUALITY_ESCALATION_MODEL?: string;
  QUALITY_ESCALATION_ENABLED?: string;
  GEMINI_API_KEY?: string;
  GEMINI_API_BASE_URL?: string;
  GEMINI_CHAT_FAST_MODEL?: string;
  GEMINI_CHAT_BALANCED_MODEL?: string;
  GEMINI_CHAT_REDUCED_CONTEXT_MODEL?: string;
  GEMINI_SUMMARY_FAST_MODEL?: string;
  GEMINI_SUMMARY_BALANCED_MODEL?: string;
  GEMINI_INSIGHTS_BALANCED_MODEL?: string;
  GEMINI_INSIGHTS_FAST_MODEL?: string;
  GEMINI_SYNC_FALLBACK_MODEL?: string;
  GEMINI_QUALITY_ESCALATION_MODEL?: string;
}

export interface InferenceResult<T> {
  data: T;
  provider?: CoachAIProvider;
  responseId?: string;
  model: string;
  selectedModel?: string;
  modelRole?: CoachModelRole;
  useCase?: CoachRoutingUseCase;
  routingVersion?: string;
  payloadTier?: CoachPayloadTier;
  contextProfile?: CoachContextProfile;
  memoryCompatibilityKey?: string;
  routingReasonTags?: string[];
  fallbackHopCount?: number;
  fallbackReason?: string;
  mode?: string;
  usage?: unknown;
  promptBytes?: number;
  fallbackPromptBytes?: number;
  modelDurationMs?: number;
  fallbackModelDurationMs?: number;
}

type CoachProfileInsightsContent = Omit<
  CoachProfileInsightsResponse,
  "generationStatus" | "insightSource"
>;
type CoachWorkoutSummaryContent = Omit<
  CoachWorkoutSummaryResponse,
  "generationStatus"
>;
type CoachChatContent = Omit<
  CoachChatResponse,
  "responseID" | "generationStatus"
>;

export interface CoachInferenceService {
  generateProfileInsights(
    request: CoachProfileInsightsRequest,
    options?: GenerateProfileInsightsOptions
  ): Promise<InferenceResult<CoachProfileInsightsResponse>>;
  generateWorkoutSummary(
    request: CoachWorkoutSummaryJobCreateRequest
  ): Promise<InferenceResult<CoachWorkoutSummaryResponse>>;
  generateChat(
    request: CoachChatRequest,
    options?: GenerateChatOptions
  ): Promise<InferenceResult<CoachChatResponse>>;
}

export interface GenerateChatOptions {
  responseId?: string;
  timeoutProfile?: "sync" | "async_job";
  contextProfile?: CoachContextProfile;
  promptProfile?: string;
  derivedAnalytics?: CoachDerivedAnalytics;
}

export interface GenerateProfileInsightsOptions {
  timeoutProfile?: "sync" | "async_job";
  contextProfile?: CoachContextProfile;
  promptProfile?: string;
  derivedAnalytics?: CoachDerivedAnalytics;
}

export class CoachInferenceServiceError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: Record<string, unknown>
  ) {
    super(message);
    this.name = "CoachInferenceServiceError";
  }
}

type CoachMetadataCarrier = {
  metadata?: Partial<CoachExecutionMetadata>;
};

type ResolvedPromptExecution = {
  contextProfile: CoachContextProfile;
  promptProfile: string;
  derivedAnalytics?: CoachDerivedAnalytics;
};

export function createWorkersAICoachService(env: Env): CoachInferenceService {
  return new WorkersAICoachService(env);
}

export function createInferenceServiceForProvider(
  env: Env,
  provider: CoachAIProvider = "workers_ai"
): CoachInferenceService {
  if (provider === "gemini") {
    return new WorkersAICoachService({
      ...env,
      AI: createGeminiAIAdapter(env),
    });
  }

  return new WorkersAICoachService(env);
}

export class WorkersAICoachService implements CoachInferenceService {
  constructor(private readonly env: Env) {}
  async generateProfileInsights(
    request: CoachProfileInsightsRequest,
    options: GenerateProfileInsightsOptions = {}
  ): Promise<InferenceResult<CoachProfileInsightsResponse>> {
    const operation = "profile_insights";
    const timeoutProfile = options.timeoutProfile ?? "sync";
    const routingDecision = buildProfileInsightsRoutingDecision(this.env, request);
    const timeouts =
      timeoutProfile === "async_job"
        ? ASYNC_LONG_TIMEOUTS
        : routingDecision.provider === "gemini"
          ? GEMINI_PROFILE_INSIGHTS_TIMEOUTS
          : PROFILE_INSIGHTS_TIMEOUTS;
    const attempts = buildProfileInsightsRoutingAttempts(this.env, routingDecision);
    const promptExecution = resolvePromptExecution(
      request,
      options,
      timeoutProfile === "async_job"
        ? "rich_async_analytics_v1"
        : "compact_sync_v2",
      timeoutProfile === "async_job"
        ? "profile_rich_async_analytics_v1"
        : "profile_compact_context_v2"
    );
    const localFallback = buildNeutralProfileInsights(
      request,
      promptExecution.derivedAnalytics
    );
    const startedAt = Date.now();
    const stats = createAttemptAccumulator();
    const errors: CoachInferenceServiceError[] = [];
    let degradedReason: string | undefined;
    let lastAttempt: ProfileInsightsRoutingAttempt | undefined;
    const sharedDetails = {
      promptVariant: promptExecution.promptProfile,
      contextProfile: promptExecution.contextProfile,
      programCommentChars:
        request.snapshot?.coachAnalysisSettings.programComment.trim().length ?? 0,
      recentPrCount: request.snapshot?.analytics.recentPersonalRecords.length ?? 0,
      relativeStrengthCount: request.snapshot?.analytics.relativeStrength.length ?? 0,
      preferredProgramWorkoutCount:
        request.snapshot?.preferredProgram?.workouts.length ?? 0,
    };
    const structuredMaxTokens = isRichContextProfile(promptExecution.contextProfile)
      ? PROFILE_INSIGHTS_ASYNC_STRUCTURED_MAX_TOKENS
      : PROFILE_INSIGHTS_STRUCTURED_MAX_TOKENS;
    const fallbackMaxTokens = isRichContextProfile(promptExecution.contextProfile)
      ? PROFILE_INSIGHTS_ASYNC_PLAIN_TEXT_MAX_TOKENS
      : PROFILE_INSIGHTS_PLAIN_TEXT_MAX_TOKENS;
    for (const attempt of attempts) {
      lastAttempt = attempt;
      const remainingBudgetMs = remainingProfileInsightsBudgetMs(
        startedAt,
        timeouts.totalBudgetMs
      );
      const timeoutMs = resolveProfileInsightsAttemptTimeoutMs(
        attempt,
        remainingBudgetMs,
        timeouts,
        timeoutProfile
      );
      const priorFallbackReason =
        attempt.fallbackHopCount > 0
          ? resolveProfileFallbackReasonFromError(errors.at(-1), timeoutProfile)
          : undefined;

      if (
        attempt.mode === "structured" &&
        timeoutMs < PROFILE_INSIGHTS_STRUCTURED_MIN_TIMEOUT_MS
      ) {
        degradedReason =
          timeoutProfile === "async_job"
            ? "async_budget_exhausted"
            : "sync_budget_exhausted";
        console.warn(
          JSON.stringify({
            event: "coach_profile_structured_fallback",
            operation,
            provider: attempt.provider,
            selectedModel: attempt.selectedModel,
            modelRole: attempt.modelRole,
            useCase: attempt.useCase,
            routingVersion: attempt.routingVersion,
            routingReasonTags: attempt.routingReasonTags,
            contextProfile: attempt.contextProfile,
            fallbackHopCount: attempt.fallbackHopCount,
            fallbackReason: degradedReason,
            attemptReason: attempt.attemptReason,
            fallbackStage: attempt.fallbackStage,
            mode: attempt.mode,
            reasonCode: "insufficient_budget_for_structured_attempt",
            promptBytes: undefined,
            modelDurationMs: undefined,
            remainingBudgetMs,
          })
        );
        continue;
      }

      if (
        attempt.mode === "plain_text_fallback" &&
        timeoutMs < timeouts.fallbackMinTimeoutMs
      ) {
        degradedReason =
          timeoutProfile === "async_job"
            ? "async_budget_exhausted"
            : "sync_budget_exhausted";
        break;
      }

      const attemptExecution = {
        ...promptExecution,
        contextProfile: attempt.contextProfile,
        promptProfile: attempt.promptProfile,
      };

      try {
        logInferenceAttempt("coach_profile_attempt_started", {
          operation,
          selectedModel: attempt.selectedModel,
          modelRole: attempt.modelRole,
          useCase: attempt.useCase,
          routingVersion: attempt.routingVersion,
          routingReasonTags: attempt.routingReasonTags,
          contextProfile: attempt.contextProfile,
          fallbackHopCount: attempt.fallbackHopCount,
          fallbackReason: priorFallbackReason,
          attemptReason: attempt.attemptReason,
          fallbackStage: attempt.fallbackStage,
          mode: attempt.mode,
          remainingBudgetMs,
        });

        if (attempt.mode === "structured") {
          const invocation = await this.runStructured({
            selectedModel: attempt.selectedModel,
            structuredAdapter: attempt.structuredAdapter,
            operation,
            messages: buildProfileInsightsMessages(request, attemptExecution),
            schema: profileInsightsResponseJsonSchema,
            maxTokens: structuredMaxTokens,
            timeoutMs,
            extraDetails: buildProfileInsightsAttemptDetails(
              request,
              attempt,
              remainingBudgetMs,
              sharedDetails
            ),
          });
          stats.structuredPromptBytes += invocation.promptBytes;
          stats.structuredModelDurationMs += invocation.modelDurationMs;
          const parsed = normalizeProfileInsightsResponse(
            parseStructuredOutput(
              invocation.rawResponse,
              profileInsightsModelOutputSchema,
              "profile insights",
              {
                operation,
                model: attempt.selectedModel,
              }
            )
          );
          const guardedResponse = applyProfileInsightsGuardrails(
            request,
            {
              ...parsed,
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            localFallback,
            attemptExecution.derivedAnalytics
          );
          const fallbackReason = hasProfileGuardrailEmptiedResponse(
            guardedResponse,
            localFallback
          )
            ? "guardrail_empty"
            : priorFallbackReason;

          logInferenceAttempt("coach_profile_attempt_succeeded", {
            operation,
            provider: attempt.provider,
            selectedModel: attempt.selectedModel,
            modelRole: attempt.modelRole,
            useCase: attempt.useCase,
            routingVersion: attempt.routingVersion,
            routingReasonTags: attempt.routingReasonTags,
            contextProfile: attempt.contextProfile,
            fallbackHopCount: attempt.fallbackHopCount,
            fallbackReason,
            attemptReason: attempt.attemptReason,
            fallbackStage: attempt.fallbackStage,
            mode: attempt.mode,
            modelDurationMs: invocation.modelDurationMs,
            promptBytes: invocation.promptBytes,
          });

          return {
            data: guardedResponse,
            provider: attempt.provider,
            model: attempt.selectedModel,
            selectedModel: attempt.selectedModel,
            modelRole: attempt.modelRole,
            useCase: attempt.useCase,
            routingVersion: attempt.routingVersion,
            payloadTier: attempt.payloadTier,
            contextProfile: attempt.contextProfile,
            memoryCompatibilityKey: attempt.memoryCompatibilityKey,
            routingReasonTags: attempt.routingReasonTags,
            fallbackHopCount: attempt.fallbackHopCount,
            fallbackReason,
            mode: "structured",
            usage: extractUsage(invocation.rawResponse),
            promptBytes: stats.structuredPromptBytes,
            modelDurationMs: stats.structuredModelDurationMs,
          };
        }

        const fallbackInvocation = await this.runPlainText({
          selectedModel: attempt.selectedModel,
          operation,
          messages: buildFallbackProfileInsightsMessages(request, attemptExecution),
          maxTokens: fallbackMaxTokens,
          timeoutMs,
          includeFallbackNotice: false,
          extraDetails: {
            ...buildProfileInsightsAttemptDetails(
              request,
              attempt,
              remainingBudgetMs,
              sharedDetails
            ),
            fallbackTrigger: errors.at(-1)?.code,
          },
        });
        stats.fallbackPromptBytes = fallbackInvocation.promptBytes;
        stats.fallbackModelDurationMs = fallbackInvocation.modelDurationMs;
        const guardedResponse = applyProfileInsightsGuardrails(
          request,
          {
            ...parsePlainProfileInsights(
              extractPlainText(fallbackInvocation.rawResponse, "profile insights")
            ),
            generationStatus: "fallback",
            insightSource: "fallback",
          },
          localFallback,
          attemptExecution.derivedAnalytics
        );
        const fallbackReason = hasProfileGuardrailEmptiedResponse(
          guardedResponse,
          localFallback
        )
          ? "guardrail_empty"
          : priorFallbackReason;

        logInferenceAttempt("coach_profile_attempt_succeeded", {
          operation,
          provider: attempt.provider,
          selectedModel: attempt.selectedModel,
          modelRole: attempt.modelRole,
          useCase: attempt.useCase,
          routingVersion: attempt.routingVersion,
          routingReasonTags: attempt.routingReasonTags,
          contextProfile: attempt.contextProfile,
          fallbackHopCount: attempt.fallbackHopCount,
          fallbackReason,
          attemptReason: attempt.attemptReason,
          fallbackStage: attempt.fallbackStage,
          mode: attempt.mode,
          modelDurationMs: fallbackInvocation.modelDurationMs,
          promptBytes: fallbackInvocation.promptBytes,
        });

        return {
          data: guardedResponse,
          provider: attempt.provider,
          model: attempt.selectedModel,
          selectedModel: attempt.selectedModel,
          modelRole: attempt.modelRole,
          useCase: attempt.useCase,
          routingVersion: attempt.routingVersion,
          payloadTier: attempt.payloadTier,
          contextProfile: attempt.contextProfile,
          memoryCompatibilityKey: attempt.memoryCompatibilityKey,
          routingReasonTags: attempt.routingReasonTags,
          fallbackHopCount: attempt.fallbackHopCount,
          fallbackReason,
          mode: "plain_text_fallback",
          usage: extractUsage(fallbackInvocation.rawResponse),
          promptBytes: stats.structuredPromptBytes || undefined,
          fallbackPromptBytes: stats.fallbackPromptBytes,
          modelDurationMs: stats.structuredModelDurationMs || undefined,
          fallbackModelDurationMs: stats.fallbackModelDurationMs,
        };
      } catch (error) {
        if (!(error instanceof CoachInferenceServiceError)) {
          throw error;
        }

        const fallbackReason = resolveProfileFallbackReasonFromError(
          error,
          timeoutProfile
        );
        const promptBytes = resolvePromptBytes(error.details);
        const modelDurationMs = resolveModelDurationMs(error.details);

        if (attempt.mode === "structured") {
          stats.structuredPromptBytes += promptBytes ?? 0;
          stats.structuredModelDurationMs += modelDurationMs ?? 0;
        } else {
          stats.fallbackPromptBytes = promptBytes;
          stats.fallbackModelDurationMs = modelDurationMs;
        }

        console.warn(
          JSON.stringify({
            event: "coach_profile_attempt_failed",
            operation,
            provider: attempt.provider,
            selectedModel: attempt.selectedModel,
            modelRole: attempt.modelRole,
            useCase: attempt.useCase,
            routingVersion: attempt.routingVersion,
            routingReasonTags: attempt.routingReasonTags,
            contextProfile: attempt.contextProfile,
            fallbackHopCount: attempt.fallbackHopCount,
            fallbackReason,
            attemptReason: attempt.attemptReason,
            fallbackStage: attempt.fallbackStage,
            mode: attempt.mode,
            reasonCode: error.code,
            reasonDetails: error.details,
            promptBytes,
            modelDurationMs,
            remainingBudgetMs,
          })
        );

        errors.push(error);

        if (!shouldAttemptProfileModelFallback(error)) {
          degradedReason = fallbackReason;
          break;
        }

        if (attempt.mode === "structured") {
          const remainingAfterFailure = remainingProfileInsightsBudgetMs(
            startedAt,
            timeouts.totalBudgetMs
          );
          console.warn(
            JSON.stringify({
              event: "coach_profile_structured_fallback",
              operation,
              provider: attempt.provider,
              selectedModel: attempt.selectedModel,
              modelRole: attempt.modelRole,
              useCase: attempt.useCase,
              routingVersion: attempt.routingVersion,
              routingReasonTags: attempt.routingReasonTags,
              contextProfile: attempt.contextProfile,
              fallbackHopCount: attempt.fallbackHopCount,
              fallbackReason,
              attemptReason: attempt.attemptReason,
              fallbackStage: attempt.fallbackStage,
              mode: attempt.mode,
              reasonCode: error.code,
              reasonDetails: error.details,
              promptBytes,
              modelDurationMs,
              remainingBudgetMs: remainingAfterFailure,
            })
          );
          continue;
        }

        degradedReason = fallbackReason;
        break;
      }
    }

    const fallbackReason =
      degradedReason ??
      resolveProfileFallbackReasonFromError(errors.at(-1), timeoutProfile);
    const finalAttempt = lastAttempt;
    const selectedModel =
      (errors.at(-1)?.details?.model as string | undefined) ??
      finalAttempt?.selectedModel ??
      routingDecision.selectedModel;
    const modelRole = finalAttempt?.modelRole ?? routingDecision.modelRole;
    const contextProfile = finalAttempt?.contextProfile ?? promptExecution.contextProfile;
    const fallbackHopCount =
      finalAttempt?.fallbackHopCount ?? Math.max(errors.length, 1);

    console.warn(
      JSON.stringify({
        event: "coach_profile_local_fallback",
        operation,
        provider: routingDecision.provider,
        selectedModel,
        modelRole,
        useCase: finalAttempt?.useCase ?? routingDecision.useCase,
        routingVersion: routingDecision.routingVersion,
        routingReasonTags: routingDecision.routingReasonTags,
        contextProfile,
        fallbackHopCount,
        fallbackReason,
        attemptReason: finalAttempt?.attemptReason ?? "local_fallback",
        fallbackStage: finalAttempt?.fallbackStage ?? "primary",
        reasonCode: errors.at(-1)?.code,
        reasonDetails: errors.at(-1)?.details,
        promptBytes:
          stats.fallbackPromptBytes ??
          (stats.structuredPromptBytes || undefined),
        modelDurationMs:
          stats.fallbackModelDurationMs ??
          (stats.structuredModelDurationMs || undefined),
      })
    );

    return {
      data: localFallback,
      provider: routingDecision.provider,
      model: selectedModel,
      selectedModel,
      modelRole,
      useCase: routingDecision.useCase,
      routingVersion: routingDecision.routingVersion,
      payloadTier: routingDecision.payloadTier,
      contextProfile,
      memoryCompatibilityKey: routingDecision.memoryCompatibilityKey,
      routingReasonTags: routingDecision.routingReasonTags,
      fallbackHopCount,
      fallbackReason,
      mode: "local_fallback",
      promptBytes: stats.structuredPromptBytes || undefined,
      fallbackPromptBytes: stats.fallbackPromptBytes,
      modelDurationMs: stats.structuredModelDurationMs || undefined,
      fallbackModelDurationMs: stats.fallbackModelDurationMs,
    };
  }

  async generateWorkoutSummary(
    request: CoachWorkoutSummaryJobCreateRequest
  ): Promise<InferenceResult<CoachWorkoutSummaryResponse>> {
    const operation = "workout_summary";
    const startedAt = Date.now();
    const localFallback = buildNeutralWorkoutSummary(request);
    const routingDecision = buildWorkoutSummaryRoutingDecision(this.env, request);
    const attempts = buildWorkoutSummaryRoutingAttempts(this.env, routingDecision);
    const stats = createAttemptAccumulator();
    const errors: CoachInferenceServiceError[] = [];
    let degradedReason: string | undefined;

    for (const attempt of attempts) {
      const remainingBudgetMs = remainingWorkoutSummaryBudgetMs(
        startedAt,
        ASYNC_LONG_TIMEOUTS.totalBudgetMs
      );
      const timeoutMs = resolveWorkoutSummaryAttemptTimeoutMs(
        attempt,
        remainingBudgetMs
      );

      if (timeoutMs < 1_500) {
        degradedReason = "async_budget_exhausted";
        break;
      }

      const attemptRequest = buildWorkoutSummaryAttemptRequest(
        request,
        attempt.payloadTier
      );

      try {
          logInferenceAttempt("coach_workout_summary_attempt_started", {
            operation,
            provider: attempt.provider,
            selectedModel: attempt.selectedModel,
          modelRole: attempt.modelRole,
          useCase: attempt.useCase,
          routingVersion: attempt.routingVersion,
          routingReasonTags: attempt.routingReasonTags,
          contextProfile: attempt.contextProfile,
          fallbackHopCount: attempt.fallbackHopCount,
          attemptReason: attempt.attemptReason,
          fallbackStage: attempt.fallbackStage,
          mode: attempt.mode,
          remainingBudgetMs,
        });
        if (attempt.mode === "structured") {
          const invocation = await this.runStructured({
            selectedModel: attempt.selectedModel,
            structuredAdapter: attempt.structuredAdapter,
            operation,
            messages: buildWorkoutSummaryMessages(attemptRequest),
            schema: workoutSummaryResponseJsonSchema,
            maxTokens:
              attempt.payloadTier === "full"
                ? WORKOUT_SUMMARY_ASYNC_STRUCTURED_MAX_TOKENS
                : WORKOUT_SUMMARY_STRUCTURED_MAX_TOKENS,
            timeoutMs,
            extraDetails: buildWorkoutSummaryAttemptDetails(
              attemptRequest,
              attempt,
              remainingBudgetMs
            ),
          });
          stats.structuredPromptBytes += invocation.promptBytes;
          stats.structuredModelDurationMs += invocation.modelDurationMs;
          const parsed = normalizeWorkoutSummaryResponse(
            parseStructuredOutput(
              invocation.rawResponse,
              workoutSummaryModelOutputSchema,
              "workout summary",
              {
                operation,
                model: attempt.selectedModel,
                sessionID: request.sessionID,
                fingerprint: request.fingerprint,
              }
            )
          );

          logInferenceAttempt("coach_workout_summary_attempt_succeeded", {
            operation,
            provider: attempt.provider,
            selectedModel: attempt.selectedModel,
            modelRole: attempt.modelRole,
            useCase: attempt.useCase,
            routingVersion: attempt.routingVersion,
            routingReasonTags: attempt.routingReasonTags,
            contextProfile: attempt.contextProfile,
            fallbackHopCount: attempt.fallbackHopCount,
            fallbackReason:
              attempt.fallbackHopCount > 0
                ? resolveGenericFallbackReasonFromError(errors.at(-1))
                : undefined,
            attemptReason: attempt.attemptReason,
            fallbackStage: attempt.fallbackStage,
            mode: attempt.mode,
            modelDurationMs: invocation.modelDurationMs,
            promptBytes: invocation.promptBytes,
          });

          return {
            data: {
              ...parsed,
              generationStatus: "model",
            },
            provider: attempt.provider,
            model: attempt.selectedModel,
            selectedModel: attempt.selectedModel,
            modelRole: attempt.modelRole,
            useCase: attempt.useCase,
            routingVersion: attempt.routingVersion,
            payloadTier: attempt.payloadTier,
            contextProfile: attempt.contextProfile,
            routingReasonTags: attempt.routingReasonTags,
            fallbackHopCount: attempt.fallbackHopCount,
            fallbackReason:
              attempt.fallbackHopCount > 0
                ? resolveGenericFallbackReasonFromError(errors.at(-1))
                : undefined,
            mode: "structured",
            usage: extractUsage(invocation.rawResponse),
            promptBytes: stats.structuredPromptBytes,
            modelDurationMs: stats.structuredModelDurationMs,
          };
        }

        const fallbackInvocation = await this.runPlainText({
          selectedModel: attempt.selectedModel,
          operation,
          messages: buildFallbackWorkoutSummaryMessages(attemptRequest),
          maxTokens: WORKOUT_SUMMARY_PLAIN_TEXT_MAX_TOKENS,
          timeoutMs,
          includeFallbackNotice: false,
          extraDetails: buildWorkoutSummaryAttemptDetails(
            attemptRequest,
            attempt,
            remainingBudgetMs
          ),
        });
        stats.fallbackPromptBytes = fallbackInvocation.promptBytes;
        stats.fallbackModelDurationMs = fallbackInvocation.modelDurationMs;
        const fallbackReason =
          attempt.fallbackHopCount > 0
            ? resolveGenericFallbackReasonFromError(errors.at(-1))
            : undefined;

        logInferenceAttempt("coach_workout_summary_attempt_succeeded", {
          operation,
          provider: attempt.provider,
          selectedModel: attempt.selectedModel,
          modelRole: attempt.modelRole,
          useCase: attempt.useCase,
          routingVersion: attempt.routingVersion,
          routingReasonTags: attempt.routingReasonTags,
          contextProfile: attempt.contextProfile,
          fallbackHopCount: attempt.fallbackHopCount,
          fallbackReason,
          attemptReason: attempt.attemptReason,
          fallbackStage: attempt.fallbackStage,
          mode: attempt.mode,
          modelDurationMs: fallbackInvocation.modelDurationMs,
          promptBytes: fallbackInvocation.promptBytes,
        });

        return {
          data: {
            ...parsePlainWorkoutSummary(
              extractPlainText(
                fallbackInvocation.rawResponse,
                "workout summary fallback"
              )
            ),
            generationStatus: "model",
          },
          provider: attempt.provider,
          model: attempt.selectedModel,
          selectedModel: attempt.selectedModel,
          modelRole: attempt.modelRole,
          useCase: attempt.useCase,
          routingVersion: attempt.routingVersion,
          payloadTier: attempt.payloadTier,
          contextProfile: attempt.contextProfile,
          routingReasonTags: attempt.routingReasonTags,
          fallbackHopCount: attempt.fallbackHopCount,
          fallbackReason,
          mode: "plain_text_fallback",
          usage: extractUsage(fallbackInvocation.rawResponse),
          promptBytes: stats.structuredPromptBytes || undefined,
          fallbackPromptBytes: stats.fallbackPromptBytes,
          modelDurationMs: stats.structuredModelDurationMs || undefined,
          fallbackModelDurationMs: stats.fallbackModelDurationMs,
        };
      } catch (error) {
        if (!(error instanceof CoachInferenceServiceError)) {
          throw error;
        }

        errors.push(error);
        stats.structuredPromptBytes += resolvePromptBytes(error.details) ?? 0;
        stats.structuredModelDurationMs +=
          resolveModelDurationMs(error.details) ?? 0;

        console.warn(
          JSON.stringify({
            event: "coach_workout_summary_attempt_failed",
            operation,
            model: attempt.selectedModel,
            modelRole: attempt.modelRole,
            useCase: attempt.useCase,
            routingVersion: attempt.routingVersion,
            routingReasonTags: attempt.routingReasonTags,
            contextProfile: attempt.contextProfile,
            fallbackHopCount: attempt.fallbackHopCount,
            fallbackReason: resolveGenericFallbackReasonFromError(error),
            attemptReason: attempt.attemptReason,
            fallbackStage: attempt.fallbackStage,
            mode: attempt.mode,
            reasonCode: error.code,
            reasonDetails: error.details,
            remainingBudgetMs,
          })
        );
      }
    }

    return {
      data: localFallback,
      provider: routingDecision.provider,
      model:
        (errors.at(-1)?.details?.model as string | undefined) ??
        routingDecision.selectedModel,
      selectedModel:
        (errors.at(-1)?.details?.model as string | undefined) ??
        routingDecision.selectedModel,
      modelRole: routingDecision.modelRole,
      useCase: routingDecision.useCase,
      routingVersion: routingDecision.routingVersion,
      payloadTier: "reduced",
      contextProfile: "rich_async_v1",
      routingReasonTags: routingDecision.routingReasonTags,
      fallbackHopCount: errors.length,
      fallbackReason:
        degradedReason ?? resolveGenericFallbackReasonFromError(errors.at(-1)),
      mode: "degraded_fallback",
      promptBytes: stats.structuredPromptBytes || undefined,
      fallbackPromptBytes: stats.fallbackPromptBytes,
      modelDurationMs: stats.structuredModelDurationMs || undefined,
      fallbackModelDurationMs: stats.fallbackModelDurationMs,
    };
  }

  async generateChat(
    request: CoachChatRequest,
    options: GenerateChatOptions = {}
  ): Promise<InferenceResult<CoachChatResponse>> {
    const operation = "chat";
    const turnID = options.responseId ?? buildOpaqueResponseID();
    const routingDecision = buildChatRoutingDecision(this.env, request, {
      timeoutProfile: options.timeoutProfile,
    });
    const attempts = buildChatRoutingAttempts(this.env, routingDecision);
    const promptExecution = resolvePromptExecution(
      request,
      options,
      routingDecision.allowedContextProfiles[0] ?? "compact_sync_v2",
      resolveDefaultChatPromptProfile(options.timeoutProfile)
    );
    const localFallback = buildNeutralChatResponse(request, promptExecution.derivedAnalytics);
    const startedAt = Date.now();
    const timeouts =
      options.timeoutProfile === "async_job"
        ? ASYNC_LONG_TIMEOUTS
        : SYNC_CHAT_TIMEOUTS;
    const stats = createAttemptAccumulator();
    const errors: CoachInferenceServiceError[] = [];
    let degradedReason: string | undefined;

    for (const attempt of attempts) {
      const remainingBudgetMs = remainingChatBudgetMs(startedAt, timeouts.totalBudgetMs);
      const timeoutMs = resolveChatAttemptTimeoutMs(
        attempt,
        remainingBudgetMs,
        options.timeoutProfile
      );

      if (timeoutMs < timeouts.fallbackMinTimeoutMs) {
        degradedReason =
          options.timeoutProfile === "async_job"
            ? "async_budget_exhausted"
            : "sync_budget_exhausted";
        break;
      }

      const attemptExecution = {
        ...promptExecution,
        contextProfile: attempt.contextProfile,
        promptProfile: attempt.promptProfile,
      };
      const structuredMaxTokens = isRichContextProfile(attempt.contextProfile)
        ? CHAT_ASYNC_STRUCTURED_MAX_TOKENS
        : CHAT_STRUCTURED_MAX_TOKENS;
      const fallbackMaxTokens = isRichContextProfile(attempt.contextProfile)
        ? CHAT_ASYNC_FALLBACK_MAX_TOKENS
        : CHAT_FALLBACK_MAX_TOKENS;

      try {
        logInferenceAttempt("coach_chat_attempt_started", {
          operation,
          provider: attempt.provider,
          selectedModel: attempt.selectedModel,
          modelRole: attempt.modelRole,
          useCase: attempt.useCase,
          routingVersion: attempt.routingVersion,
          routingReasonTags: attempt.routingReasonTags,
          contextProfile: attempt.contextProfile,
          fallbackHopCount: attempt.fallbackHopCount,
          attemptReason: attempt.attemptReason,
          fallbackStage: attempt.fallbackStage,
          mode: attempt.mode,
          turnID,
          remainingBudgetMs,
        });
        if (attempt.mode === "structured") {
          const rawResponse = await this.runStructured({
            selectedModel: attempt.selectedModel,
            structuredAdapter: attempt.structuredAdapter,
            operation,
            messages: buildChatMessages(request, attemptExecution),
            schema: chatResponseJsonSchema,
            maxTokens: structuredMaxTokens,
            timeoutMs,
            extraDetails: buildChatAttemptDetails(
              request,
              attempt,
              turnID,
              remainingBudgetMs
            ),
          });
          stats.structuredPromptBytes += rawResponse.promptBytes;
          stats.structuredModelDurationMs += rawResponse.modelDurationMs;
          const parsed = normalizeChatResponse(
            parseStructuredOutput(
              rawResponse.rawResponse,
              chatResponseModelOutputSchema,
              "chat",
              {
                operation,
                model: attempt.selectedModel,
                turnID,
              }
            )
          );
          const fallbackReason =
            attempt.fallbackHopCount > 0
              ? resolveGenericFallbackReasonFromError(errors.at(-1))
              : undefined;

          logInferenceAttempt("coach_chat_attempt_succeeded", {
            operation,
            provider: attempt.provider,
            selectedModel: attempt.selectedModel,
            modelRole: attempt.modelRole,
            useCase: attempt.useCase,
            routingVersion: attempt.routingVersion,
            routingReasonTags: attempt.routingReasonTags,
            contextProfile: attempt.contextProfile,
            fallbackHopCount: attempt.fallbackHopCount,
            fallbackReason,
            attemptReason: attempt.attemptReason,
            fallbackStage: attempt.fallbackStage,
            mode: attempt.mode,
            turnID,
            modelDurationMs: rawResponse.modelDurationMs,
            promptBytes: rawResponse.promptBytes,
          });

          return {
            data: {
              ...applyChatGuardrails(
                request,
                {
                  ...parsed,
                  generationStatus: "model",
                },
                attemptExecution.derivedAnalytics
              ),
              responseID: turnID,
            },
            provider: attempt.provider,
            responseId: turnID,
            model: attempt.selectedModel,
            selectedModel: attempt.selectedModel,
            modelRole: attempt.modelRole,
            useCase: attempt.useCase,
            routingVersion: attempt.routingVersion,
            payloadTier: attempt.payloadTier,
            contextProfile: attempt.contextProfile,
            memoryCompatibilityKey: attempt.memoryCompatibilityKey,
            routingReasonTags: attempt.routingReasonTags,
            fallbackHopCount: attempt.fallbackHopCount,
            fallbackReason,
            mode: "structured",
            usage: extractUsage(rawResponse.rawResponse),
            promptBytes: stats.structuredPromptBytes,
            modelDurationMs: stats.structuredModelDurationMs,
          };
        }

        const fallbackResponse = await this.runPlainText({
          selectedModel: attempt.selectedModel,
          operation,
          messages: buildFallbackChatMessages(request, attemptExecution),
          maxTokens: fallbackMaxTokens,
          timeoutMs,
          extraDetails: buildChatAttemptDetails(
            request,
            attempt,
            turnID,
            remainingBudgetMs
          ),
        });
        const answerMarkdown = extractPlainText(
          fallbackResponse.rawResponse,
          "chat fallback"
        );
        stats.fallbackPromptBytes = fallbackResponse.promptBytes;
        stats.fallbackModelDurationMs = fallbackResponse.modelDurationMs;
        const fallbackReason =
          attempt.fallbackHopCount > 0
            ? resolveGenericFallbackReasonFromError(errors.at(-1))
            : undefined;

        logInferenceAttempt("coach_chat_attempt_succeeded", {
          operation,
          provider: attempt.provider,
          selectedModel: attempt.selectedModel,
          modelRole: attempt.modelRole,
          useCase: attempt.useCase,
          routingVersion: attempt.routingVersion,
          routingReasonTags: attempt.routingReasonTags,
          contextProfile: attempt.contextProfile,
          fallbackHopCount: attempt.fallbackHopCount,
          fallbackReason,
          attemptReason: attempt.attemptReason,
          fallbackStage: attempt.fallbackStage,
          mode: attempt.mode,
          turnID,
          modelDurationMs: fallbackResponse.modelDurationMs,
          promptBytes: fallbackResponse.promptBytes,
        });

        return {
          data: {
            ...applyChatGuardrails(
              request,
              {
                answerMarkdown,
                followUps: [],
                generationStatus: "model",
              },
              attemptExecution.derivedAnalytics
            ),
            responseID: turnID,
          },
          provider: attempt.provider,
          responseId: turnID,
          model: attempt.selectedModel,
          selectedModel: attempt.selectedModel,
          modelRole: attempt.modelRole,
          useCase: attempt.useCase,
          routingVersion: attempt.routingVersion,
          payloadTier: attempt.payloadTier,
          contextProfile: attempt.contextProfile,
          memoryCompatibilityKey: attempt.memoryCompatibilityKey,
          routingReasonTags: attempt.routingReasonTags,
          fallbackHopCount: attempt.fallbackHopCount,
          fallbackReason,
          mode: "plain_text_fallback",
          usage: extractUsage(fallbackResponse.rawResponse),
          promptBytes: stats.structuredPromptBytes || undefined,
          fallbackPromptBytes: stats.fallbackPromptBytes,
          modelDurationMs: stats.structuredModelDurationMs || undefined,
          fallbackModelDurationMs: stats.fallbackModelDurationMs,
        };
      } catch (error) {
        if (!(error instanceof CoachInferenceServiceError)) {
          throw error;
        }
        errors.push(error);
        stats.structuredPromptBytes += resolvePromptBytes(error.details) ?? 0;
        stats.structuredModelDurationMs +=
          resolveModelDurationMs(error.details) ?? 0;

        console.warn(
          JSON.stringify({
            event: "coach_chat_attempt_failed",
            operation,
            model: attempt.selectedModel,
            modelRole: attempt.modelRole,
            useCase: attempt.useCase,
            routingVersion: attempt.routingVersion,
            routingReasonTags: attempt.routingReasonTags,
            contextProfile: attempt.contextProfile,
            turnID,
            fallbackHopCount: attempt.fallbackHopCount,
            fallbackReason: resolveGenericFallbackReasonFromError(error),
            attemptReason: attempt.attemptReason,
            fallbackStage: attempt.fallbackStage,
            mode: attempt.mode,
            reasonCode: error.code,
            reasonDetails: error.details,
            remainingBudgetMs,
          })
        );
      }
    }

    return buildDegradedChatResult({
      provider: routingDecision.provider,
      request,
      responseId: turnID,
      fallback: localFallback,
      model:
        (errors.at(-1)?.details?.model as string | undefined) ??
        routingDecision.selectedModel,
      mode: "degraded_fallback",
      startedAt,
      derivedAnalytics: promptExecution.derivedAnalytics,
      errors,
      selectedModel:
        (errors.at(-1)?.details?.model as string | undefined) ??
        routingDecision.selectedModel,
      modelRole: routingDecision.modelRole,
      useCase: routingDecision.useCase,
      routingVersion: routingDecision.routingVersion,
      routingReasonTags: routingDecision.routingReasonTags,
      payloadTier:
        attempts.at(-1)?.payloadTier ??
        routingDecision.payloadTier,
      contextProfile:
        attempts.at(-1)?.contextProfile ??
        routingDecision.allowedContextProfiles.at(-1) ??
        promptExecution.contextProfile,
      memoryCompatibilityKey: routingDecision.memoryCompatibilityKey,
      fallbackHopCount: errors.length,
      fallbackReason:
        degradedReason ?? resolveGenericFallbackReasonFromError(errors.at(-1)),
      promptBytes: stats.structuredPromptBytes || undefined,
      fallbackPromptBytes: stats.fallbackPromptBytes,
      modelDurationMs: stats.structuredModelDurationMs || undefined,
      fallbackModelDurationMs: stats.fallbackModelDurationMs,
    });
  }

  private async runStructured(input: {
    selectedModel: string;
    structuredAdapter: StructuredAdapter;
    operation: "profile_insights" | "workout_summary" | "chat";
    messages: PromptMessage[];
    schema: Record<string, unknown>;
    maxTokens: number;
    timeoutMs: number;
    extraDetails?: Record<string, unknown>;
  }): Promise<ModelInvocationResult> {
    return this.runModel(
      input.selectedModel,
      buildStructuredPayload(input),
      {
        ...input.extraDetails,
        model: input.selectedModel,
        operation: input.operation,
        mode: "structured",
        messageCount: input.messages.length,
        maxTokens: input.maxTokens,
        timeoutMs: input.timeoutMs,
      }
    );
  }

  private async runPlainText(input: {
    selectedModel: string;
    operation: "profile_insights" | "workout_summary" | "chat";
    messages: PromptMessage[];
    maxTokens: number;
    timeoutMs: number;
    includeFallbackNotice?: boolean;
    extraDetails?: Record<string, unknown>;
  }): Promise<ModelInvocationResult> {
    const messages = input.includeFallbackNotice === false
      ? input.messages
      : [
          {
            role: "system" as const,
            content:
              "The previous structured-output attempt failed. Keep the answer compact and in markdown only.",
          },
          ...input.messages,
        ];

    return this.runModel(
      input.selectedModel,
      {
        messages,
        max_tokens: input.maxTokens,
        temperature: 0.25,
      },
      {
        ...input.extraDetails,
        model: input.selectedModel,
        operation: input.operation,
        mode: "plain_text_fallback",
        messageCount: messages.length,
        maxTokens: input.maxTokens,
        timeoutMs: input.timeoutMs,
      }
    );
  }

  private async runModel(
    selectedModel: string,
    payload: Record<string, unknown>,
    details: Record<string, unknown>
  ): Promise<ModelInvocationResult> {
    if (!this.env.AI) {
      throw new CoachInferenceServiceError(
        500,
        "server_misconfigured",
        "Workers AI binding is not configured",
        details
      );
    }

    const timeoutMs = parseTimeoutMs(details.timeoutMs);
    const startedAt = Date.now();
    const promptBytes = byteLength(payload.messages);

    try {
      const rawResponse = await withTimeout(
        this.env.AI.run(selectedModel, payload),
        timeoutMs
      );
      return {
        rawResponse,
        promptBytes,
        modelDurationMs: Date.now() - startedAt,
      };
    } catch (error) {
      throw normalizeWorkersAIError(error, {
        ...details,
        model: selectedModel,
        promptBytes,
        modelDurationMs: Date.now() - startedAt,
      });
    }
  }
}

interface ModelInvocationResult {
  rawResponse: unknown;
  promptBytes: number;
  modelDurationMs: number;
}

interface AttemptAccumulator {
  structuredPromptBytes: number;
  fallbackPromptBytes?: number;
  structuredModelDurationMs: number;
  fallbackModelDurationMs?: number;
}

function createAttemptAccumulator(): AttemptAccumulator {
  return {
    structuredPromptBytes: 0,
    structuredModelDurationMs: 0,
  };
}

function buildStructuredPayload(input: {
  messages: PromptMessage[];
  schema: Record<string, unknown>;
  maxTokens: number;
  structuredAdapter: StructuredAdapter;
}): Record<string, unknown> {
  if (input.structuredAdapter === "response_format_json_schema") {
    return {
      messages: input.messages,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "coach_response",
          schema: input.schema,
        },
      },
      max_tokens: input.maxTokens,
      temperature: 0.2,
    };
  }

  return {
    messages: input.messages,
    guided_json: input.schema,
    max_tokens: input.maxTokens,
    temperature: 0.2,
  };
}

function resolveDefaultChatPromptProfile(
  timeoutProfile: "sync" | "async_job" | undefined
): string {
  return timeoutProfile === "async_job"
    ? "chat_rich_async_analytics_v1"
    : "chat_compact_sync_v2";
}

function buildChatAttemptDetails(
  request: CoachChatRequest,
  attempt: ChatRoutingAttempt,
  turnID: string,
  remainingBudgetMs: number
): Record<string, unknown> {
  return {
    promptVariant: attempt.promptProfile,
    contextProfile: attempt.contextProfile,
    modelRole: attempt.modelRole,
    useCase: attempt.useCase,
    routingVersion: attempt.routingVersion,
    routingReasonTags: attempt.routingReasonTags,
    fallbackStage: attempt.fallbackStage,
    fallbackHopCount: attempt.fallbackHopCount,
    attemptReason: attempt.attemptReason,
    turnID,
    recentTurnCount: request.clientRecentTurns.length,
    recentTurnChars: totalTurnCharacters(request.clientRecentTurns),
    questionChars: request.question.trim().length,
    remainingBudgetMs,
  };
}

function buildProfileInsightsAttemptDetails(
  request: CoachProfileInsightsRequest,
  attempt: ProfileInsightsRoutingAttempt,
  remainingBudgetMs: number,
  sharedDetails: Record<string, unknown>
): Record<string, unknown> {
  return {
    ...sharedDetails,
    promptVariant: attempt.promptProfile,
    contextProfile: attempt.contextProfile,
    modelRole: attempt.modelRole,
    selectedModel: attempt.selectedModel,
    mode: attempt.mode,
    useCase: attempt.useCase,
    routingVersion: attempt.routingVersion,
    routingReasonTags: attempt.routingReasonTags,
    fallbackStage: attempt.fallbackStage,
    fallbackHopCount: attempt.fallbackHopCount,
    attemptReason: attempt.attemptReason,
    payloadTier: attempt.payloadTier,
    installID: request.installID,
    capabilityScope: request.capabilityScope,
    remainingBudgetMs,
  };
}

function buildWorkoutSummaryAttemptDetails(
  request: CoachWorkoutSummaryJobCreateRequest,
  attempt: WorkoutSummaryRoutingAttempt,
  remainingBudgetMs: number
): Record<string, unknown> {
  return {
    promptVariant: attempt.promptProfile,
    contextProfile: attempt.contextProfile,
    modelRole: attempt.modelRole,
    useCase: attempt.useCase,
    routingVersion: attempt.routingVersion,
    routingReasonTags: attempt.routingReasonTags,
    fallbackStage: attempt.fallbackStage,
    fallbackHopCount: attempt.fallbackHopCount,
    attemptReason: attempt.attemptReason,
    payloadTier: attempt.payloadTier,
    sessionID: request.sessionID,
    fingerprint: request.fingerprint,
    requestMode: request.requestMode,
    trigger: request.trigger,
    inputMode: request.inputMode,
    currentExerciseCount: request.currentWorkout.exerciseCount,
    historyExerciseCount: request.recentExerciseHistory.length,
    historySessionCount: request.recentExerciseHistory.reduce(
      (total, exerciseHistory) => total + exerciseHistory.sessions.length,
      0
    ),
    remainingBudgetMs,
  };
}

function buildWorkoutSummaryAttemptRequest(
  request: CoachWorkoutSummaryJobCreateRequest,
  payloadTier: CoachPayloadTier
): CoachWorkoutSummaryJobCreateRequest {
  if (payloadTier === "full") {
    return request;
  }

  return {
    ...request,
    recentExerciseHistory: request.recentExerciseHistory
      .slice(0, 4)
      .map((exerciseHistory) => ({
        ...exerciseHistory,
        sessions: exerciseHistory.sessions.slice(0, 2).map((session) => ({
          ...session,
          completedSets: session.completedSets.slice(0, 4),
        })),
      })),
  };
}

function resolveChatAttemptTimeoutMs(
  attempt: ChatRoutingAttempt,
  remainingBudgetMs: number,
  timeoutProfile: "sync" | "async_job" | undefined
): number {
  const preferred =
    timeoutProfile === "async_job"
      ? {
          primary: 300_000,
          same_model_reduced_context: 120_000,
          alternate_model_reduced_context: 90_000,
          reduced_model_structured: 45_000,
          reduced_model_plain_text: 30_000,
        }
      : {
          primary: 12_000,
          same_model_reduced_context: 5_000,
          alternate_model_reduced_context: 4_000,
          reduced_model_structured: 3_000,
          reduced_model_plain_text: 3_000,
        };

  const stageBudget = preferred[attempt.fallbackStage];
  return Math.max(Math.min(stageBudget, remainingBudgetMs), 0);
}

function resolveProfileInsightsAttemptTimeoutMs(
  attempt: ProfileInsightsRoutingAttempt,
  remainingBudgetMs: number,
  timeouts:
    | typeof PROFILE_INSIGHTS_TIMEOUTS
    | typeof ASYNC_LONG_TIMEOUTS,
  timeoutProfile: "sync" | "async_job"
): number {
  const preferred =
    timeoutProfile === "async_job"
      ? {
          primary: 120_000,
          insights_balanced_structured: 90_000,
          quality_escalation_structured: 60_000,
          sync_fallback_plain_text: timeouts.fallbackTimeoutMs,
        }
      : attempt.provider === "gemini"
        ? {
            primary: 22_000,
            insights_balanced_structured: 18_000,
            quality_escalation_structured: 14_000,
            sync_fallback_plain_text: timeouts.fallbackTimeoutMs,
          }
        : {
            primary: 8_000,
            insights_balanced_structured: 7_000,
            quality_escalation_structured: 4_000,
            sync_fallback_plain_text: timeouts.fallbackTimeoutMs,
          };

  if (attempt.mode === "plain_text_fallback") {
    return Math.max(
      Math.min(preferred.sync_fallback_plain_text, remainingBudgetMs),
      0
    );
  }

  const reservedBudget =
    timeouts.fallbackMinTimeoutMs + PROFILE_INSIGHTS_STRUCTURED_SAFETY_BUFFER_MS;
  const stageBudget = preferred[attempt.fallbackStage];
  return Math.max(
    Math.min(stageBudget, Math.max(remainingBudgetMs - reservedBudget, 0)),
    0
  );
}

function resolveWorkoutSummaryAttemptTimeoutMs(
  attempt: WorkoutSummaryRoutingAttempt,
  remainingBudgetMs: number
): number {
  const preferred = {
    primary: 300_000,
    same_model_reduced_payload: 120_000,
    alternate_model_reduced_payload: 90_000,
    sync_fallback_structured: 45_000,
    sync_fallback_plain_text: 30_000,
  };

  return Math.max(Math.min(preferred[attempt.fallbackStage], remainingBudgetMs), 0);
}

function shouldAttemptPlainTextFallback(
  error: CoachInferenceServiceError
): boolean {
  return error.code !== "upstream_timeout";
}

function shouldAttemptProfileModelFallback(
  error: CoachInferenceServiceError
): boolean {
  return error.code.startsWith("upstream_");
}

function shouldAttemptWorkoutSummaryPlainTextFallback(
  error: CoachInferenceServiceError
): boolean {
  return error.code.startsWith("upstream_");
}

function shouldAttemptChatPlainTextFallback(
  error: CoachInferenceServiceError
): boolean {
  return error.code.startsWith("upstream_");
}

function isRichContextProfile(contextProfile: CoachContextProfile): boolean {
  return (
    contextProfile === "rich_async_v1" ||
    contextProfile === "rich_async_analytics_v1"
  );
}

function resolvePromptExecution(
  request: CoachMetadataCarrier & {
    snapshot?: CoachProfileInsightsRequest["snapshot"] | CoachChatRequest["snapshot"];
  },
  options:
    | GenerateChatOptions
    | GenerateProfileInsightsOptions
    | Record<string, never>,
  defaultContextProfile: CoachContextProfile,
  defaultPromptProfile: string
): ResolvedPromptExecution {
  const metadata = request.metadata;
  const contextProfile =
    ("contextProfile" in options && options.contextProfile) ||
    metadata?.contextProfile ||
    defaultContextProfile;
  const promptProfile =
    ("promptProfile" in options && options.promptProfile) ||
    metadata?.promptProfile ||
    defaultPromptProfile;
  const derivedAnalytics =
    ("derivedAnalytics" in options && options.derivedAnalytics) ||
    metadata?.derivedAnalytics ||
    (request.snapshot
      ? buildDerivedCoachAnalyticsFromCompactSnapshot(
          request.snapshot as NonNullable<typeof request.snapshot>
        )
      : undefined);

  return {
    contextProfile,
    promptProfile,
    derivedAnalytics,
  };
}

function parseStructuredOutput<T>(
  rawResponse: unknown,
  schema: { parse(input: unknown): T },
  label: string,
  details: Record<string, unknown>
): T {
  const rawPayload = extractResponsePayload(rawResponse, label);
  const parsedJSON =
    typeof rawPayload === "string" ? parseJSONPayload(rawPayload, label) : rawPayload;

  try {
    return schema.parse(parsedJSON);
  } catch {
    throw new CoachInferenceServiceError(
      502,
      "upstream_invalid_output",
      `Workers AI returned schema-invalid ${label} output`,
      {
        ...details,
        responseShape: describeResponseShape(rawResponse),
      }
    );
  }
}

function normalizeChatResponse(
  response: {
    answerMarkdown: string;
    followUps: string[];
  }
): CoachChatContent {
  return {
    answerMarkdown: response.answerMarkdown.trim(),
    followUps: normalizeChatFollowUps(response.followUps),
  };
}

function normalizeChatFollowUps(followUps: string[]): string[] {
  return dedupeText(
    followUps
      .map((followUp) => normalizeChatFollowUp(followUp))
      .filter((followUp): followUp is string => Boolean(followUp))
  ).slice(0, 3);
}

function normalizeChatFollowUp(followUp: string): string | null {
  const trimmed = followUp.trim();
  if (!trimmed) {
    return null;
  }

  const collapsedWhitespace = trimmed.replace(/\s+/g, " ");
  const normalizedQuotes = collapsedWhitespace.replace(/[“”]/g, "\"").replace(/[‘’]/g, "'");
  const withoutTrailingPunctuation = normalizedQuotes.replace(/[.?!]+$/g, "").trim();
  if (!withoutTrailingPunctuation) {
    return null;
  }

  const normalized = withoutTrailingPunctuation.toLowerCase();
  if (isAssistantSideFollowUp(normalized)) {
    const transformed = transformAssistantSideFollowUp(withoutTrailingPunctuation);
    return transformed ? ensureTrailingPeriod(transformed) : null;
  }

  return ensureTrailingPeriod(withoutTrailingPunctuation);
}

function isAssistantSideFollowUp(normalized: string): boolean {
  return (
    /^(?:do|would|will|can|could|should)\s+you\b/.test(normalized) ||
    /^(?:do|would|will|can|could|should)\s+we\b/.test(normalized) ||
    /^want\b/.test(normalized) ||
    /^need\b/.test(normalized) ||
    /^interested in\b/.test(normalized) ||
    /^(?:хочешь|хотите|хотели бы|нужно ли|нужен ли|нужна ли|нужны ли)\b/u.test(normalized)
  );
}

function transformAssistantSideFollowUp(followUp: string): string | null {
  const wantMatch = followUp.match(/^want\s+(.+)$/i);
  if (wantMatch?.[1]) {
    return `Give me ${stripSecondPersonReferences(wantMatch[1])}`;
  }

  const needMatch = followUp.match(/^need\s+(.+)$/i);
  if (needMatch?.[1]) {
    return `Give me ${stripSecondPersonReferences(needMatch[1])}`;
  }

  const interestedMatch = followUp.match(/^interested in\s+(.+)$/i);
  if (interestedMatch?.[1]) {
    return `Tell me more about ${stripSecondPersonReferences(interestedMatch[1])}`;
  }

  const doYouWantMatch = followUp.match(
    /^(?:do|would|will|can|could|should)\s+you\s+(?:want|like|need)\s+(.+)$/i
  );
  if (doYouWantMatch?.[1]) {
    const normalizedTail = normalizeFollowUpActionTail(doYouWantMatch[1]);
    if (!normalizedTail) {
      return null;
    }

    if (/^(?:change|adjust|rewrite|redo|rebuild|compare|adapt|make|turn)\b/i.test(normalizedTail)) {
      return `Help me ${normalizedTail}`;
    }

    return `Give me ${normalizedTail}`;
  }

  const doWeMatch = followUp.match(
    /^(?:do|would|will|can|could|should)\s+we\s+(.+)$/i
  );
  if (doWeMatch?.[1]) {
    const normalizedTail = normalizeFollowUpActionTail(doWeMatch[1]);
    return normalizedTail ? `Help me ${normalizedTail}` : null;
  }

  return null;
}

function stripSecondPersonReferences(value: string): string {
  return value
    .replace(/\byour\b/gi, "my")
    .replace(/\byou\b/gi, "me")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeFollowUpActionTail(value: string): string {
  return stripSecondPersonReferences(value)
    .replace(/^to\s+/i, "")
    .replace(/\s+/g, " ")
    .trim();
}

function ensureTrailingPeriod(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) {
    return trimmed;
  }

  return /[.?!]$/.test(trimmed) ? trimmed : `${trimmed}.`;
}

function normalizeProfileInsightsResponse(
  response: {
    summary: string;
    recommendations: string[];
  }
): CoachProfileInsightsContent {
  return {
    summary: response.summary.trim(),
    recommendations: dedupeText(response.recommendations).slice(0, 8),
  };
}

function normalizeWorkoutSummaryResponse(
  response: {
    headline: string;
    summary: string;
    highlights: string[];
    nextWorkoutFocus: string[];
  }
): CoachWorkoutSummaryContent {
  return {
    headline: response.headline.trim(),
    summary: response.summary.trim(),
    highlights: dedupeText(response.highlights).slice(0, 4),
    nextWorkoutFocus: dedupeText(response.nextWorkoutFocus).slice(0, 3),
  };
}

function parsePlainProfileInsights(
  content: string
): CoachProfileInsightsContent {
  const normalized = content.replace(/\r\n/g, "\n").trim();
  const paragraphs = normalized
    .split(/\n\s*\n+/)
    .map((paragraph) => cleanPlainParagraph(paragraph))
    .filter(Boolean);
  const bulletRecommendations = normalized
    .split("\n")
    .map((line) => parseBulletRecommendation(line))
    .filter((value): value is string => Boolean(value));

  let summary =
    paragraphs.find((paragraph) => !looksLikeRecommendationSection(paragraph)) ??
    cleanPlainParagraph(normalized);

  if (!summary) {
    throw new CoachInferenceServiceError(
      502,
      "upstream_empty_output",
      "Workers AI returned empty profile insights fallback output"
    );
  }

  summary = summary.slice(0, 1200);

  const narrativeRecommendations =
    bulletRecommendations.length > 0
      ? []
      : paragraphs
          .filter((paragraph) => paragraph !== summary)
          .filter((paragraph) => !looksLikeRecommendationSection(paragraph));

  return {
    summary,
    recommendations: dedupeText([
      ...bulletRecommendations,
      ...narrativeRecommendations,
    ]).slice(0, 8),
  };
}

function parsePlainWorkoutSummary(
  content: string
): CoachWorkoutSummaryContent {
  const normalized = content.replace(/\r\n/g, "\n").trim();
  const lines = normalized.split("\n");
  const sections = parseLabeledSections(lines);

  const headline = cleanPlainParagraph(
    sections.headline ?? lines[0] ?? ""
  ).slice(0, 160);
  const summary = cleanPlainParagraph(
    sections.summary ??
      normalized
        .split(/\n\s*\n+/)
        .map((paragraph) => cleanPlainParagraph(paragraph))
        .find(Boolean) ??
      ""
  ).slice(0, 900);
  const highlights = dedupeText(
    extractSectionBullets(sections.highlights).map((item) =>
      cleanPlainParagraph(item)
    )
  ).slice(0, 4);
  const nextWorkoutFocus = dedupeText(
    extractSectionBullets(sections.nextWorkoutFocus).map((item) =>
      cleanPlainParagraph(item)
    )
  ).slice(0, 3);

  if (!headline || !summary || highlights.length === 0) {
    throw new CoachInferenceServiceError(
      502,
      "upstream_invalid_output",
      "Workers AI returned schema-invalid workout summary fallback output"
    );
  }

  return {
    headline,
    summary,
    highlights,
    nextWorkoutFocus,
  };
}

function applyProfileInsightsGuardrails(
  request: CoachProfileInsightsRequest,
  response: CoachProfileInsightsResponse,
  fallback: CoachProfileInsightsResponse,
  derivedAnalytics?: CoachDerivedAnalytics
): CoachProfileInsightsResponse {
  const constraints = extractConstraintsFromSnapshot(request.snapshot);
  const summary =
    shouldBlockFrequencyStructureText(response.summary, constraints) ||
    shouldBlockUnsupportedClaimText(response.summary, derivedAnalytics)
    ? fallback.summary
    : response.summary;
  const recommendations = filterUnsupportedClaimText(
    filterFrequencyStructureText(response.recommendations, constraints),
    derivedAnalytics
  );
  return {
    summary,
    recommendations:
      recommendations.length > 0 ? recommendations : fallback.recommendations,
    generationStatus: response.generationStatus,
    insightSource: response.insightSource,
  };
}

function hasProfileGuardrailEmptiedResponse(
  response: CoachProfileInsightsResponse,
  fallback: CoachProfileInsightsResponse
): boolean {
  return (
    response.summary === fallback.summary &&
    response.recommendations.length === fallback.recommendations.length &&
    response.recommendations.every(
      (recommendation, index) => recommendation === fallback.recommendations[index]
    )
  );
}

function resolveProfileFallbackReasonFromError(
  error: CoachInferenceServiceError | undefined,
  timeoutProfile: "sync" | "async_job"
): string | undefined {
  if (!error) {
    return undefined;
  }

  if (error.code === "upstream_timeout") {
    return "upstream_timeout";
  }

  if (error.code === "upstream_invalid_json") {
    return "structured_parse_failed";
  }

  if (
    timeoutProfile === "sync" &&
    (error.code === "upstream_request_failed" || error.code === "upstream_empty_output")
  ) {
    return "model_error";
  }

  return "model_error";
}

function resolveGenericFallbackReasonFromError(
  error: CoachInferenceServiceError | undefined
): string | undefined {
  if (!error) {
    return undefined;
  }

  if (error.code === "upstream_timeout") {
    return "upstream_timeout";
  }

  if (error.code === "upstream_invalid_json") {
    return "structured_parse_failed";
  }

  if (
    error.code === "upstream_request_failed" ||
    error.code === "upstream_empty_output"
  ) {
    return "model_error";
  }

  return error.code;
}

function logInferenceAttempt(
  event: string,
  payload: Record<string, unknown>
): void {
  console.log(
    JSON.stringify({
      event,
      ...payload,
    })
  );
}

function applyChatGuardrails(
  request: CoachChatRequest,
  response: Omit<CoachChatResponse, "responseID">,
  derivedAnalytics?: CoachDerivedAnalytics
): Omit<CoachChatResponse, "responseID"> {
  const constraints = extractConstraintsFromSnapshot(request.snapshot);
  return {
    answerMarkdown: filterChatAnswerMarkdown(
      response.answerMarkdown,
      constraints,
      request.locale,
      derivedAnalytics
    ),
    followUps: response.followUps,
    generationStatus: response.generationStatus,
  };
}

function buildNeutralProfileInsights(
  request: CoachProfileInsightsRequest,
  derivedAnalytics?: CoachDerivedAnalytics
): CoachProfileInsightsResponse {
  const snapshot = request.snapshot;
  if (!snapshot) {
    return {
      summary: localizedCoachText(request.locale, "fallbackSummary"),
      recommendations: [
        localizedCoachText(request.locale, "fallbackProgressionBaseline"),
      ],
      generationStatus: "fallback",
      insightSource: "fallback",
    };
  }

  const locale = request.locale;
  const constraints = extractConstraintsFromSnapshot(snapshot);
  const recommendations: string[] = [];
  const consistency = snapshot.analytics.consistency;

  if (
    constraints.rollingSplitExecution ||
    constraints.preserveWeeklyFrequency ||
    constraints.preserveProgramWorkoutCount ||
    derivedAnalytics?.splitExecution.mode === "rolling_rotation"
  ) {
    recommendations.push(
      localizedCoachText(locale, "fallbackCommentGuardrail")
    );
  }

  if (consistency.workoutsThisWeek < consistency.weeklyTarget) {
    recommendations.push(
      localizedCoachText(locale, "consistencyGap", {
        completed: consistency.workoutsThisWeek,
        target: consistency.weeklyTarget,
      })
    );
  } else if (consistency.streakWeeks > 0) {
    recommendations.push(
      localizedCoachText(locale, "streak", {
        weeks: consistency.streakWeeks,
      })
    );
  }

  const recentPR = snapshot.analytics.recentPersonalRecords[0];
  if (recentPR) {
    recommendations.push(
      localizedCoachText(locale, "fallbackRecentPR", {
        exercise: recentPR.exerciseName,
        delta: formatLoad(recentPR.delta),
      })
    );
  }

  recommendations.push(
    localizedCoachText(locale, "fallbackProgressionBaseline")
  );

  return {
    summary: localizedCoachText(locale, "fallbackSummary"),
    recommendations: dedupeText(recommendations).slice(0, 5),
    generationStatus: "fallback",
    insightSource: "fallback",
  };
}

function buildNeutralWorkoutSummary(
  request: CoachWorkoutSummaryJobCreateRequest
): CoachWorkoutSummaryResponse {
  const locale = request.locale.toLowerCase().startsWith("ru") ? "ru" : "en";
  const currentWorkout = request.currentWorkout;
  const topExercise = currentWorkout.exercises
    .slice()
    .sort((left, right) => right.totalVolume - left.totalVolume)[0];
  const matchedHistoryCount = request.recentExerciseHistory.reduce(
    (total, exerciseHistory) => total + exerciseHistory.sessions.length,
    0
  );
  const progressHighlight = topExercise
    ? buildWorkoutSummaryExerciseProgressHighlight(
        request,
        topExercise.exerciseID
      )
    : undefined;

  const headline =
    locale === "ru"
      ? `Тренировка ${currentWorkout.title} завершена`
      : `${currentWorkout.title} completed`;
  const summary =
    locale === "ru"
      ? `Выполнено ${currentWorkout.completedSetsCount} из ${currentWorkout.totalSetsCount} сетов по ${currentWorkout.exerciseCount} упражнениям. Сводка опирается на текущую тренировку${matchedHistoryCount > 0 ? " и недавние выполнения тех же упражнений" : ""}.`
      : `You completed ${currentWorkout.completedSetsCount} of ${currentWorkout.totalSetsCount} sets across ${currentWorkout.exerciseCount} exercises. This summary is based on the current workout${matchedHistoryCount > 0 ? " and recent same-exercise history" : ""}.`;

  const highlights = dedupeText(
    [
      topExercise
        ? locale === "ru"
          ? `Наибольший объём пришёлся на ${topExercise.exerciseName}: ${formatLoad(topExercise.totalVolume)} кг общего тоннажа.`
          : `${topExercise.exerciseName} carried the highest workload at ${formatLoad(topExercise.totalVolume)} kg of total volume.`
        : undefined,
      progressHighlight,
      locale === "ru"
        ? `Завершено ${currentWorkout.completedSetsCount} рабочих сетов в этой сессии.`
        : `${currentWorkout.completedSetsCount} working sets were completed in this session.`,
    ].filter((value): value is string => Boolean(value))
  ).slice(0, 4);

  const nextWorkoutFocus = dedupeText(
    [
      locale === "ru"
        ? "Ориентируйтесь на уверенно выполненные сегодняшние сеты как на базу для следующей тренировки."
        : "Use the cleanest sets from today as the baseline for the next session.",
      locale === "ru"
        ? "Повышайте нагрузку только там, где техника и повторы выглядели повторяемыми."
        : "Add load only where today's reps and execution looked repeatable.",
    ]
  ).slice(0, 3);

  return {
    headline,
    summary,
    highlights: highlights.length > 0
      ? highlights
      : locale === "ru"
        ? ["Текущая тренировка завершена и может служить базой для следующего прогресса."]
        : ["This completed session can serve as the baseline for your next progression step."],
    nextWorkoutFocus,
    generationStatus: "fallback",
  };
}

function buildNeutralChatResponse(
  request: CoachChatRequest,
  derivedAnalytics?: CoachDerivedAnalytics
): Omit<CoachChatResponse, "responseID"> {
  const snapshot = request.snapshot;
  const locale = request.locale;
  const bullets: string[] = [];

  if (!snapshot) {
    bullets.push(localizedCoachText(locale, "fallbackProgressionBaseline"));
    return {
      answerMarkdown: formatFallbackMarkdown(
        localizedCoachText(locale, "fallbackSummary"),
        bullets
      ),
      followUps: [],
      generationStatus: "fallback",
    };
  }

  const constraints = extractConstraintsFromSnapshot(snapshot);
  const consistency = snapshot.analytics.consistency;

  if (
    constraints.rollingSplitExecution ||
    constraints.preserveWeeklyFrequency ||
    constraints.preserveProgramWorkoutCount ||
    derivedAnalytics?.splitExecution.mode === "rolling_rotation"
  ) {
    bullets.push(localizedCoachText(locale, "fallbackCommentGuardrail"));
  }

  if (consistency.workoutsThisWeek < consistency.weeklyTarget) {
    bullets.push(
      localizedCoachText(locale, "consistencyGap", {
        completed: consistency.workoutsThisWeek,
        target: consistency.weeklyTarget,
      })
    );
  } else if (consistency.streakWeeks > 0) {
    bullets.push(
      localizedCoachText(locale, "streak", {
        weeks: consistency.streakWeeks,
      })
    );
  }

  const recentPR = snapshot.analytics.recentPersonalRecords[0];
  if (recentPR) {
    bullets.push(
      localizedCoachText(locale, "fallbackRecentPR", {
        exercise: recentPR.exerciseName,
        delta: formatLoad(recentPR.delta),
      })
    );
  }

  bullets.push(localizedCoachText(locale, "fallbackProgressionBaseline"));

  return {
    answerMarkdown: formatFallbackMarkdown(
      localizedCoachText(locale, "fallbackSummary"),
      dedupeText(bullets).slice(0, 4)
    ),
    followUps: [],
    generationStatus: "fallback",
  };
}

function extractConstraintsFromSnapshot(
  snapshot: CoachProfileInsightsRequest["snapshot"] | CoachChatRequest["snapshot"]
): ProgramCommentConstraints {
  return extractProgramCommentConstraints(
    snapshot?.coachAnalysisSettings.programComment
  );
}

function filterFrequencyStructureText(
  values: string[],
  constraints: ProgramCommentConstraints
): string[] {
  if (!hasFrequencyStructureGuardrails(constraints)) {
    return dedupeText(values).slice(0, 8);
  }

  return dedupeText(
    values.filter((value) => !shouldBlockFrequencyStructureText(value, constraints))
  ).slice(0, 8);
}

function filterChatAnswerMarkdown(
  answerMarkdown: string,
  constraints: ProgramCommentConstraints,
  locale: string,
  derivedAnalytics?: CoachDerivedAnalytics
): string {
  const sanitizedAnswer = sanitizeChatAnswerMarkdown(answerMarkdown);

  if (!hasFrequencyStructureGuardrails(constraints) && !derivedAnalytics) {
    return sanitizedAnswer;
  }

  const lines = sanitizedAnswer
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean)
    .filter((line) => !shouldBlockFrequencyStructureText(line, constraints))
    .filter((line) => !shouldBlockUnsupportedClaimText(line, derivedAnalytics));

  if (lines.length > 0) {
    return lines.join("\n\n");
  }

  return localizedCoachText(locale, "commentConstraintAcknowledged");
}

function sanitizeChatAnswerMarkdown(answerMarkdown: string): string {
  const normalized = answerMarkdown.replace(/\r\n/g, "\n").trim();
  if (!normalized) {
    return "";
  }

  const cleanedLines: string[] = [];
  let insideCodeFence = false;

  for (const rawLine of normalized.split("\n")) {
    const line = rawLine.trimEnd();
    const trimmed = line.trim();

    if (trimmed.startsWith("```")) {
      insideCodeFence = !insideCodeFence;
      continue;
    }

    if (insideCodeFence) {
      continue;
    }

    if (!trimmed) {
      cleanedLines.push("");
      continue;
    }

    if (trimmed.toLowerCase() === "markdown") {
      continue;
    }

    if (looksLikeStructuredChangeLine(trimmed)) {
      continue;
    }

    cleanedLines.push(line);
  }

  const collapsed = cleanedLines
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  return collapsed || normalized;
}

function looksLikeStructuredChangeLine(line: string): boolean {
  return /^(?:[-*]\s*)?(?:setWeeklyWorkoutTarget|addWorkoutDay|deleteWorkoutDay|swapWorkoutExercise|updateTemplateExercisePrescription)\s*:/i
    .test(line);
}

function hasFrequencyStructureGuardrails(
  constraints: ProgramCommentConstraints
): boolean {
  return (
    constraints.rollingSplitExecution ||
    constraints.preserveWeeklyFrequency ||
    constraints.preserveProgramWorkoutCount
  );
}

function shouldBlockFrequencyStructureText(
  value: string,
  constraints: ProgramCommentConstraints
): boolean {
  if (!hasFrequencyStructureGuardrails(constraints)) {
    return false;
  }

  const normalized = value.trim();
  if (!normalized) {
    return false;
  }

  const blockStructure =
    constraints.rollingSplitExecution || constraints.preserveProgramWorkoutCount;
  const blockFrequency = constraints.preserveWeeklyFrequency;

  const structurePatterns = [
    /\bsaved\s+program\s+has\b.*\bworkouts?\b.*\bweekly\s+target\b/i,
    /\bprogram\b.*\bhas\b.*\bworkouts?\b.*\bweekly\s+target\b/i,
    /\b(?:saved|current)\s+program\b.*\bworkout\s+days?\b.*\bweekly\s+target\b/i,
    /\bworkout\s+days?\b.*\bweekly\s+target\b/i,
    /\badd\b.*\bworkout\s+day\b/i,
    /\bremove\b.*\bworkout\s+day\b/i,
    /в\s+программ[ее]\b.*трениров/i,
    /добавить.*тренировочн(?:ый|ого)\s+день/i,
    /удалить.*тренировочн(?:ый|ого)\s+день/i,
  ];
  const frequencyPatterns = [
    /\bkeep\b.*\b(?:sessions?|workouts?)\s+(?:per|a)\s+week\b/i,
    /\b(?:increase|decrease|adjust|change|update|set)\b.*\b(?:sessions?|workouts?)\s+(?:per|a)\s+week\b/i,
    /\bweekly\s+(?:training\s+)?target\b/i,
    /держите.*частот/i,
    /(?:увелич|сниз|измен|скоррект|обнов).*(?:трениров|занят).*(?:в\s+недел|\/нед)/i,
    /недельн(?:ая|ую)\s+цель/i,
  ];

  if (
    blockStructure &&
    structurePatterns.some((pattern) => pattern.test(normalized))
  ) {
    return true;
  }

  if (
    blockFrequency &&
    frequencyPatterns.some((pattern) => pattern.test(normalized))
  ) {
    return true;
  }

  return false;
}

function filterUnsupportedClaimText(
  values: string[],
  derivedAnalytics?: CoachDerivedAnalytics
): string[] {
  return dedupeText(
    values.filter((value) => !shouldBlockUnsupportedClaimText(value, derivedAnalytics))
  ).slice(0, 8);
}

function shouldBlockUnsupportedClaimText(
  value: string,
  derivedAnalytics?: CoachDerivedAnalytics
): boolean {
  if (!derivedAnalytics) {
    return false;
  }

  const normalized = value.trim();
  if (!normalized) {
    return false;
  }

  const mismatchPatterns = [
    /\bmismatch\b/i,
    /\bprogram\b.*\bdoes not match\b/i,
    /\bsaved\s+program\b.*\bweekly\s+target\b/i,
    /несоответств/i,
  ];
  const muscleFrequencyPatterns = [
    /\b(?:chest|back|legs|shoulders|arms|core)\b.*\b(?:once|twice|\d+\s*(?:x|times?))\b.*\b(?:per|a)\s+week\b/i,
    /\b(?:train|hit)\b.*\b(?:chest|back|legs|shoulders|arms|core)\b.*\b(?:per|a)\s+week\b/i,
    /\b(?:груд|спин|ног|плеч|рук|кор)\w*\b.*(?:раз|раза)\s+в\s+недел/i,
  ];
  const laggingPatterns = [
    /\blagging\b/i,
    /\bundertrained\b/i,
    /\bimbalanc(?:e|ed)\b/i,
    /отстающ/i,
    /дисбаланс/i,
  ];

  if (
    !derivedAnalytics.splitExecution.shouldTreatProgramCountAsMismatch &&
    mismatchPatterns.some((pattern) => pattern.test(normalized))
  ) {
    return true;
  }

  if (
    !derivedAnalytics.supportedClaims.muscleExposure &&
    muscleFrequencyPatterns.some((pattern) => pattern.test(normalized))
  ) {
    return true;
  }

  if (
    !derivedAnalytics.supportedClaims.laggingCandidates &&
    laggingPatterns.some((pattern) => pattern.test(normalized))
  ) {
    return true;
  }

  return false;
}

function formatLoad(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

function extractPlainText(rawResponse: unknown, label: string): string {
  const payload = extractResponsePayload(rawResponse, label);
  if (typeof payload === "string") {
    const trimmed = payload.trim();
    if (trimmed) {
      return trimmed;
    }
  }

  if (isRecord(payload)) {
    const answerMarkdown = payload.answerMarkdown;
    if (typeof answerMarkdown === "string" && answerMarkdown.trim()) {
      return answerMarkdown.trim();
    }
  }

  throw new CoachInferenceServiceError(
    502,
    "upstream_empty_output",
    `Workers AI returned empty ${label} output`
  );
}

function extractUsage(rawResponse: unknown): unknown {
  if (!isRecord(rawResponse)) {
    return undefined;
  }

  if (rawResponse.usage !== undefined) {
    return rawResponse.usage;
  }

  if (isRecord(rawResponse.result) && rawResponse.result.usage !== undefined) {
    return rawResponse.result.usage;
  }

  if (rawResponse.metrics !== undefined) {
    return rawResponse.metrics;
  }

  return undefined;
}

function extractResponsePayload(rawResponse: unknown, label: string): unknown {
  if (typeof rawResponse === "string") {
    const trimmed = rawResponse.trim();
    if (trimmed) {
      return trimmed;
    }
  }

  if (isRecord(rawResponse)) {
    if (rawResponse.response !== undefined) {
      return rawResponse.response;
    }

    if (isRecord(rawResponse.result) && rawResponse.result.response !== undefined) {
      return rawResponse.result.response;
    }

    if (typeof rawResponse.output_text === "string" && rawResponse.output_text.trim()) {
      return rawResponse.output_text;
    }

    const choiceContent = extractChoiceMessageContent(rawResponse);
    if (choiceContent !== undefined) {
      return choiceContent;
    }

    if (isRecord(rawResponse.result)) {
      const nestedChoiceContent = extractChoiceMessageContent(rawResponse.result);
      if (nestedChoiceContent !== undefined) {
        return nestedChoiceContent;
      }
    }
  }

  throw new CoachInferenceServiceError(
    502,
    "upstream_empty_output",
    `Workers AI returned empty ${label} output`,
    {
      responseShape: describeResponseShape(rawResponse),
    }
  );
}

function parseJSONPayload(payload: string, label: string): unknown {
  const trimmed = normalizePotentialJSON(payload);
  if (!trimmed) {
    throw new CoachInferenceServiceError(
      502,
      "upstream_empty_output",
      `Workers AI returned empty ${label} output`
    );
  }

  try {
    return JSON.parse(trimmed);
  } catch {
    throw new CoachInferenceServiceError(
      502,
      "upstream_invalid_json",
      `Workers AI returned invalid ${label} JSON`,
      {
        payloadPreview: trimmed.slice(0, 200),
      }
    );
  }
}

function extractChoiceMessageContent(payload: unknown): unknown {
  if (!isRecord(payload) || !Array.isArray(payload.choices)) {
    return undefined;
  }

  const firstChoice = payload.choices[0];
  if (!isRecord(firstChoice)) {
    return undefined;
  }

  const message = firstChoice.message;
  if (!isRecord(message)) {
    return undefined;
  }

  const content = message.content;
  if (typeof content === "string") {
    const trimmed = content.trim();
    return trimmed ? trimmed : undefined;
  }

  if (Array.isArray(content)) {
    const text = content
      .map((item) => {
        if (typeof item === "string") {
          return item;
        }
        if (isRecord(item) && typeof item.text === "string") {
          return item.text;
        }
        return "";
      })
      .join("")
      .trim();

    return text || undefined;
  }

  return undefined;
}

function normalizeWorkersAIError(
  error: unknown,
  details: Record<string, unknown>
): CoachInferenceServiceError {
  if (error instanceof CoachInferenceServiceError) {
    return error;
  }
  const message =
    error instanceof Error ? error.message : "Unknown Workers AI error";
  const normalizedMessage = message.toLowerCase();

  if (
    normalizedMessage.includes("timeout") ||
    normalizedMessage.includes("timed out") ||
    normalizedMessage.includes("deadline")
  ) {
    return new CoachInferenceServiceError(
      504,
      "upstream_timeout",
      "Workers AI request timed out",
      {
        ...details,
        providerMessage: message.slice(0, 200),
      }
    );
  }

  return new CoachInferenceServiceError(
    502,
    "upstream_request_failed",
    "Workers AI request failed",
    {
      ...details,
      providerMessage: message.slice(0, 200),
    }
  );
}

function createGeminiAIAdapter(env: Env): WorkersAI {
  return {
    async run(model: string, inputs: Record<string, unknown>): Promise<unknown> {
      const apiKey = env.GEMINI_API_KEY?.trim();
      if (!apiKey) {
        throw new CoachInferenceServiceError(
          503,
          "provider_not_configured",
          "Gemini provider is not configured",
          { provider: "gemini", model }
        );
      }

      const baseURL =
        env.GEMINI_API_BASE_URL?.trim() ||
        "https://generativelanguage.googleapis.com/v1beta";
      const payload = buildGeminiRequestPayload(inputs);
      for (let attempt = 0; attempt <= GEMINI_MAX_RATE_LIMIT_RETRIES; attempt += 1) {
        const response = await fetch(
          `${baseURL}/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`,
          {
            method: "POST",
            headers: {
              "content-type": "application/json",
            },
            body: JSON.stringify(payload),
          }
        );

        const responseText = await response.text();
        const responseJSON = responseText ? safeJSONParse(responseText) : undefined;
        if (!response.ok) {
          const retryDelayMs = resolveGeminiRetryDelayMs(responseJSON);
          if (response.status === 429 && attempt < GEMINI_MAX_RATE_LIMIT_RETRIES) {
            const backoffMs = Math.min(
              retryDelayMs ?? GEMINI_BASE_RETRY_DELAY_MS * (attempt + 1),
              GEMINI_MAX_RETRY_DELAY_MS
            );
            console.warn(
              JSON.stringify({
                event: "coach_gemini_retry_scheduled",
                provider: "gemini",
                model,
                status: response.status,
                retryAttempt: attempt + 1,
                retryDelayMs: backoffMs,
              })
            );
            await sleep(backoffMs);
            continue;
          }

          throw normalizeGeminiHTTPError(response.status, responseJSON, {
            provider: "gemini",
            model,
            retryAttemptCount: attempt,
            retryDelayMs,
          });
        }

        const candidateText = extractGeminiText(responseJSON);
        if (!candidateText) {
          throw new CoachInferenceServiceError(
            502,
            "upstream_empty_output",
            "Gemini returned empty output",
            {
              provider: "gemini",
              model,
              responseShape: describeResponseShape(responseJSON),
            }
          );
        }

        return {
          response: candidateText,
          usage: isRecord(responseJSON) ? responseJSON.usageMetadata : undefined,
          response_id:
            isRecord(responseJSON) && typeof responseJSON.responseId === "string"
              ? responseJSON.responseId
              : undefined,
          provider: "gemini",
        };
      }

      throw new CoachInferenceServiceError(
        503,
        "provider_unavailable",
        "Gemini provider is unavailable",
        { provider: "gemini", model }
      );
    },
  };
}

function buildGeminiRequestPayload(
  inputs: Record<string, unknown>
): Record<string, unknown> {
  const messages = Array.isArray(inputs.messages) ? (inputs.messages as PromptMessage[]) : [];
  const systemMessages = messages
    .filter((message) => message.role === "system")
    .map((message) => message.content.trim())
    .filter(Boolean);
  const nonSystemMessages = messages.filter((message) => message.role !== "system");
  const contents = nonSystemMessages.map((message) => ({
    role: message.role === "assistant" ? "model" : "user",
    parts: [{ text: message.content }],
  }));
  const generationConfig: Record<string, unknown> = {};
  if (typeof inputs.max_tokens === "number") {
    generationConfig.maxOutputTokens = inputs.max_tokens;
  }
  if (typeof inputs.temperature === "number") {
    generationConfig.temperature = inputs.temperature;
  }

  const jsonSchema = extractGeminiResponseSchema(inputs);
  if (jsonSchema) {
    generationConfig.responseMimeType = "application/json";
    generationConfig.responseJsonSchema = jsonSchema;
  }

  return {
    contents,
    ...(systemMessages.length > 0
      ? {
          systemInstruction: {
            parts: [{ text: systemMessages.join("\n\n") }],
          },
        }
      : {}),
    generationConfig,
  };
}

function extractGeminiResponseSchema(
  inputs: Record<string, unknown>
): Record<string, unknown> | undefined {
  if (
    isRecord(inputs.response_format) &&
    isRecord(inputs.response_format.json_schema) &&
    isRecord(inputs.response_format.json_schema.schema)
  ) {
    return inputs.response_format.json_schema.schema as Record<string, unknown>;
  }
  if (isRecord(inputs.guided_json)) {
    return inputs.guided_json as Record<string, unknown>;
  }
  return undefined;
}

function normalizeGeminiHTTPError(
  status: number,
  payload: unknown,
  details: Record<string, unknown>
): CoachInferenceServiceError {
  const errorPayload = isRecord(payload) && isRecord(payload.error) ? payload.error : undefined;
  const providerMessage =
    errorPayload && typeof errorPayload.message === "string"
      ? errorPayload.message.slice(0, 300)
      : `Gemini request failed with status ${status}`;
  const providerStatus =
    errorPayload && typeof errorPayload.status === "string"
      ? errorPayload.status
      : undefined;

  if (status === 401 || status === 403) {
    return new CoachInferenceServiceError(
      503,
      "provider_auth_failed",
      "Gemini authentication failed",
      { ...details, providerMessage, providerStatus }
    );
  }
  if (status === 429) {
    return new CoachInferenceServiceError(
      429,
      "provider_rate_limited",
      "Gemini quota or rate limit exceeded",
      { ...details, providerMessage, providerStatus }
    );
  }
  if (status === 400 || status === 404) {
    return new CoachInferenceServiceError(
      502,
      "provider_unsupported_request",
      "Gemini rejected the request",
      { ...details, providerMessage, providerStatus }
    );
  }
  if (status >= 500) {
    return new CoachInferenceServiceError(
      503,
      "provider_unavailable",
      "Gemini provider is unavailable",
      { ...details, providerMessage, providerStatus }
    );
  }

  return new CoachInferenceServiceError(
    502,
    "upstream_request_failed",
    "Gemini request failed",
    { ...details, providerMessage, providerStatus }
  );
}

function resolveGeminiRetryDelayMs(payload: unknown): number | undefined {
  if (!isRecord(payload) || !isRecord(payload.error) || !Array.isArray(payload.error.details)) {
    return undefined;
  }

  for (const detail of payload.error.details) {
    if (!isRecord(detail)) {
      continue;
    }

    const retryDelayValue =
      typeof detail.retryDelay === "string"
        ? detail.retryDelay
        : isRecord(detail.retryInfo) && typeof detail.retryInfo.retryDelay === "string"
          ? detail.retryInfo.retryDelay
          : undefined;
    const parsed = retryDelayValue ? parseGoogleDurationMs(retryDelayValue) : undefined;
    if (parsed !== undefined) {
      return parsed;
    }
  }

  return undefined;
}

function parseGoogleDurationMs(value: string): number | undefined {
  const match = value.match(/^(\d+)(?:\.(\d{1,9}))?s$/);
  if (!match) {
    return undefined;
  }

  const seconds = Number.parseInt(match[1] ?? "0", 10);
  const nanos = Number.parseInt((match[2] ?? "").padEnd(9, "0"), 10);
  return seconds * 1_000 + Math.floor(nanos / 1_000_000);
}

function extractGeminiText(payload: unknown): string | undefined {
  if (!isRecord(payload) || !Array.isArray(payload.candidates)) {
    return undefined;
  }
  const candidate = payload.candidates[0];
  if (!isRecord(candidate) || !isRecord(candidate.content) || !Array.isArray(candidate.content.parts)) {
    return undefined;
  }
  const text = candidate.content.parts
    .map((part) => (isRecord(part) && typeof part.text === "string" ? part.text : ""))
    .join("")
    .trim();
  return text || undefined;
}

function safeJSONParse(value: string): unknown {
  try {
    return JSON.parse(value);
  } catch {
    return undefined;
  }
}

function parseTimeoutMs(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return value;
  }

  return 12_000;
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  let timeoutHandle: ReturnType<typeof setTimeout> | undefined;

  try {
    return await Promise.race([
      promise,
      new Promise<T>((_, reject) => {
        timeoutHandle = setTimeout(() => {
          reject(
            new Error(`Workers AI request timed out after ${timeoutMs}ms`)
          );
        }, timeoutMs);
      }),
    ]);
  } finally {
    if (timeoutHandle !== undefined) {
      clearTimeout(timeoutHandle);
    }
  }
}

async function sleep(delayMs: number): Promise<void> {
  if (!Number.isFinite(delayMs) || delayMs <= 0) {
    return;
  }

  await new Promise<void>((resolve) => {
    setTimeout(resolve, delayMs);
  });
}

function normalizePotentialJSON(payload: string): string {
  const trimmed = payload.trim();
  if (!trimmed) {
    return trimmed;
  }

  if (trimmed.startsWith("```")) {
    const withoutOpeningFence = trimmed.replace(/^```(?:json)?\s*/i, "");
    return withoutOpeningFence.replace(/\s*```$/, "").trim();
  }

  const objectStart = trimmed.indexOf("{");
  const objectEnd = trimmed.lastIndexOf("}");
  if (objectStart >= 0 && objectEnd > objectStart) {
    return trimmed.slice(objectStart, objectEnd + 1).trim();
  }

  const arrayStart = trimmed.indexOf("[");
  const arrayEnd = trimmed.lastIndexOf("]");
  if (arrayStart >= 0 && arrayEnd > arrayStart) {
    return trimmed.slice(arrayStart, arrayEnd + 1).trim();
  }

  return trimmed;
}

function describeResponseShape(rawResponse: unknown): Record<string, unknown> {
  if (!isRecord(rawResponse)) {
    return {
      rawType: typeof rawResponse,
    };
  }

  const response = rawResponse.response;
  const resultResponse =
    isRecord(rawResponse.result) ? rawResponse.result.response : undefined;
  const effectiveResponse = response ?? resultResponse;

  return {
    rawType: "object",
    topLevelKeys: Object.keys(rawResponse).slice(0, 12),
    responseType: Array.isArray(effectiveResponse)
      ? "array"
      : typeof effectiveResponse,
    responseKeys: isRecord(effectiveResponse)
      ? Object.keys(effectiveResponse).slice(0, 12)
      : undefined,
  };
}

function byteLength(value: unknown): number {
  return new TextEncoder().encode(JSON.stringify(value)).length;
}

function totalTurnCharacters(turns: CoachChatRequest["clientRecentTurns"]): number {
  return turns.reduce((total, turn) => total + turn.content.length, 0);
}

function remainingProfileInsightsBudgetMs(
  startedAt: number,
  totalBudgetMs: number
): number {
  return Math.max(totalBudgetMs - (Date.now() - startedAt), 0);
}

function remainingWorkoutSummaryBudgetMs(
  startedAt: number,
  totalBudgetMs: number
): number {
  return Math.max(totalBudgetMs - (Date.now() - startedAt), 0);
}

function remainingChatBudgetMs(startedAt: number, totalBudgetMs: number): number {
  return Math.max(totalBudgetMs - (Date.now() - startedAt), 0);
}

function buildDegradedChatResult(input: {
  provider: CoachAIProvider;
  request: CoachChatRequest;
  responseId: string;
  fallback: Omit<CoachChatResponse, "responseID">;
  model: string;
  selectedModel?: string;
  modelRole?: CoachModelRole;
  useCase?: CoachRoutingUseCase;
  routingVersion?: string;
  payloadTier?: CoachPayloadTier;
  contextProfile?: CoachContextProfile;
  memoryCompatibilityKey?: string;
  routingReasonTags?: string[];
  fallbackHopCount?: number;
  fallbackReason?: string;
  mode: string;
  startedAt: number;
  derivedAnalytics?: CoachDerivedAnalytics;
  errors: CoachInferenceServiceError[];
  promptBytes?: number;
  fallbackPromptBytes?: number;
  modelDurationMs?: number;
  fallbackModelDurationMs?: number;
}): InferenceResult<CoachChatResponse> {
  const promptBytes = input.promptBytes ?? input.errors
    .map((error) => resolvePromptBytes(error.details))
    .find((value): value is number => value !== undefined);

  return {
    data: {
      ...applyChatGuardrails(
        input.request,
        input.fallback,
        input.derivedAnalytics
      ),
      responseID: input.responseId,
    },
    provider: input.provider,
    responseId: input.responseId,
    model: input.model,
    selectedModel: input.selectedModel ?? input.model,
    modelRole: input.modelRole,
    useCase: input.useCase,
    routingVersion: input.routingVersion,
    payloadTier: input.payloadTier,
    contextProfile: input.contextProfile,
    memoryCompatibilityKey: input.memoryCompatibilityKey,
    routingReasonTags: input.routingReasonTags,
    fallbackHopCount: input.fallbackHopCount,
    fallbackReason: input.fallbackReason,
    mode: input.mode,
    promptBytes,
    fallbackPromptBytes: input.fallbackPromptBytes,
    modelDurationMs:
      input.modelDurationMs ?? Date.now() - input.startedAt,
    fallbackModelDurationMs: input.fallbackModelDurationMs,
  };
}

function resolvePromptBytes(
  details?: Record<string, unknown>
): number | undefined {
  const value = details?.promptBytes;
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function resolveModelDurationMs(
  details?: Record<string, unknown>
): number | undefined {
  const value = details?.modelDurationMs;
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function formatFallbackMarkdown(summary: string, bullets: string[]): string {
  const markdownBullets = bullets.map((bullet) => `- ${bullet}`);
  return [summary, ...markdownBullets].join("\n\n");
}

function localizedCoachText(
  locale: string,
  key:
    | "summaryAligned"
    | "summaryAdjustments"
    | "frequencyRange"
    | "repRange"
    | "volumeRange"
    | "consistencyGap"
    | "streak"
    | "etaWeeks"
    | "etaMonths"
    | "etaRecommendation"
    | "draftWeeklyTargetTitle"
    | "draftWeeklyTargetSummary"
    | "draftAddDayTitle"
    | "draftAddDaySummary"
    | "draftAddDayWorkoutTitle"
    | "draftDeleteDayTitle"
    | "draftDeleteDaySummary"
    | "fallbackSummary"
    | "fallbackCommentGuardrail"
    | "fallbackRecentPR"
    | "fallbackProgressionBaseline"
    | "commentConstraintAcknowledged",
  params: Record<string, string | number> = {}
): string {
  const ru = locale.toLowerCase().startsWith("ru");
  const templates: Record<string, string> = ru
    ? {
        summaryAligned:
          "Текущий план в целом соответствует вашей цели. Ниже самые полезные корректировки для прогресса и соблюдения режима.",
        summaryAdjustments:
          "Текущий план требует корректировки по %count% пунктам, чтобы лучше соответствовать вашей цели.",
        frequencyRange:
          "Держите частоту в диапазоне %lower%-%upper% тренировок в неделю.",
        repRange:
          "Для базовых движений ориентируйтесь на %mainLower%-%mainUpper% повторений, для аксессуаров на %accessoryLower%-%accessoryUpper%.",
        volumeRange:
          "Цельтесь в %lower%-%upper% рабочих подходов на основную мышечную группу в неделю.",
        consistencyGap:
          "На этой неделе выполнено %completed% из %target% запланированных тренировок, поэтому сейчас важнее стабильность, чем добавление нагрузки.",
        streak:
          "У вас серия из %weeks% недель подряд. Сохраняйте этот ритм и повышайте нагрузку постепенно.",
        etaWeeks: "%lower%-%upper% недель",
        etaMonths: "%lower%-%upper% мес.",
        etaRecommendation:
          "При текущем темпе ориентир по цели составляет примерно %eta%.",
        draftWeeklyTargetTitle: "Скорректировать недельную частоту",
        draftWeeklyTargetSummary:
          "Обновить недельную цель до %target% тренировок, чтобы она лучше соответствовала текущей нагрузке и восстановлению.",
        draftAddDayTitle: "Добавить тренировочный день",
        draftAddDaySummary:
          "Добавить ещё один день в программу \"%programTitle%\", чтобы приблизить её к рекомендуемой частоте.",
        draftAddDayWorkoutTitle: "Тренировка %index%",
        draftDeleteDayTitle: "Убрать лишний тренировочный день",
        draftDeleteDaySummary:
          "Удалить день \"%workoutTitle%\", чтобы программа лучше соответствовала целевой частоте.",
        fallbackSummary:
          "Сводка построена по фактическим данным журнала и сохранённому описанию того, как вы реально выполняете программу.",
        fallbackCommentGuardrail:
          "Сохраняйте текущую ротацию и недельный ритм, если именно так вы реально выполняете программу.",
        fallbackRecentPR:
          "Недавний прирост по упражнению \"%exercise%\" на %delta% кг показывает, что текущая прогрессия работает.",
        fallbackProgressionBaseline:
          "Ориентируйтесь на последние завершённые тренировки и повышайте нагрузку только там, где повторы были уверенно повторяемыми.",
        commentConstraintAcknowledged:
          "Учту вашу сохранённую заметку и не буду предлагать менять недельную частоту или количество тренировочных дней в программе.",
      }
    : {
        summaryAligned:
          "Your current plan broadly matches your goal. Below are the highest-value adjustments for progress and adherence.",
        summaryAdjustments:
          "Your current plan needs %count% adjustments to better match your goal.",
        frequencyRange:
          "Keep training frequency around %lower%-%upper% sessions per week.",
        repRange:
          "Keep main lifts around %mainLower%-%mainUpper% reps and accessories around %accessoryLower%-%accessoryUpper% reps.",
        volumeRange:
          "Aim for roughly %lower%-%upper% hard sets per muscle group each week.",
        consistencyGap:
          "You completed %completed% of %target% planned sessions this week, so consistency matters more than extra load right now.",
        streak:
          "You have a %weeks%-week consistency streak. Keep that rhythm and progress load gradually.",
        etaWeeks: "%lower%-%upper% weeks",
        etaMonths: "%lower%-%upper% months",
        etaRecommendation:
          "At the current pace, your goal timeline looks roughly like %eta%.",
        draftWeeklyTargetTitle: "Adjust weekly training target",
        draftWeeklyTargetSummary:
          "Update the weekly target to %target% sessions so it better matches your current workload and recovery.",
        draftAddDayTitle: "Add a workout day",
        draftAddDaySummary:
          "Add another day to \"%programTitle%\" so the program better matches the recommended frequency.",
        draftAddDayWorkoutTitle: "Workout %index%",
        draftDeleteDayTitle: "Remove an extra workout day",
        draftDeleteDaySummary:
          "Remove \"%workoutTitle%\" so the program better matches the target frequency.",
        fallbackSummary:
          "This summary is based on factual training data and on your saved note about how you actually run the program.",
        fallbackCommentGuardrail:
          "Keep the current rotation and weekly rhythm if that reflects how you actually run the program.",
        fallbackRecentPR:
          "A recent improvement on \"%exercise%\" of %delta% kg suggests the current progression is working.",
        fallbackProgressionBaseline:
          "Use the most recent completed sessions as the baseline and add load only where the previous work looked repeatable.",
        commentConstraintAcknowledged:
          "I will respect your saved note and avoid recommending changes to weekly frequency or to the number of workout days in the program.",
      };

  return Object.entries(params).reduce(
    (text, [name, value]) => text.replaceAll(`%${name}%`, String(value)),
    templates[key]
  );
}

function buildGoalEtaRecommendation(
  locale: string,
  goal: NonNullable<CoachProfileInsightsRequest["snapshot"]>["analytics"]["goal"]
): string | undefined {
  if (
    goal.etaWeeksLowerBound === undefined ||
    goal.etaWeeksUpperBound === undefined
  ) {
    return undefined;
  }

  const etaText =
    goal.etaWeeksUpperBound >= 8
      ? localizedCoachText(locale, "etaMonths", {
          lower: Math.max(Math.ceil(goal.etaWeeksLowerBound / 4.345), 1),
          upper: Math.max(Math.ceil(goal.etaWeeksUpperBound / 4.345), 1),
        })
      : localizedCoachText(locale, "etaWeeks", {
          lower: goal.etaWeeksLowerBound,
          upper: goal.etaWeeksUpperBound,
        });

  return localizedCoachText(locale, "etaRecommendation", {
    eta: etaText,
  });
}

function localizedWorkoutFocus(locale: string, goal: string): string {
  const ru = locale.toLowerCase().startsWith("ru");

  switch (goal) {
    case "strength":
      return ru ? "Силовой акцент" : "Strength focus";
    case "hypertrophy":
      return ru ? "Гипертрофия" : "Hypertrophy focus";
    case "fatLoss":
      return ru ? "Расход энергии и объём" : "Energy expenditure and volume";
    case "generalFitness":
      return ru ? "Общая физическая подготовка" : "General fitness";
    default:
      return ru ? "Дополнительная тренировка" : "Additional training day";
  }
}

function clamp(value: number, lower: number, upper: number): number {
  return Math.min(Math.max(value, lower), upper);
}

export function buildOpaqueResponseID(): string {
  return `coach-turn_${crypto.randomUUID()}`;
}

function parseBulletRecommendation(line: string): string | undefined {
  const match = line.match(/^\s*(?:[-*•]|\d+[.)])\s+(.+?)\s*$/);
  if (!match?.[1]) {
    return undefined;
  }

  const cleaned = cleanPlainParagraph(match[1]);
  return cleaned || undefined;
}

function cleanPlainParagraph(text: string): string {
  const joined = text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .filter((line) => !isSectionHeading(line))
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();

  return stripKnownLabel(joined);
}

function isSectionHeading(line: string): boolean {
  const normalized = stripMarkdownPrefix(line)
    .replace(/[:：]\s*$/, "")
    .trim()
    .toLowerCase();

  return [
    "summary",
    "coach summary",
    "recommendations",
    "recommendation",
    "key recommendations",
    "сводка",
    "итог",
    "рекомендации",
  ].includes(normalized);
}

function stripKnownLabel(text: string): string {
  return stripMarkdownPrefix(text)
    .replace(
      /^(?:summary|coach summary|recommendations?|key recommendations|сводка|итог|рекомендации)\s*[:：-]\s*/i,
      ""
    )
    .trim();
}

function stripMarkdownPrefix(text: string): string {
  return text
    .replace(/^#{1,6}\s*/, "")
    .replace(/^[-*•]\s+/, "")
    .replace(/^\*\*(.+)\*\*$/, "$1")
    .replace(/^__(.+)__$/, "$1")
    .trim();
}

function looksLikeRecommendationSection(text: string): boolean {
  const normalized = text.toLowerCase();
  return (
    normalized.startsWith("recommendation") ||
    normalized.startsWith("key recommendation") ||
    normalized.startsWith("рекомендац")
  );
}

function parseLabeledSections(lines: string[]): Record<string, string> {
  const sections: Record<string, string> = {};
  let currentKey: string | undefined;

  for (const rawLine of lines) {
    const line = rawLine.trimEnd();
    const match = line.match(
      /^(Headline|Summary|Highlights|Next workout focus)\s*:\s*(.*)$/i
    );

    if (match) {
      currentKey = normalizeSectionKey(match[1] ?? "");
      sections[currentKey] = (match[2] ?? "").trim();
      continue;
    }

    if (!currentKey) {
      continue;
    }

    sections[currentKey] = [sections[currentKey], line.trim()]
      .filter(Boolean)
      .join("\n");
  }

  return sections;
}

function normalizeSectionKey(value: string): string {
  switch (value.trim().toLowerCase()) {
    case "headline":
      return "headline";
    case "summary":
      return "summary";
    case "highlights":
      return "highlights";
    case "next workout focus":
      return "nextWorkoutFocus";
    default:
      return value.trim();
  }
}

function extractSectionBullets(section: string | undefined): string[] {
  if (!section) {
    return [];
  }

  const bulletLines = section
    .split("\n")
    .map((line) => parseBulletRecommendation(line))
    .filter((value): value is string => Boolean(value));

  if (bulletLines.length > 0) {
    return bulletLines;
  }

  return section
    .split(/\n+/)
    .map((line) => cleanPlainParagraph(line))
    .filter(Boolean);
}

function buildWorkoutSummaryExerciseProgressHighlight(
  request: CoachWorkoutSummaryJobCreateRequest,
  exerciseID: string
): string | undefined {
  const locale = request.locale.toLowerCase().startsWith("ru") ? "ru" : "en";
  const currentExercise = request.currentWorkout.exercises.find(
    (exercise) => exercise.exerciseID === exerciseID
  );
  const history = request.recentExerciseHistory.find(
    (exercise) => exercise.exerciseID === exerciseID
  );

  if (!currentExercise || !history || history.sessions.length === 0) {
    return undefined;
  }

  const currentBestWeight = currentExercise.sets
    .filter((set) => set.isCompleted && set.weight > 0)
    .reduce((best, set) => Math.max(best, set.weight), 0);
  const historicalBestWeight = history.sessions
    .map((session) => session.bestWeight ?? 0)
    .reduce((best, value) => Math.max(best, value), 0);

  if (currentBestWeight > 0 && currentBestWeight >= historicalBestWeight) {
    return locale === "ru"
      ? `${currentExercise.exerciseName} вышло на лучший недавний вес: ${formatLoad(currentBestWeight)} кг.`
      : `${currentExercise.exerciseName} matched or exceeded your best recent load at ${formatLoad(currentBestWeight)} kg.`;
  }

  const latestAverageReps = history.sessions[0]?.averageReps;
  if (latestAverageReps !== undefined) {
    return locale === "ru"
      ? `${currentExercise.exerciseName} можно сравнивать с недавней базой около ${formatLoad(latestAverageReps)} повторений в среднем за сет.`
      : `${currentExercise.exerciseName} can be compared against a recent baseline of about ${formatLoad(latestAverageReps)} reps per set.`;
  }

  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

type PromptMessage = {
  role: "system" | "user" | "assistant";
  content: string;
};

function dedupeText(values: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];

  for (const value of values.map((item) => item.trim()).filter(Boolean)) {
    if (seen.has(value)) {
      continue;
    }

    seen.add(value);
    result.push(value);
  }

  return result;
}

const profileInsightsResponseJsonSchema = {
  type: "object",
  properties: {
    summary: {
      type: "string",
    },
    recommendations: {
      type: "array",
      items: {
        type: "string",
      },
    },
  },
  required: ["summary", "recommendations"],
  additionalProperties: false,
} as const;

const chatResponseJsonSchema = {
  type: "object",
  properties: {
    answerMarkdown: {
      type: "string",
    },
    followUps: {
      type: "array",
      items: {
        type: "string",
      },
    },
  },
  required: ["answerMarkdown", "followUps"],
  additionalProperties: false,
} as const;

const workoutSummaryResponseJsonSchema = {
  type: "object",
  properties: {
    headline: {
      type: "string",
    },
    summary: {
      type: "string",
    },
    highlights: {
      type: "array",
      items: {
        type: "string",
      },
    },
    nextWorkoutFocus: {
      type: "array",
      items: {
        type: "string",
      },
    },
  },
  required: ["headline", "summary", "highlights", "nextWorkoutFocus"],
  additionalProperties: false,
} as const;
