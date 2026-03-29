import type { WorkflowStep } from "cloudflare:workers";
import {
  CoachInferenceServiceError,
  DEFAULT_AI_MODEL,
  createInferenceServiceForProvider,
  type CoachInferenceService,
  type Env,
  type InferenceResult,
} from "./openai";
import {
  ActiveCoachChatJobError,
  CloudflareCoachStateRepository,
  type CoachChatJobRecord,
  type CoachStateStore,
} from "./state";
import type { CoachChatJobError, CoachChatResponse } from "./schemas";

const DEFAULT_WORKFLOW_STEP_CONFIG = {
  timeout: "10 minutes",
  retries: {
    limit: 5,
    delay: "10 seconds",
    backoff: "exponential" as const,
  },
} as const;

export interface CoachChatWorkflowPayload {
  jobID: string;
}

interface ChatJobExecutionDependencies {
  createInferenceService?: (
    env: Env,
    provider: "workers_ai" | "gemini"
  ) => CoachInferenceService;
  createStateRepository?: (env: Env) => CoachStateStore;
  now?: () => number;
}

type ChatJobFailureOrigin =
  | "claim"
  | "inference"
  | "persist_completion"
  | "memory_commit"
  | "workflow_runtime";

type GeneratedChatResponse = {
  latestJob: CoachChatJobRecord;
  inferenceResult: InferenceResult<CoachChatResponse>;
  inferenceMode: NonNullable<CoachChatJobRecord["inferenceMode"]>;
  totalJobDurationMs: number;
};

type ChatJobExecutionDiagnostics = {
  errorName: string;
  errorMessage: string;
  stackPreview?: string;
  wasRecognizedAsInferenceError: boolean;
  wasRecognizedAsPersistenceError: boolean;
  inferredCancellation: boolean;
};

class ChatJobExecutionPhaseError extends Error {
  constructor(
    readonly failureOrigin: ChatJobFailureOrigin,
    readonly cause: unknown
  ) {
    super(cause instanceof Error ? cause.message : "Unknown error");
    this.name = cause instanceof Error ? cause.name : "ChatJobExecutionPhaseError";
    this.stack = cause instanceof Error ? cause.stack : undefined;
  }
}

