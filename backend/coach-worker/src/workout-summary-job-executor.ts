import type { WorkflowStep } from "cloudflare:workers";
import {
  CoachInferenceServiceError,
  DEFAULT_AI_MODEL,
  createInferenceServiceForProvider,
  type CoachInferenceService,
  type Env,
} from "./openai";
import {
  CloudflareCoachStateRepository,
  type CoachStateStore,
  type CoachWorkoutSummaryJobRecord,
} from "./state";
import type { CoachChatJobError } from "./schemas";

const DEFAULT_WORKFLOW_STEP_CONFIG = {
  timeout: "10 minutes",
  retries: {
    limit: 5,
    delay: "10 seconds",
    backoff: "exponential" as const,
  },
} as const;

export interface WorkoutSummaryWorkflowPayload {
  jobID: string;
}

interface WorkoutSummaryExecutionDependencies {
  createInferenceService?: (
    env: Env,
    provider: "workers_ai" | "gemini"
  ) => CoachInferenceService;
  createStateRepository?: (env: Env) => CoachStateStore;
  now?: () => number;
}

export async function executeWorkoutSummaryJob(
  jobID: string,
  env: Env,
  deps: WorkoutSummaryExecutionDependencies = {},
  step?: WorkflowStep
): Promise<CoachWorkoutSummaryJobRecord | null> {
  const createInferenceService =
    deps.createInferenceService ?? createInferenceServiceForProvider;
  const createStateRepository =
    deps.createStateRepository ?? createDefaultStateRepository;
  const now = deps.now ?? Date.now;

  const stateRepository = createStateRepository(env);
  const initialJob = await stateRepository.getWorkoutSummaryJobByID(jobID);

  if (!initialJob) {
    console.error(
      JSON.stringify({
        event: "workout_summary_job_failed",
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
    return expireWorkoutSummaryJob(stateRepository, initialJob, now);
  }

  const startedAt = new Date(now()).toISOString();
  const claimResult = await runWorkflowStep(
    step,
    "mark_workout_summary_job_running",
    DEFAULT_WORKFLOW_STEP_CONFIG,
    async () => {
      const updated = await stateRepository.markWorkoutSummaryJobRunning(
        jobID,
        startedAt
      );
      return {
        claimed: updated.claimed,
        found: Boolean(updated.job),
        status: updated.job?.status ?? null,
      };
    }
  );

  if (!claimResult.found) {
    return null;
  }

  const claimedJob = await stateRepository.getWorkoutSummaryJobByID(jobID);
  if (!claimedJob) {
    throw new Error(`Workout summary job ${jobID} was not found.`);
  }

  if (!claimResult.claimed) {
    if (claimedJob.status === "running") {
      logWorkoutSummaryJobEvent(
        "workout_summary_job_duplicate_execution_skipped",
        claimedJob
      );
    }
    return claimedJob;
  }

  const runningJob = claimedJob;
  if (isJobExpired(runningJob, now())) {
    return expireWorkoutSummaryJob(stateRepository, runningJob, now);
  }
  logWorkoutSummaryJobEvent("workout_summary_job_started", runningJob);
  logWorkoutSummaryJobEvent("workout_summary_job_running", runningJob);

  try {
    await runWorkflowStep(
      step,
      "generate_and_persist_workout_summary",
      DEFAULT_WORKFLOW_STEP_CONFIG,
      async () => {
        const latestJob = await stateRepository.getWorkoutSummaryJobByID(jobID);
        if (!latestJob) {
          throw new Error(`Workout summary job ${jobID} was not found.`);
        }
        if (isTerminalJobStatus(latestJob.status)) {
          return { terminalStatus: latestJob.status };
        }
        if (isJobExpired(latestJob, now())) {
          await expireWorkoutSummaryJob(stateRepository, latestJob, now);
          return { terminalStatus: "failed" as const };
        }

        try {
          const inferenceResult = await inferenceService.generateWorkoutSummary(
            latestJob.preparedRequest
          );
          const completedAt = new Date(now()).toISOString();
          const totalJobDurationMs = Math.max(
            now() - Date.parse(latestJob.createdAt),
            0
          );
          const inferenceMode =
            inferenceResult.mode === "plain_text_fallback"
              ? "plain_text_fallback"
              : inferenceResult.mode === "degraded_fallback"
                ? "degraded_fallback"
                : "structured";

          await stateRepository.completeWorkoutSummaryJob(jobID, {
            completedAt,
            result: {
              ...inferenceResult.data,
              inferenceMode,
              modelDurationMs:
                inferenceResult.fallbackModelDurationMs ??
                inferenceResult.modelDurationMs,
              totalJobDurationMs,
            },
            promptBytes: inferenceResult.promptBytes,
            fallbackPromptBytes: inferenceResult.fallbackPromptBytes,
            modelDurationMs:
              inferenceResult.fallbackModelDurationMs ??
              inferenceResult.modelDurationMs,
            fallbackModelDurationMs: inferenceResult.fallbackModelDurationMs,
            totalJobDurationMs,
            inferenceMode,
            generationStatus: inferenceResult.data.generationStatus,
          });

          return { terminalStatus: "completed" as const };
        } catch (error) {
          const failure = normalizeWorkoutSummaryJobExecutionError(error);
          if (failure.retryable) {
            throw error;
          }

          const failedAt = new Date(now()).toISOString();
          const totalJobDurationMs = Math.max(
            now() - Date.parse(latestJob.createdAt),
            0
          );
          console.error(
            JSON.stringify({
              event: "workout_summary_job_failure_diagnostics",
              jobID,
              installID: latestJob.installID,
              sessionID: latestJob.sessionID,
              clientRequestID: latestJob.clientRequestID,
              errorCode: failure.code,
              errorMessage:
                error instanceof Error ? error.message.slice(0, 300) : "Unknown error",
              ...extractInferenceErrorDiagnostics(error),
            })
          );
          await stateRepository.failWorkoutSummaryJob(jobID, {
            completedAt: failedAt,
            error: failure,
            promptBytes: extractNumericErrorDetail(error, "promptBytes"),
            fallbackPromptBytes: extractNumericErrorDetail(
              error,
              "fallbackPromptBytes"
            ),
            modelDurationMs: extractNumericErrorDetail(error, "modelDurationMs"),
            fallbackModelDurationMs: extractNumericErrorDetail(
              error,
              "fallbackModelDurationMs"
            ),
            totalJobDurationMs,
            inferenceMode: normalizeInferenceMode(error),
          });

          return { terminalStatus: "failed" as const, errorCode: failure.code };
        }
      }
    );
    const finalJob =
      (await stateRepository.getWorkoutSummaryJobByID(jobID)) ?? runningJob;
    if (finalJob.status === "completed") {
      logWorkoutSummaryJobEvent("workout_summary_job_completed", finalJob);
    } else if (finalJob.status === "failed") {
      logWorkoutSummaryJobEvent("workout_summary_job_failed", finalJob, {
        errorCode: finalJob.error?.code,
      });
    }
    return finalJob;
  } catch (error) {
    const failedAt = new Date(now()).toISOString();
    const currentJob =
      (await stateRepository.getWorkoutSummaryJobByID(jobID)) ?? runningJob;
    const totalJobDurationMs = Math.max(
      now() - Date.parse(currentJob.createdAt),
      0
    );
    const failure = normalizeWorkoutSummaryJobExecutionError(error);
    console.error(
      JSON.stringify({
        event: "workout_summary_job_failure_diagnostics",
        jobID,
        installID: currentJob.installID,
        sessionID: currentJob.sessionID,
        clientRequestID: currentJob.clientRequestID,
        errorCode: failure.code,
        errorMessage:
          error instanceof Error ? error.message.slice(0, 300) : "Unknown error",
        ...extractInferenceErrorDiagnostics(error),
      })
    );
    const failedJob = await stateRepository.failWorkoutSummaryJob(jobID, {
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
    });
    logWorkoutSummaryJobEvent("workout_summary_job_failed", failedJob, {
      errorCode: failure.code,
    });
    return failedJob;
  }
}

function createDefaultStateRepository(env: Env): CoachStateStore {
  if (!env.COACH_STATE_KV || !env.BACKUPS_R2 || !env.APP_META_DB) {
    throw new Error("Workout summary workflow is missing state bindings.");
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

function logWorkoutSummaryJobEvent(
  event: string,
  job: CoachWorkoutSummaryJobRecord,
  extra: Record<string, unknown> = {}
): void {
  const payload = JSON.stringify({
    event,
    jobID: job.jobID,
    installID: job.installID,
    sessionID: job.sessionID,
    clientRequestID: job.clientRequestID,
    fingerprint: job.fingerprint,
    status: job.status,
    requestMode: job.requestMode,
    trigger: job.trigger,
    inputMode: job.inputMode,
    currentExerciseCount: job.currentExerciseCount,
    historyExerciseCount: job.historyExerciseCount,
    historySessionCount: job.historySessionCount,
    promptVersion: job.promptVersion,
    model: job.model,
    provider: job.provider ?? job.preparedRequest.metadata?.provider ?? "workers_ai",
    useCase: job.preparedRequest.metadata?.useCase,
    modelRole: job.preparedRequest.metadata?.modelRole,
    selectedModel: job.preparedRequest.metadata?.selectedModel,
    routingVersion: job.preparedRequest.metadata?.routingVersion,
    promptBytes: job.promptBytes,
    fallbackPromptBytes: job.fallbackPromptBytes,
    modelDurationMs: job.modelDurationMs,
    fallbackModelDurationMs: job.fallbackModelDurationMs,
    totalJobDurationMs: job.totalJobDurationMs,
    inferenceMode: job.inferenceMode,
    generationStatus: job.generationStatus,
    ...extra,
  });

  if (event === "workout_summary_job_failed") {
    console.error(payload);
    return;
  }

  console.log(payload);
}

function normalizeWorkoutSummaryJobExecutionError(
  error: unknown
): CoachChatJobError {
  if (error instanceof CoachInferenceServiceError) {
    return {
      code: error.code,
      message: shouldExposeInferenceErrorMessage(error.code)
        ? error.message
        : "Coach upstream request failed.",
      retryable: isRetryableInferenceErrorCode(error.code),
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

function extractInferenceErrorDiagnostics(
  error: unknown
): Record<string, unknown> {
  if (!(error instanceof CoachInferenceServiceError)) {
    return {};
  }

  return {
    requestedModel: error.details?.requestedModel,
    attemptedModels: error.details?.attemptedModels,
    fallbackModelUsed: error.details?.fallbackModelUsed,
    providerQuotaExhausted: error.details?.providerQuotaExhausted,
    geminiDailyQuotaExhausted: error.details?.geminiDailyQuotaExhausted,
    providerFamilyBlocked: error.details?.providerFamilyBlocked,
    blockedUntil: error.details?.blockedUntil,
    quotaClassificationKind: error.details?.quotaClassificationKind,
    requestPath: error.details?.requestPath,
    sourceProviderErrorStatus: error.details?.sourceProviderErrorStatus,
    sourceProviderErrorCode: error.details?.sourceProviderErrorCode,
    providerFamily: error.details?.providerFamily,
    emergencyFallbackUsed: error.details?.emergencyFallbackUsed,
  };
}

function extractNumericErrorDetail(
  error: unknown,
  key: string
): number | undefined {
  const details =
    error instanceof CoachInferenceServiceError ? error.details : undefined;
  const value = details?.[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function normalizeInferenceMode(error: unknown): CoachWorkoutSummaryJobRecord["inferenceMode"] {
  const details =
    error instanceof CoachInferenceServiceError ? error.details : undefined;
  const mode = details?.mode;
  return mode === "structured" ||
    mode === "plain_text_fallback" ||
    mode === "degraded_fallback"
    ? mode
    : undefined;
}

function isTerminalJobStatus(status: CoachWorkoutSummaryJobRecord["status"]): boolean {
  return status === "completed" || status === "failed" || status === "canceled";
}

function isJobExpired(
  job: CoachWorkoutSummaryJobRecord,
  nowMs: number
): boolean {
  const deadlineAt = job.preparedRequest.metadata?.jobDeadlineAt;
  if (!deadlineAt) {
    return false;
  }

  const deadlineMs = Date.parse(deadlineAt);
  return Number.isFinite(deadlineMs) && nowMs >= deadlineMs;
}

async function expireWorkoutSummaryJob(
  stateRepository: CoachStateStore,
  job: CoachWorkoutSummaryJobRecord,
  now: () => number
): Promise<CoachWorkoutSummaryJobRecord> {
  const failedAt = new Date(now()).toISOString();
  const totalJobDurationMs = Math.max(now() - Date.parse(job.createdAt), 0);
  return stateRepository.failWorkoutSummaryJob(job.jobID, {
    completedAt: failedAt,
    error: {
      code: "job_ttl_expired",
      message: "Workout summary job exceeded its execution deadline.",
      retryable: false,
    },
    totalJobDurationMs,
  });
}
