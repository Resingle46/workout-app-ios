import type {
  CoachContextProfile,
  CoachExecutionMetadata,
  CoachMemoryProfile,
} from "./context";
import type {
  CoachAIProvider,
  CoachChatRequest,
  CoachProfileInsightsRequest,
  CoachWorkoutSummaryJobCreateRequest,
} from "./schemas";

export const DEFAULT_AI_MODEL = "@cf/mistralai/mistral-small-3.1-24b-instruct";
export const DEFAULT_CHAT_FAST_MODEL = "@cf/zai-org/glm-4.7-flash";
export const DEFAULT_CHAT_REDUCED_MODEL = "@cf/meta/llama-3.1-8b-instruct-fast";
export const DEFAULT_MODEL_ROUTING_VERSION = "phase1.v1";
export const DEFAULT_GEMINI_CHAT_FAST_MODEL = "gemini-2.5-flash-lite";
export const DEFAULT_GEMINI_CHAT_BALANCED_MODEL = "gemini-2.5-flash";
export const DEFAULT_GEMINI_CHAT_REDUCED_MODEL = "gemini-2.5-flash-lite";
export const DEFAULT_GEMINI_SUMMARY_MODEL = "gemini-2.5-flash";
export const DEFAULT_GEMINI_INSIGHTS_MODEL = "gemini-2.5-flash";
export const DEFAULT_GEMINI_SYNC_FALLBACK_MODEL = "gemini-2.5-flash-lite";

export type CoachRoutingUseCase =
  | "simple_qna"
  | "follow_up_clarification"
  | "workout_summary"
  | "rolling_rotation_split_reasoning"
  | "lagging_muscle_imbalance"
  | "program_redesign"
  | "low_data_case"
  | "profile_insights";

export type CoachModelRole =
  | "chat_fast"
  | "chat_balanced"
  | "chat_reduced_context"
  | "summary_fast"
  | "summary_balanced"
  | "insights_fast"
  | "insights_balanced"
  | "sync_fallback"
  | "quality_escalation";

export type CoachPayloadTier = "full" | "reduced" | "compact";
export type StructuredAdapter = "guided_json" | "response_format_json_schema";
export type CoachOutputContract =
  | "chat_markdown_v1"
  | "summary_json_v1"
  | "insights_json_v1";

export interface ModelCapability {
  structuredAdapter: StructuredAdapter;
}

export interface RoutingDecision {
  provider: CoachAIProvider;
  operation: "chat" | "workout_summary" | "profile_insights";
  useCase: CoachRoutingUseCase;
  modelRole: CoachModelRole;
  selectedModel: string;
  allowedContextProfiles: CoachContextProfile[];
  payloadTier: CoachPayloadTier;
  routingVersion: string;
  memoryCompatibilityKey?: string;
  structuredAdapter: StructuredAdapter;
  outputContract: CoachOutputContract;
  promptFamily: string;
  contextFamily: string;
  escalationEligible: boolean;
  routingReasonTags: string[];
}

export interface ChatRoutingAttempt {
  provider: CoachAIProvider;
  modelRole: CoachModelRole;
  selectedModel: string;
  contextProfile: CoachContextProfile;
  promptProfile: string;
  payloadTier: CoachPayloadTier;
  mode: "structured" | "plain_text_fallback";
  fallbackStage:
    | "primary"
    | "same_model_reduced_context"
    | "alternate_model_reduced_context"
    | "reduced_model_structured"
    | "reduced_model_plain_text";
  structuredAdapter: StructuredAdapter;
  memoryCompatibilityKey: string;
  routingVersion: string;
  useCase: CoachRoutingUseCase;
  routingReasonTags: string[];
  attemptReason: string;
  fallbackHopCount: number;
}

export interface WorkoutSummaryRoutingAttempt {
  provider: CoachAIProvider;
  modelRole: CoachModelRole;
  selectedModel: string;
  contextProfile: "rich_async_v1";
  promptProfile: string;
  payloadTier: CoachPayloadTier;
  mode: "structured" | "plain_text_fallback";
  fallbackStage:
    | "primary"
    | "same_model_reduced_payload"
    | "alternate_model_reduced_payload"
    | "sync_fallback_structured"
    | "sync_fallback_plain_text";
  structuredAdapter: StructuredAdapter;
  routingVersion: string;
  useCase: "workout_summary";
  routingReasonTags: string[];
  attemptReason: string;
  fallbackHopCount: number;
}

export interface ProfileInsightsRoutingAttempt {
  provider: CoachAIProvider;
  modelRole: CoachModelRole;
  selectedModel: string;
  contextProfile: "compact_sync_v2";
  promptProfile: string;
  payloadTier: "compact";
  mode: "structured" | "plain_text_fallback";
  fallbackStage:
    | "primary"
    | "insights_balanced_structured"
    | "quality_escalation_structured"
    | "sync_fallback_plain_text";
  structuredAdapter: StructuredAdapter;
  memoryCompatibilityKey: string;
  routingVersion: string;
  useCase: "profile_insights";
  routingReasonTags: string[];
  attemptReason: string;
  fallbackHopCount: number;
}

