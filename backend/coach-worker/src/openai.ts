import OpenAI from "openai";
import {
  chatResponseSchema,
  profileInsightsResponseSchema,
  type CoachChatRequest,
  type CoachChatResponse,
  type CoachProfileInsightsRequest,
  type CoachProfileInsightsResponse,
} from "./schemas";
import { buildChatMessages, buildProfileInsightsMessages } from "./prompts";

export interface Env {
  OPENAI_API_KEY: string;
  COACH_INTERNAL_TOKEN: string;
  OPENAI_MODEL?: string;
  COACH_PROMPT_VERSION?: string;
}

interface ResponsesSDK {
  create(request: Record<string, unknown>): Promise<{
    id?: string;
    output_text?: string;
    usage?: unknown;
  }>;
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

export class OpenAIServiceError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string
  ) {
    super(message);
    this.name = "OpenAIServiceError";
  }
}

export function createOpenAICoachService(env: Env): CoachInferenceService {
  const client = new OpenAI({
    apiKey: env.OPENAI_API_KEY,
  });

  return new OpenAICoachService(client.responses, env);
}

export class OpenAICoachService implements CoachInferenceService {
  constructor(
    private readonly responses: ResponsesSDK,
    private readonly env: Env
  ) {}

  async generateProfileInsights(
    request: CoachProfileInsightsRequest
  ): Promise<InferenceResult<CoachProfileInsightsResponse>> {
    const response = await this.createStructuredResponse({
      schemaName: "coach_profile_insights",
      schema: profileInsightsJsonSchema,
      store: false,
      input: buildProfileInsightsMessages(request),
    });

    return {
      data: normalizeProfileInsights(
        parseStructuredOutput(
          response.output_text,
          profileInsightsResponseSchema,
          "profile insights"
        )
      ),
      responseId: response.id,
      model: this.modelName,
      usage: response.usage,
    };
  }

  async generateChat(
    request: CoachChatRequest
  ): Promise<InferenceResult<CoachChatResponse>> {
    const response = await this.createStructuredResponse({
      schemaName: "coach_chat_response",
      schema: chatResponseJsonSchema,
      store: true,
      previousResponseID: request.previousResponseID,
      input: buildChatMessages(request),
    });

    const parsed = normalizeChatResponse(
      parseStructuredOutput(response.output_text, chatResponseSchema, "chat")
    );

    return {
      data: {
        ...parsed,
        responseID: response.id ?? parsed.responseID,
      },
      responseId: response.id,
      model: this.modelName,
      usage: response.usage,
    };
  }

  private get modelName(): string {
    return this.env.OPENAI_MODEL?.trim() || "gpt-5-mini";
  }

  private async createStructuredResponse(input: {
    schemaName: string;
    schema: Record<string, unknown>;
    store: boolean;
    previousResponseID?: string;
    input: Array<{ role: "system" | "user"; content: string }>;
  }) {
    try {
      return await this.responses.create({
        model: this.modelName,
        store: input.store,
        previous_response_id: input.previousResponseID,
        input: input.input,
        text: {
          format: {
            type: "json_schema",
            name: input.schemaName,
            strict: true,
            schema: input.schema,
          },
        },
      });
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Unknown OpenAI error";
      const normalizedMessage = message.toLowerCase();
      if (
        normalizedMessage.includes("timeout") ||
        normalizedMessage.includes("timed out") ||
        normalizedMessage.includes("deadline")
      ) {
        throw new OpenAIServiceError(
          504,
          "upstream_timeout",
          "OpenAI request timed out"
        );
      }

      throw new OpenAIServiceError(
        502,
        "upstream_request_failed",
        "OpenAI request failed"
      );
    }
  }
}

function parseStructuredOutput<T>(
  outputText: string | undefined,
  schema: { parse(input: unknown): T },
  label: string
): T {
  const trimmed = outputText?.trim();
  if (!trimmed) {
    throw new OpenAIServiceError(
      502,
      "upstream_empty_output",
      `OpenAI returned empty ${label} output`
    );
  }

  let parsedJSON: unknown;
  try {
    parsedJSON = JSON.parse(trimmed);
  } catch {
    throw new OpenAIServiceError(
      502,
      "upstream_invalid_json",
      `OpenAI returned invalid ${label} JSON`
    );
  }

  try {
    return schema.parse(parsedJSON);
  } catch {
    throw new OpenAIServiceError(
      502,
      "upstream_invalid_output",
      `OpenAI returned schema-invalid ${label} output`
    );
  }
}

function normalizeProfileInsights(
  response: CoachProfileInsightsResponse
): CoachProfileInsightsResponse {
  return {
    summary: response.summary.trim(),
    recommendations: dedupeText(response.recommendations).slice(0, 8),
    suggestedChanges: response.suggestedChanges.slice(0, 5),
  };
}

function normalizeChatResponse(
  response: CoachChatResponse
): CoachChatResponse {
  return {
    answerMarkdown: response.answerMarkdown.trim(),
    responseID: response.responseID.trim(),
    followUps: dedupeText(response.followUps).slice(0, 4),
    suggestedChanges: response.suggestedChanges.slice(0, 5),
  };
}

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
    responseID: {
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
  required: ["answerMarkdown", "responseID", "followUps", "suggestedChanges"],
} as const;
