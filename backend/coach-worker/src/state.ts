import {
  buildCoachContextFromSnapshot,
  hashAppSnapshot,
  hashCoachContext,
  jsonByteLength,
  normalizeCoachAnalysisSettings,
  overlayCoachAnalysisSettings,
  stableJSONStringify,
} from "./context";
import type {
  AppSnapshotPayload,
  BackupDownloadResponse,
  BackupEnvelopeV2,
  BackupHead,
  BackupReconcileRequest,
  BackupReconcileResponse,
  BackupUploadRequest,
  BackupUploadResponse,
  CoachChatInferenceMode,
  CoachChatJobCreateRequest,
  CoachChatJobError,
  CoachChatJobResult,
  CoachChatJobStatus,
  CoachChatRequest,
  CoachConversationTurn,
  CoachPreferencesUpdateRequest,
  CoachPreferencesUpdateResponse,
  CoachProfileInsightsRequest,
  CoachProfileInsightsResponse,
  CoachSnapshotSyncRequest,
  CoachWorkoutSummaryInputMode,
  CoachWorkoutSummaryJobCreateRequest,
  CoachWorkoutSummaryJobResult,
  CoachWorkoutSummaryRequestMode,
  CoachWorkoutSummaryTrigger,
  CompactCoachSnapshot,
  CoachRuntimeContextDelta,
} from "./schemas";

const LEGACY_SNAPSHOT_TTL_SECONDS = 30 * 24 * 60 * 60;
const CHAT_MEMORY_TTL_SECONDS = 7 * 24 * 60 * 60;
const INSIGHTS_CACHE_TTL_SECONDS = 6 * 60 * 60;
const CHAT_MEMORY_MAX_TURNS = 4;
const CHAT_MEMORY_MAX_CONTENT_LENGTH = 220;
const CHAT_MEMORY_MAX_TOTAL_CHARACTERS = 600;
const BACKUP_SCHEMA_VERSION = 2;

export interface CoachKVNamespace {
  get(key: string, type: "text"): Promise<string | null>;
  get<T = unknown>(key: string, type: "json"): Promise<T | null>;
  put(
    key: string,
    value: string,
    options?: {
      expirationTtl?: number;
    }
  ): Promise<void>;
  delete(key: string): Promise<void>;
}

export interface CoachR2Object {
  arrayBuffer(): Promise<ArrayBuffer>;
}

export interface CoachR2Bucket {
  get(key: string): Promise<CoachR2Object | null>;
  put(
    key: string,
    value: ReadableStream<Uint8Array> | ArrayBuffer | ArrayBufferView | string,
    options?: {
      httpMetadata?: {
        contentType?: string;
        contentEncoding?: string;
      };
    }
  ): Promise<void>;
  delete(keys: string | string[]): Promise<void>;
}

export interface CoachD1PreparedStatement {
  bind(...values: unknown[]): CoachD1PreparedStatement;
  first<T = Record<string, unknown>>(): Promise<T | null>;
  run(): Promise<unknown>;
  all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
}

export interface CoachD1Database {
  prepare(query: string): CoachD1PreparedStatement;
}

export interface StoredChatMemory {
  updatedAt: string;
  recentTurns: CoachConversationTurn[];
}

export interface StoredLegacyCoachSnapshot {
  hash: string;
  updatedAt: string;
  snapshot: CompactCoachSnapshot;
}

export interface ResolvedCoachContext {
  snapshot: CompactCoachSnapshot;
  contextHash: string;
  cacheAllowed: boolean;
  source: "remote_full" | "inline_legacy" | "stored_legacy";
  backupHead?: BackupHead;
}

export interface PreparedCoachChatJobRequest extends CoachChatRequest {
  clientRequestID: string;
  responseID: string;
}

export interface CreateCoachChatJobInput {
  jobID: string;
  installID: string;
  clientRequestID: string;
  createdAt: string;
  preparedRequest: PreparedCoachChatJobRequest;
  contextHash: string;
  contextSource: ResolvedCoachContext["source"];
  chatMemoryHit: boolean;
  snapshotBytes: number;
  recentTurnCount: number;
  recentTurnChars: number;
  questionChars: number;
}

export interface CompleteCoachChatJobInput {
  completedAt: string;
  result: CoachChatJobResult;
  promptBytes?: number;
  fallbackPromptBytes?: number;
  modelDurationMs?: number;
  fallbackModelDurationMs?: number;
  totalJobDurationMs?: number;
  inferenceMode?: CoachChatInferenceMode;
  generationStatus?: CoachChatJobResult["generationStatus"];
}

export interface FailCoachChatJobInput {
  completedAt: string;
  error: CoachChatJobError;
  promptBytes?: number;
  fallbackPromptBytes?: number;
  modelDurationMs?: number;
  fallbackModelDurationMs?: number;
  totalJobDurationMs?: number;
  inferenceMode?: CoachChatInferenceMode;
}

export interface CreateWorkoutSummaryJobInput {
  jobID: string;
  installID: string;
  clientRequestID: string;
  sessionID: string;
  fingerprint: string;
  createdAt: string;
  preparedRequest: CoachWorkoutSummaryJobCreateRequest;
  requestMode: CoachWorkoutSummaryRequestMode;
  trigger: CoachWorkoutSummaryTrigger;
  inputMode: CoachWorkoutSummaryInputMode;
  currentExerciseCount: number;
  historyExerciseCount: number;
  historySessionCount: number;
}

export interface CompleteWorkoutSummaryJobInput {
  completedAt: string;
  result: CoachWorkoutSummaryJobResult;
  promptBytes?: number;
  fallbackPromptBytes?: number;
  modelDurationMs?: number;
  fallbackModelDurationMs?: number;
  totalJobDurationMs?: number;
  inferenceMode?: CoachChatInferenceMode;
  generationStatus?: CoachWorkoutSummaryJobResult["generationStatus"];
}

export interface FailWorkoutSummaryJobInput {
  completedAt: string;
  error: CoachChatJobError;
  promptBytes?: number;
  fallbackPromptBytes?: number;
  modelDurationMs?: number;
  fallbackModelDurationMs?: number;
  totalJobDurationMs?: number;
  inferenceMode?: CoachChatInferenceMode;
}

export interface CoachChatJobRecord {
  jobID: string;
  installID: string;
  clientRequestID: string;
  status: CoachChatJobStatus;
  preparedRequest: PreparedCoachChatJobRequest;
  result?: CoachChatJobResult;
  error?: CoachChatJobError;
  createdAt: string;
  startedAt?: string;
  completedAt?: string;
  contextHash: string;
  contextSource: ResolvedCoachContext["source"];
  chatMemoryHit: boolean;
  snapshotBytes: number;
  recentTurnCount: number;
  recentTurnChars: number;
  questionChars: number;
  promptVersion: string;
  model: string;
  promptBytes?: number;
  fallbackPromptBytes?: number;
  modelDurationMs?: number;
  fallbackModelDurationMs?: number;
  totalJobDurationMs?: number;
  inferenceMode?: CoachChatInferenceMode;
  generationStatus?: CoachChatJobResult["generationStatus"];
  memoryCommittedAt?: string;
}

export interface CoachWorkoutSummaryJobRecord {
  jobID: string;
  installID: string;
  clientRequestID: string;
  sessionID: string;
  fingerprint: string;
  status: CoachChatJobStatus;
  preparedRequest: CoachWorkoutSummaryJobCreateRequest;
  result?: CoachWorkoutSummaryJobResult;
  error?: CoachChatJobError;
  createdAt: string;
  startedAt?: string;
  completedAt?: string;
  requestMode: CoachWorkoutSummaryRequestMode;
  trigger: CoachWorkoutSummaryTrigger;
  inputMode: CoachWorkoutSummaryInputMode;
  currentExerciseCount: number;
  historyExerciseCount: number;
  historySessionCount: number;
  promptVersion: string;
  model: string;
  promptBytes?: number;
  fallbackPromptBytes?: number;
  modelDurationMs?: number;
  fallbackModelDurationMs?: number;
  totalJobDurationMs?: number;
  inferenceMode?: CoachChatInferenceMode;
  generationStatus?: CoachWorkoutSummaryJobResult["generationStatus"];
}

export interface ClaimCoachChatJobExecutionResult {
  job: CoachChatJobRecord | null;
  claimed: boolean;
}