export async function executeChatJob(
  jobID: string,
  env: Env,
  deps: ChatJobExecutionDependencies = {},
  step?: WorkflowStep
): Promise<CoachChatJobRecord | null> {
  const createInferenceService =
    deps.createInferenceService ?? createInferenceServiceForProvider;
  const createStateRepository =
    deps.createStateRepository ?? createDefaultStateRepository;
  const now = deps.now ?? Date.now;

  const stateRepository = createStateRepository(env);
  const initialJob = await stateRepository.getChatJobByID(jobID);

  if (!initialJob) {
    console.error(
      JSON.stringify({
        event: "coach_chat_job_failed",
        jobID,
        provider: "unknown",
        errorCode: "job_not_found",
      })
    );
    return null;
  }

  const inferenceService = createInferenceService(
    env,
    initialJob.provider ?? "workers_ai"
  );

  if (isTerminalJobStatus(initialJob.status)) {
    return initialJob;
  }

  if (isJobExpired(initialJob, now())) {
    return expireChatJob(stateRepository, initialJob, now);
  }

  let currentJobForFailure = initialJob;
  let terminalFailureOrigin: ChatJobFailureOrigin | undefined;

  try {
    const startedAt = new Date(now()).toISOString();
    const claimResult = await runWorkflowStep(
      step,
      "mark_chat_job_running",
      DEFAULT_WORKFLOW_STEP_CONFIG,
      async () => {
        try {
          const updated = await stateRepository.markChatJobRunning(jobID, startedAt);
          return {
            claimed: updated.claimed,
            found: Boolean(updated.job),
            status: updated.job?.status ?? null,
          };
        } catch (error) {
          throw wrapChatJobExecutionError("claim", error);
        }
      }
    );

    if (!claimResult.found) {
      return null;
    }

    const claimedJob = await stateRepository.getChatJobByID(jobID);
    if (!claimedJob) {
      throw new Error(`Coach chat job ${jobID} was not found.`);
    }
    currentJobForFailure = claimedJob;

    if (!claimResult.claimed) {
      if (claimedJob.status === "running") {
        logChatJobEvent(
          "coach_chat_job_duplicate_execution_skipped",
          claimedJob
        );
      }
      return claimedJob;
    }

    const runningJob = claimedJob;

    if (isJobExpired(runningJob, now())) {
      terminalFailureOrigin = "workflow_runtime";
      return expireChatJob(stateRepository, runningJob, now);
    }

    logChatJobEvent("coach_chat_job_started", runningJob);
    logChatJobEvent("coach_chat_job_running", runningJob);

    const generationResult = await runWorkflowStep(
      step,
      "generate_chat_response",
      DEFAULT_WORKFLOW_STEP_CONFIG,
      async () => {
        const latestJob = await stateRepository.getChatJobByID(jobID);
        if (!latestJob) {
          throw new Error(`Coach chat job ${jobID} was not found.`);
        }
        currentJobForFailure = latestJob;
        if (isTerminalJobStatus(latestJob.status)) {
          return { terminalStatus: latestJob.status as CoachChatJobRecord["status"] };
        }
        if (isJobExpired(latestJob, now())) {
          terminalFailureOrigin = "workflow_runtime";
          await expireChatJob(stateRepository, latestJob, now);
          return { terminalStatus: "failed" as const };
        }

        try {
          const inferenceResult = await inferenceService.generateChat(
            latestJob.preparedRequest,
            {
              responseId: latestJob.preparedRequest.responseID,
              timeoutProfile: "async_job",
            }
          );

          return {
            terminalStatus: "generated" as const,
            generated: buildGeneratedChatResponse(
              latestJob,
              inferenceResult,
              now
            ),
          };
        } catch (error) {
          throw wrapChatJobExecutionError("inference", error);
        }
      }
    );

    if (generationResult.terminalStatus === "generated") {
      const generated = generationResult.generated;
      currentJobForFailure = generated.latestJob;
      await runWorkflowStep(
        step,
        "persist_chat_completion",
        DEFAULT_WORKFLOW_STEP_CONFIG,
        async () => {
          logChatCompletionPersistenceEvent(
            "coach_chat_job_persist_started",
            generated.latestJob,
            generated,
            {
              phase: "persist_completion",
              failureOrigin: "persist_completion",
            }
          );

          try {
            await stateRepository.completeChatJob(jobID, {
              completedAt: new Date(now()).toISOString(),
              result: {
                ...generated.inferenceResult.data,
                responseID: generated.latestJob.preparedRequest.responseID,
                inferenceMode: generated.inferenceMode,
                modelDurationMs: generated.inferenceResult.modelDurationMs,
                totalJobDurationMs: generated.totalJobDurationMs,
              },
              promptBytes: generated.inferenceResult.promptBytes,
              fallbackPromptBytes: generated.inferenceResult.fallbackPromptBytes,
              modelDurationMs: generated.inferenceResult.modelDurationMs,
              fallbackModelDurationMs:
                generated.inferenceResult.fallbackModelDurationMs,
              totalJobDurationMs: generated.totalJobDurationMs,
              inferenceMode: generated.inferenceMode,
              generationStatus: generated.inferenceResult.data.generationStatus,
            });
          } catch (error) {
            logChatCompletionPersistenceEvent(
              "coach_chat_job_persist_failed",
              generated.latestJob,
              generated,
              {
                phase: "persist_completion",
                failureOrigin: "persist_completion",
                ...summarizeExecutionError(error),
              }
            );
            throw wrapChatJobExecutionError("persist_completion", error);
          }

          logChatCompletionPersistenceEvent(
            "coach_chat_job_persist_succeeded",
            generated.latestJob,
            generated,
            {
              phase: "persist_completion",
              failureOrigin: "persist_completion",
            }
          );

          return { terminalStatus: "completed" as const };
        }
      );
    }

    const finalJob = (await stateRepository.getChatJobByID(jobID)) ?? runningJob;

    if (finalJob.status === "completed") {
      try {
        await runWorkflowStep(
          step,
          "commit_chat_memory",
          DEFAULT_WORKFLOW_STEP_CONFIG,
          async () => {
            await stateRepository.commitChatJobMemory(jobID);
            return { committed: true };
          }
        );
      } catch (error) {
        console.error(
          JSON.stringify({
            event: "coach_chat_job_memory_commit_failed",
            phase: "memory_commit",
            failureOrigin: "memory_commit",
            jobID: finalJob.jobID,
            installID: finalJob.installID,
            clientRequestID: finalJob.clientRequestID,
            provider: finalJob.provider ?? finalJob.preparedRequest.metadata?.provider ?? "workers_ai",
            status: finalJob.status,
            ...summarizeExecutionError(error),
          })
        );
      }
    }

    if (finalJob.status === "completed") {
      logChatJobEvent("coach_chat_job_completed", finalJob);
    } else if (finalJob.status === "failed") {
      logChatJobEvent("coach_chat_job_failed", finalJob, {
        phase: terminalFailureOrigin ?? "workflow_runtime",
        failureOrigin: terminalFailureOrigin ?? "workflow_runtime",
        errorCode: finalJob.error?.code,
      });
    }
    return finalJob;
  } catch (error) {
    const failedAt = new Date(now()).toISOString();
    const currentJob =
      (await stateRepository.getChatJobByID(jobID)) ?? currentJobForFailure;
    const totalJobDurationMs = Math.max(
      now() - Date.parse(currentJob.createdAt),
      0
    );
    const failureOrigin = resolveFailureOrigin(error);
    const failure = normalizeChatJobExecutionError(error);
    console.error(
      JSON.stringify({
        event: "coach_chat_job_failure_diagnostics",
        phase: failureOrigin,
        failureOrigin,
        jobID,
        installID: currentJob.installID,
        clientRequestID: currentJob.clientRequestID,
        errorCode: failure.code,
        ...summarizeExecutionError(error),
        ...extractInferenceErrorDiagnostics(error),
      })
    );
    const failedJob = await persistFailedStateSafely(
      stateRepository,
      jobID,
      {
        completedAt: failedAt,
        error: failure,
        promptBytes: extractNumericErrorDetail(error, "promptBytes"),
        fallbackPromptBytes: extractNumericErrorDetail(error, "fallbackPromptBytes"),
        modelDurationMs: extractNumericErrorDetail(error, "modelDurationMs"),
        fallbackModelDurationMs: extractNumericErrorDetail(
          error,
          "fallbackModelDurationMs"
        ),
        totalJobDurationMs,
        inferenceMode: normalizeInferenceMode(error),
      },
      currentJob,
      failureOrigin
    );
    logChatJobEvent("coach_chat_job_failed", failedJob, {
      phase: failureOrigin,
      failureOrigin,
      errorCode: failure.code,
    });
    return failedJob;
  }
}

