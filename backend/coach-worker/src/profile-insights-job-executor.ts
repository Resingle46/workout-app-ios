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
  type CoachProfileInsightsJobRecord,
  type CoachStateStore,
} from "./state";
import type { CoachChatJobError } from "./schemas";

const DEFAULT_WORKFLOW_STEP_CONFIG = {
  timeout: "15 minutes",
  retries: {
    limit: 5,
    delay: "10 seconds",
    backoff: "exponential" as const,
  },
} as const;

export interface ProfileInsightsWorkflowPayload {
  jobID: string;
}

interface ProfileInsightsExecutionDependencies {
  createInferenceService?: (
    env: Env,
    provider: "workers_ai" | "gemini"
  ) => CoachInferenceService;
  createStateRepository?: (env: Env) => CoachStateStore;
  now?: () => number;
}

export async function executeProfileInsightsJob(
  jobID: string,
  env: Env,
  deps: ProfileInsightsExecutionDependencies = {},
  step?: WorkflowStep
): Promise<CoachProfileInsightsJobRecord | null> {
  const createInferenceService =
    deps.createInferenceService ?? createInferenceServiceForProvider;
  const createStateRepository =
    deps.createStateRepository ?? createDefaultStateRepository;
  const now = deps.now ?? Date.now;

  const stateRepository = createStateRepository(env);
  const initialJob = await stateRepository.getProfileInsightsJobByID(jobID);

  if (!initialJob) {
    console.error(
      JSON.stringify({
        event: "profile_insights_job_failed",
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
    return expireProfileInsightsJob(stateRepository, initialJob, now);
  }

  const startedAt = new Date(now()).toISOString();
  const claimResult = await runWorkflowStep(
    step,
    "mark_profile_insights_job_running",
    DEFAULT_WORKFLOW_STEP_CONFIG,
    async () => {
      const updated = await stateRepository.markProfileInsightsJobRunning(
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

  const claimedJob = await stateRepository.getProfileInsightsJobByID(jobID);
  if (!claimedJob) {
    throw new Error(`Profile insights job ${jobID} was not found.`);
  }

  if (!claimResult.claimed) {
    if (claimedJob.status === "running") {
      logProfileInsightsJobEvent(
        "profile_insights_job_duplicate_execution_skipped",
        claimedJob
      );
    }
    return claimedJob;
  }

  const runningJob = claimedJob;
  if (isJobExpired(runningJob, now())) {
    return expireProfileInsightsJob(stateRepository, runningJob, now);
  }
  logProfileInsightsJobEvent("profile_insights_job_started", runningJob);
  logProfileInsightsJobEvent("profile_insights_job_running", runningJob);

  try {
    await runWorkflowStep(
      step,
      "generate_and_persist_profile_insights",
      DEFAULT_WORKFLOW_STEP_CONFIG,
      async () => {
        const latestJob = await stateRepository.getProfileInsightsJobByID(jobID);
        if (!latestJob) {
          throw new Error(`Profile insights job ${jobID} was not found.`);
        }
        if (isTerminalJobStatus(latestJob.status)) {
          return { terminalStatus: latestJob.status };
        }
        if (isJobExpired(latestJob, now())) {
          await expireProfileInsightsJob(stateRepository, latestJob, now);
          return { terminalStatus: "failed" as const };
        }

        try {
          const inferenceResult = await inferenceService.generateProfileInsights(
            latestJob.preparedRequest,
            { timeoutProfile: "async_job" }
          );
          const completedAt = new Date(now()).toISOString();
          const totalJobDurationMs = Math.max(
            now() - Date.parse(latestJob.createdAt),
            0
          );
          const inferenceMode =
            normalizeProfileInsightsInferenceMode(inferenceResult.mode) ??
            "degraded_fallback";

          await stateRepository.completeProfileInsightsJob(jobID, {
            completedAt,
            result: {
              summary: inferenceResult.data.summary,
              keyObservations: inferenceResult.data.keyObservations ?? [],
              topConstraints: inferenceResult.data.topConstraints ?? [],
              recommendations: inferenceResult.data.recommendations ?? [],
              confidenceNotes: inferenceResult.data.confidenceNotes ?? [],
              executionContext: inferenceResult.data.executionContext,
              generationStatus: inferenceResult.data.generationStatus ?? "fallback",
              insightSource: inferenceResult.data.insightSource ?? "fallback",
              selectedModel:
                inferenceResult.data.selectedModel ?? inferenceResult.selectedModel,
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
          const failure = normalizeProfileInsightsJobExecutionError(error);
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
              event: "profile_insights_job_failure_diagnostics",
              jobID,
              installID: latestJob.installID,
              clientRequestID: latestJob.clientRequestID,
              contextHash: latestJob.contextHash,
              errorCode: failure.code,
              errorMessage:
                error instanceof Error ? error.message.slice(0, 300) : "Unknown error",
              ...extractInferenceErrorDiagnostics(error),
            })
          );
          await stateRepository.failProfileInsightsJob(jobID, {
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
            inferenceMode: extractInferenceModeFromError(error),
          });

          return { terminalStatus: "failed" as const, errorCode: failure.code };
        }
      }
    );
    const finalJob =
      (await stateRepository.getProfileInsightsJobByID(jobID)) ?? runningJob;
    if (finalJob.status === "completed") {
      logProfileInsightsJobEvent("profile_insights_job_completed", finalJob);
    } else if (finalJob.status === "failed") {
      logProfileInsightsJobEvent("profile_insights_job_failed", finalJob, {
        errorCode: finalJob.error?.code,
      });
    }
    return finalJob;
  } catch (error) {
    const failedAt = new Date(now()).toISOString();
    const currentJob =
      (await stateRepository.getProfileInsightsJobByID(jobID)) ?? runningJob;
    const totalJobDurationMs = Math.max(
      now() - Date.parse(currentJob.createdAt),
      0
    );
    const failure = normalizeProfileInsightsJobExecutionError(error);
    console.error(
      JSON.stringify({
        event: "profile_insights_job_failure_diagnostics",
        jobID,
        installID: currentJob.installID,
        clientRequestID: currentJob.clientRequestID,
        contextHash: currentJob.contextHash,
        errorCode: failure.code,
        errorMessage:
          error instanceof Error ? error.message.slice(0, 300) : "Unknown error",
        ...extractInferenceErrorDiagnostics(error),
      })
    );
    const failedJob = await stateRepository.failProfileInsightsJob(jobID, {
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
      inferenceMode: extractInferenceModeFromError(error),
    });
    logProfileInsightsJobEvent("profile_insights_job_failed", failedJob, {
      errorCode: failure.code,
    });
    return failedJob;
  }
}

function createDefaultStateRepository(env: Env): CoachStateStore {
  if (!env.COACH_STATE_KV || !env.BACKUPS_R2 || !env.APP_META_DB) {
    throw new Error("Profile insights workflow is missing state bindings.");
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

function logProfileInsightsJobEvent(
  event: string,
  job: CoachProfileInsightsJobRecord,
  extra: Record<string, unknown> = {}
): void {
  const payload = JSON.stringify({
    event,
    jobID: job.jobID,
    installID: job.installID,
    clientRequestID: job.clientRequestID,
    status: job.status,
    contextHash: job.contextHash,
    contextSource: job.contextSource,
    snapshotBytes: job.snapshotBytes,
    programCommentChars: job.programCommentChars,
    recentPrCount: job.recentPrCount,
    relativeStrengthCount: job.relativeStrengthCount,
    preferredProgramWorkoutCount: job.preferredProgramWorkoutCount,
    promptVersion: job.promptVersion,
    model: job.model,
    provider: job.provider ?? job.preparedRequest.metadata?.provider ?? "workers_ai",
    useCase: job.preparedRequest.metadata?.useCase,
    modelRole: job.preparedRequest.metadata?.modelRole,
    selectedModel: job.preparedRequest.metadata?.selectedModel,
    routingVersion: job.preparedRequest.metadata?.routingVersion,
    contextProfile: job.preparedRequest.metadata?.contextProfile,
    promptProfile: job.preparedRequest.metadata?.promptProfile,
    promptFamily: job.preparedRequest.metadata?.promptFamily,
    contextFamily: job.preparedRequest.metadata?.contextFamily,
    routingReasonTags: job.preparedRequest.metadata?.routingReasonTags,
    promptBytes: job.promptBytes,
    fallbackPromptBytes: job.fallbackPromptBytes,
    modelDurationMs: job.modelDurationMs,
    fallbackModelDurationMs: job.fallbackModelDurationMs,
    totalJobDurationMs: job.totalJobDurationMs,
    inferenceMode: job.inferenceMode,
    generationStatus: job.generationStatus,
    ...extra,
  });

  if (event === "profile_insights_job_failed") {
    console.error(payload);
    return;
  }

  console.log(payload);
}

function normalizeProfileInsightsJobExecutionError(
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
    profileGuardrailDowngradedClaims:
      error.details?.profileGuardrailDowngradedClaims,
    profileGuardrailBlockedClaims: error.details?.profileGuardrailBlockedClaims,
    profileGuardrailFullSummaryReplacement:
      error.details?.profileGuardrailFullSummaryReplacement,
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

function extractInferenceModeFromError(
  error: unknown
): CoachProfileInsightsJobRecord["inferenceMode"] {
  const details =
    error instanceof CoachInferenceServiceError ? error.details : undefined;
  return normalizeProfileInsightsInferenceMode(details?.mode);
}

function normalizeProfileInsightsInferenceMode(
  mode: unknown
): CoachProfileInsightsJobRecord["inferenceMode"] {
  if (mode === "structured" || mode === "plain_text_fallback") {
    return mode;
  }
  if (mode === "degraded_fallback" || mode === "local_fallback") {
    return "degraded_fallback";
  }
  return undefined;
}

function isTerminalJobStatus(status: CoachProfileInsightsJobRecord["status"]): boolean {
  return status === "completed" || status === "failed" || status === "canceled";
}

function isJobExpired(
  job: CoachProfileInsightsJobRecord,
  nowMs: number
): boolean {
  const deadlineAt = job.preparedRequest.metadata?.jobDeadlineAt;
  if (!deadlineAt) {
    return false;
  }

  const deadlineMs = Date.parse(deadlineAt);
  return Number.isFinite(deadlineMs) && nowMs >= deadlineMs;
}

async function expireProfileInsightsJob(
  stateRepository: CoachStateStore,
  job: CoachProfileInsightsJobRecord,
  now: () => number
): Promise<CoachProfileInsightsJobRecord> {
  const failedAt = new Date(now()).toISOString();
  const totalJobDurationMs = Math.max(now() - Date.parse(job.createdAt), 0);
  return stateRepository.failProfileInsightsJob(job.jobID, {
    completedAt: failedAt,
    error: {
      code: "job_ttl_expired",
      message: "Profile insights job exceeded its execution deadline.",
      retryable: false,
    },
    totalJobDurationMs,
  });
}