export interface CoachStateStore {
  storeLegacySnapshot(
    request: CoachSnapshotSyncRequest
  ): Promise<{ acceptedHash: string; storedAt: string }>;
  resolveCoachContext(
    request:
      | CoachProfileInsightsRequest
      | CoachChatRequest
      | {
          installID: string;
          snapshotHash?: string;
          snapshot?: CompactCoachSnapshot;
          runtimeContextDelta?: CoachRuntimeContextDelta;
        }
  ): Promise<ResolvedCoachContext>;
  getInsightsCache(
    installID: string,
    contextHash: string
  ): Promise<CoachProfileInsightsResponse | null>;
  storeInsightsCache(
    installID: string,
    contextHash: string,
    response: CoachProfileInsightsResponse
  ): Promise<void>;
  getChatMemory(
    installID: string,
    contextHash: string
  ): Promise<StoredChatMemory | null>;
  appendChatMemory(
    installID: string,
    contextHash: string,
    baseTurns: CoachConversationTurn[],
    question: string,
    answerMarkdown: string
  ): Promise<StoredChatMemory>;
  createChatJob(input: CreateCoachChatJobInput): Promise<CoachChatJobRecord>;
  getChatJob(jobID: string, installID: string): Promise<CoachChatJobRecord | null>;
  getChatJobByID(jobID: string): Promise<CoachChatJobRecord | null>;
  findActiveChatJob(installID: string): Promise<CoachChatJobRecord | null>;
  markChatJobRunning(
    jobID: string,
    startedAt: string
  ): Promise<ClaimCoachChatJobExecutionResult>;
  completeChatJob(
    jobID: string,
    input: CompleteCoachChatJobInput
  ): Promise<CoachChatJobRecord>;
  failChatJob(
    jobID: string,
    input: FailCoachChatJobInput
  ): Promise<CoachChatJobRecord>;
  commitChatJobMemory(jobID: string): Promise<void>;
  createWorkoutSummaryJob(
    input: CreateWorkoutSummaryJobInput
  ): Promise<CoachWorkoutSummaryJobRecord>;
  getWorkoutSummaryJob(
    jobID: string,
    installID: string
  ): Promise<CoachWorkoutSummaryJobRecord | null>;
  getWorkoutSummaryJobByID(
    jobID: string
  ): Promise<CoachWorkoutSummaryJobRecord | null>;
  markWorkoutSummaryJobRunning(
    jobID: string,
    startedAt: string
  ): Promise<{ job: CoachWorkoutSummaryJobRecord | null; claimed: boolean }>;
  completeWorkoutSummaryJob(
    jobID: string,
    input: CompleteWorkoutSummaryJobInput
  ): Promise<CoachWorkoutSummaryJobRecord>;
  failWorkoutSummaryJob(
    jobID: string,
    input: FailWorkoutSummaryJobInput
  ): Promise<CoachWorkoutSummaryJobRecord>;
  reconcileBackup(
    request: BackupReconcileRequest
  ): Promise<BackupReconcileResponse>;
  uploadBackup(request: BackupUploadRequest): Promise<BackupUploadResponse>;
  downloadBackup(input: {
    installID: string;
    version?: number;
  }): Promise<BackupDownloadResponse>;
  updateCoachPreferences(
    request: CoachPreferencesUpdateRequest
  ): Promise<CoachPreferencesUpdateResponse>;
  deleteInstallState(installID: string): Promise<void>;
}

interface InstallStateRow {
  install_id: string;
  current_backup_version: number | null;
  current_backup_hash: string | null;
  current_backup_r2_key: string | null;
  current_backup_schema_version: number | null;
  compression: "gzip" | "identity";
  size_bytes: number;
  uploaded_at: string | null;
  client_source_modified_at: string | null;
  coach_state_version: number;
  selected_program_id: string | null;
  program_comment: string;
  created_at: string;
  updated_at: string;
}

interface BackupVersionRow {
  install_id: string;
  backup_version: number;
  backup_hash: string;
  r2_key: string;
  schema_version: number;
  compression: "gzip" | "identity";
  size_bytes: number;
  uploaded_at: string;
  client_source_modified_at: string | null;
  app_version: string;
  build_number: string;
}

interface CoachChatJobRow {
  job_id: string;
  install_id: string;
  client_request_id: string;
  status: CoachChatJobStatus;
  prepared_request_json: string;
  response_json: string | null;
  error_code: string | null;
  error_message: string | null;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  context_hash: string;
  context_source: ResolvedCoachContext["source"];
  chat_memory_hit: number;
  snapshot_bytes: number;
  recent_turn_count: number;
  recent_turn_chars: number;
  question_chars: number;
  prompt_version: string;
  model: string;
  prompt_bytes: number | null;
  fallback_prompt_bytes: number | null;
  model_duration_ms: number | null;
  fallback_model_duration_ms: number | null;
  total_job_duration_ms: number | null;
  inference_mode: CoachChatInferenceMode | null;
  generation_status: CoachChatJobResult["generationStatus"] | null;
  memory_committed_at: string | null;
}

interface WorkoutSummaryJobRow {
  job_id: string;
  install_id: string;
  client_request_id: string;
  session_id: string;
  fingerprint: string;
  status: CoachChatJobStatus;
  prepared_request_json: string;
  response_json: string | null;
  error_code: string | null;
  error_message: string | null;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  request_mode: CoachWorkoutSummaryRequestMode;
  trigger: CoachWorkoutSummaryTrigger;
  input_mode: CoachWorkoutSummaryInputMode;
  current_exercise_count: number;
  history_exercise_count: number;
  history_session_count: number;
  prompt_version: string;
  model: string;
  prompt_bytes: number | null;
  fallback_prompt_bytes: number | null;
  model_duration_ms: number | null;
  fallback_model_duration_ms: number | null;
  total_job_duration_ms: number | null;
  inference_mode: CoachChatInferenceMode | null;
  generation_status: CoachWorkoutSummaryJobResult["generationStatus"] | null;
}

interface InternalBackupRecord {
  remote: BackupHead;
  envelope: BackupEnvelopeV2;
}

export class CloudflareCoachStateRepository implements CoachStateStore {
  constructor(
    private readonly kv: CoachKVNamespace,
    private readonly r2: CoachR2Bucket,
    private readonly db: CoachD1Database,
    private readonly promptVersion: string,
    private readonly model: string,
    private readonly now: () => Date = () => new Date()
  ) {}

  async storeLegacySnapshot(
    request: CoachSnapshotSyncRequest
  ): Promise<{ acceptedHash: string; storedAt: string }> {
    const acceptedHash =
      request.snapshotHash || (await hashCoachContext(request.snapshot));
    const storedAt = request.snapshotUpdatedAt;
    await this.db
      .prepare(
        `
          INSERT INTO legacy_compact_snapshots (
            install_id,
            snapshot_hash,
            snapshot_json,
            updated_at
          ) VALUES (?, ?, ?, ?)
          ON CONFLICT(install_id) DO UPDATE SET
            snapshot_hash = excluded.snapshot_hash,
            snapshot_json = excluded.snapshot_json,
            updated_at = excluded.updated_at
        `
      )
      .bind(
        request.installID,
        acceptedHash,
        stableJSONStringify(request.snapshot),
        storedAt
      )
      .run();

    return { acceptedHash, storedAt };
  }

  async resolveCoachContext(
    request:
      | CoachProfileInsightsRequest
      | CoachChatRequest
      | {
          installID: string;
          snapshotHash?: string;
          snapshot?: CompactCoachSnapshot;
          runtimeContextDelta?: CoachRuntimeContextDelta;
        }
  ): Promise<ResolvedCoachContext> {
    const remoteState = await this.getCurrentInstallState(request.installID);
    if (remoteState?.current_backup_version && remoteState.current_backup_hash) {
      const backup = await this.readBackupRecord(
        request.installID,
        remoteState.current_backup_version
      );
      if (backup) {
        const serverSnapshot = buildCoachContextFromSnapshot({
          snapshot: overlayCoachAnalysisSettings(backup.envelope.snapshot, {
            selectedProgramID: remoteState.selected_program_id,
            programComment: remoteState.program_comment,
          }),
          selectedProgramID: remoteState.selected_program_id,
          programComment: remoteState.program_comment,
          runtimeContextDelta: request.runtimeContextDelta,
        });
        const contextHash = `${remoteState.current_backup_hash}:${remoteState.coach_state_version}`;
        return {
          snapshot: serverSnapshot,
          contextHash,
          cacheAllowed: !request.runtimeContextDelta?.activeWorkout,
          source: "remote_full",
          backupHead: toBackupHead(remoteState),
        };
      }
    }

    if (request.snapshot) {
      const contextHash =
        request.snapshotHash || (await hashCoachContext(request.snapshot));
      return {
        snapshot: withRuntimeContext(request.snapshot, request.runtimeContextDelta),
        contextHash,
        cacheAllowed: !request.runtimeContextDelta?.activeWorkout,
        source: "inline_legacy",
      };
    }

    const legacySnapshot = await this.getLegacySnapshot(request.installID);
    if (
      legacySnapshot &&
      (!request.snapshotHash || legacySnapshot.hash === request.snapshotHash)
    ) {
      return {
        snapshot: withRuntimeContext(
          legacySnapshot.snapshot,
          request.runtimeContextDelta
        ),
        contextHash: legacySnapshot.hash,
        cacheAllowed: !request.runtimeContextDelta?.activeWorkout,
        source: "stored_legacy",
      };
    }

    throw new MissingCoachContextError();
  }

  async getInsightsCache(
    installID: string,
    contextHash: string
  ): Promise<CoachProfileInsightsResponse | null> {
    return this.kv.get<CoachProfileInsightsResponse>(
      insightsCacheKey(installID, contextHash, this.promptVersion, this.model),
      "json"
    );
  }