async function persistFailedStateSafely(
  stateRepository: CoachStateStore,
  jobID: string,
  input: {
    completedAt: string;
    error: CoachChatJobError;
    promptBytes?: number;
    fallbackPromptBytes?: number;
    modelDurationMs?: number;
    fallbackModelDurationMs?: number;
    totalJobDurationMs?: number;
    inferenceMode?: CoachChatJobRecord["inferenceMode"];
  },
  fallbackJob: CoachChatJobRecord,
  failureOrigin: ChatJobFailureOrigin
): Promise<CoachChatJobRecord> {
  try {
    return await stateRepository.failChatJob(jobID, input);
  } catch (persistError) {
    console.error(
      JSON.stringify({
        event: "terminal_state_persist_failed",
        phase: failureOrigin,
        failureOrigin,
        jobID,
        installID: fallbackJob.installID,
        clientRequestID: fallbackJob.clientRequestID,
        errorCode: input.error.code,
        persistErrorMessage:
          persistError instanceof Error
            ? persistError.message.slice(0, 300)
            : "Unknown persistence error",
      })
    );

    try {
      return await stateRepository.failChatJob(jobID, input);
    } catch (retryPersistError) {
      console.error(
        JSON.stringify({
          event: "terminal_state_persist_retry_failed",
          phase: failureOrigin,
          failureOrigin,
          jobID,
          installID: fallbackJob.installID,
          clientRequestID: fallbackJob.clientRequestID,
          errorCode: input.error.code,
          persistErrorMessage:
            retryPersistError instanceof Error
              ? retryPersistError.message.slice(0, 300)
              : "Unknown persistence retry error",
        })
      );
      return {
        ...fallbackJob,
        status: "failed",
        completedAt: input.completedAt,
        error: input.error,
        promptBytes: input.promptBytes,
        fallbackPromptBytes: input.fallbackPromptBytes,
        modelDurationMs: input.modelDurationMs,
        fallbackModelDurationMs: input.fallbackModelDurationMs,
        totalJobDurationMs: input.totalJobDurationMs,
        inferenceMode: input.inferenceMode,
      };
    }
  }
}