type EnvLike = {
  AI_MODEL?: string;
  MODEL_ROUTING_ENABLED?: string;
  MODEL_ROUTING_VERSION?: string;
  CHAT_FAST_MODEL?: string;
  CHAT_BALANCED_MODEL?: string;
  CHAT_REDUCED_CONTEXT_MODEL?: string;
  SUMMARY_FAST_MODEL?: string;
  SUMMARY_BALANCED_MODEL?: string;
  SYNC_FALLBACK_MODEL?: string;
  INSIGHTS_BALANCED_MODEL?: string;
  INSIGHTS_FAST_MODEL?: string;
  QUALITY_ESCALATION_MODEL?: string;
  QUALITY_ESCALATION_ENABLED?: string;
  GEMINI_CHAT_FAST_MODEL?: string;
  GEMINI_CHAT_BALANCED_MODEL?: string;
  GEMINI_CHAT_REDUCED_CONTEXT_MODEL?: string;
  GEMINI_SUMMARY_FAST_MODEL?: string;
  GEMINI_SUMMARY_BALANCED_MODEL?: string;
  GEMINI_INSIGHTS_BALANCED_MODEL?: string;
  GEMINI_INSIGHTS_FAST_MODEL?: string;
  GEMINI_SYNC_FALLBACK_MODEL?: string;
  GEMINI_QUALITY_ESCALATION_MODEL?: string;
};

export function resolveProvider(
  requestProvider: CoachAIProvider | undefined,
  metadataProvider: CoachAIProvider | undefined
): CoachAIProvider {
  return metadataProvider ?? requestProvider ?? "workers_ai";
}

export function isModelRoutingEnabled(env: EnvLike): boolean {
  return parseBooleanFlag(env.MODEL_ROUTING_ENABLED);
}

export function isQualityEscalationEnabled(env: EnvLike): boolean {
  return parseBooleanFlag(env.QUALITY_ESCALATION_ENABLED);
}

export function resolveModelRoutingVersion(env: EnvLike): string {
  return (
    env.MODEL_ROUTING_VERSION?.trim() || DEFAULT_MODEL_ROUTING_VERSION
  );
}

export function resolveModelForRole(
  env: EnvLike,
  providerOrRole: CoachAIProvider | CoachModelRole,
  roleOrOptions?: CoachModelRole | { allowAlternateRouting?: boolean },
  maybeOptions: { allowAlternateRouting?: boolean } = {}
): string {
  const provider: CoachAIProvider =
    providerOrRole === "workers_ai" || providerOrRole === "gemini"
      ? providerOrRole
      : "workers_ai";
  const role: CoachModelRole =
    typeof roleOrOptions === "string"
      ? roleOrOptions
      : (providerOrRole as CoachModelRole);
  const options =
    typeof roleOrOptions === "string"
      ? maybeOptions
      : (roleOrOptions ?? {});

  if (provider === "gemini") {
    return resolveGeminiModelForRole(env, role, options);
  }
  const seedModel = env.AI_MODEL?.trim() || DEFAULT_AI_MODEL;
  const allowAlternateRouting =
    options.allowAlternateRouting ?? isModelRoutingEnabled(env);

  if (!allowAlternateRouting) {
    if (role === "quality_escalation" && !isQualityEscalationEnabled(env)) {
      return seedModel;
    }
    return seedModel;
  }

  switch (role) {
    case "chat_fast":
      return env.CHAT_FAST_MODEL?.trim() || DEFAULT_CHAT_FAST_MODEL;
    case "chat_balanced":
      return env.CHAT_BALANCED_MODEL?.trim() || seedModel;
    case "chat_reduced_context":
      return (
        env.CHAT_REDUCED_CONTEXT_MODEL?.trim() || DEFAULT_CHAT_REDUCED_MODEL
      );
    case "summary_fast":
      return (
        env.SUMMARY_FAST_MODEL?.trim() ||
        env.CHAT_FAST_MODEL?.trim() ||
        DEFAULT_CHAT_FAST_MODEL
      );
    case "summary_balanced":
      return env.SUMMARY_BALANCED_MODEL?.trim() || seedModel;
    case "insights_fast":
      return (
        env.INSIGHTS_FAST_MODEL?.trim() ||
        env.CHAT_FAST_MODEL?.trim() ||
        DEFAULT_CHAT_FAST_MODEL
      );
    case "insights_balanced":
      return env.INSIGHTS_BALANCED_MODEL?.trim() || seedModel;
    case "sync_fallback":
      return env.SYNC_FALLBACK_MODEL?.trim() || DEFAULT_CHAT_REDUCED_MODEL;
    case "quality_escalation":
      if (!isQualityEscalationEnabled(env)) {
        return seedModel;
      }
      return env.QUALITY_ESCALATION_MODEL?.trim() || seedModel;
    default:
      return seedModel;
  }
}

export function resolveModelCapability(
  provider: CoachAIProvider,
  model: string
): ModelCapability {
  if (provider === "gemini") {
    return {
      structuredAdapter: "response_format_json_schema",
    };
  }
  if (
    model === "@cf/zai-org/glm-4.7-flash" ||
    model === "@cf/meta/llama-3.1-8b-instruct-fast"
  ) {
    return {
      structuredAdapter: "response_format_json_schema",
    };
  }

  return {
    structuredAdapter: "guided_json",
  };
}