  async storeInsightsCache(
    installID: string,
    contextHash: string,
    response: CoachProfileInsightsResponse
  ): Promise<void> {
    await this.kv.put(
      insightsCacheKey(installID, contextHash, this.promptVersion, this.model),
      JSON.stringify(response),
      { expirationTtl: INSIGHTS_CACHE_TTL_SECONDS }
    );
  }

  async getChatMemory(
    installID: string,
    contextHash: string
  ): Promise<StoredChatMemory | null> {
    return this.kv.get<StoredChatMemory>(
      chatMemoryKey(installID, contextHash),
      "json"
    );
  }

  async appendChatMemory(
    installID: string,
    contextHash: string,
    baseTurns: CoachConversationTurn[],
    question: string,
    answerMarkdown: string
  ): Promise<StoredChatMemory> {
    const memory: StoredChatMemory = {
      updatedAt: this.now().toISOString(),
      recentTurns: normalizeChatTurns([
        ...baseTurns,
        { role: "user", content: question },
        { role: "assistant", content: answerMarkdown },
      ]),
    };

    await this.kv.put(
      chatMemoryKey(installID, contextHash),
      JSON.stringify(memory),
      { expirationTtl: CHAT_MEMORY_TTL_SECONDS }
    );

    return memory;
  }

  async createChatJob(input: CreateCoachChatJobInput): Promise<CoachChatJobRecord> {
    const existing = await this.getChatJobByClientRequestID(
      input.installID,
      input.clientRequestID
    );
    if (existing) {
      return existing;
    }

    try {
      await this.db
        .prepare(
          `
            INSERT INTO coach_chat_jobs (
              job_id,
              install_id,
              client_request_id,
              status,
              prepared_request_json,
              created_at,
              context_hash,
              context_source,
              chat_memory_hit,
              snapshot_bytes,
              recent_turn_count,
              recent_turn_chars,
              question_chars,
              prompt_version,
              model
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          `
        )
        .bind(
          input.jobID,
          input.installID,
          input.clientRequestID,
          "queued",
          stableJSONStringify(input.preparedRequest),
          input.createdAt,
          input.contextHash,
          input.contextSource,
          input.chatMemoryHit ? 1 : 0,
          input.snapshotBytes,
          input.recentTurnCount,
          input.recentTurnChars,
          input.questionChars,
          this.promptVersion,
          this.model
        )
        .run();
    } catch (error) {
      const duplicated = await this.getChatJobByClientRequestID(
        input.installID,
        input.clientRequestID
      );
      if (duplicated) {
        return duplicated;
      }

      const active = await this.findActiveChatJob(input.installID);
      if (active) {
        throw new ActiveCoachChatJobError(active.jobID);
      }

      throw error;
    }

    const created = await this.getChatJob(input.jobID, input.installID);
    if (!created) {
      throw new Error("Failed to read created coach chat job.");
    }

    return created;
  }

  async getChatJob(
    jobID: string,
    installID: string
  ): Promise<CoachChatJobRecord | null> {
    const row = await this.db
      .prepare(
        `SELECT * FROM coach_chat_jobs WHERE job_id = ? AND install_id = ? LIMIT 1`
      )
      .bind(jobID, installID)
      .first<CoachChatJobRow>();
    return row ? parseCoachChatJobRow(row) : null;
  }

  async getChatJobByID(jobID: string): Promise<CoachChatJobRecord | null> {
    const row = await this.db
      .prepare(`SELECT * FROM coach_chat_jobs WHERE job_id = ? LIMIT 1`)
      .bind(jobID)
      .first<CoachChatJobRow>();
    return row ? parseCoachChatJobRow(row) : null;
  }

  async findActiveChatJob(installID: string): Promise<CoachChatJobRecord | null> {
    const row = await this.db
      .prepare(
        `
          SELECT * FROM coach_chat_jobs
          WHERE install_id = ? AND status IN ('queued', 'running')
          ORDER BY created_at DESC
          LIMIT 1
        `
      )
      .bind(installID)
      .first<CoachChatJobRow>();
    return row ? parseCoachChatJobRow(row) : null;
  }

  async markChatJobRunning(
    jobID: string,
    startedAt: string
  ): Promise<ClaimCoachChatJobExecutionResult> {
    const updateResult = await this.db
      .prepare(
        `
          UPDATE coach_chat_jobs
          SET
            status = 'running',
            started_at = COALESCE(started_at, ?)
          WHERE job_id = ? AND status = 'queued'
        `
      )
      .bind(startedAt, jobID)
      .run();
    return {
      job: await this.getChatJobByID(jobID),
      claimed: d1Changes(updateResult) > 0,
    };
  }

  async completeChatJob(
    jobID: string,
    input: CompleteCoachChatJobInput
  ): Promise<CoachChatJobRecord> {
    await this.db
      .prepare(
        `
          UPDATE coach_chat_jobs
          SET
            status = 'completed',
            response_json = ?,
            error_code = NULL,
            error_message = NULL,
            completed_at = ?,
            prompt_bytes = ?,
            fallback_prompt_bytes = ?,
            model_duration_ms = ?,
            fallback_model_duration_ms = ?,
            total_job_duration_ms = ?,
            inference_mode = ?,
            generation_status = ?
          WHERE job_id = ?
        `
      )
      .bind(
        stableJSONStringify(input.result),
        input.completedAt,
        input.promptBytes ?? null,
        input.fallbackPromptBytes ?? null,
        input.modelDurationMs ?? null,
        input.fallbackModelDurationMs ?? null,
        input.totalJobDurationMs ?? null,
        input.inferenceMode ?? null,
        input.generationStatus ?? null,
        jobID
      )
      .run();

    const job = await this.getChatJobByID(jobID);
    if (!job) {
      throw new Error("Completed coach chat job was not found.");
    }

    return job;
  }

  async failChatJob(
    jobID: string,
    input: FailCoachChatJobInput
  ): Promise<CoachChatJobRecord> {
    await this.db
      .prepare(
        `
          UPDATE coach_chat_jobs
          SET
            status = 'failed',
            response_json = NULL,
            error_code = ?,
            error_message = ?,
            completed_at = ?,
            prompt_bytes = ?,
            fallback_prompt_bytes = ?,
            model_duration_ms = ?,
            fallback_model_duration_ms = ?,
            total_job_duration_ms = ?,
            inference_mode = ?,
            generation_status = NULL
          WHERE job_id = ?
        `
      )
      .bind(
        input.error.code,
        input.error.message,
        input.completedAt,
        input.promptBytes ?? null,
        input.fallbackPromptBytes ?? null,
        input.modelDurationMs ?? null,
        input.fallbackModelDurationMs ?? null,
        input.totalJobDurationMs ?? null,
        input.inferenceMode ?? null,
        jobID
      )
      .run();

    const job = await this.getChatJobByID(jobID);
    if (!job) {
      throw new Error("Failed coach chat job was not found.");
    }

    return job;
  }

  async commitChatJobMemory(jobID: string): Promise<void> {
    const job = await this.getChatJobByID(jobID);
    if (!job || job.memoryCommittedAt) {
      return;
    }

    const committedAt = this.now().toISOString();
    const cacheAllowed = !job.preparedRequest.runtimeContextDelta?.activeWorkout;

    if (cacheAllowed && job.status === "completed" && job.result) {
      await this.appendChatMemory(
        job.installID,
        job.contextHash,
        job.preparedRequest.clientRecentTurns,
        job.preparedRequest.question,
        job.result.answerMarkdown
      );
    }

    await this.db
      .prepare(
        `
          UPDATE coach_chat_jobs
          SET memory_committed_at = COALESCE(memory_committed_at, ?)
          WHERE job_id = ?
        `
      )
      .bind(committedAt, jobID)
      .run();
  }

  async createWorkoutSummaryJob(
    input: CreateWorkoutSummaryJobInput
  ): Promise<CoachWorkoutSummaryJobRecord> {
    const existingByClientRequestID =
      await this.getWorkoutSummaryJobByClientRequestID(
        input.installID,
        input.clientRequestID
      );
    if (existingByClientRequestID) {
      return existingByClientRequestID;
    }

    const existingByFingerprint = await this.getWorkoutSummaryJobByFingerprint(
      input.installID,
      input.sessionID,
      input.fingerprint
    );
    if (existingByFingerprint) {
      return existingByFingerprint;
    }

    try {
      await this.db
        .prepare(
          `
            INSERT INTO coach_workout_summary_jobs (
              job_id,
              install_id,
              client_request_id,
              session_id,
              fingerprint,
              status,
              prepared_request_json,
              created_at,
              request_mode,
              trigger,
              input_mode,
              current_exercise_count,
              history_exercise_count,
              history_session_count,
              prompt_version,
              model
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          `
        )
        .bind(
          input.jobID,
          input.installID,
          input.clientRequestID,
          input.sessionID,
          input.fingerprint,
          "queued",
          stableJSONStringify(input.preparedRequest),
          input.createdAt,
          input.requestMode,
          input.trigger,
          input.inputMode,
          input.currentExerciseCount,
          input.historyExerciseCount,
          input.historySessionCount,
          this.promptVersion,
          this.model
        )
        .run();
    } catch {
      const duplicatedByClientRequestID =
        await this.getWorkoutSummaryJobByClientRequestID(
          input.installID,
          input.clientRequestID
        );
      if (duplicatedByClientRequestID) {
        return duplicatedByClientRequestID;
      }

      const duplicatedByFingerprint = await this.getWorkoutSummaryJobByFingerprint(
        input.installID,
        input.sessionID,
        input.fingerprint
      );
      if (duplicatedByFingerprint) {
        return duplicatedByFingerprint;
      }

      throw new Error("Failed to create workout summary job.");
    }

    const created = await this.getWorkoutSummaryJob(input.jobID, input.installID);
    if (!created) {
      throw new Error("Failed to read created workout summary job.");
    }

    return created;
  }