function createDefaultStateRepository(env: Env): CoachStateStore {
  if (!env.COACH_STATE_KV || !env.BACKUPS_R2 || !env.APP_META_DB) {
    throw new Error("Coach chat job workflow is missing state bindings.");
  }

  return new CloudflareCoachStateRepository(
    env.COACH_STATE_KV,
    env.BACKUPS_R2,
    env.APP_META_DB,
    env.COACH_PROMPT_VERSION?.trim() || "2026-03-25.v1",
    env.AI_MODEL?.trim() || DEFAULT_AI_MODEL
  );
}

async function runWorkflowStep<T>(
  step: WorkflowStep | undefined,
  name: string,
  config: {
    timeout: string;
    retries: {
      limit: number;
      delay: string;
      backoff: "constant" | "linear" | "exponential";
    };
  } | undefined,
  callback: () => Promise<T>
): Promise<T> {
  if (!step) {
    return callback();
  }

  if (config) {
    return (
      step.do as unknown as (
        stepName: string,
        stepConfig: typeof config,
        stepCallback: () => Promise<T>
      ) => Promise<T>
    )(name, config, callback);
  }

  return step.do(name, callback);
}

function logChatJobEvent(
  event: string,
  job: CoachChatJobRecord,
  extra: Record<string, unknown> = {}
): void {
  const phase =
    (typeof extra.phase === "string"
      ? extra.phase
      : typeof extra.failureOrigin === "string"
        ? extra.failureOrigin
        : resolveEventPhase(event)) ?? resolveEventPhase(event);
  const payload = JSON.stringify({
    event,
    phase,
    jobID: job.jobID,
    installID: job.installID,
    clientRequestID: job.clientRequestID,
    status: job.status,
    contextHash: job.contextHash,
    contextSource: job.contextSource,
    chatMemoryHit: job.chatMemoryHit,
    snapshotBytes: job.snapshotBytes,
    recentTurnCount: job.recentTurnCount,
    recentTurnChars: job.recentTurnChars,
    questionChars: job.questionChars,
    promptVersion: job.promptVersion,
    model: job.model,
    provider: job.provider ?? job.preparedRequest.metadata?.provider ?? "workers_ai",
    useCase: job.preparedRequest.metadata?.useCase,
    modelRole: job.preparedRequest.metadata?.modelRole,
    selectedModel: job.preparedRequest.metadata?.selectedModel,
    routingVersion: job.preparedRequest.metadata?.routingVersion,
    memoryCompatibilityKey: job.preparedRequest.metadata?.memoryCompatibilityKey,
    promptBytes: job.promptBytes,
    fallbackPromptBytes: job.fallbackPromptBytes,
    modelDurationMs: job.modelDurationMs,
    fallbackModelDurationMs: job.fallbackModelDurationMs,
    totalJobDurationMs: job.totalJobDurationMs,
    inferenceMode: job.inferenceMode,
    generationStatus: job.generationStatus,
    ...extra,
  });

  if (event === "coach_chat_job_failed") {
    console.error(payload);
    return;
  }

  console.log(payload);
}

function normalizeChatJobExecutionError(error: unknown): CoachChatJobError {
  const cause = unwrapExecutionError(error);

  if (cause instanceof ActiveCoachChatJobError) {
    return {
      code: "chat_job_in_progress",
      message: cause.message,
      retryable: true,
    };
  }

  if (cause instanceof CoachInferenceServiceError) {
    return {
      code: cause.code,
      message: shouldExposeInferenceErrorMessage(cause.code)
        ? cause.message
        : "Coach upstream request failed.",
      retryable: isRetryableInferenceErrorCode(cause.code),
    };
  }

  if (isRuntimeInterruptionLikeError(cause)) {
    return {
      code: "workflow_runtime_interrupted",
      message: "Workflow runtime was interrupted before completion.",
      retryable: true,
    };
  }

  if (isPersistenceError(cause)) {
    return {
      code: "persistence_error",
      message: "Failed to persist job state.",
      retryable: true,
    };
  }

  return {
    code: "internal_error",
    message: "Internal server error.",
    retryable: true,
  };
}

function isRetryableInferenceErrorCode(code: string): boolean {
  if (shouldExposeInferenceErrorMessage(code)) {
    return false;
  }

  return (
    code.startsWith("upstream_") ||
    code === "provider_rate_limited" ||
    code === "provider_unavailable"
  );
}

function shouldExposeInferenceErrorMessage(code: string): boolean {
  return (
    code === "provider_quota_exhausted" ||
    code === "gemini_daily_quota_exhausted" ||
    code === "provider_family_blocked"
  );
}

