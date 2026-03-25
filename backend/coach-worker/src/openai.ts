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
  buildChatMessages,
  buildFallbackChatMessages,
  buildProfileInsightsMessages,
} from "./prompts";

export const DEFAULT_AI_MODEL = "@cf/mistralai/mistral-small-3.1-24b-instruct";

interface WorkersAI {
  run(model: string, inputs: Record<string, unknown>): Promise<unknown>;
}

export interface Env {
  AI?: WorkersAI;
  COACH_INTERNAL_TOKEN: string;
  AI_MODEL?: string;
  COACH_PROMPT_VERSION?: string;
}

export interface InferenceResult<T> {
  data: T;
  responseId?: string;
  model: string;
  usage?: unknown;
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
    message: string
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
    const rawResponse = await this.runStructured({
      messages: buildProfileInsightsMessages(request),
      schema: profileInsightsJsonSchema,
      maxTokens: 850,
    });

    const response = parseStructuredOutput(
      rawResponse,
      profileInsightsModelOutputSchema,
      "profile insights"
    );
    return {
      data: normalizeProfileInsights(response),
      model: this.modelName,
      usage: extractUsage(rawResponse),
    };
  }

  async generateChat(
    request: CoachChatRequest
  ): Promise<InferenceResult<CoachChatResponse>> {
    const turnID = buildOpaqueResponseID();
    const messages = buildChatMessages(request);

    try {
      const rawResponse = await this.runStructured({
        messages,
        schema: chatResponseJsonSchema,
        maxTokens: 900,
      });
      const parsed = normalizeChatResponse(
        parseStructuredOutput(
          rawResponse,
          chatResponseModelOutputSchema,
          "chat"
        )
      );

      return {
        data: {
          ...parsed,
          responseID: turnID,
        },
        responseId: turnID,
        model: this.modelName,
        usage: extractUsage(rawResponse),
      };
    } catch (error) {
      if (!(error instanceof CoachInferenceServiceError)) {
        throw error;
      }

      const fallbackResponse = await this.runPlainText({
        messages: buildFallbackChatMessages(request),
        maxTokens: 750,
      });
      const answerMarkdown = extractPlainText(fallbackResponse, "chat fallback");

      return {
        data: {
          answerMarkdown,
          responseID: turnID,
          followUps: [],
          suggestedChanges: [],
        },
        responseId: turnID,
        model: this.modelName,
        usage: extractUsage(fallbackResponse),
      };
    }
  }

  private get modelName(): string {
    return this.env.AI_MODEL?.trim() || DEFAULT_AI_MODEL;
  }

  private async runStructured(input: {
    messages: PromptMessage[];
    schema: Record<string, unknown>;
    maxTokens: number;
  }): Promise<unknown> {
    return this.runModel({
      messages: input.messages,
      guided_json: input.schema,
      max_tokens: input.maxTokens,
      temperature: 0.2,
    });
  }

  private async runPlainText(input: {
    messages: PromptMessage[];
    maxTokens: number;
  }): Promise<unknown> {
    return this.runModel({
      messages: [
        {
          role: "system",
          content:
            "The previous structured-output attempt failed. Keep the answer compact and in markdown only.",
        },
        ...input.messages,
      ],
      max_tokens: input.maxTokens,
      temperature: 0.25,
    });
  }

  private async runModel(payload: Record<string, unknown>): Promise<unknown> {
    if (!this.env.AI) {
      throw new CoachInferenceServiceError(
        500,
        "server_misconfigured",
        "Workers AI binding is not configured"
      );
    }

    try {
      return await this.env.AI.run(this.modelName, payload);
    } catch (error) {
      throw normalizeWorkersAIError(error);
    }
  }
}

function parseStructuredOutput<T>(
  rawResponse: unknown,
  schema: { parse(input: unknown): T },
  label: string
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
      `Workers AI returned schema-invalid ${label} output`
    );
  }
}

function normalizeProfileInsights(
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
    `Workers AI returned empty ${label} output`
  );
}

function parseJSONPayload(payload: string, label: string): unknown {
  const trimmed = payload.trim();
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
      `Workers AI returned invalid ${label} JSON`
    );
  }
}