export function buildChatRoutingDecision(
  env: EnvLike,
  request: CoachChatRequest & { metadata?: Partial<CoachExecutionMetadata> },
  options: { timeoutProfile?: "sync" | "async_job" } = {}
): RoutingDecision {
  const metadata = request.metadata;
  const provider = resolveProvider(request.provider, metadata?.provider);
  const useCase = coerceUseCase(
    metadata?.useCase,
    classifyChatUseCase(request, options.timeoutProfile)
  );
  const modelRole = coerceModelRole(
    metadata?.modelRole,
    defaultChatModelRole(useCase)
  );
  const selectedModel =
    metadata?.selectedModel ??
    resolveModelForRole(env, provider, modelRole, {
      allowAlternateRouting: isModelRoutingEnabled(env),
    });
  const allowedContextProfiles =
    metadata?.allowedContextProfiles ?? resolveChatContextProfiles(useCase, options);
  const contextFamily = resolveContextFamily(allowedContextProfiles);
  const promptFamily = metadata?.promptFamily ?? resolveChatPromptFamily(useCase, options);
  const routingVersion =
    metadata?.routingVersion ?? resolveModelRoutingVersion(env);
  const memoryProfile = metadata?.memoryProfile ?? "compact_v1";
  const routingReasonTags =
    metadata?.routingReasonTags ??
    buildChatRoutingReasonTags(
      env,
      request,
      useCase,
      modelRole,
      allowedContextProfiles,
      options.timeoutProfile
    );

  return {
    provider,
    operation: "chat",
    useCase,
    modelRole,
    selectedModel,
    allowedContextProfiles,
    payloadTier:
      allowedContextProfiles[0] === "compact_sync_v2" ? "compact" : "full",
    routingVersion,
    memoryCompatibilityKey:
      metadata?.memoryCompatibilityKey ??
      buildMemoryCompatibilityKey(
        provider,
        "chat_markdown_v1",
        promptFamily,
        contextFamily,
        memoryProfile,
        routingVersion
      ),
    structuredAdapter: resolveModelCapability(
      provider,
      selectedModel
    ).structuredAdapter,
    outputContract: "chat_markdown_v1",
    promptFamily,
    contextFamily,
    escalationEligible: false,
    routingReasonTags,
  };
}

export function buildWorkoutSummaryRoutingDecision(
  env: EnvLike,
  request: CoachWorkoutSummaryJobCreateRequest & {
    metadata?: Partial<CoachExecutionMetadata>;
  }
): RoutingDecision {
  const metadata = request.metadata;
  const provider = resolveProvider(request.provider, metadata?.provider);
  const selectedModel =
    metadata?.selectedModel ??
    resolveModelForRole(env, provider, "summary_fast", {
      allowAlternateRouting: isModelRoutingEnabled(env),
    });
  const routingVersion =
    metadata?.routingVersion ?? resolveModelRoutingVersion(env);
  const routingReasonTags =
    metadata?.routingReasonTags ??
    buildSummaryRoutingReasonTags(
      env,
      provider,
      coerceModelRole(metadata?.modelRole, "summary_fast")
    );

  return {
    provider,
    operation: "workout_summary",
    useCase: "workout_summary",
    modelRole: coerceModelRole(metadata?.modelRole, "summary_fast"),
    selectedModel,
    allowedContextProfiles: ["rich_async_v1"],
    payloadTier: "full",
    routingVersion,
    structuredAdapter: resolveModelCapability(
      provider,
      selectedModel
    ).structuredAdapter,
    outputContract: "summary_json_v1",
    promptFamily: metadata?.promptFamily ?? "summary_async_v1",
    contextFamily: metadata?.contextFamily ?? "rich_async_family",
    escalationEligible: false,
    routingReasonTags,
  };
}

export function buildProfileInsightsRoutingDecision(
  env: EnvLike,
  request: CoachProfileInsightsRequest & {
    metadata?: Partial<CoachExecutionMetadata>;
  }
): RoutingDecision {
  const metadata = request.metadata;
  const provider = resolveProvider(request.provider, metadata?.provider);
  const modelRole = coerceModelRole(metadata?.modelRole, "insights_fast");
  const selectedModel =
    metadata?.selectedModel ??
    resolveModelForRole(env, provider, modelRole, {
      allowAlternateRouting: isModelRoutingEnabled(env),
    });
  const routingVersion =
    metadata?.routingVersion ?? resolveModelRoutingVersion(env);
  const memoryProfile = metadata?.memoryProfile ?? "compact_v1";
  const routingReasonTags =
    metadata?.routingReasonTags ??
    buildProfileInsightsRoutingReasonTags(
      env,
      provider,
      modelRole
    );

  return {
    provider,
    operation: "profile_insights",
    useCase: coerceUseCase(metadata?.useCase, "profile_insights"),
    modelRole,
    selectedModel,
    allowedContextProfiles: ["compact_sync_v2"],
    payloadTier: "compact",
    routingVersion,
    memoryCompatibilityKey:
      metadata?.memoryCompatibilityKey ??
      buildMemoryCompatibilityKey(
        provider,
        "insights_json_v1",
        "profile_sync_v1",
        "compact_sync_family",
        memoryProfile,
        routingVersion
      ),
    structuredAdapter: resolveModelCapability(
      provider,
      selectedModel
    ).structuredAdapter,
    outputContract: "insights_json_v1",
    promptFamily: metadata?.promptFamily ?? "profile_sync_v1",
    contextFamily: metadata?.contextFamily ?? "compact_sync_family",
    escalationEligible: isQualityEscalationEnabled(env),
    routingReasonTags,
  };
}

