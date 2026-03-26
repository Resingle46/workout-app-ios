import {
  chatResponseModelOutputSchema,
  profileInsightsModelOutputSchema,
  suggestedChangeSchema,
  type CoachChatRequest,
  type CoachChatResponse,
  type CoachProfileInsightsRequest,
  type CoachProfileInsightsResponse,
} from "./schemas";
import {
  buildProfileInsightsMessages,
  buildChatMessages,
  buildFallbackChatMessages,
  buildFallbackProfileInsightsMessages,
} from "./prompts";
import { extractProgramCommentConstraints, type ProgramCommentConstraints } from "./context";
import type {
  CoachD1Database,
  CoachKVNamespace,
  CoachR2Bucket,
} from "./state";

export const DEFAULT_AI_MODEL = "@cf/mistralai/mistral-small-3.1-24b-instruct";
const PROFILE_INSIGHTS_STRUCTURED_MAX_TOKENS = 550;
const PROFILE_INSIGHTS_PLAIN_TEXT_MAX_TOKENS = 260;
const CHAT_STRUCTURED_MAX_TOKENS = 700;
const CHAT_FALLBACK_MAX_TOKENS = 450;
const PROFILE_INSIGHTS_STRUCTURED_TIMEOUT_MS = 12_000;
const PROFILE_INSIGHTS_PLAIN_TEXT_TIMEOUT_MS = 8_000;
const CHAT_TOTAL_BUDGET_MS = 24_000;
const CHAT_STRUCTURED_TIMEOUT_MS = 18_000;
const CHAT_FALLBACK_TIMEOUT_MS = 6_000;
const CHAT_FALLBACK_MIN_TIMEOUT_MS = 2_000;

interface WorkersAI {
  run(model: string, inputs: Record<string, unknown>): Promise<unknown>;
}

export interface Env {
  AI?: WorkersAI;
  COACH_STATE_KV?: CoachKVNamespace;
  BACKUPS_R2?: CoachR2Bucket;
  APP_META_DB?: CoachD1Database;
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
  modelDurationMs?: number;
}

