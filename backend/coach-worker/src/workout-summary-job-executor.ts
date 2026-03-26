import type { WorkflowStep } from "cloudflare:workers";
import {
  CoachInferenceServiceError,
  DEFAULT_AI_MODEL,
  createWorkersAICoachService,
  type CoachInferenceService,
  type Env,
} from "./openai";
import {
  CloudflareCoachStateRepository,
  type CoachStateStore,
  type CoachWorkoutSummaryJobRecord,
} from "./state";
import type { CoachChatJobError } from "./schemas";

export interface WorkoutSummaryWorkflowPayload {
  jobID: string;
}

interface WorkoutSummaryExecutionDependencies {
  createInferenceService?: (env: Env) => CoachInferenceService;
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
    deps.createInferenceService ?? createWorkersAICoachService;
  const createStateRepository =
    deps.createStateRepository ?? createDefaultStateRepository;
  const now = deps.now ?? Date.now;

  const stateRepository = createStateRepository(env);
  const inferenceService = createInferenceService(env);
  const initialJob = await stateRepository.getWorkoutSummaryJobByID(jobID);

  if (!initialJob) {
    console.error(
      JSON.stringify({
        event: "workout_summary_job_failed",
        jobID,
        errorCode: "job_not_found",
      })
    );
    return null;
  }

  if (isTerminalJobStatus(initialJob.status)) {
    return initialJob;
  }

  const startedAt = new Date(now()).toISOString();
  const claimResult = await runWorkflowStep(
    step,
    "mark_workout_summary_job_running",
    async () => stateRepository.markWorkoutSummaryJobRunning(jobID, startedAt)
  );

  if (!claimResult.job) {
    return null;
  }

  if (!claimResult.claimed) {
    if (claimResult.job.status === "running") {
      logWorkoutSummaryJobEvent(
        "workout_summary_job_duplicate_execution_skipped",
        claimResult.job
      );
    }
    return claimResult.job;
  }

  const runningJob = claimResult.job;
  logWorkoutSummaryJobEvent("workout_summary_job_started", runningJob);
  logWorkoutSummaryJobEvent("workout_summary_job_running", runningJob);

  try {
    const inferenceResult = await runWorkflowStep(
      step,
      "generate_workout_summary",
      async () => inferenceService.generateWorkoutSummary(runningJob.preparedRequest)
    );

    const completedAt = new Date(now()).toISOString();
    const totalJobDurationMs = Math.max(
      now() - Date.parse(runningJob.createdAt),
      0
    );
    const inferenceMode =
      inferenceResult.mode === "plain_text_fallback"
        ? "plain_text_fallback"
        : inferenceResult.mode === "degraded_fallback"
          ? "degraded_fallback"
          : "structured";

    const completedJob = await runWorkflowStep(
      step,
      "persist_workout_summary_job_completion",
      async () =>
        stateRepository.completeWorkoutSummaryJob(jobID, {
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
        })
    );

    logWorkoutSummaryJobEvent("workout_summary_job_completed", completedJob);
    return completedJob;
  } catch (error) {
    const failedAt = new Date(now()).toISOString();
    const currentJob =
      (await stateRepository.getWorkoutSummaryJobByID(jobID)) ?? runningJob;
    const totalJobDurationMs = Math.max(
      now() - Date.parse(currentJob.createdAt),
      0
    );
    const failure = normalizeWorkoutSummaryJobExecutionError(error);
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
  callback: () => Promise<T>
): Promise<T> {
  if (!step) {
    return callback();
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
      message: "Coach upstream request failed.",
      retryable: error.code.startsWith("upstream_"),
    };
  }

  return {
    code: "internal_error",
    message: "Internal server error.",
    retryable: true,
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