export function buildChatRoutingAttempts(
  env: EnvLike,
  decision: RoutingDecision
): ChatRoutingAttempt[] {
  const reducedContextProfile =
    decision.allowedContextProfiles[1] ??
    decision.allowedContextProfiles[0] ??
    "compact_sync_v2";
  const smallestContextProfile =
    decision.allowedContextProfiles[decision.allowedContextProfiles.length - 1] ??
    reducedContextProfile;
  const alternateRole =
    decision.modelRole === "chat_balanced" ? "chat_fast" : "chat_balanced";

  const attempts: ChatRoutingAttempt[] = [
    {
      provider: decision.provider,
      modelRole: decision.modelRole,
      selectedModel: decision.selectedModel,
      contextProfile: decision.allowedContextProfiles[0] ?? "compact_sync_v2",
      promptProfile: resolveChatPromptProfile(
        decision.useCase,
        decision.allowedContextProfiles[0] ?? "compact_sync_v2",
        "primary"
      ),
      payloadTier: decision.payloadTier,
      mode: "structured",
      fallbackStage: "primary",
      structuredAdapter: decision.structuredAdapter,
      memoryCompatibilityKey: decision.memoryCompatibilityKey ?? "chat-memory",
      routingVersion: decision.routingVersion,
      useCase: decision.useCase,
      routingReasonTags: decision.routingReasonTags,
      attemptReason: "primary_selected_route",
      fallbackHopCount: 0,
    },
  ];

  if (reducedContextProfile !== attempts[0].contextProfile) {
    attempts.push({
      provider: decision.provider,
      modelRole: decision.modelRole,
      selectedModel: decision.selectedModel,
      contextProfile: reducedContextProfile,
      promptProfile: resolveChatPromptProfile(
        decision.useCase,
        reducedContextProfile,
        "reduced"
      ),
      payloadTier:
        reducedContextProfile === "compact_sync_v2" ? "compact" : "reduced",
      mode: "structured",
      fallbackStage: "same_model_reduced_context",
      structuredAdapter: decision.structuredAdapter,
      memoryCompatibilityKey: decision.memoryCompatibilityKey ?? "chat-memory",
      routingVersion: decision.routingVersion,
      useCase: decision.useCase,
      routingReasonTags: decision.routingReasonTags,
      attemptReason: "same_model_reduced_context_after_failure",
      fallbackHopCount: 1,
    });
  }

  const alternateModel = resolveModelForRole(env, decision.provider, alternateRole);
  attempts.push({
    provider: decision.provider,
    modelRole: alternateRole,
    selectedModel: alternateModel,
    contextProfile: reducedContextProfile,
    promptProfile: resolveChatPromptProfile(
      decision.useCase,
      reducedContextProfile,
      "alternate"
    ),
    payloadTier:
      reducedContextProfile === "compact_sync_v2" ? "compact" : "reduced",
    mode: "structured",
    fallbackStage: "alternate_model_reduced_context",
    structuredAdapter: resolveModelCapability(
      decision.provider,
      alternateModel
    ).structuredAdapter,
    memoryCompatibilityKey: decision.memoryCompatibilityKey ?? "chat-memory",
    routingVersion: decision.routingVersion,
    useCase: decision.useCase,
    routingReasonTags: decision.routingReasonTags,
    attemptReason: "alternate_main_tier_after_reduced_context_failure",
    fallbackHopCount: attempts.length,
  });

  const reducedModel = resolveModelForRole(
    env,
    decision.provider,
    "chat_reduced_context"
  );
  attempts.push({
    provider: decision.provider,
    modelRole: "chat_reduced_context",
    selectedModel: reducedModel,
    contextProfile: smallestContextProfile,
    promptProfile: resolveChatPromptProfile(
      decision.useCase,
      smallestContextProfile,
      "reduced_model"
    ),
    payloadTier:
      smallestContextProfile === "compact_sync_v2" ? "compact" : "reduced",
    mode: "structured",
    fallbackStage: "reduced_model_structured",
    structuredAdapter: resolveModelCapability(
      decision.provider,
      reducedModel
    ).structuredAdapter,
    memoryCompatibilityKey: decision.memoryCompatibilityKey ?? "chat-memory",
    routingVersion: decision.routingVersion,
    useCase: decision.useCase,
    routingReasonTags: decision.routingReasonTags,
    attemptReason: "reduced_context_model_after_main_tier_failures",
    fallbackHopCount: attempts.length,
  });
  attempts.push({
    provider: decision.provider,
    modelRole: "chat_reduced_context",
    selectedModel: reducedModel,
    contextProfile: smallestContextProfile,
    promptProfile: resolveChatPromptProfile(
      decision.useCase,
      smallestContextProfile,
      "reduced_model"
    ),
    payloadTier:
      smallestContextProfile === "compact_sync_v2" ? "compact" : "reduced",
    mode: "plain_text_fallback",
    fallbackStage: "reduced_model_plain_text",
    structuredAdapter: resolveModelCapability(
      decision.provider,
      reducedModel
    ).structuredAdapter,
    memoryCompatibilityKey: decision.memoryCompatibilityKey ?? "chat-memory",
    routingVersion: decision.routingVersion,
    useCase: decision.useCase,
    routingReasonTags: decision.routingReasonTags,
    attemptReason: "plain_text_after_structured_failures",
    fallbackHopCount: attempts.length,
  });

  return dedupeChatAttempts(attempts);
}