  async getWorkoutSummaryJob(
    jobID: string,
    installID: string
  ): Promise<CoachWorkoutSummaryJobRecord | null> {
    const row = await this.db
      .prepare(
        `
          SELECT * FROM coach_workout_summary_jobs
          WHERE job_id = ? AND install_id = ?
          LIMIT 1
        `
      )
      .bind(jobID, installID)
      .first<WorkoutSummaryJobRow>();
    return row ? parseWorkoutSummaryJobRow(row) : null;
  }

  async getWorkoutSummaryJobByID(
    jobID: string
  ): Promise<CoachWorkoutSummaryJobRecord | null> {
    const row = await this.db
      .prepare(
        `SELECT * FROM coach_workout_summary_jobs WHERE job_id = ? LIMIT 1`
      )
      .bind(jobID)
      .first<WorkoutSummaryJobRow>();
    return row ? parseWorkoutSummaryJobRow(row) : null;
  }

  async markWorkoutSummaryJobRunning(
    jobID: string,
    startedAt: string
  ): Promise<{ job: CoachWorkoutSummaryJobRecord | null; claimed: boolean }> {
    const updateResult = await this.db
      .prepare(
        `
          UPDATE coach_workout_summary_jobs
          SET
            status = 'running',
            started_at = COALESCE(started_at, ?)
          WHERE job_id = ? AND status = 'queued'
        `
      )
      .bind(startedAt, jobID)
      .run();

    return {
      job: await this.getWorkoutSummaryJobByID(jobID),
      claimed: d1Changes(updateResult) > 0,
    };
  }

  async completeWorkoutSummaryJob(
    jobID: string,
    input: CompleteWorkoutSummaryJobInput
  ): Promise<CoachWorkoutSummaryJobRecord> {
    await this.db
      .prepare(
        `
          UPDATE coach_workout_summary_jobs
          SET
            status = 'completed',
            response_json = ?,
            error_code = NULL,
            error_message = NULL,
            completed_at = ?,
            prompt_bytes = ?,
            fallback_prompt_bytes = ?,
            model_duration_ms = ?,
            fallback_model_duration_ms = ?,
            total_job_duration_ms = ?,
            inference_mode = ?,
            generation_status = ?
          WHERE job_id = ?
        `
      )
      .bind(
        stableJSONStringify(input.result),
        input.completedAt,
        input.promptBytes ?? null,
        input.fallbackPromptBytes ?? null,
        input.modelDurationMs ?? null,
        input.fallbackModelDurationMs ?? null,
        input.totalJobDurationMs ?? null,
        input.inferenceMode ?? null,
        input.generationStatus ?? null,
        jobID
      )
      .run();

    const job = await this.getWorkoutSummaryJobByID(jobID);
    if (!job) {
      throw new Error("Completed workout summary job was not found.");
    }

    return job;
  }

  async failWorkoutSummaryJob(
    jobID: string,
    input: FailWorkoutSummaryJobInput
  ): Promise<CoachWorkoutSummaryJobRecord> {
    await this.db
      .prepare(
        `
          UPDATE coach_workout_summary_jobs
          SET
            status = 'failed',
            response_json = NULL,
            error_code = ?,
            error_message = ?,
            completed_at = ?,
            prompt_bytes = ?,
            fallback_prompt_bytes = ?,
            model_duration_ms = ?,
            fallback_model_duration_ms = ?,
            total_job_duration_ms = ?,
            inference_mode = ?,
            generation_status = NULL
          WHERE job_id = ?
        `
      )
      .bind(
        input.error.code,
        input.error.message,
        input.completedAt,
        input.promptBytes ?? null,
        input.fallbackPromptBytes ?? null,
        input.modelDurationMs ?? null,
        input.fallbackModelDurationMs ?? null,
        input.totalJobDurationMs ?? null,
        input.inferenceMode ?? null,
        jobID
      )
      .run();

    const job = await this.getWorkoutSummaryJobByID(jobID);
    if (!job) {
      throw new Error("Failed workout summary job was not found.");
    }

    return job;
  }

  async reconcileBackup(
    request: BackupReconcileRequest
  ): Promise<BackupReconcileResponse> {
    const current = await this.getCurrentInstallState(request.installID);
    const remote = current?.current_backup_version ? toBackupHead(current) : undefined;

    if (!remote) {
      return {
        action:
          request.localStateKind === "user_data" && request.localBackupHash
            ? "upload"
            : "noop",
      };
    }

    if (request.localBackupHash && request.localBackupHash === remote.backupHash) {
      return { action: "noop", remote };
    }

    if (request.localStateKind === "seed") {
      return { action: "download", remote };
    }

    const remoteChangedSinceSync =
      (request.lastSyncedRemoteVersion ?? null) !== remote.backupVersion &&
      (request.lastSyncedBackupHash ?? null) !== remote.backupHash;

    if (!remoteChangedSinceSync) {
      return { action: "upload", remote };
    }

    if (
      request.localBackupHash &&
      request.lastSyncedBackupHash &&
      request.localBackupHash === request.lastSyncedBackupHash
    ) {
      return { action: "download", remote };
    }

    return { action: "conflict", remote };
  }

  async uploadBackup(
    request: BackupUploadRequest
  ): Promise<BackupUploadResponse> {
    const current = await this.getCurrentInstallState(request.installID);
    if (
      (current?.current_backup_version ?? undefined) !== request.expectedRemoteVersion
    ) {
      throw new StaleRemoteStateError(current?.current_backup_version ?? undefined);
    }

    const normalizedSettings = normalizeCoachAnalysisSettings(
      request.snapshot.coachAnalysisSettings,
      request.snapshot.programs
    );
    const snapshot: AppSnapshotPayload = {
      ...request.snapshot,
      coachAnalysisSettings: normalizedSettings,
    };
    const backupHash = await hashAppSnapshot(snapshot);

    if (current?.current_backup_hash === backupHash && current.current_backup_version) {
      return toBackupHead(current);
    }

    const uploadedAt = this.now().toISOString();
    const backupVersion = (current?.current_backup_version ?? 0) + 1;
    const envelope: BackupEnvelopeV2 = {
      schemaVersion: BACKUP_SCHEMA_VERSION,
      installID: request.installID,
      backupHash,
      uploadedAt,
      clientSourceModifiedAt: request.clientSourceModifiedAt,
      appVersion: request.appVersion,
      buildNumber: request.buildNumber,
      snapshot,
    };
    const r2Key = backupObjectKey(request.installID, backupVersion, backupHash);
    const compressed = await gzipText(JSON.stringify(envelope));
    await this.r2.put(r2Key, compressed, {
      httpMetadata: {
        contentType: "application/json",
        contentEncoding: "gzip",
      },
    });

    const metadataChanged =
      current?.selected_program_id !== (normalizedSettings.selectedProgramID ?? null) ||
      current?.program_comment !== normalizedSettings.programComment;
    const coachStateVersion = current
      ? current.coach_state_version + (metadataChanged ? 1 : 0)
      : 1;
    const sizeBytes = compressed.byteLength;

    await this.db
      .prepare(
        `
          INSERT INTO backup_versions (
            install_id,
            backup_version,
            backup_hash,
            r2_key,
            schema_version,
            compression,
            size_bytes,
            uploaded_at,
            client_source_modified_at,
            app_version,
            build_number
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `
      )
      .bind(
        request.installID,
        backupVersion,
        backupHash,
        r2Key,
        BACKUP_SCHEMA_VERSION,
        "gzip",
        sizeBytes,
        uploadedAt,
        request.clientSourceModifiedAt ?? null,
        request.appVersion,
        request.buildNumber
      )
      .run();

    const createdAt = current?.created_at ?? uploadedAt;
    await this.db
      .prepare(
        `
          INSERT INTO install_state (
            install_id,
            current_backup_version,
            current_backup_hash,
            current_backup_r2_key,
            current_backup_schema_version,
            compression,
            size_bytes,
            uploaded_at,
            client_source_modified_at,
            coach_state_version,
            selected_program_id,
            program_comment,
            created_at,
            updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(install_id) DO UPDATE SET
            current_backup_version = excluded.current_backup_version,
            current_backup_hash = excluded.current_backup_hash,
            current_backup_r2_key = excluded.current_backup_r2_key,
            current_backup_schema_version = excluded.current_backup_schema_version,
            compression = excluded.compression,
            size_bytes = excluded.size_bytes,
            uploaded_at = excluded.uploaded_at,
            client_source_modified_at = excluded.client_source_modified_at,
            coach_state_version = excluded.coach_state_version,
            selected_program_id = excluded.selected_program_id,
            program_comment = excluded.program_comment,
            updated_at = excluded.updated_at
        `
      )
      .bind(
        request.installID,
        backupVersion,
        backupHash,
        r2Key,
        BACKUP_SCHEMA_VERSION,
        "gzip",
        sizeBytes,
        uploadedAt,
        request.clientSourceModifiedAt ?? null,
        coachStateVersion,
        normalizedSettings.selectedProgramID ?? null,
        normalizedSettings.programComment,
        createdAt,
        uploadedAt
      )
      .run();

    return {
      installID: request.installID,
      backupVersion,
      backupHash,
      r2Key,
      uploadedAt,
      clientSourceModifiedAt: request.clientSourceModifiedAt,
      selectedProgramID: normalizedSettings.selectedProgramID,
      programComment: normalizedSettings.programComment,
      coachStateVersion,
      schemaVersion: BACKUP_SCHEMA_VERSION,
      compression: "gzip",
      sizeBytes,
    };
  }