function resolveEventPhase(event: string): string {
  if (event.includes("started") || event.includes("running")) {
    return "claim";
  }
  if (event.includes("duplicate") || event.includes("skipped")) {
    return "claim";
  }
  if (event.includes("memory")) {
    return "memory_commit";
  }
  if (event.includes("persist")) {
    return "persist_completion";
  }
  if (event.includes("completed")) {
    return "persist_completion";
  }
  return "workflow_runtime";
}

function buildGeneratedChatResponse(
  latestJob: CoachChatJobRecord,
  inferenceResult: InferenceResult<CoachChatResponse>,
  now: () => number
): GeneratedChatResponse {
  return {
    latestJob,
    inferenceResult,
    inferenceMode:
      inferenceResult.mode === "plain_text_fallback"
        ? "plain_text_fallback"
        : inferenceResult.mode === "degraded_fallback"
          ? "degraded_fallback"
          : "structured",
    totalJobDurationMs: Math.max(now() - Date.parse(latestJob.createdAt), 0),
  };
}

function logChatCompletionPersistenceEvent(
  event: string,
  job: CoachChatJobRecord,
  generated: GeneratedChatResponse,
  extra: Record<string, unknown> = {}
): void {
  const payload = JSON.stringify({
    event,
    phase: "persist_completion",
    jobID: job.jobID,
    installID: job.installID,
    clientRequestID: job.clientRequestID,
    selectedModel:
      generated.inferenceResult.selectedModel ??
      job.preparedRequest.metadata?.selectedModel ??
      generated.inferenceResult.model,
    modelRole:
      generated.inferenceResult.modelRole ?? job.preparedRequest.metadata?.modelRole,
    inferenceMode: generated.inferenceMode,
    generationStatus: generated.inferenceResult.data.generationStatus,
    promptBytes: generated.inferenceResult.promptBytes,
    fallbackPromptBytes: generated.inferenceResult.fallbackPromptBytes,
    modelDurationMs: generated.inferenceResult.modelDurationMs,
    fallbackModelDurationMs: generated.inferenceResult.fallbackModelDurationMs,
    totalJobDurationMs: generated.totalJobDurationMs,
    requestedModel: generated.inferenceResult.requestedModel,
    attemptedModels: generated.inferenceResult.attemptedModels,
    fallbackModelUsed: generated.inferenceResult.fallbackModelUsed,
    providerQuotaExhausted: generated.inferenceResult.providerQuotaExhausted,
    geminiDailyQuotaExhausted:
      generated.inferenceResult.geminiDailyQuotaExhausted,
    providerFamilyBlocked: generated.inferenceResult.providerFamilyBlocked,
    blockedUntil: generated.inferenceResult.blockedUntil,
    quotaClassificationKind: generated.inferenceResult.quotaClassificationKind,
    requestPath: generated.inferenceResult.requestPath,
    sourceProviderErrorStatus:
      generated.inferenceResult.sourceProviderErrorStatus,
    sourceProviderErrorCode: generated.inferenceResult.sourceProviderErrorCode,
    providerFamily: generated.inferenceResult.providerFamily,
    emergencyFallbackUsed: generated.inferenceResult.emergencyFallbackUsed,
    ...extra,
  });

  if (event.includes("failed")) {
    console.error(payload);
    return;
  }

  console.log(payload);
}

function wrapChatJobExecutionError(
  failureOrigin: ChatJobFailureOrigin,
  error: unknown
): ChatJobExecutionPhaseError {
  if (error instanceof ChatJobExecutionPhaseError) {
    return error;
  }

  return new ChatJobExecutionPhaseError(failureOrigin, error);
}

function resolveFailureOrigin(error: unknown): ChatJobFailureOrigin {
  return error instanceof ChatJobExecutionPhaseError
    ? error.failureOrigin
    : "workflow_runtime";
}

function unwrapExecutionError(error: unknown): unknown {
  return error instanceof ChatJobExecutionPhaseError ? error.cause : error;
}