export function buildWorkoutSummaryRoutingAttempts(
  env: EnvLike,
  decision: RoutingDecision
): WorkoutSummaryRoutingAttempt[] {
  const alternateRole =
    decision.modelRole === "summary_balanced" ? "summary_fast" : "summary_balanced";
  const alternateModel = resolveModelForRole(
    env,
    decision.provider,
    alternateRole
  );
  const fallbackModel = resolveModelForRole(
    env,
    decision.provider,
    "sync_fallback"
  );

  return dedupeWorkoutSummaryAttempts([
    {
      provider: decision.provider,
      modelRole: decision.modelRole,
      selectedModel: decision.selectedModel,
      contextProfile: "rich_async_v1",
      promptProfile: "workout_summary_rich_async_v1",
      payloadTier: "full",
      mode: "structured",
      fallbackStage: "primary",
      structuredAdapter: decision.structuredAdapter,
      routingVersion: decision.routingVersion,
      useCase: "workout_summary",
      routingReasonTags: decision.routingReasonTags,
      attemptReason: "primary_selected_route",
      fallbackHopCount: 0,
    },
    {
      provider: decision.provider,
      modelRole: decision.modelRole,
      selectedModel: decision.selectedModel,
      contextProfile: "rich_async_v1",
      promptProfile: "workout_summary_rich_async_v1_reduced",
      payloadTier: "reduced",
      mode: "structured",
      fallbackStage: "same_model_reduced_payload",
      structuredAdapter: decision.structuredAdapter,
      routingVersion: decision.routingVersion,
      useCase: "workout_summary",
      routingReasonTags: decision.routingReasonTags,
      attemptReason: "same_model_reduced_payload_after_failure",
      fallbackHopCount: 1,
    },
    {
      provider: decision.provider,
      modelRole: alternateRole,
      selectedModel: alternateModel,
      contextProfile: "rich_async_v1",
      promptProfile: "workout_summary_rich_async_v1_reduced",
      payloadTier: "reduced",
      mode: "structured",
      fallbackStage: "alternate_model_reduced_payload",
      structuredAdapter: resolveModelCapability(
        decision.provider,
        alternateModel
      ).structuredAdapter,
      routingVersion: decision.routingVersion,
      useCase: "workout_summary",
      routingReasonTags: decision.routingReasonTags,
      attemptReason: "alternate_main_tier_after_reduced_payload_failure",
      fallbackHopCount: 2,
    },
    {
      provider: decision.provider,
      modelRole: "sync_fallback",
      selectedModel: fallbackModel,
      contextProfile: "rich_async_v1",
      promptProfile: "workout_summary_rich_async_v1_reduced",
      payloadTier: "reduced",
      mode: "structured",
      fallbackStage: "sync_fallback_structured",
      structuredAdapter: resolveModelCapability(
        decision.provider,
        fallbackModel
      ).structuredAdapter,
      routingVersion: decision.routingVersion,
      useCase: "workout_summary",
      routingReasonTags: decision.routingReasonTags,
      attemptReason: "sync_fallback_structured_after_main_tier_failures",
      fallbackHopCount: 3,
    },
    {
      provider: decision.provider,
      modelRole: "sync_fallback",
      selectedModel: fallbackModel,
      contextProfile: "rich_async_v1",
      promptProfile: "workout_summary_rich_async_v1_reduced",
      payloadTier: "reduced",
      mode: "plain_text_fallback",
      fallbackStage: "sync_fallback_plain_text",
      structuredAdapter: resolveModelCapability(
        decision.provider,
        fallbackModel
      ).structuredAdapter,
      routingVersion: decision.routingVersion,
      useCase: "workout_summary",
      routingReasonTags: decision.routingReasonTags,
      attemptReason: "plain_text_after_structured_failures",
      fallbackHopCount: 4,
    },
  ]);
}