  async downloadBackup(input: {
    installID: string;
    version?: number;
  }): Promise<BackupDownloadResponse> {
    const current = await this.getCurrentInstallState(input.installID);
    const backupVersion = input.version ?? current?.current_backup_version ?? undefined;
    if (!backupVersion) {
      throw new MissingRemoteBackupError();
    }

    const record = await this.readBackupRecord(input.installID, backupVersion);
    if (!record) {
      throw new MissingRemoteBackupError();
    }

    const snapshot =
      input.version === undefined && current
        ? overlayCoachAnalysisSettings(record.envelope.snapshot, {
            selectedProgramID: current.selected_program_id,
            programComment: current.program_comment,
          })
        : record.envelope.snapshot;

    return {
      remote: input.version === undefined && current ? toBackupHead(current) : record.remote,
      backup: {
        ...record.envelope,
        snapshot,
      },
    };
  }

  async updateCoachPreferences(
    request: CoachPreferencesUpdateRequest
  ): Promise<CoachPreferencesUpdateResponse> {
    const current = await this.getCurrentInstallState(request.installID);
    const now = this.now().toISOString();
    const normalizedProgramComment = request.programComment.trim().slice(0, 500);
    let selectedProgramID = request.selectedProgramID ?? null;

    if (current?.current_backup_version) {
      const backup = await this.readBackupRecord(
        request.installID,
        current.current_backup_version
      );
      if (backup) {
        const normalizedSettings = normalizeCoachAnalysisSettings(
          {
            selectedProgramID: request.selectedProgramID,
            programComment: normalizedProgramComment,
          },
          backup.envelope.snapshot.programs
        );
        selectedProgramID = normalizedSettings.selectedProgramID ?? null;
      }
    }

    const coachStateVersion =
      current?.selected_program_id !== selectedProgramID ||
      current?.program_comment !== normalizedProgramComment
        ? (current?.coach_state_version ?? 0) + 1
        : current?.coach_state_version ?? 0;

    await this.db
      .prepare(
        `
          INSERT INTO install_state (
            install_id,
            current_backup_version,
            current_backup_hash,
            current_backup_r2_key,
            current_backup_schema_version,
            compression,
            size_bytes,
            uploaded_at,
            client_source_modified_at,
            coach_state_version,
            selected_program_id,
            program_comment,
            created_at,
            updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(install_id) DO UPDATE SET
            coach_state_version = excluded.coach_state_version,
            selected_program_id = excluded.selected_program_id,
            program_comment = excluded.program_comment,
            updated_at = excluded.updated_at
        `
      )
      .bind(
        request.installID,
        current?.current_backup_version ?? null,
        current?.current_backup_hash ?? null,
        current?.current_backup_r2_key ?? null,
        current?.current_backup_schema_version ?? null,
        current?.compression ?? "gzip",
        current?.size_bytes ?? 0,
        current?.uploaded_at ?? null,
        current?.client_source_modified_at ?? null,
        coachStateVersion,
        selectedProgramID,
        normalizedProgramComment,
        current?.created_at ?? now,
        now
      )
      .run();

    return {
      installID: request.installID,
      selectedProgramID: selectedProgramID ?? undefined,
      programComment: normalizedProgramComment,
      coachStateVersion,
      updatedAt: now,
    };
  }

  async deleteInstallState(installID: string): Promise<void> {
    const backups = await this.listBackupVersions(installID);
    if (backups.length > 0) {
      await this.r2.delete(backups.map((backup) => backup.r2_key));
    }

    await this.db
      .prepare(`DELETE FROM backup_versions WHERE install_id = ?`)
      .bind(installID)
      .run();
    await this.db
      .prepare(`DELETE FROM install_state WHERE install_id = ?`)
      .bind(installID)
      .run();
    await this.db
      .prepare(`DELETE FROM legacy_compact_snapshots WHERE install_id = ?`)
      .bind(installID)
      .run();
    await this.db
      .prepare(`DELETE FROM coach_chat_jobs WHERE install_id = ?`)
      .bind(installID)
      .run();
    await this.db
      .prepare(`DELETE FROM coach_workout_summary_jobs WHERE install_id = ?`)
      .bind(installID)
      .run();
  }

  private async getCurrentInstallState(
    installID: string
  ): Promise<InstallStateRow | null> {
    return this.db
      .prepare(`SELECT * FROM install_state WHERE install_id = ?`)
      .bind(installID)
      .first<InstallStateRow>();
  }

  private async listBackupVersions(
    installID: string
  ): Promise<BackupVersionRow[]> {
    const results = await this.db
      .prepare(
        `SELECT * FROM backup_versions WHERE install_id = ? ORDER BY backup_version DESC`
      )
      .bind(installID)
      .all<BackupVersionRow>();
    return results.results;
  }

  private async readBackupRecord(
    installID: string,
    version: number
  ): Promise<InternalBackupRecord | null> {
    const row = await this.db
      .prepare(
        `SELECT * FROM backup_versions WHERE install_id = ? AND backup_version = ?`
      )
      .bind(installID, version)
      .first<BackupVersionRow>();
    if (!row) {
      return null;
    }

    const object = await this.r2.get(row.r2_key);
    if (!object) {
      return null;
    }

    const text = await gunzipToText(await object.arrayBuffer());
    const envelope = JSON.parse(text) as BackupEnvelopeV2;
    return {
      remote: {
        installID,
        backupVersion: row.backup_version,
        backupHash: row.backup_hash,
        r2Key: row.r2_key,
        uploadedAt: row.uploaded_at,
        clientSourceModifiedAt: row.client_source_modified_at ?? undefined,
        selectedProgramID: undefined,
        programComment: "",
        coachStateVersion: 0,
        schemaVersion: row.schema_version,
        compression: row.compression,
        sizeBytes: row.size_bytes,
      },
      envelope,
    };
  }

  private async getLegacySnapshot(
    installID: string
  ): Promise<StoredLegacyCoachSnapshot | null> {
    const row = await this.db
      .prepare(
        `SELECT snapshot_hash, snapshot_json, updated_at FROM legacy_compact_snapshots WHERE install_id = ?`
      )
      .bind(installID)
      .first<{ snapshot_hash: string; snapshot_json: string; updated_at: string }>();
    if (!row) {
      return null;
    }
    return {
      hash: row.snapshot_hash,
      updatedAt: row.updated_at,
      snapshot: JSON.parse(row.snapshot_json) as CompactCoachSnapshot,
    };
  }

  private async getChatJobByClientRequestID(
    installID: string,
    clientRequestID: string
  ): Promise<CoachChatJobRecord | null> {
    const row = await this.db
      .prepare(
        `
          SELECT * FROM coach_chat_jobs
          WHERE install_id = ? AND client_request_id = ?
          LIMIT 1
        `
      )
      .bind(installID, clientRequestID)
      .first<CoachChatJobRow>();
    return row ? parseCoachChatJobRow(row) : null;
  }

  private async getWorkoutSummaryJobByClientRequestID(
    installID: string,
    clientRequestID: string
  ): Promise<CoachWorkoutSummaryJobRecord | null> {
    const row = await this.db
      .prepare(
        `
          SELECT * FROM coach_workout_summary_jobs
          WHERE install_id = ? AND client_request_id = ?
          LIMIT 1
        `
      )
      .bind(installID, clientRequestID)
      .first<WorkoutSummaryJobRow>();
    return row ? parseWorkoutSummaryJobRow(row) : null;
  }

  private async getWorkoutSummaryJobByFingerprint(
    installID: string,
    sessionID: string,
    fingerprint: string
  ): Promise<CoachWorkoutSummaryJobRecord | null> {
    const row = await this.db
      .prepare(
        `
          SELECT * FROM coach_workout_summary_jobs
          WHERE install_id = ?
            AND session_id = ?
            AND fingerprint = ?
            AND status IN ('queued', 'running', 'completed')
          ORDER BY created_at DESC
          LIMIT 1
        `
      )
      .bind(installID, sessionID, fingerprint)
      .first<WorkoutSummaryJobRow>();
    return row ? parseWorkoutSummaryJobRow(row) : null;
  }
}

