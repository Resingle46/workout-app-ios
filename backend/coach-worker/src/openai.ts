import {
  chatResponseModelOutputSchema,
  profileInsightsModelOutputSchema,
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

export const DEFAULT_AI_MODEL = "@cf/mistralai/mistral-small-3.1-24b-instruct";
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
const PROFILE_INSIGHTS_TIMEOUTS = {
  totalBudgetMs: 25_000,
  structuredTimeoutMs: 18_000,
  fallbackTimeoutMs: 5_000,
  fallbackMinTimeoutMs: 3_000,
} as const;
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
}

export interface InferenceResult<T> {
  data: T;
  responseId?: string;
  model: string;
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

export class WorkersAICoachService implements CoachInferenceService {
  constructor(private readonly env: Env) {}
  async generateProfileInsights(
    request: CoachProfileInsightsRequest,
    options: GenerateProfileInsightsOptions = {}
  ): Promise<InferenceResult<CoachProfileInsightsResponse>> {
    const operation = "profile_insights";
    const timeoutProfile = options.timeoutProfile ?? "sync";
    const timeouts =
      timeoutProfile === "async_job" ? ASYNC_LONG_TIMEOUTS : PROFILE_INSIGHTS_TIMEOUTS;
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

    try {
      const invocation = await this.runStructured({
        operation,
        messages: buildProfileInsightsMessages(request, promptExecution),
        schema: profileInsightsResponseJsonSchema,
        maxTokens: structuredMaxTokens,
        timeoutMs: timeouts.structuredTimeoutMs,
        extraDetails: sharedDetails,
      });
      const parsed = normalizeProfileInsightsResponse(
        parseStructuredOutput(
          invocation.rawResponse,
          profileInsightsModelOutputSchema,
          "profile insights",
          {
            operation,
            model: this.modelName,
          }
        )
      );

      return {
        data: applyProfileInsightsGuardrails(
          request,
          {
            ...parsed,
            generationStatus: "model",
            insightSource: "fresh_model",
          },
          localFallback,
          promptExecution.derivedAnalytics
        ),
        model: this.modelName,
        mode: "structured",
        usage: extractUsage(invocation.rawResponse),
        promptBytes: invocation.promptBytes,
        modelDurationMs: invocation.modelDurationMs,
      };
    } catch (error) {
      if (!(error instanceof CoachInferenceServiceError)) {
        throw error;
      }

      if (!shouldAttemptProfilePlainTextFallback(error)) {
        console.warn(
          JSON.stringify({
            event: "coach_profile_local_fallback",
            operation,
            model: this.modelName,
            promptVariant: sharedDetails.promptVariant,
            reasonCode: error.code,
            reasonDetails: error.details,
          })
        );

        return {
          data: localFallback,
          model: this.modelName,
          mode: "local_fallback",
        };
      }

      const remainingBudgetMs = remainingProfileInsightsBudgetMs(
        startedAt,
        timeouts.totalBudgetMs
      );

      console.warn(
        JSON.stringify({
          event: "coach_profile_structured_fallback",
          operation,
          model: this.modelName,
          promptVariant: sharedDetails.promptVariant,
          reasonCode: error.code,
          reasonDetails: error.details,
          remainingBudgetMs,
        })
      );

      if (remainingBudgetMs < timeouts.fallbackMinTimeoutMs) {
        console.warn(
          JSON.stringify({
            event: "coach_profile_local_fallback",
            operation,
            model: this.modelName,
            promptVariant: sharedDetails.promptVariant,
            reasonCode: error.code,
            reasonDetails: error.details,
            degradedReason: "insufficient_fallback_budget",
            remainingBudgetMs,
          })
        );

        return {
          data: localFallback,
          model: this.modelName,
          mode: "local_fallback",
        };
      }

      try {
        const fallbackInvocation = await this.runPlainText({
          operation,
          messages: buildFallbackProfileInsightsMessages(request, promptExecution),
          maxTokens: fallbackMaxTokens,
          timeoutMs: Math.min(timeouts.fallbackTimeoutMs, remainingBudgetMs),
          includeFallbackNotice: false,
          extraDetails: {
            ...sharedDetails,
            fallbackTrigger: error.code,
            remainingBudgetMs,
          },
        });

        return {
          data: applyProfileInsightsGuardrails(
            request,
            {
              ...parsePlainProfileInsights(
                extractPlainText(fallbackInvocation.rawResponse, "profile insights")
              ),
              generationStatus: "model",
              insightSource: "fresh_model",
            },
            localFallback,
            promptExecution.derivedAnalytics
          ),
          model: this.modelName,
          mode: "plain_text_fallback",
          usage: extractUsage(fallbackInvocation.rawResponse),
          promptBytes: fallbackInvocation.promptBytes,
          modelDurationMs: Date.now() - startedAt,
        };
      } catch (fallbackError) {
        if (!(fallbackError instanceof CoachInferenceServiceError)) {
          throw fallbackError;
        }

        console.warn(
          JSON.stringify({
            event: "coach_profile_local_fallback",
            operation,
            model: this.modelName,
            promptVariant: sharedDetails.promptVariant,
            remainingBudgetMs,
            structuredReasonCode: error.code,
            structuredReasonDetails: error.details,
            reasonCode: fallbackError.code,
            reasonDetails: fallbackError.details,
          })
        );
      }

        return {
          data: localFallback,
          model: this.modelName,
          mode: "local_fallback",
        };
    }
  }