export function buildProfileInsightsRoutingAttempts(
  env: EnvLike,
  decision: RoutingDecision
): ProfileInsightsRoutingAttempt[] {
  const memoryCompatibilityKey =
    decision.memoryCompatibilityKey ?? "profile-insights-memory";
  const balancedModel = resolveModelForRole(
    env,
    decision.provider,
    "insights_balanced"
  );
  const syncFallbackModel = resolveModelForRole(
    env,
    decision.provider,
    "sync_fallback"
  );
  const attempts: ProfileInsightsRoutingAttempt[] = [
    {
      provider: decision.provider,
      modelRole: decision.modelRole,
      selectedModel: decision.selectedModel,
      contextProfile: "compact_sync_v2",
      promptProfile: "profile_compact_context_v2",
      payloadTier: "compact",
      mode: "structured",
      fallbackStage: "primary",
      structuredAdapter: decision.structuredAdapter,
      memoryCompatibilityKey,
      routingVersion: decision.routingVersion,
      useCase: "profile_insights",
      routingReasonTags: decision.routingReasonTags,
      attemptReason: "primary_selected_route",
      fallbackHopCount: 0,
    },
    {
      provider: decision.provider,
      modelRole: "insights_balanced",
      selectedModel: balancedModel,
      contextProfile: "compact_sync_v2",
      promptProfile: "profile_compact_context_v2",
      payloadTier: "compact",
      mode: "structured",
      fallbackStage: "insights_balanced_structured",
      structuredAdapter: resolveModelCapability(
        decision.provider,
        balancedModel
      ).structuredAdapter,
      memoryCompatibilityKey,
      routingVersion: decision.routingVersion,
      useCase: "profile_insights",
      routingReasonTags: decision.routingReasonTags,
      attemptReason: "balanced_structured_after_fast_failure",
      fallbackHopCount: 1,
    },
  ];

  if (decision.escalationEligible) {
    const escalationModel = resolveModelForRole(
      env,
      decision.provider,
      "quality_escalation"
    );
    if (escalationModel !== balancedModel) {
      attempts.push({
        modelRole: "quality_escalation",
        provider: decision.provider,
        selectedModel: escalationModel,
        contextProfile: "compact_sync_v2",
        promptProfile: "profile_compact_context_v2",
        payloadTier: "compact",
        mode: "structured",
        fallbackStage: "quality_escalation_structured",
        structuredAdapter:
          resolveModelCapability(
            decision.provider,
            escalationModel
          ).structuredAdapter,
        memoryCompatibilityKey,
        routingVersion: decision.routingVersion,
        useCase: "profile_insights",
        routingReasonTags: decision.routingReasonTags,
        attemptReason: "quality_escalation_after_balanced_failure",
        fallbackHopCount: attempts.length,
      });
    }
  }

  attempts.push({
    provider: decision.provider,
    modelRole: "sync_fallback",
    selectedModel: syncFallbackModel,
    contextProfile: "compact_sync_v2",
    promptProfile: "profile_compact_context_v2",
    payloadTier: "compact",
    mode: "plain_text_fallback",
    fallbackStage: "sync_fallback_plain_text",
    structuredAdapter: resolveModelCapability(
      decision.provider,
      syncFallbackModel
    ).structuredAdapter,
    memoryCompatibilityKey,
    routingVersion: decision.routingVersion,
    useCase: "profile_insights",
    routingReasonTags: decision.routingReasonTags,
    attemptReason: "plain_text_after_structured_failures",
    fallbackHopCount: attempts.length,
  });

  return dedupeProfileInsightsAttempts(attempts);
}

export function resolvePrimaryChatExecutionProfile(
  decision: RoutingDecision
): {
  contextProfile: CoachContextProfile;
  promptProfile: string;
} {
  const contextProfile = decision.allowedContextProfiles[0] ?? "compact_sync_v2";
  return {
    contextProfile,
    promptProfile: resolveChatPromptProfile(
      decision.useCase,
      contextProfile,
      "primary"
    ),
  };
}

export function buildMemoryCompatibilityKey(
  provider: CoachAIProvider,
  outputContract: CoachOutputContract,
  promptFamily: string,
  contextFamily: string,
  memoryProfile: CoachMemoryProfile,
  routingVersion: string
): string {
  return [
    provider,
    outputContract,
    promptFamily,
    contextFamily,
    memoryProfile,
    routingVersion,
  ].join(":");
}

function classifyChatUseCase(
  request: CoachChatRequest,
  timeoutProfile: "sync" | "async_job" | undefined
): CoachRoutingUseCase {
  const question = request.question.toLowerCase();
  const hasRecentTurns = request.clientRecentTurns.length > 0;
  const snapshot = request.snapshot;
  const hasTrainingData = Boolean(
    snapshot &&
      (snapshot.recentFinishedSessions.length > 0 ||
        snapshot.analytics.recentPersonalRecords.length > 0 ||
        snapshot.preferredProgram?.workouts.length)
  );

  if (!hasTrainingData) {
    return "low_data_case";
  }

  if (
    /(redesign|rebuild|rewrite|overhaul|switch.*split|change.*split|new program|program redesign|upper lower|push pull|full body|programa|програм|сплит)/i.test(
      question
    )
  ) {
    return "program_redesign";
  }

  if (/(lagging|imbalance|undertrained|weak point|отста|дисбаланс)/i.test(question)) {
    return "lagging_muscle_imbalance";
  }

  if (
    /(rolling rotation|rotation|split|weekly target|frequency|days per week|mismatch|calendar|ротац|частот|сплит)/i.test(
      question
    )
  ) {
    return "rolling_rotation_split_reasoning";
  }

  if (hasRecentTurns && timeoutProfile === "async_job") {
    return "follow_up_clarification";
  }

  return "simple_qna";
}

