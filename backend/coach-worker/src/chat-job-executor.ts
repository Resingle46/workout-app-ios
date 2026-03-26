import type { WorkflowStep } from "cloudflare:workers";
import {
  CoachInferenceServiceError,
  DEFAULT_AI_MODEL,
  createWorkersAICoachService,
  type CoachInferenceService,
  type Env,
} from "./openai";
import {
  ActiveCoachChatJobError,
  CloudflareCoachStateRepository,
  type CoachChatJobRecord,
  type CoachStateStore,
} from "./state";
import type { CoachChatJobError } from "./schemas";

export interface CoachChatWorkflowPayload {
  jobID: string;
}

interface ChatJobExecutionDependencies {
  createInferenceService?: (env: Env) => CoachInferenceService;
  createStateRepository?: (env: Env) => CoachStateStore;
  now?: () => number;
}

export async function executeChatJob(
  jobID: string,
  env: Env,
  deps: ChatJobExecutionDependencies = {},
  step?: WorkflowStep
): Promise<CoachChatJobRecord | null> {
  const createInferenceService =
    deps.createInferenceService ?? createWorkersAICoachService;
  const createStateRepository =
    deps.createStateRepository ?? createDefaultStateRepository;
  const now = deps.now ?? Date.now;

  const stateRepository = createStateRepository(env);
  const inferenceService = createInferenceService(env);
  const initialJob = await stateRepository.getChatJobByID(jobID);

  if (!initialJob) {
    console.error(
      JSON.stringify({
        event: "coach_chat_job_failed",
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
    "mark_chat_job_running",
    async () => {
      const updated = await stateRepository.markChatJobRunning(jobID, startedAt);
      if (!updated.job) {
        throw new Error(`Coach chat job ${jobID} was not found.`);
      }
      return updated;
    }
  );

  if (!claimResult.job) {
    return null;
  }

  if (!claimResult.claimed) {
    if (claimResult.job.status === "running") {
      logChatJobEvent(
        "coach_chat_job_duplicate_execution_skipped",
        claimResult.job
      );
    }
    return claimResult.job;
  }

  const runningJob = claimResult.job;

  logChatJobEvent("coach_chat_job_started", runningJob);
  logChatJobEvent("coach_chat_job_running", runningJob);

  try {
    const inferenceResult = await runWorkflowStep(
      step,
      "generate_chat_response",
      async () =>
        inferenceService.generateChat(runningJob.preparedRequest, {
          responseId: runningJob.preparedRequest.responseID,
          timeoutProfile: "async_job",
        })
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
      "persist_chat_job_completion",
      async () =>
        stateRepository.completeChatJob(jobID, {
          completedAt,
          result: {
            ...inferenceResult.data,
            responseID: runningJob.preparedRequest.responseID,
            inferenceMode,
            modelDurationMs: inferenceResult.modelDurationMs,
            totalJobDurationMs,
          },
          promptBytes: inferenceResult.promptBytes,
          fallbackPromptBytes: inferenceResult.fallbackPromptBytes,
          modelDurationMs: inferenceResult.modelDurationMs,
          fallbackModelDurationMs: inferenceResult.fallbackModelDurationMs,
          totalJobDurationMs,
          inferenceMode,
          generationStatus: inferenceResult.data.generationStatus,
        })
    );

    try {
      await runWorkflowStep(step, "commit_chat_memory", async () => {
        await stateRepository.commitChatJobMemory(jobID);
        return { committed: true };
      });
    } catch (error) {
      console.error(
        JSON.stringify({
          event: "coach_chat_job_memory_commit_failed",
          jobID: completedJob.jobID,
          installID: completedJob.installID,
          clientRequestID: completedJob.clientRequestID,
          status: completedJob.status,
          errorMessage:
            error instanceof Error ? error.message.slice(0, 300) : "Unknown error",
        })
      );
    }

    const finalJob = (await stateRepository.getChatJobByID(jobID)) ?? completedJob;
    logChatJobEvent("coach_chat_job_completed", finalJob);
    return finalJob;
  } catch (error) {
    const failedAt = new Date(now()).toISOString();
    const currentJob = (await stateRepository.getChatJobByID(jobID)) ?? runningJob;
    const totalJobDurationMs = Math.max(
      now() - Date.parse(currentJob.createdAt),
      0
    );
    const failure = normalizeChatJobExecutionError(error);
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
      currentJob
    );
    logChatJobEvent("coach_chat_job_failed", failedJob, {
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
  fallbackJob: CoachChatJobRecord
): Promise<CoachChatJobRecord> {
  try {
    return await stateRepository.failChatJob(jobID, input);
  } catch (persistError) {
    console.error(
      JSON.stringify({
        event: "terminal_state_persist_failed",
        phase: "persist_failure",
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
          phase: "persist_failure",
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
  callback: () => Promise<T>
): Promise<T> {
  if (!step) {
    return callback();
  }

  return step.do(name, callback);
}

function logChatJobEvent(
  event: string,
  job: CoachChatJobRecord,
  extra: Record<string, unknown> = {}
): void {
  const payload = JSON.stringify({
    event,
    phase: resolveEventPhase(event),
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
  if (error instanceof ActiveCoachChatJobError) {
    return {
      code: "chat_job_in_progress",
      message: error.message,
      retryable: true,
    };
  }

  if (error instanceof CoachInferenceServiceError) {
    return {
      code: error.code,
      message: "Coach upstream request failed.",
      retryable: error.code.startsWith("upstream_"),
    };
  }

  if (isPersistenceError(error)) {
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

function resolveEventPhase(event: string): string {
  if (event.includes("started") || event.includes("running")) {
    return "claim";
  }
  if (event.includes("completed")) {
    return "persist_completion";
  }
  if (event.includes("failed")) {
    return "persist_failure";
  }
  if (event.includes("memory")) {
    return "memory_commit";
  }
  return "inference";
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
  const details =
    error instanceof CoachInferenceServiceError ? error.details : undefined;
  const value = details?.[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function normalizeInferenceMode(error: unknown): CoachChatJobRecord["inferenceMode"] {
  const details =
    error instanceof CoachInferenceServiceError ? error.details : undefined;
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