function summarizeExecutionError(error: unknown): ChatJobExecutionDiagnostics {
  const cause = unwrapExecutionError(error);
  const recognizedInferenceError = cause instanceof CoachInferenceServiceError;
  const recognizedPersistenceError = isPersistenceError(cause);
  return {
    errorName:
      cause instanceof Error && cause.name.trim().length > 0
        ? cause.name
        : "UnknownError",
    errorMessage:
      cause instanceof Error ? cause.message.slice(0, 300) : "Unknown error",
    stackPreview:
      cause instanceof Error && cause.stack
        ? cause.stack.split("\n").slice(0, 4).join("\n").slice(0, 600)
        : undefined,
    wasRecognizedAsInferenceError: recognizedInferenceError,
    wasRecognizedAsPersistenceError: recognizedPersistenceError,
    inferredCancellation: isRuntimeInterruptionLikeError(cause),
  };
}

function extractInferenceErrorDiagnostics(
  error: unknown
): Record<string, unknown> {
  const cause = unwrapExecutionError(error);
  if (!(cause instanceof CoachInferenceServiceError)) {
    return {};
  }

  return {
    requestedModel: cause.details?.requestedModel,
    attemptedModels: cause.details?.attemptedModels,
    fallbackModelUsed: cause.details?.fallbackModelUsed,
    providerQuotaExhausted: cause.details?.providerQuotaExhausted,
    geminiDailyQuotaExhausted: cause.details?.geminiDailyQuotaExhausted,
    providerFamilyBlocked: cause.details?.providerFamilyBlocked,
    blockedUntil: cause.details?.blockedUntil,
    quotaClassificationKind: cause.details?.quotaClassificationKind,
    requestPath: cause.details?.requestPath,
    sourceProviderErrorStatus: cause.details?.sourceProviderErrorStatus,
    sourceProviderErrorCode: cause.details?.sourceProviderErrorCode,
    providerFamily: cause.details?.providerFamily,
    emergencyFallbackUsed: cause.details?.emergencyFallbackUsed,
  };
}

function isRuntimeInterruptionLikeError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }

  const name = error.name.toLowerCase();
  const message = error.message.toLowerCase();
  const stack = error.stack?.toLowerCase() ?? "";

  return (
    name.includes("abort") ||
    name.includes("cancel") ||
    message.includes("abort") ||
    message.includes("canceled") ||
    message.includes("cancelled") ||
    message.includes("promise will never complete") ||
    message.includes("script will never generate a response") ||
    message.includes("workflow cancellation") ||
    message.includes("workflow cancelled") ||
    message.includes("workflow canceled") ||
    message.includes("context canceled") ||
    message.includes("context cancelled") ||
    message.includes("rpc context cancellation") ||
    message.includes("rpc context canceled") ||
    stack.includes("aborterror")
  );
}

function isPersistenceError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }
  const message = error.message.toLowerCase();
  return (
    message.includes("d1") ||
    message.includes("kv") ||
    message.includes("r2") ||
    message.includes("persist") ||
    message.includes("sqlite")
  );
}

function extractNumericErrorDetail(
  error: unknown,
  key: string
): number | undefined {
  const cause = unwrapExecutionError(error);
  const details =
    cause instanceof CoachInferenceServiceError ? cause.details : undefined;
  const value = details?.[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function normalizeInferenceMode(error: unknown): CoachChatJobRecord["inferenceMode"] {
  const cause = unwrapExecutionError(error);
  const details =
    cause instanceof CoachInferenceServiceError ? cause.details : undefined;
  const mode = details?.mode;
  return mode === "structured" ||
    mode === "plain_text_fallback" ||
    mode === "degraded_fallback"
    ? mode
    : undefined;
}

function isTerminalJobStatus(status: CoachChatJobRecord["status"]): boolean {
  return status === "completed" || status === "failed" || status === "canceled";
}

function isJobExpired(
  job: CoachChatJobRecord,
  nowMs: number
): boolean {
  const deadlineAt = job.preparedRequest.metadata?.jobDeadlineAt;
  if (!deadlineAt) {
    return false;
  }

  const deadlineMs = Date.parse(deadlineAt);
  return Number.isFinite(deadlineMs) && nowMs >= deadlineMs;
}

async function expireChatJob(
  stateRepository: CoachStateStore,
  job: CoachChatJobRecord,
  now: () => number
): Promise<CoachChatJobRecord> {
  const failedAt = new Date(now()).toISOString();
  const totalJobDurationMs = Math.max(now() - Date.parse(job.createdAt), 0);
  return persistFailedStateSafely(
    stateRepository,
    job.jobID,
    {
      completedAt: failedAt,
      error: {
        code: "job_ttl_expired",
        message: "Chat job exceeded its execution deadline.",
        retryable: false,
      },
      totalJobDurationMs,
    },
    job,
    "workflow_runtime"
  );
}