export class InMemoryCoachStateRepository implements CoachStateStore {
  private readonly legacySnapshots = new Map<string, StoredLegacyCoachSnapshot>();
  private readonly backupHeads = new Map<string, BackupHead>();
  private readonly backups = new Map<string, Map<number, BackupEnvelopeV2>>();
  private readonly insightsCache = new Map<string, CoachProfileInsightsResponse>();
  private readonly chatMemory = new Map<string, StoredChatMemory>();
  private readonly chatJobs = new Map<string, CoachChatJobRecord>();
  private readonly workoutSummaryJobs = new Map<string, CoachWorkoutSummaryJobRecord>();
  private readonly coachStateVersions = new Map<string, number>();

  constructor(
    private readonly promptVersion: string,
    private readonly model: string,
    private readonly now: () => Date = () => new Date()
  ) {}

  async storeLegacySnapshot(
    request: CoachSnapshotSyncRequest
  ): Promise<{ acceptedHash: string; storedAt: string }> {
    const acceptedHash =
      request.snapshotHash || (await hashCoachContext(request.snapshot));
    const storedAt = request.snapshotUpdatedAt;
    this.legacySnapshots.set(request.installID, {
      hash: acceptedHash,
      updatedAt: storedAt,
      snapshot: request.snapshot,
    });
    return { acceptedHash, storedAt };
  }

  async resolveCoachContext(
    request:
      | CoachProfileInsightsRequest
      | CoachChatRequest
      | {
          installID: string;
          snapshotHash?: string;
          snapshot?: CompactCoachSnapshot;
          runtimeContextDelta?: CoachRuntimeContextDelta;
        }
  ): Promise<ResolvedCoachContext> {
    const remote = this.backupHeads.get(request.installID);
    if (remote) {
      const backup = this.backups.get(request.installID)?.get(remote.backupVersion);
      if (backup) {
        return {
          snapshot: buildCoachContextFromSnapshot({
            snapshot: overlayCoachAnalysisSettings(backup.snapshot, {
              selectedProgramID: remote.selectedProgramID,
              programComment: remote.programComment,
            }),
            selectedProgramID: remote.selectedProgramID,
            programComment: remote.programComment,
            runtimeContextDelta: request.runtimeContextDelta,
          }),
          contextHash: `${remote.backupHash}:${remote.coachStateVersion}`,
          cacheAllowed: !request.runtimeContextDelta?.activeWorkout,
          source: "remote_full",
          backupHead: remote,
        };
      }
    }

    if (request.snapshot) {
      return {
        snapshot: withRuntimeContext(request.snapshot, request.runtimeContextDelta),
        contextHash:
          request.snapshotHash || (await hashCoachContext(request.snapshot)),
        cacheAllowed: !request.runtimeContextDelta?.activeWorkout,
        source: "inline_legacy",
      };
    }

    const stored = this.legacySnapshots.get(request.installID);
    if (stored && (!request.snapshotHash || stored.hash === request.snapshotHash)) {
      return {
        snapshot: withRuntimeContext(stored.snapshot, request.runtimeContextDelta),
        contextHash: stored.hash,
        cacheAllowed: !request.runtimeContextDelta?.activeWorkout,
        source: "stored_legacy",
      };
    }

    throw new MissingCoachContextError();
  }

  async getInsightsCache(
    installID: string,
    contextHash: string
  ): Promise<CoachProfileInsightsResponse | null> {
    return (
      this.insightsCache.get(
        insightsCacheKey(installID, contextHash, this.promptVersion, this.model)
      ) ?? null
    );
  }

  async storeInsightsCache(
    installID: string,
    contextHash: string,
    response: CoachProfileInsightsResponse
  ): Promise<void> {
    this.insightsCache.set(
      insightsCacheKey(installID, contextHash, this.promptVersion, this.model),
      response
    );
  }

  async getChatMemory(
    installID: string,
    contextHash: string
  ): Promise<StoredChatMemory | null> {
    return this.chatMemory.get(chatMemoryKey(installID, contextHash)) ?? null;
  }

  async appendChatMemory(
    installID: string,
    contextHash: string,
    baseTurns: CoachConversationTurn[],
    question: string,
    answerMarkdown: string
  ): Promise<StoredChatMemory> {
    const memory: StoredChatMemory = {
      updatedAt: this.now().toISOString(),
      recentTurns: normalizeChatTurns([
        ...baseTurns,
        { role: "user", content: question },
        { role: "assistant", content: answerMarkdown },
      ]),
    };
    this.chatMemory.set(chatMemoryKey(installID, contextHash), memory);
    return memory;
  }

  async createChatJob(input: CreateCoachChatJobInput): Promise<CoachChatJobRecord> {
    const existing = [...this.chatJobs.values()].find(
      (job) =>
        job.installID === input.installID &&
        job.clientRequestID === input.clientRequestID
    );
    if (existing) {
      return existing;
    }

    const active = [...this.chatJobs.values()].find(
      (job) =>
        job.installID === input.installID &&
        (job.status === "queued" || job.status === "running")
    );
    if (active) {
      throw new ActiveCoachChatJobError(active.jobID);
    }

    const created: CoachChatJobRecord = {
      jobID: input.jobID,
      installID: input.installID,
      clientRequestID: input.clientRequestID,
      status: "queued",
      preparedRequest: input.preparedRequest,
      createdAt: input.createdAt,
      contextHash: input.contextHash,
      contextSource: input.contextSource,
      chatMemoryHit: input.chatMemoryHit,
      snapshotBytes: input.snapshotBytes,
      recentTurnCount: input.recentTurnCount,
      recentTurnChars: input.recentTurnChars,
      questionChars: input.questionChars,
      promptVersion: this.promptVersion,
      model: this.model,
    };
    this.chatJobs.set(created.jobID, created);
    return created;
  }

  async getChatJob(
    jobID: string,
    installID: string
  ): Promise<CoachChatJobRecord | null> {
    const job = this.chatJobs.get(jobID);
    if (!job || job.installID !== installID) {
      return null;
    }

    return job;
  }

  async getChatJobByID(jobID: string): Promise<CoachChatJobRecord | null> {
    return this.chatJobs.get(jobID) ?? null;
  }

  async findActiveChatJob(installID: string): Promise<CoachChatJobRecord | null> {
    const jobs = [...this.chatJobs.values()]
      .filter(
        (job) =>
          job.installID === installID &&
          (job.status === "queued" || job.status === "running")
      )
      .sort((left, right) => right.createdAt.localeCompare(left.createdAt));
    return jobs[0] ?? null;
  }

  async markChatJobRunning(
    jobID: string,
    startedAt: string
  ): Promise<ClaimCoachChatJobExecutionResult> {
    const job = this.chatJobs.get(jobID);
    if (!job) {
      return {
        job: null,
        claimed: false,
      };
    }

    if (job.status === "queued") {
      job.status = "running";
      job.startedAt ??= startedAt;
      return {
        job,
        claimed: true,
      };
    }

    return {
      job,
      claimed: false,
    };
  }

  async completeChatJob(
    jobID: string,
    input: CompleteCoachChatJobInput
  ): Promise<CoachChatJobRecord> {
    const job = this.chatJobs.get(jobID);
    if (!job) {
      throw new Error("Completed coach chat job was not found.");
    }

    job.status = "completed";
    job.result = input.result;
    job.error = undefined;
    job.completedAt = input.completedAt;
    job.promptBytes = input.promptBytes;
    job.fallbackPromptBytes = input.fallbackPromptBytes;
    job.modelDurationMs = input.modelDurationMs;
    job.fallbackModelDurationMs = input.fallbackModelDurationMs;
    job.totalJobDurationMs = input.totalJobDurationMs;
    job.inferenceMode = input.inferenceMode;
    job.generationStatus = input.generationStatus;
    return job;
  }

  async failChatJob(
    jobID: string,
    input: FailCoachChatJobInput
  ): Promise<CoachChatJobRecord> {
    const job = this.chatJobs.get(jobID);
    if (!job) {
      throw new Error("Failed coach chat job was not found.");
    }

    job.status = "failed";
    job.result = undefined;
    job.error = input.error;
    job.completedAt = input.completedAt;
    job.promptBytes = input.promptBytes;
    job.fallbackPromptBytes = input.fallbackPromptBytes;
    job.modelDurationMs = input.modelDurationMs;
    job.fallbackModelDurationMs = input.fallbackModelDurationMs;
    job.totalJobDurationMs = input.totalJobDurationMs;
    job.inferenceMode = input.inferenceMode;
    job.generationStatus = undefined;
    return job;
  }

  async commitChatJobMemory(jobID: string): Promise<void> {
    const job = this.chatJobs.get(jobID);
    if (!job || job.memoryCommittedAt) {
      return;
    }

    if (
      !job.preparedRequest.runtimeContextDelta?.activeWorkout &&
      job.status === "completed" &&
      job.result
    ) {
      await this.appendChatMemory(
        job.installID,
        job.contextHash,
        job.preparedRequest.clientRecentTurns,
        job.preparedRequest.question,
        job.result.answerMarkdown
      );
    }

    job.memoryCommittedAt = this.now().toISOString();
  }