export interface CoachInferenceService {
  generateProfileInsights(
    request: CoachProfileInsightsRequest
  ): Promise<InferenceResult<CoachProfileInsightsResponse>>;
  generateChat(
    request: CoachChatRequest
  ): Promise<InferenceResult<CoachChatResponse>>;
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

export function createWorkersAICoachService(env: Env): CoachInferenceService {
  return new WorkersAICoachService(env);
}

export class WorkersAICoachService implements CoachInferenceService {
  constructor(private readonly env: Env) {}
  async generateProfileInsights(
    request: CoachProfileInsightsRequest
  ): Promise<InferenceResult<CoachProfileInsightsResponse>> {
    const operation = "profile_insights";
    const localFallback = buildNeutralProfileInsights(request);
    const startedAt = Date.now();

    try {
      const invocation = await this.runStructured({
        operation,
        messages: buildProfileInsightsMessages(request),
        schema: profileInsightsResponseJsonSchema,
        maxTokens: PROFILE_INSIGHTS_STRUCTURED_MAX_TOKENS,
        timeoutMs: PROFILE_INSIGHTS_STRUCTURED_TIMEOUT_MS,
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
          parsed,
          localFallback
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

      if (!shouldAttemptPlainTextFallback(error)) {
        console.warn(
          JSON.stringify({
            event: "coach_profile_local_fallback",
            operation,
            model: this.modelName,
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

      console.warn(
        JSON.stringify({
          event: "coach_profile_structured_fallback",
          operation,
          model: this.modelName,
          reasonCode: error.code,
          reasonDetails: error.details,
        })
      );

      try {
        const fallbackInvocation = await this.runPlainText({
          operation,
          messages: buildFallbackProfileInsightsMessages(request),
          maxTokens: PROFILE_INSIGHTS_PLAIN_TEXT_MAX_TOKENS,
          timeoutMs: PROFILE_INSIGHTS_PLAIN_TEXT_TIMEOUT_MS,
          includeFallbackNotice: false,
        });

        return {
          data: applyProfileInsightsGuardrails(
            request,
            parsePlainProfileInsights(
              extractPlainText(fallbackInvocation.rawResponse, "profile insights")
            ),
            localFallback
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

  async generateChat(
    request: CoachChatRequest
  ): Promise<InferenceResult<CoachChatResponse>> {
    const operation = "chat";
    const turnID = buildOpaqueResponseID();
    const messages = buildChatMessages(request);
    const localFallback = buildNeutralChatResponse(request);
    const startedAt = Date.now();
    const sharedDetails = {
      turnID,
      recentTurnCount: request.clientRecentTurns.length,
      recentTurnChars: totalTurnCharacters(request.clientRecentTurns),
      questionChars: request.question.trim().length,
    };

    try {
      const rawResponse = await this.runStructured({
        operation,
        messages,
        schema: chatResponseJsonSchema,
        maxTokens: CHAT_STRUCTURED_MAX_TOKENS,
        timeoutMs: CHAT_STRUCTURED_TIMEOUT_MS,
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
          ...applyChatGuardrails(request, parsed),
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

      const remainingBudgetMs = remainingChatBudgetMs(startedAt);

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

      if (remainingBudgetMs < CHAT_FALLBACK_MIN_TIMEOUT_MS) {
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
          errors: [error],
        });
      }

      try {
        const fallbackResponse = await this.runPlainText({
          operation,
          messages: buildFallbackChatMessages(request),
          maxTokens: CHAT_FALLBACK_MAX_TOKENS,
          timeoutMs: Math.min(CHAT_FALLBACK_TIMEOUT_MS, remainingBudgetMs),
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
              suggestedChanges: [],
            }),
            responseID: turnID,
          },
          responseId: turnID,
          model: this.modelName,
          mode: "plain_text_fallback",
          usage: extractUsage(fallbackResponse.rawResponse),
          promptBytes: fallbackResponse.promptBytes,
          modelDurationMs: Date.now() - startedAt,
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
          errors: [fallbackError, error],
        });
      }
    }
  }

  private get modelName(): string {
    return this.env.AI_MODEL?.trim() || DEFAULT_AI_MODEL;
  }

  private async runStructured(input: {
    operation: "profile_insights" | "chat";
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
    operation: "profile_insights" | "chat";
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

    try {
      const timeoutMs = parseTimeoutMs(details.timeoutMs);
      const startedAt = Date.now();
      const promptBytes = byteLength(payload.messages);
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
        promptBytes: byteLength(payload.messages),
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

function shouldAttemptChatPlainTextFallback(
  error: CoachInferenceServiceError
): boolean {
  return error.code.startsWith("upstream_");
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
    suggestedChanges: unknown[];
  }
): Omit<CoachChatResponse, "responseID"> {
  return {
    answerMarkdown: response.answerMarkdown.trim(),
    followUps: dedupeText(response.followUps).slice(0, 4),
    suggestedChanges: normalizeSuggestedChanges(response.suggestedChanges),
  };
}

function normalizeProfileInsightsResponse(
  response: {
    summary: string;
    recommendations: string[];
    suggestedChanges: unknown[];
  }
): CoachProfileInsightsResponse {
  return {
    summary: response.summary.trim(),
    recommendations: dedupeText(response.recommendations).slice(0, 8),
    suggestedChanges: normalizeSuggestedChanges(response.suggestedChanges),
  };
}

function parsePlainProfileInsights(
  content: string
): CoachProfileInsightsResponse {
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
    suggestedChanges: [],
  };
}

function applyProfileInsightsGuardrails(
  request: CoachProfileInsightsRequest,
  response: CoachProfileInsightsResponse,
  fallback: CoachProfileInsightsResponse
): CoachProfileInsightsResponse {
  const constraints = extractConstraintsFromSnapshot(request.snapshot);
  const summary = shouldBlockFrequencyStructureText(response.summary, constraints)
    ? fallback.summary
    : response.summary;
  const recommendations = filterFrequencyStructureText(
    response.recommendations,
    constraints
  );
  return {
    summary,
    recommendations:
      recommendations.length > 0 ? recommendations : fallback.recommendations,
    suggestedChanges: filterSuggestedChangesByConstraints(
      response.suggestedChanges,
      constraints
    ),
  };
}

function applyChatGuardrails(
  request: CoachChatRequest,
  response: Omit<CoachChatResponse, "responseID">
): Omit<CoachChatResponse, "responseID"> {
  const constraints = extractConstraintsFromSnapshot(request.snapshot);
  return {
    answerMarkdown: filterChatAnswerMarkdown(
      response.answerMarkdown,
      constraints,
      request.locale
    ),
    followUps: response.followUps,
    suggestedChanges: filterSuggestedChangesByConstraints(
      response.suggestedChanges,
      constraints
    ),
  };
}

function buildNeutralProfileInsights(
  request: CoachProfileInsightsRequest
): CoachProfileInsightsResponse {
  const snapshot = request.snapshot;
  if (!snapshot) {
    return {
      summary: localizedCoachText(request.locale, "fallbackSummary"),
      recommendations: [
        localizedCoachText(request.locale, "fallbackProgressionBaseline"),
      ],
      suggestedChanges: [],
    };
  }

  const locale = request.locale;
  const constraints = extractConstraintsFromSnapshot(snapshot);
  const recommendations: string[] = [];
  const consistency = snapshot.analytics.consistency;

  if (
    constraints.rollingSplitExecution ||
    constraints.preserveWeeklyFrequency ||
    constraints.preserveProgramWorkoutCount
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
    suggestedChanges: [],
  };
}

function buildNeutralChatResponse(
  request: CoachChatRequest
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
      suggestedChanges: [],
    };
  }

  const constraints = extractConstraintsFromSnapshot(snapshot);
  const consistency = snapshot.analytics.consistency;

  if (
    constraints.rollingSplitExecution ||
    constraints.preserveWeeklyFrequency ||
    constraints.preserveProgramWorkoutCount
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
    suggestedChanges: [],
  };
}

function extractConstraintsFromSnapshot(
  snapshot: CoachProfileInsightsRequest["snapshot"] | CoachChatRequest["snapshot"]
): ProgramCommentConstraints {
  return extractProgramCommentConstraints(
    snapshot?.coachAnalysisSettings.programComment
  );
}

function filterSuggestedChangesByConstraints(
  changes: CoachProfileInsightsResponse["suggestedChanges"],
  constraints: ProgramCommentConstraints
): CoachProfileInsightsResponse["suggestedChanges"] {
  return changes.filter((change) => {
    if (
      constraints.preserveWeeklyFrequency &&
      change.type === "setWeeklyWorkoutTarget"
    ) {
      return false;
    }

    if (
      (constraints.rollingSplitExecution ||
        constraints.preserveProgramWorkoutCount) &&
      (change.type === "addWorkoutDay" || change.type === "deleteWorkoutDay")
    ) {
      return false;
    }

    return true;
  });
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
  locale: string
): string {
  if (!hasFrequencyStructureGuardrails(constraints)) {
    return answerMarkdown.trim();
  }

  const lines = answerMarkdown
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean)
    .filter((line) => !shouldBlockFrequencyStructureText(line, constraints));

  if (lines.length > 0) {
    return lines.join("\n\n");
  }

  return localizedCoachText(locale, "commentConstraintAcknowledged");
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

function formatLoad(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

function normalizeSuggestedChanges(
  values: unknown[]
): CoachProfileInsightsResponse["suggestedChanges"] {
  const result: CoachProfileInsightsResponse["suggestedChanges"] = [];

  for (const value of values) {
    const parsed = suggestedChangeSchema.safeParse(value);
    if (!parsed.success) {
      continue;
    }

    result.push(parsed.data);
    if (result.length >= 5) {
      break;
    }
  }

  return result;
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

function remainingChatBudgetMs(startedAt: number): number {
  return Math.max(CHAT_TOTAL_BUDGET_MS - (Date.now() - startedAt), 0);
}

function buildDegradedChatResult(input: {
  request: CoachChatRequest;
  responseId: string;
  fallback: Omit<CoachChatResponse, "responseID">;
  model: string;
  mode: string;
  startedAt: number;
  errors: CoachInferenceServiceError[];
}): InferenceResult<CoachChatResponse> {
  const promptBytes = input.errors
    .map((error) => resolvePromptBytes(error.details))
    .find((value): value is number => value !== undefined);

  return {
    data: {
      ...applyChatGuardrails(input.request, input.fallback),
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

function buildOpaqueResponseID(): string {
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

const guidedSuggestedChangeJsonSchema = {
  type: "object",
  properties: {
    id: { type: "string" },
    type: { type: "string" },
    title: { type: "string" },
    summary: { type: "string" },
    weeklyWorkoutTarget: { type: "integer" },
    programID: { type: "string" },
    workoutID: { type: "string" },
    templateExerciseID: { type: "string" },
    replacementExerciseID: { type: "string" },
    workoutTitle: { type: "string" },
    workoutFocus: { type: "string" },
    reps: { type: "integer" },
    setsCount: { type: "integer" },
    suggestedWeight: { type: "number" },
  },
  required: ["id", "type", "title", "summary"],
} as const;

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
    suggestedChanges: {
      type: "array",
      items: guidedSuggestedChangeJsonSchema,
    },
  },
  required: ["summary", "recommendations", "suggestedChanges"],
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
    suggestedChanges: {
      type: "array",
      items: guidedSuggestedChangeJsonSchema,
    },
  },
  required: ["answerMarkdown", "followUps", "suggestedChanges"],
} as const;