function defaultChatModelRole(useCase: CoachRoutingUseCase): CoachModelRole {
  switch (useCase) {
    case "rolling_rotation_split_reasoning":
    case "lagging_muscle_imbalance":
    case "program_redesign":
      return "chat_balanced";
    default:
      return "chat_fast";
  }
}

function resolveChatContextProfiles(
  useCase: CoachRoutingUseCase,
  options: { timeoutProfile?: "sync" | "async_job" } = {}
): CoachContextProfile[] {
  if (options.timeoutProfile !== "async_job") {
    return ["compact_sync_v2"];
  }

  switch (useCase) {
    case "rolling_rotation_split_reasoning":
    case "lagging_muscle_imbalance":
    case "program_redesign":
      return ["rich_async_analytics_v1", "rich_async_v1", "compact_sync_v2"];
    case "low_data_case":
      return ["compact_sync_v2"];
    default:
      return ["rich_async_v1", "compact_sync_v2"];
  }
}

function resolveChatPromptFamily(
  useCase: CoachRoutingUseCase,
  options: { timeoutProfile?: "sync" | "async_job" } = {}
): string {
  if (options.timeoutProfile !== "async_job") {
    return "chat_sync_default_v1";
  }

  switch (useCase) {
    case "rolling_rotation_split_reasoning":
    case "lagging_muscle_imbalance":
    case "program_redesign":
      return "chat_async_reasoning_v1";
    case "low_data_case":
      return "chat_sync_low_data_v1";
    default:
      return "chat_async_default_v1";
  }
}

function resolveChatPromptProfile(
  useCase: CoachRoutingUseCase,
  contextProfile: CoachContextProfile,
  phase: "primary" | "reduced" | "alternate" | "reduced_model"
): string {
  if (contextProfile === "rich_async_analytics_v1") {
    return "chat_rich_async_analytics_v1";
  }

  if (contextProfile === "rich_async_v1") {
    if (
      useCase === "rolling_rotation_split_reasoning" ||
      useCase === "lagging_muscle_imbalance" ||
      useCase === "program_redesign"
    ) {
      return "chat_rich_async_v1_reduced";
    }
    return phase === "primary" ? "chat_rich_async_v1" : "chat_rich_async_v1_reduced";
  }

  if (useCase === "low_data_case" && phase === "primary") {
    return "chat_compact_sync_v2";
  }

  return "chat_compact_sync_v2_reduced";
}

function resolveContextFamily(
  contextProfiles: CoachContextProfile[]
): string {
  return contextProfiles.some(
    (profile) =>
      profile === "rich_async_v1" || profile === "rich_async_analytics_v1"
  )
    ? "rich_async_family"
    : "compact_sync_family";
}

function buildChatRoutingReasonTags(
  env: EnvLike,
  request: CoachChatRequest,
  useCase: CoachRoutingUseCase,
  modelRole: CoachModelRole,
  allowedContextProfiles: CoachContextProfile[],
  timeoutProfile: "sync" | "async_job" | undefined
): string[] {
  const hasTrainingData = Boolean(
    request.snapshot &&
      (request.snapshot.recentFinishedSessions.length > 0 ||
        request.snapshot.analytics.recentPersonalRecords.length > 0 ||
        request.snapshot.preferredProgram?.workouts.length)
  );

  return [
    "operation:chat",
    `provider:${resolveProvider(request.provider, undefined)}`,
    `use_case:${useCase}`,
    `model_role:${modelRole}`,
    `timeout_profile:${timeoutProfile ?? "sync_default"}`,
    `context_family:${resolveContextFamily(allowedContextProfiles)}`,
    `primary_context:${allowedContextProfiles[0] ?? "compact_sync_v2"}`,
    `recent_turns:${request.clientRecentTurns.length > 0 ? "yes" : "no"}`,
    `training_data:${hasTrainingData ? "yes" : "no"}`,
    `routing_enabled:${isModelRoutingEnabled(env) ? "true" : "false"}`,
  ];
}

function buildSummaryRoutingReasonTags(
  env: EnvLike,
  provider: CoachAIProvider,
  modelRole: CoachModelRole
): string[] {
  return [
    "operation:workout_summary",
    `provider:${provider}`,
    "use_case:workout_summary",
    `model_role:${modelRole}`,
    "timeout_profile:async_job",
    "context_family:rich_async_family",
    "primary_context:rich_async_v1",
    `routing_enabled:${isModelRoutingEnabled(env) ? "true" : "false"}`,
  ];
}