  async createWorkoutSummaryJob(
    input: CreateWorkoutSummaryJobInput
  ): Promise<CoachWorkoutSummaryJobRecord> {
    const existingByClientRequestID = [...this.workoutSummaryJobs.values()].find(
      (job) =>
        job.installID === input.installID &&
        job.clientRequestID === input.clientRequestID
    );
    if (existingByClientRequestID) {
      return existingByClientRequestID;
    }

    const existingByFingerprint = [...this.workoutSummaryJobs.values()]
      .filter(
        (job) =>
          job.installID === input.installID &&
          job.sessionID === input.sessionID &&
          job.fingerprint === input.fingerprint &&
          isReusableWorkoutSummaryJobStatus(job.status)
      )
      .sort((left, right) => right.createdAt.localeCompare(left.createdAt))[0];
    if (existingByFingerprint) {
      return existingByFingerprint;
    }

    const created: CoachWorkoutSummaryJobRecord = {
      jobID: input.jobID,
      installID: input.installID,
      clientRequestID: input.clientRequestID,
      sessionID: input.sessionID,
      fingerprint: input.fingerprint,
      status: "queued",
      preparedRequest: input.preparedRequest,
      createdAt: input.createdAt,
      requestMode: input.requestMode,
      trigger: input.trigger,
      inputMode: input.inputMode,
      currentExerciseCount: input.currentExerciseCount,
      historyExerciseCount: input.historyExerciseCount,
      historySessionCount: input.historySessionCount,
      promptVersion: this.promptVersion,
      model: this.model,
    };
    this.workoutSummaryJobs.set(created.jobID, created);
    return created;
  }

  async getWorkoutSummaryJob(
    jobID: string,
    installID: string
  ): Promise<CoachWorkoutSummaryJobRecord | null> {
    const job = this.workoutSummaryJobs.get(jobID);
    if (!job || job.installID !== installID) {
      return null;
    }

    return job;
  }

  async getWorkoutSummaryJobByID(
    jobID: string
  ): Promise<CoachWorkoutSummaryJobRecord | null> {
    return this.workoutSummaryJobs.get(jobID) ?? null;
  }

  async markWorkoutSummaryJobRunning(
    jobID: string,
    startedAt: string
  ): Promise<{ job: CoachWorkoutSummaryJobRecord | null; claimed: boolean }> {
    const job = this.workoutSummaryJobs.get(jobID);
    if (!job) {
      return {
        job: null,
        claimed: false,
      };
    }

    if (job.status === "queued") {
      job.status = "running";
      job.startedAt ??= startedAt;
      return {
        job,
        claimed: true,
      };
    }

    return {
      job,
      claimed: false,
    };
  }

  async completeWorkoutSummaryJob(
    jobID: string,
    input: CompleteWorkoutSummaryJobInput
  ): Promise<CoachWorkoutSummaryJobRecord> {
    const job = this.workoutSummaryJobs.get(jobID);
    if (!job) {
      throw new Error("Completed workout summary job was not found.");
    }

    job.status = "completed";
    job.result = input.result;
    job.error = undefined;
    job.completedAt = input.completedAt;
    job.promptBytes = input.promptBytes;
    job.fallbackPromptBytes = input.fallbackPromptBytes;
    job.modelDurationMs = input.modelDurationMs;
    job.fallbackModelDurationMs = input.fallbackModelDurationMs;
    job.totalJobDurationMs = input.totalJobDurationMs;
    job.inferenceMode = input.inferenceMode;
    job.generationStatus = input.generationStatus;
    return job;
  }

  async failWorkoutSummaryJob(
    jobID: string,
    input: FailWorkoutSummaryJobInput
  ): Promise<CoachWorkoutSummaryJobRecord> {
    const job = this.workoutSummaryJobs.get(jobID);
    if (!job) {
      throw new Error("Failed workout summary job was not found.");
    }

    job.status = "failed";
    job.result = undefined;
    job.error = input.error;
    job.completedAt = input.completedAt;
    job.promptBytes = input.promptBytes;
    job.fallbackPromptBytes = input.fallbackPromptBytes;
    job.modelDurationMs = input.modelDurationMs;
    job.fallbackModelDurationMs = input.fallbackModelDurationMs;
    job.totalJobDurationMs = input.totalJobDurationMs;
    job.inferenceMode = input.inferenceMode;
    job.generationStatus = undefined;
    return job;
  }

  async reconcileBackup(
    request: BackupReconcileRequest
  ): Promise<BackupReconcileResponse> {
    const remote = this.backupHeads.get(request.installID);
    if (!remote) {
      return {
        action:
          request.localStateKind === "user_data" && request.localBackupHash
            ? "upload"
            : "noop",
      };
    }

    if (request.localBackupHash && request.localBackupHash === remote.backupHash) {
      return { action: "noop", remote };
    }

    if (request.localStateKind === "seed") {
      return { action: "download", remote };
    }

    const remoteChangedSinceSync =
      (request.lastSyncedRemoteVersion ?? null) !== remote.backupVersion &&
      (request.lastSyncedBackupHash ?? null) !== remote.backupHash;

    if (!remoteChangedSinceSync) {
      return { action: "upload", remote };
    }

    if (
      request.localBackupHash &&
      request.lastSyncedBackupHash &&
      request.localBackupHash === request.lastSyncedBackupHash
    ) {
      return { action: "download", remote };
    }

    return { action: "conflict", remote };
  }

  async uploadBackup(
    request: BackupUploadRequest
  ): Promise<BackupUploadResponse> {
    const current = this.backupHeads.get(request.installID);
    if ((current?.backupVersion ?? undefined) !== request.expectedRemoteVersion) {
      throw new StaleRemoteStateError(current?.backupVersion);
    }

    const normalizedSettings = normalizeCoachAnalysisSettings(
      request.snapshot.coachAnalysisSettings,
      request.snapshot.programs
    );
    const snapshot: AppSnapshotPayload = {
      ...request.snapshot,
      coachAnalysisSettings: normalizedSettings,
    };
    const backupHash = await hashAppSnapshot(snapshot);
    if (current?.backupHash === backupHash) {
      return current;
    }

    const uploadedAt = this.now().toISOString();
    const backupVersion = (current?.backupVersion ?? 0) + 1;
    const coachStateVersion =
      current &&
      current.selectedProgramID === normalizedSettings.selectedProgramID &&
      current.programComment === normalizedSettings.programComment
        ? current.coachStateVersion
        : (current?.coachStateVersion ?? 0) + 1;
    const envelope: BackupEnvelopeV2 = {
      schemaVersion: BACKUP_SCHEMA_VERSION,
      installID: request.installID,
      backupHash,
      uploadedAt,
      clientSourceModifiedAt: request.clientSourceModifiedAt,
      appVersion: request.appVersion,
      buildNumber: request.buildNumber,
      snapshot,
    };
    this.backups.set(
      request.installID,
      new Map(this.backups.get(request.installID)).set(backupVersion, envelope)
    );
    const remote: BackupHead = {
      installID: request.installID,
      backupVersion,
      backupHash,
      r2Key: backupObjectKey(request.installID, backupVersion, backupHash),
      uploadedAt,
      clientSourceModifiedAt: request.clientSourceModifiedAt,
      selectedProgramID: normalizedSettings.selectedProgramID,
      programComment: normalizedSettings.programComment,
      coachStateVersion,
      schemaVersion: BACKUP_SCHEMA_VERSION,
      compression: "gzip",
      sizeBytes: jsonByteLength(envelope),
    };
    this.backupHeads.set(request.installID, remote);
    this.coachStateVersions.set(request.installID, coachStateVersion);
    return remote;
  }

  async downloadBackup(input: {
    installID: string;
    version?: number;
  }): Promise<BackupDownloadResponse> {
    const remote = this.backupHeads.get(input.installID);
    const version = input.version ?? remote?.backupVersion;
    const backup = version ? this.backups.get(input.installID)?.get(version) : undefined;
    if (!remote || !version || !backup) {
      throw new MissingRemoteBackupError();
    }

    return {
      remote,
      backup: {
        ...backup,
        snapshot:
          input.version === undefined
            ? overlayCoachAnalysisSettings(backup.snapshot, {
                selectedProgramID: remote.selectedProgramID,
                programComment: remote.programComment,
              })
            : backup.snapshot,
      },
    };
  }

  async updateCoachPreferences(
    request: CoachPreferencesUpdateRequest
  ): Promise<CoachPreferencesUpdateResponse> {
    const current = this.backupHeads.get(request.installID);
    const backup = current
      ? this.backups.get(request.installID)?.get(current.backupVersion)
      : undefined;
    const normalizedSettings = normalizeCoachAnalysisSettings(
      {
        selectedProgramID: request.selectedProgramID,
        programComment: request.programComment,
      },
      backup?.snapshot.programs ?? []
    );
    const coachStateVersion =
      current &&
      current.selectedProgramID === normalizedSettings.selectedProgramID &&
      current.programComment === normalizedSettings.programComment
        ? current.coachStateVersion
        : (current?.coachStateVersion ?? 0) + 1;
    const updatedAt = this.now().toISOString();
    if (current) {
      this.backupHeads.set(request.installID, {
        ...current,
        selectedProgramID: normalizedSettings.selectedProgramID,
        programComment: normalizedSettings.programComment,
        coachStateVersion,
      });
    }
    this.coachStateVersions.set(request.installID, coachStateVersion);
    return {
      installID: request.installID,
      selectedProgramID: normalizedSettings.selectedProgramID,
      programComment: normalizedSettings.programComment,
      coachStateVersion,
      updatedAt,
    };
  }