  async generateWorkoutSummary(
    request: CoachWorkoutSummaryJobCreateRequest
  ): Promise<InferenceResult<CoachWorkoutSummaryResponse>> {
    const operation = "workout_summary";
    const startedAt = Date.now();
    const localFallback = buildNeutralWorkoutSummary(request);
    const promptExecution = resolvePromptExecution(
      request as CoachWorkoutSummaryJobCreateRequest & CoachMetadataCarrier,
      {},
      "rich_async_v1",
      "workout_summary_rich_async_v1"
    );
    const sharedDetails = {
      promptVariant: promptExecution.promptProfile,
      contextProfile: promptExecution.contextProfile,
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
    };

    try {
      const invocation = await this.runStructured({
        operation,
        messages: buildWorkoutSummaryMessages(request),
        schema: workoutSummaryResponseJsonSchema,
        maxTokens: WORKOUT_SUMMARY_ASYNC_STRUCTURED_MAX_TOKENS,
        timeoutMs: ASYNC_LONG_TIMEOUTS.structuredTimeoutMs,
        extraDetails: sharedDetails,
      });
      const parsed = normalizeWorkoutSummaryResponse(
        parseStructuredOutput(
          invocation.rawResponse,
          workoutSummaryModelOutputSchema,
          "workout summary",
          {
            operation,
            model: this.modelName,
            sessionID: request.sessionID,
            fingerprint: request.fingerprint,
          }
        )
      );

      return {
        data: {
          ...parsed,
          generationStatus: "model",
        },
        model: this.modelName,
        mode: "structured",
        usage: extractUsage(invocation.rawResponse),
        promptBytes: invocation.promptBytes,
        modelDurationMs: invocation.modelDurationMs,
      };
    } catch (error) {
      if (!(error instanceof CoachInferenceServiceError)) {
        throw error;
      }

      if (!shouldAttemptWorkoutSummaryPlainTextFallback(error)) {
        return {
          data: localFallback,
          model: this.modelName,
          mode: "degraded_fallback",
          promptBytes: resolvePromptBytes(error.details),
          modelDurationMs: Date.now() - startedAt,
        };
      }

      const remainingBudgetMs = remainingWorkoutSummaryBudgetMs(
        startedAt,
        ASYNC_LONG_TIMEOUTS.totalBudgetMs
      );

      console.warn(
        JSON.stringify({
          event: "coach_workout_summary_structured_fallback",
          operation,
          model: this.modelName,
          reasonCode: error.code,
          reasonDetails: error.details,
          remainingBudgetMs,
          ...sharedDetails,
        })
      );

      if (remainingBudgetMs < ASYNC_LONG_TIMEOUTS.fallbackMinTimeoutMs) {
        return {
          data: localFallback,
          model: this.modelName,
          mode: "degraded_fallback",
          promptBytes: resolvePromptBytes(error.details),
          modelDurationMs: Date.now() - startedAt,
        };
      }

      try {
        const fallbackInvocation = await this.runPlainText({
          operation,
          messages: buildFallbackWorkoutSummaryMessages(request),
          maxTokens: WORKOUT_SUMMARY_ASYNC_PLAIN_TEXT_MAX_TOKENS,
          timeoutMs: Math.min(
            ASYNC_LONG_TIMEOUTS.fallbackTimeoutMs,
            remainingBudgetMs
          ),
          includeFallbackNotice: false,
          extraDetails: {
            ...sharedDetails,
            fallbackTrigger: error.code,
            remainingBudgetMs,
          },
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
          model: this.modelName,
          mode: "plain_text_fallback",
          usage: extractUsage(fallbackInvocation.rawResponse),
          promptBytes: resolvePromptBytes(error.details),
          fallbackPromptBytes: fallbackInvocation.promptBytes,
          modelDurationMs: resolveModelDurationMs(error.details),
          fallbackModelDurationMs: fallbackInvocation.modelDurationMs,
        };
      } catch (fallbackError) {
        if (!(fallbackError instanceof CoachInferenceServiceError)) {
          throw fallbackError;
        }

        console.warn(
          JSON.stringify({
            event: "coach_workout_summary_degraded_response",
            operation,
            model: this.modelName,
            reasonCode: fallbackError.code,
            reasonDetails: fallbackError.details,
            originalReasonCode: error.code,
            originalReasonDetails: error.details,
            ...sharedDetails,
          })
        );

        return {
          data: localFallback,
          model: this.modelName,
          mode: "degraded_fallback",
          promptBytes: resolvePromptBytes(error.details),
          fallbackPromptBytes: resolvePromptBytes(fallbackError.details),
          modelDurationMs: Date.now() - startedAt,
        };
      }
    }
  }

  async generateChat(
    request: CoachChatRequest,
    options: GenerateChatOptions = {}
  ): Promise<InferenceResult<CoachChatResponse>> {
    const operation = "chat";
    const turnID = options.responseId ?? buildOpaqueResponseID();
    const promptExecution = resolvePromptExecution(
      request,
      options,
      options.timeoutProfile === "async_job"
        ? "rich_async_analytics_v1"
        : "compact_sync_v2",
      options.timeoutProfile === "async_job"
        ? "chat_rich_async_analytics_v1"
        : "chat_compact_sync_v2"
    );
    const messages = buildChatMessages(request, promptExecution);
    const localFallback = buildNeutralChatResponse(
      request,
      promptExecution.derivedAnalytics
    );
    const startedAt = Date.now();
    const timeouts =
      options.timeoutProfile === "async_job"
        ? ASYNC_LONG_TIMEOUTS
        : SYNC_CHAT_TIMEOUTS;
    const sharedDetails = {
      promptVariant: promptExecution.promptProfile,
      contextProfile: promptExecution.contextProfile,
      turnID,
      recentTurnCount: request.clientRecentTurns.length,
      recentTurnChars: totalTurnCharacters(request.clientRecentTurns),
      questionChars: request.question.trim().length,
    };
    const structuredMaxTokens = isRichContextProfile(promptExecution.contextProfile)
      ? CHAT_ASYNC_STRUCTURED_MAX_TOKENS
      : CHAT_STRUCTURED_MAX_TOKENS;
    const fallbackMaxTokens = isRichContextProfile(promptExecution.contextProfile)
      ? CHAT_ASYNC_FALLBACK_MAX_TOKENS
      : CHAT_FALLBACK_MAX_TOKENS;

    try {
      const rawResponse = await this.runStructured({
        operation,
        messages,
        schema: chatResponseJsonSchema,
        maxTokens: structuredMaxTokens,
        timeoutMs: timeouts.structuredTimeoutMs,
        extraDetails: sharedDetails,
      });
      const parsed = normalizeChatResponse(
        parseStructuredOutput(
          rawResponse.rawResponse,
          chatResponseModelOutputSchema,
          "chat",
          {
            operation,
            model: this.modelName,
            turnID,
          }
        )
      );

      return {
        data: {
          ...applyChatGuardrails(request, {
            ...parsed,
            generationStatus: "model",
          }, promptExecution.derivedAnalytics),
          responseID: turnID,
        },
        responseId: turnID,
        model: this.modelName,
        mode: "structured",
        usage: extractUsage(rawResponse.rawResponse),
        promptBytes: rawResponse.promptBytes,
        modelDurationMs: rawResponse.modelDurationMs,
      };
    } catch (error) {
      if (!(error instanceof CoachInferenceServiceError)) {
        throw error;
      }
      if (!shouldAttemptChatPlainTextFallback(error)) {
        throw error;
      }

      const remainingBudgetMs = remainingChatBudgetMs(
        startedAt,
        timeouts.totalBudgetMs
      );

      console.warn(
        JSON.stringify({
          event: "coach_chat_structured_fallback",
          operation,
          model: this.modelName,
          turnID,
          reasonCode: error.code,
          reasonDetails: error.details,
          remainingBudgetMs,
        })
      );

      if (remainingBudgetMs < timeouts.fallbackMinTimeoutMs) {
        console.warn(
          JSON.stringify({
            event: "coach_chat_degraded_response",
            operation,
            model: this.modelName,
            turnID,
            degradedReason: "insufficient_fallback_budget",
            reasonCode: error.code,
            reasonDetails: error.details,
            remainingBudgetMs,
          })
        );

        return buildDegradedChatResult({
          request,
          responseId: turnID,
          fallback: localFallback,
          model: this.modelName,
          mode: "degraded_fallback",
          startedAt,
          derivedAnalytics: promptExecution.derivedAnalytics,
          errors: [error],
        });
      }

      try {
        const fallbackResponse = await this.runPlainText({
          operation,
          messages: buildFallbackChatMessages(request, promptExecution),
          maxTokens: fallbackMaxTokens,
          timeoutMs: Math.min(timeouts.fallbackTimeoutMs, remainingBudgetMs),
          extraDetails: {
            ...sharedDetails,
            fallbackTrigger: error.code,
            remainingBudgetMs,
          },
        });
        const answerMarkdown = extractPlainText(
          fallbackResponse.rawResponse,
          "chat fallback"
        );

        return {
          data: {
            ...applyChatGuardrails(request, {
              answerMarkdown,
              followUps: [],
              generationStatus: "model",
            }, promptExecution.derivedAnalytics),
            responseID: turnID,
          },
          responseId: turnID,
          model: this.modelName,
          mode: "plain_text_fallback",
          usage: extractUsage(fallbackResponse.rawResponse),
          promptBytes: resolvePromptBytes(error.details),
          fallbackPromptBytes: fallbackResponse.promptBytes,
          modelDurationMs: resolveModelDurationMs(error.details),
          fallbackModelDurationMs: fallbackResponse.modelDurationMs,
        };
      } catch (fallbackError) {
        if (!(fallbackError instanceof CoachInferenceServiceError)) {
          throw fallbackError;
        }

        console.warn(
          JSON.stringify({
            event: "coach_chat_degraded_response",
            operation,
            model: this.modelName,
            turnID,
            degradedReason: "fallback_failed",
            reasonCode: fallbackError.code,
            reasonDetails: fallbackError.details,
            originalReasonCode: error.code,
            originalReasonDetails: error.details,
          })
        );

        return buildDegradedChatResult({
          request,
          responseId: turnID,
          fallback: localFallback,
          model: this.modelName,
          mode: "degraded_fallback",
          startedAt,
          derivedAnalytics: promptExecution.derivedAnalytics,
          errors: [fallbackError, error],
        });
      }
    }
  }

  private get modelName(): string {
    return this.env.AI_MODEL?.trim() || DEFAULT_AI_MODEL;
  }

  private async runStructured(input: {
    operation: "profile_insights" | "workout_summary" | "chat";
    messages: PromptMessage[];
    schema: Record<string, unknown>;
    maxTokens: number;
    timeoutMs: number;
    extraDetails?: Record<string, unknown>;
  }): Promise<ModelInvocationResult> {
    return this.runModel(
      {
        messages: input.messages,
        guided_json: input.schema,
        max_tokens: input.maxTokens,
        temperature: 0.2,
      },
      {
        ...input.extraDetails,
        operation: input.operation,
        mode: "structured",
        messageCount: input.messages.length,
        maxTokens: input.maxTokens,
        timeoutMs: input.timeoutMs,
      }
    );
  }

  private async runPlainText(input: {
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
      {
        messages,
        max_tokens: input.maxTokens,
        temperature: 0.25,
      },
      {
        ...input.extraDetails,
        operation: input.operation,
        mode: "plain_text_fallback",
        messageCount: messages.length,
        maxTokens: input.maxTokens,
        timeoutMs: input.timeoutMs,
      }
    );
  }

  private async runModel(
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
        this.env.AI.run(this.modelName, payload),
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
        model: this.modelName,
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

function shouldAttemptPlainTextFallback(
  error: CoachInferenceServiceError
): boolean {
  return error.code !== "upstream_timeout";
}

function shouldAttemptProfilePlainTextFallback(
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
    followUps: dedupeText(response.followUps).slice(0, 4),
  };
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

function normalizeWorkersAIError(
  error: unknown,
  details: Record<string, unknown>
): CoachInferenceServiceError {
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
  request: CoachChatRequest;
  responseId: string;
  fallback: Omit<CoachChatResponse, "responseID">;
  model: string;
  mode: string;
  startedAt: number;
  derivedAnalytics?: CoachDerivedAnalytics;
  errors: CoachInferenceServiceError[];
}): InferenceResult<CoachChatResponse> {
  const promptBytes = input.errors
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
    responseId: input.responseId,
    model: input.model,
    mode: input.mode,
    promptBytes,
    modelDurationMs: Date.now() - input.startedAt,
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
} as const;