function normalizeWorkersAIError(error: unknown): CoachInferenceServiceError {
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
      "Workers AI request timed out"
    );
  }

  return new CoachInferenceServiceError(
    502,
    "upstream_request_failed",
    "Workers AI request failed"
  );
}

function buildOpaqueResponseID(): string {
  return `coach-turn_${crypto.randomUUID()}`;
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

const suggestedChangeOneOf = [
  {
    type: "object",
    additionalProperties: false,
    properties: {
      id: { type: "string", minLength: 1 },
      type: { const: "setWeeklyWorkoutTarget" },
      title: { type: "string", minLength: 1 },
      summary: { type: "string", minLength: 1 },
      weeklyWorkoutTarget: { type: "integer", minimum: 1 },
    },
    required: ["id", "type", "title", "summary", "weeklyWorkoutTarget"],
  },
  {
    type: "object",
    additionalProperties: false,
    properties: {
      id: { type: "string", minLength: 1 },
      type: { const: "addWorkoutDay" },
      title: { type: "string", minLength: 1 },
      summary: { type: "string", minLength: 1 },
      programID: { type: "string", format: "uuid" },
      workoutTitle: { type: "string", minLength: 1 },
      workoutFocus: { type: "string" },
    },
    required: ["id", "type", "title", "summary", "programID", "workoutTitle"],
  },
  {
    type: "object",
    additionalProperties: false,
    properties: {
      id: { type: "string", minLength: 1 },
      type: { const: "deleteWorkoutDay" },
      title: { type: "string", minLength: 1 },
      summary: { type: "string", minLength: 1 },
      programID: { type: "string", format: "uuid" },
      workoutID: { type: "string", format: "uuid" },
    },
    required: ["id", "type", "title", "summary", "programID", "workoutID"],
  },
  {
    type: "object",
    additionalProperties: false,
    properties: {
      id: { type: "string", minLength: 1 },
      type: { const: "swapWorkoutExercise" },
      title: { type: "string", minLength: 1 },
      summary: { type: "string", minLength: 1 },
      programID: { type: "string", format: "uuid" },
      workoutID: { type: "string", format: "uuid" },
      templateExerciseID: { type: "string", format: "uuid" },
      replacementExerciseID: { type: "string", format: "uuid" },
    },
    required: [
      "id",
      "type",
      "title",
      "summary",
      "programID",
      "workoutID",
      "templateExerciseID",
      "replacementExerciseID",
    ],
  },
  {
    type: "object",
    additionalProperties: false,
    properties: {
      id: { type: "string", minLength: 1 },
      type: { const: "updateTemplateExercisePrescription" },
      title: { type: "string", minLength: 1 },
      summary: { type: "string", minLength: 1 },
      programID: { type: "string", format: "uuid" },
      workoutID: { type: "string", format: "uuid" },
      templateExerciseID: { type: "string", format: "uuid" },
      reps: { type: "integer", minimum: 1 },
      setsCount: { type: "integer", minimum: 1 },
      suggestedWeight: { type: "number", minimum: 0 },
    },
    required: [
      "id",
      "type",
      "title",
      "summary",
      "programID",
      "workoutID",
      "templateExerciseID",
      "reps",
      "setsCount",
      "suggestedWeight",
    ],
  },
];

const profileInsightsJsonSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    summary: {
      type: "string",
      minLength: 1,
    },
    recommendations: {
      type: "array",
      items: {
        type: "string",
        minLength: 1,
      },
      maxItems: 8,
    },
    suggestedChanges: {
      type: "array",
      items: {
        oneOf: suggestedChangeOneOf,
      },
      maxItems: 5,
    },
  },
  required: ["summary", "recommendations", "suggestedChanges"],
} as const;

const chatResponseJsonSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    answerMarkdown: {
      type: "string",
      minLength: 1,
    },
    followUps: {
      type: "array",
      items: {
        type: "string",
        minLength: 1,
      },
      maxItems: 4,
    },
    suggestedChanges: {
      type: "array",
      items: {
        oneOf: suggestedChangeOneOf,
      },
      maxItems: 5,
    },
  },
  required: ["answerMarkdown", "followUps", "suggestedChanges"],
} as const;