  async deleteInstallState(installID: string): Promise<void> {
    this.legacySnapshots.delete(installID);
    this.backupHeads.delete(installID);
    this.backups.delete(installID);
    this.coachStateVersions.delete(installID);
    for (const [jobID, job] of this.chatJobs.entries()) {
      if (job.installID === installID) {
        this.chatJobs.delete(jobID);
      }
    }
    for (const [jobID, job] of this.workoutSummaryJobs.entries()) {
      if (job.installID === installID) {
        this.workoutSummaryJobs.delete(jobID);
      }
    }
    for (const key of [...this.insightsCache.keys()]) {
      if (key.startsWith(`${installID}:`)) {
        this.insightsCache.delete(key);
      }
    }
    for (const key of [...this.chatMemory.keys()]) {
      if (key.startsWith(`${installID}:`)) {
        this.chatMemory.delete(key);
      }
    }
  }
}

export class MissingCoachContextError extends Error {
  constructor() {
    super("Coach snapshot sync required.");
    this.name = "MissingCoachContextError";
  }
}

export class MissingRemoteBackupError extends Error {
  constructor() {
    super("Remote backup not found.");
    this.name = "MissingRemoteBackupError";
  }
}

export class StaleRemoteStateError extends Error {
  constructor(readonly currentRemoteVersion?: number) {
    super("Remote backup head changed.");
    this.name = "StaleRemoteStateError";
  }
}

export class ActiveCoachChatJobError extends Error {
  constructor(readonly jobID: string) {
    super("Coach chat job already in progress.");
    this.name = "ActiveCoachChatJobError";
  }
}

export function normalizeChatTurns(
  turns: CoachConversationTurn[]
): CoachConversationTurn[] {
  const normalized = turns
    .map((turn) => ({
      role: turn.role,
      content: turn.content.trim().slice(0, CHAT_MEMORY_MAX_CONTENT_LENGTH),
    }))
    .filter((turn) => turn.content.length > 0)
    .slice(-CHAT_MEMORY_MAX_TURNS);

  const result: CoachConversationTurn[] = [];
  let totalCharacters = 0;

  for (const turn of normalized.toReversed()) {
    const nextTotal = totalCharacters + turn.content.length;
    if (result.length > 0 && nextTotal > CHAT_MEMORY_MAX_TOTAL_CHARACTERS) {
      break;
    }

    result.push(turn);
    totalCharacters = nextTotal;
  }

  return result.reverse();
}

function parseCoachChatJobRow(row: CoachChatJobRow): CoachChatJobRecord {
  return {
    jobID: row.job_id,
    installID: row.install_id,
    clientRequestID: row.client_request_id,
    status: row.status,
    preparedRequest: JSON.parse(
      row.prepared_request_json
    ) as PreparedCoachChatJobRequest,
    result: row.response_json
      ? (JSON.parse(row.response_json) as CoachChatJobResult)
      : undefined,
    error:
      row.error_code && row.error_message
        ? {
            code: row.error_code,
            message: row.error_message,
            retryable: isRetryableJobErrorCode(row.error_code),
          }
        : undefined,
    createdAt: row.created_at,
    startedAt: row.started_at ?? undefined,
    completedAt: row.completed_at ?? undefined,
    contextHash: row.context_hash,
    contextSource: row.context_source,
    chatMemoryHit: row.chat_memory_hit === 1,
    snapshotBytes: row.snapshot_bytes,
    recentTurnCount: row.recent_turn_count,
    recentTurnChars: row.recent_turn_chars,
    questionChars: row.question_chars,
    promptVersion: row.prompt_version,
    model: row.model,
    promptBytes: nullableNumber(row.prompt_bytes),
    fallbackPromptBytes: nullableNumber(row.fallback_prompt_bytes),
    modelDurationMs: nullableNumber(row.model_duration_ms),
    fallbackModelDurationMs: nullableNumber(row.fallback_model_duration_ms),
    totalJobDurationMs: nullableNumber(row.total_job_duration_ms),
    inferenceMode: row.inference_mode ?? undefined,
    generationStatus: row.generation_status ?? undefined,
    memoryCommittedAt: row.memory_committed_at ?? undefined,
  };
}

function parseWorkoutSummaryJobRow(
  row: WorkoutSummaryJobRow
): CoachWorkoutSummaryJobRecord {
  return {
    jobID: row.job_id,
    installID: row.install_id,
    clientRequestID: row.client_request_id,
    sessionID: row.session_id,
    fingerprint: row.fingerprint,
    status: row.status,
    preparedRequest: JSON.parse(
      row.prepared_request_json
    ) as CoachWorkoutSummaryJobCreateRequest,
    result: row.response_json
      ? (JSON.parse(row.response_json) as CoachWorkoutSummaryJobResult)
      : undefined,
    error:
      row.error_code && row.error_message
        ? {
            code: row.error_code,
            message: row.error_message,
            retryable: isRetryableJobErrorCode(row.error_code),
          }
        : undefined,
    createdAt: row.created_at,
    startedAt: row.started_at ?? undefined,
    completedAt: row.completed_at ?? undefined,
    requestMode: row.request_mode,
    trigger: row.trigger,
    inputMode: row.input_mode,
    currentExerciseCount: row.current_exercise_count,
    historyExerciseCount: row.history_exercise_count,
    historySessionCount: row.history_session_count,
    promptVersion: row.prompt_version,
    model: row.model,
    promptBytes: nullableNumber(row.prompt_bytes),
    fallbackPromptBytes: nullableNumber(row.fallback_prompt_bytes),
    modelDurationMs: nullableNumber(row.model_duration_ms),
    fallbackModelDurationMs: nullableNumber(row.fallback_model_duration_ms),
    totalJobDurationMs: nullableNumber(row.total_job_duration_ms),
    inferenceMode: row.inference_mode ?? undefined,
    generationStatus: row.generation_status ?? undefined,
  };
}

function nullableNumber(value: number | null): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function d1Changes(result: unknown): number {
  if (
    result &&
    typeof result === "object" &&
    "meta" in result &&
    result.meta &&
    typeof result.meta === "object" &&
    "changes" in result.meta &&
    typeof result.meta.changes === "number"
  ) {
    return result.meta.changes;
  }

  return 0;
}

function isRetryableJobErrorCode(code: string): boolean {
  return (
    code.startsWith("upstream_") ||
    code === "workflow_start_failed" ||
    code === "persistence_error" ||
    code === "internal_error"
  );
}

function isReusableWorkoutSummaryJobStatus(
  status: CoachChatJobStatus
): boolean {
  return status === "queued" || status === "running" || status === "completed";
}

function insightsCacheKey(
  installID: string,
  contextHash: string,
  promptVersion: string,
  model: string
): string {
  return `${installID}:insights:${contextHash}:${promptVersion}:${model}`;
}

function chatMemoryKey(installID: string, contextHash: string): string {
  return `${installID}:chat-memory:${contextHash}`;
}

function backupObjectKey(
  installID: string,
  backupVersion: number,
  backupHash: string
): string {
  return `installs/${installID}/backups/v${String(backupVersion).padStart(6, "0")}-${backupHash}.json.gz`;
}

function toBackupHead(row: InstallStateRow): BackupHead {
  if (
    !row.current_backup_version ||
    !row.current_backup_hash ||
    !row.current_backup_r2_key ||
    !row.uploaded_at ||
    !row.current_backup_schema_version
  ) {
    throw new MissingRemoteBackupError();
  }

  return {
    installID: row.install_id,
    backupVersion: row.current_backup_version,
    backupHash: row.current_backup_hash,
    r2Key: row.current_backup_r2_key,
    uploadedAt: row.uploaded_at,
    clientSourceModifiedAt: row.client_source_modified_at ?? undefined,
    selectedProgramID: row.selected_program_id ?? undefined,
    programComment: row.program_comment,
    coachStateVersion: row.coach_state_version,
    schemaVersion: row.current_backup_schema_version,
    compression: row.compression,
    sizeBytes: row.size_bytes,
  };
}

function withRuntimeContext(
  snapshot: CompactCoachSnapshot,
  runtimeContextDelta?: CoachRuntimeContextDelta
): CompactCoachSnapshot {
  if (!runtimeContextDelta?.activeWorkout) {
    return snapshot;
  }

  return {
    ...snapshot,
    activeWorkout: runtimeContextDelta.activeWorkout,
  };
}

async function gzipText(input: string): Promise<ArrayBuffer> {
  const stream = new Blob([input]).stream().pipeThrough(new CompressionStream("gzip"));
  return await new Response(stream).arrayBuffer();
}

async function gunzipToText(input: ArrayBuffer): Promise<string> {
  const stream = new Blob([input]).stream().pipeThrough(new DecompressionStream("gzip"));
  return await new Response(stream).text();
}