function buildProfileInsightsRoutingReasonTags(
  env: EnvLike,
  provider: CoachAIProvider,
  modelRole: CoachModelRole
): string[] {
  return [
    "operation:profile_insights",
    `provider:${provider}`,
    "use_case:profile_insights",
    `model_role:${modelRole}`,
    "timeout_profile:sync",
    "context_family:compact_sync_family",
    "primary_context:compact_sync_v2",
    `routing_enabled:${isModelRoutingEnabled(env) ? "true" : "false"}`,
  ];
}

function dedupeChatAttempts(attempts: ChatRoutingAttempt[]): ChatRoutingAttempt[] {
  const seen = new Set<string>();
  return attempts.filter((attempt) => {
    const key = [
      attempt.selectedModel,
      attempt.contextProfile,
      attempt.mode,
    ].join("|");
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}

function dedupeWorkoutSummaryAttempts(
  attempts: WorkoutSummaryRoutingAttempt[]
): WorkoutSummaryRoutingAttempt[] {
  const seen = new Set<string>();
  return attempts.filter((attempt) => {
    const key = [
      attempt.selectedModel,
      attempt.payloadTier,
      attempt.mode,
    ].join("|");
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}

function dedupeProfileInsightsAttempts(
  attempts: ProfileInsightsRoutingAttempt[]
): ProfileInsightsRoutingAttempt[] {
  const seen = new Set<string>();
  return attempts
    .filter((attempt) => {
      const key = [attempt.selectedModel, attempt.mode].join("|");
      if (seen.has(key)) {
        return false;
      }
      seen.add(key);
      return true;
    })
    .map((attempt, index) => ({
      ...attempt,
      fallbackHopCount: index,
    }));
}

function parseBooleanFlag(value: string | undefined): boolean {
  if (!value) {
    return false;
  }

  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

function coerceUseCase(
  value: string | undefined,
  fallback: CoachRoutingUseCase
): CoachRoutingUseCase {
  return isRoutingUseCase(value) ? value : fallback;
}

function coerceModelRole(
  value: string | undefined,
  fallback: CoachModelRole
): CoachModelRole {
  return isModelRole(value) ? value : fallback;
}

function isRoutingUseCase(value: string | undefined): value is CoachRoutingUseCase {
  return (
    value === "simple_qna" ||
    value === "follow_up_clarification" ||
    value === "workout_summary" ||
    value === "rolling_rotation_split_reasoning" ||
    value === "lagging_muscle_imbalance" ||
    value === "program_redesign" ||
    value === "low_data_case" ||
    value === "profile_insights"
  );
}

function isModelRole(value: string | undefined): value is CoachModelRole {
  return (
    value === "chat_fast" ||
    value === "chat_balanced" ||
    value === "chat_reduced_context" ||
    value === "summary_fast" ||
    value === "summary_balanced" ||
    value === "insights_fast" ||
    value === "insights_balanced" ||
    value === "sync_fallback" ||
    value === "quality_escalation"
  );
}

function resolveGeminiModelForRole(
  env: EnvLike,
  role: CoachModelRole,
  options: { allowAlternateRouting?: boolean } = {}
): string {
  const seedModel = env.GEMINI_CHAT_BALANCED_MODEL?.trim() || DEFAULT_GEMINI_CHAT_BALANCED_MODEL;
  const allowAlternateRouting =
    options.allowAlternateRouting ?? isModelRoutingEnabled(env);

  if (!allowAlternateRouting) {
    if (role === "quality_escalation") {
      return seedModel;
    }
    return seedModel;
  }

  switch (role) {
    case "chat_fast":
      return env.GEMINI_CHAT_FAST_MODEL?.trim() || DEFAULT_GEMINI_CHAT_FAST_MODEL;
    case "chat_balanced":
      return env.GEMINI_CHAT_BALANCED_MODEL?.trim() || seedModel;
    case "chat_reduced_context":
      return (
        env.GEMINI_CHAT_REDUCED_CONTEXT_MODEL?.trim() ||
        DEFAULT_GEMINI_CHAT_REDUCED_MODEL
      );
    case "summary_fast":
      return env.GEMINI_SUMMARY_FAST_MODEL?.trim() || DEFAULT_GEMINI_SUMMARY_MODEL;
    case "summary_balanced":
      return (
        env.GEMINI_SUMMARY_BALANCED_MODEL?.trim() ||
        env.GEMINI_SUMMARY_FAST_MODEL?.trim() ||
        DEFAULT_GEMINI_SUMMARY_MODEL
      );
    case "insights_fast":
      return (
        env.GEMINI_INSIGHTS_FAST_MODEL?.trim() ||
        DEFAULT_GEMINI_INSIGHTS_MODEL
      );
    case "insights_balanced":
      return (
        env.GEMINI_INSIGHTS_BALANCED_MODEL?.trim() ||
        env.GEMINI_INSIGHTS_FAST_MODEL?.trim() ||
        DEFAULT_GEMINI_INSIGHTS_MODEL
      );
    case "sync_fallback":
      return (
        env.GEMINI_SYNC_FALLBACK_MODEL?.trim() ||
        DEFAULT_GEMINI_SYNC_FALLBACK_MODEL
      );
    case "quality_escalation":
      return env.GEMINI_QUALITY_ESCALATION_MODEL?.trim() || seedModel;
    default:
      return seedModel;
  }
}
