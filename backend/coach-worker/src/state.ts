import {
  buildCoachContextFromSnapshot,
  buildDerivedCoachAnalyticsFromCompactSnapshot,
  buildDerivedCoachAnalyticsFromSnapshot,
  DEFAULT_ANALYTICS_VERSION,
  DEFAULT_CONTEXT_VERSION,
  hashAppSnapshot,
  hashCoachContext,
  jsonByteLength,
  normalizeCoachAnalysisSettings,
  overlayCoachAnalysisSettings,
  stableJSONStringify,
  type CoachContextProfile,
  type CoachDerivedAnalytics,
  type CoachExecutionMetadata,
  type CoachMemoryProfile,
} from "./context";
import { DEFAULT_MODEL_ROUTING_VERSION } from "./routing";
import type {
  AppSnapshotPayload,
  CoachAIProvider,
  BackupDeleteRequest,
  BackupDownloadResponse,
  BackupEnvelopeV2,
  BackupHead,
  BackupRestoreDecisionRequest,
  BackupStatusRequest,
  BackupStatusResponse,
  BackupUploadRequest,
  BackupUploadResponse,
  CoachChatInferenceMode,
  CoachChatJobError,
  CoachChatJobResult,
  CoachChatJobStatus,
  CoachChatRequest,
  CoachConversationTurn,
  CoachPreferencesUpdateRequest,
  CoachPreferencesUpdateResponse,
  CoachProfileInsightsJobCreateRequest,
  CoachProfileInsightsJobResult,
  CoachProfileInsightsRequest,
  CoachProfileInsightsResponse,
  CoachMemoryClearRequest,
  CoachWorkoutSummaryInputMode,
  CoachWorkoutSummaryJobCreateRequest,
  CoachWorkoutSummaryJobResult,
  CoachWorkoutSummaryRequestMode,
  CoachWorkoutSummaryTrigger,
  CompactCoachSnapshot,
  CoachRuntimeContextDelta,
} from "./schemas";

const CHAT_MEMORY_TTL_SECONDS = 7 * 24 * 60 * 60;
const INSIGHTS_CACHE_TTL_SECONDS = 6 * 60 * 60;
const DEGRADED_INSIGHTS_CACHE_TTL_SECONDS = 10 * 60;
const CHAT_MEMORY_MAX_TURNS = 12;
const CHAT_MEMORY_MAX_CONTENT_LENGTH = 800;
const CHAT_MEMORY_MAX_TOTAL_CHARACTERS = 4_800;
const BACKUP_SCHEMA_VERSION = 2;

export interface CoachKVNamespace {
  get(key: string, type: "text"): Promise<string | null>;
  get<T = unknown>(key: string, type: "json"): Promise<T | null>;
  list?(options?: { prefix?: string; limit?: number; cursor?: string }): Promise<{
    keys: Array<{ name: string }>;
    list_complete?: boolean;
    cursor?: string;
  }>;
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

export interface ResolvedCoachContext {
  snapshot: CompactCoachSnapshot;
  contextHash: string;
  cacheAllowed: boolean;
  source: "remote_full" | "inline_legacy";
  backupHead?: BackupHead;
  contextVersion: string;
  analyticsVersion: string;
  derivedAnalytics: CoachDerivedAnalytics;
}

export interface PreparedCoachChatJobRequest extends CoachChatRequest {
  clientRequestID: string;
  responseID: string;
  metadata?: CoachExecutionMetadata;
}

export interface PreparedWorkoutSummaryJobRequest
  extends CoachWorkoutSummaryJobCreateRequest {
  metadata?: CoachExecutionMetadata;
}

export interface PreparedProfileInsightsJobRequest
  extends CoachProfileInsightsJobCreateRequest {
  metadata?: CoachExecutionMetadata;
}

export interface CreateCoachChatJobInput {
  jobID: string;
  installID: string;
  clientRequestID: string;
  createdAt: string;
  model: string;
  provider: CoachAIProvider;
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
  model: string;
  provider: CoachAIProvider;
  preparedRequest: PreparedWorkoutSummaryJobRequest;
  requestMode: CoachWorkoutSummaryRequestMode;
  trigger: CoachWorkoutSummaryTrigger;
  inputMode: CoachWorkoutSummaryInputMode;
  currentExerciseCount: number;
  historyExerciseCount: number;
  historySessionCount: number;
}

export interface CreateProfileInsightsJobInput {
  jobID: string;
  installID: string;
  clientRequestID: string;
  createdAt: string;
  model: string;
  provider: CoachAIProvider;
  preparedRequest: PreparedProfileInsightsJobRequest;
  contextHash: string;
  contextSource: ResolvedCoachContext["source"];
  snapshotBytes: number;
  programCommentChars: number;
  recentPrCount: number;
  relativeStrengthCount: number;
  preferredProgramWorkoutCount: number;
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

export interface CompleteProfileInsightsJobInput {
  completedAt: string;
  result: CoachProfileInsightsJobResult;
  promptBytes?: number;
  fallbackPromptBytes?: number;
  modelDurationMs?: number;
  fallbackModelDurationMs?: number;
  totalJobDurationMs?: number;
  inferenceMode?: CoachChatInferenceMode;
  generationStatus?: CoachProfileInsightsJobResult["generationStatus"];
}

export interface FailProfileInsightsJobInput {
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
  provider?: CoachAIProvider;
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
  preparedRequest: PreparedWorkoutSummaryJobRequest;
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
  provider?: CoachAIProvider;
  promptBytes?: number;
  fallbackPromptBytes?: number;
  modelDurationMs?: number;
  fallbackModelDurationMs?: number;
  totalJobDurationMs?: number;
  inferenceMode?: CoachChatInferenceMode;
  generationStatus?: CoachWorkoutSummaryJobResult["generationStatus"];
}

export interface CoachProfileInsightsJobRecord {
  jobID: string;
  installID: string;
  clientRequestID: string;
  status: CoachChatJobStatus;
  preparedRequest: PreparedProfileInsightsJobRequest;
  result?: CoachProfileInsightsJobResult;
  error?: CoachChatJobError;
  createdAt: string;
  startedAt?: string;
  completedAt?: string;
  contextHash: string;
  contextSource: ResolvedCoachContext["source"];
  snapshotBytes: number;
  programCommentChars: number;
  recentPrCount: number;
  relativeStrengthCount: number;
  preferredProgramWorkoutCount: number;
  promptVersion: string;
  model: string;
  provider?: CoachAIProvider;
  promptBytes?: number;
  fallbackPromptBytes?: number;
  modelDurationMs?: number;
  fallbackModelDurationMs?: number;
  totalJobDurationMs?: number;
  inferenceMode?: CoachChatInferenceMode;
  generationStatus?: CoachProfileInsightsJobResult["generationStatus"];
}

export interface ClaimCoachChatJobExecutionResult {
  job: CoachChatJobRecord | null;
  claimed: boolean;
}

export interface ContextStorageKeyInput {
  contextHash: string;
  provider?: CoachAIProvider;
  contextProfile: CoachContextProfile;
  contextVersion: string;
  analyticsVersion: string;
  providerID?: string;
  promptVersion?: string;
  model?: string;
  memoryProfile?: CoachMemoryProfile;
  routingVersion?: string;
  memoryCompatibilityKey?: string;
}

export interface InstallAuthorizationResult {
  authMode: "legacy_compat" | "secret_valid" | "unbound_secret";
}

export interface CoachStateStore {
  authorizeInstallAccess(input: {
    installID: string;
    providedSecret?: string;
    allowLegacyCompat?: boolean;
    enrollIfMissing?: boolean;
  }): Promise<InstallAuthorizationResult>;
  bindInstallSecret(installID: string, providedSecret: string): Promise<void>;
  resolveCoachContext(
    request:
      | CoachProfileInsightsRequest
      | CoachChatRequest
      | {
          installID: string;
          localBackupHash?: string;
          snapshotHash?: string;
          snapshot?: CompactCoachSnapshot;
          runtimeContextDelta?: CoachRuntimeContextDelta;
        }
  ): Promise<ResolvedCoachContext>;
  getInsightsCache(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<CoachProfileInsightsResponse | null>;
  getDegradedInsightsCache(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<CoachProfileInsightsResponse | null>;
  storeInsightsCache(
    installID: string,
    key: ContextStorageKeyInput,
    response: CoachProfileInsightsResponse
  ): Promise<void>;
  storeDegradedInsightsCache(
    installID: string,
    key: ContextStorageKeyInput,
    response: CoachProfileInsightsResponse
  ): Promise<void>;
  deleteDegradedInsightsCache(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<void>;
  getChatMemory(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<StoredChatMemory | null>;
  appendChatMemory(
    installID: string,
    key: ContextStorageKeyInput,
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
  createProfileInsightsJob(
    input: CreateProfileInsightsJobInput
  ): Promise<CoachProfileInsightsJobRecord>;
  getProfileInsightsJob(
    jobID: string,
    installID: string
  ): Promise<CoachProfileInsightsJobRecord | null>;
  getProfileInsightsJobByID(
    jobID: string
  ): Promise<CoachProfileInsightsJobRecord | null>;
  markProfileInsightsJobRunning(
    jobID: string,
    startedAt: string
  ): Promise<{ job: CoachProfileInsightsJobRecord | null; claimed: boolean }>;
  completeProfileInsightsJob(
    jobID: string,
    input: CompleteProfileInsightsJobInput
  ): Promise<CoachProfileInsightsJobRecord>;
  failProfileInsightsJob(
    jobID: string,
    input: FailProfileInsightsJobInput
  ): Promise<CoachProfileInsightsJobRecord>;
  getBackupStatus(request: BackupStatusRequest): Promise<BackupStatusResponse>;
  uploadBackup(request: BackupUploadRequest): Promise<BackupUploadResponse>;
  downloadBackup(input: {
    installID: string;
    version?: number;
  }): Promise<BackupDownloadResponse>;
  updateCoachPreferences(
    request: CoachPreferencesUpdateRequest
  ): Promise<CoachPreferencesUpdateResponse>;
  recordRestoreDecision(request: BackupRestoreDecisionRequest): Promise<void>;
  clearRemoteAIMemory(request: CoachMemoryClearRequest): Promise<void>;
  deleteRemoteBackup(request: BackupDeleteRequest): Promise<void>;
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
  install_secret_hash: string | null;
  auth_enrolled_at: string | null;
  last_seen_local_hash: string | null;
  last_seen_local_modified_at: string | null;
  last_status_sync_state: string | null;
  last_status_context_state: string | null;
  last_restore_offered_version: number | null;
  last_restore_decision: string | null;
  last_restore_decision_local_hash: string | null;
  last_restore_decision_at: string | null;
  context_ready_backup_hash: string | null;
  context_ready_coach_state_version: number | null;
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
  provider: CoachAIProvider | null;
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
  provider: CoachAIProvider | null;
  prompt_bytes: number | null;
  fallback_prompt_bytes: number | null;
  model_duration_ms: number | null;
  fallback_model_duration_ms: number | null;
  total_job_duration_ms: number | null;
  inference_mode: CoachChatInferenceMode | null;
  generation_status: CoachWorkoutSummaryJobResult["generationStatus"] | null;
}

interface ProfileInsightsJobRow {
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
  snapshot_bytes: number;
  program_comment_chars: number;
  recent_pr_count: number;
  relative_strength_count: number;
  preferred_program_workout_count: number;
  prompt_version: string;
  model: string;
  provider: CoachAIProvider | null;
  prompt_bytes: number | null;
  fallback_prompt_bytes: number | null;
  model_duration_ms: number | null;
  fallback_model_duration_ms: number | null;
  total_job_duration_ms: number | null;
  inference_mode: CoachChatInferenceMode | null;
  generation_status: CoachProfileInsightsJobResult["generationStatus"] | null;
}

interface InternalBackupRecord {
  remote: BackupHead;
  envelope: BackupEnvelopeV2;
}

export class CloudflareCoachStateRepository implements CoachStateStore {
  private chatJobProviderColumnSupport: boolean | undefined;
  private workoutSummaryProviderColumnSupport: boolean | undefined;
  private profileInsightsJobProviderColumnSupport: boolean | undefined;

  constructor(
    private readonly kv: CoachKVNamespace,
    private readonly r2: CoachR2Bucket,
    private readonly db: CoachD1Database,
    private readonly promptVersion: string,
    private readonly model: string,
    private readonly now: () => Date = () => new Date()
  ) {}

  async authorizeInstallAccess(input: {
    installID: string;
    providedSecret?: string;
    allowLegacyCompat?: boolean;
    enrollIfMissing?: boolean;
  }): Promise<InstallAuthorizationResult> {
    const current = await this.getCurrentInstallState(input.installID);
    const providedSecret = input.providedSecret?.trim();
    const storedSecretHash = current?.install_secret_hash?.trim() ?? null;

    if (storedSecretHash) {
      if (!providedSecret) {
        throw new InstallAccessError("install_proof_required");
      }

      const providedHash = await sha256Hex(providedSecret);
      if (providedHash !== storedSecretHash) {
        throw new InstallAccessError("install_proof_invalid");
      }

      return { authMode: "secret_valid" };
    }

    if (providedSecret) {
      if (current && input.enrollIfMissing !== false) {
        await this.bindInstallSecret(input.installID, providedSecret);
        return { authMode: "secret_valid" };
      }

      return { authMode: "unbound_secret" };
    }

    if (input.allowLegacyCompat !== false) {
      return { authMode: "legacy_compat" };
    }

    throw new InstallAccessError("install_proof_required");
  }

  async bindInstallSecret(installID: string, providedSecret: string): Promise<void> {
    const current = await this.getCurrentInstallState(installID);
    if (!current) {
      return;
    }

    const now = this.now().toISOString();
    const secretHash = await sha256Hex(providedSecret.trim());
    await this.db
      .prepare(
        `
          UPDATE install_state
          SET install_secret_hash = ?,
              auth_enrolled_at = COALESCE(auth_enrolled_at, ?),
              updated_at = ?
          WHERE install_id = ?
        `
      )
      .bind(secretHash, now, now, installID)
      .run();
  }

  async resolveCoachContext(
    request:
      | CoachProfileInsightsRequest
      | CoachChatRequest
      | {
          installID: string;
          localBackupHash?: string;
          snapshotHash?: string;
          snapshot?: CompactCoachSnapshot;
          runtimeContextDelta?: CoachRuntimeContextDelta;
        }
  ): Promise<ResolvedCoachContext> {
    const remoteState = await this.getCurrentInstallState(request.installID);
    const remoteHashMismatch =
      Boolean(remoteState?.current_backup_hash) &&
      Boolean(request.localBackupHash) &&
      request.localBackupHash !== remoteState?.current_backup_hash;
    if (remoteState?.current_backup_version && remoteState.current_backup_hash) {
      if (remoteHashMismatch && !request.snapshot) {
        throw new StaleRemoteStateError(remoteState.current_backup_version);
      }
      const backup = remoteHashMismatch
        ? null
        : await this.readBackupRecord(
            request.installID,
            remoteState.current_backup_version
          );
      if (backup) {
        const snapshot = overlayCoachAnalysisSettings(backup.envelope.snapshot, {
          selectedProgramID: remoteState.selected_program_id,
          programComment: remoteState.program_comment,
        });
        const serverSnapshot = buildCoachContextFromSnapshot({
          snapshot,
          selectedProgramID: remoteState.selected_program_id,
          programComment: remoteState.program_comment,
          runtimeContextDelta: request.runtimeContextDelta,
        });
        const finishedSessions = snapshot.history
          .filter((session) => Boolean(session.endedAt))
          .sort(
            (left, right) => Date.parse(right.startedAt) - Date.parse(left.startedAt)
          );
        const selectedProgram = snapshot.coachAnalysisSettings.selectedProgramID
          ? snapshot.programs.find(
              (program) => program.id === snapshot.coachAnalysisSettings.selectedProgramID
            )
          : snapshot.programs.find((program) => program.workouts.length > 0);
        const consistencySummary = serverSnapshot.analytics.consistency;
        const derivedAnalytics = buildDerivedCoachAnalyticsFromSnapshot({
          snapshot,
          preferredProgram: selectedProgram,
          profile: snapshot.profile,
          consistencySummary,
          coachAnalysisSettings: snapshot.coachAnalysisSettings,
          finishedSessions,
        });
        const contextHash = `${remoteState.current_backup_hash}:${remoteState.coach_state_version}`;
        return {
          snapshot: serverSnapshot,
          contextHash,
          cacheAllowed: !request.runtimeContextDelta?.activeWorkout,
          source: "remote_full",
          backupHead: toBackupHead(remoteState),
          contextVersion: DEFAULT_CONTEXT_VERSION,
          analyticsVersion: DEFAULT_ANALYTICS_VERSION,
          derivedAnalytics,
        };
      }
    }

    if (request.snapshot) {
      const contextHash =
        request.snapshotHash || (await hashCoachContext(request.snapshot));
      const snapshot = withRuntimeContext(
        request.snapshot,
        request.runtimeContextDelta
      );
      return {
        snapshot,
        contextHash,
        cacheAllowed: !request.runtimeContextDelta?.activeWorkout,
        source: "inline_legacy",
        contextVersion: DEFAULT_CONTEXT_VERSION,
        analyticsVersion: DEFAULT_ANALYTICS_VERSION,
        derivedAnalytics: buildDerivedCoachAnalyticsFromCompactSnapshot(snapshot),
      };
    }

    throw new MissingCoachContextError();
  }

  async getInsightsCache(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<CoachProfileInsightsResponse | null> {
    const resolvedPromptVersion = key.promptVersion ?? this.promptVersion;
    const resolvedModel = key.model ?? this.model;
    const resolvedRoutingVersion =
      key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION;
    const resolvedProviderID = key.providerID ?? "workers_ai";
    const primary = await this.kv.get<CoachProfileInsightsResponse>(
      insightsCacheKey(
        installID,
        key.provider ?? "workers_ai",
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        resolvedProviderID,
        resolvedPromptVersion,
        resolvedRoutingVersion,
        resolvedModel
      ),
      "json"
    );

    if (primary) {
      return primary;
    }

    if ((key.provider ?? "workers_ai") !== "workers_ai") {
      return null;
    }

    return this.kv.get<CoachProfileInsightsResponse>(
      legacyInsightsCacheKey(
        installID,
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        resolvedPromptVersion,
        resolvedModel
      ),
      "json"
    );
  }

  async getDegradedInsightsCache(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<CoachProfileInsightsResponse | null> {
    const resolvedPromptVersion = key.promptVersion ?? this.promptVersion;
    const resolvedModel = key.model ?? this.model;
    const resolvedRoutingVersion =
      key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION;
    const resolvedProviderID = key.providerID ?? "workers_ai";
    return this.kv.get<CoachProfileInsightsResponse>(
      degradedInsightsCacheKey(
        installID,
        key.provider ?? "workers_ai",
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        resolvedProviderID,
        resolvedPromptVersion,
        resolvedRoutingVersion,
        resolvedModel
      ),
      "json"
    );
  }

  async storeInsightsCache(
    installID: string,
    key: ContextStorageKeyInput,
    response: CoachProfileInsightsResponse
  ): Promise<void> {
    const resolvedPromptVersion = key.promptVersion ?? this.promptVersion;
    const resolvedModel = key.model ?? this.model;
    const resolvedRoutingVersion =
      key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION;
    const resolvedProviderID = key.providerID ?? "workers_ai";
    await this.kv.put(
      insightsCacheKey(
        installID,
        key.provider ?? "workers_ai",
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        resolvedProviderID,
        resolvedPromptVersion,
        resolvedRoutingVersion,
        resolvedModel
      ),
      JSON.stringify(response),
      { expirationTtl: INSIGHTS_CACHE_TTL_SECONDS }
    );
  }

  async storeDegradedInsightsCache(
    installID: string,
    key: ContextStorageKeyInput,
    response: CoachProfileInsightsResponse
  ): Promise<void> {
    const resolvedPromptVersion = key.promptVersion ?? this.promptVersion;
    const resolvedModel = key.model ?? this.model;
    const resolvedRoutingVersion =
      key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION;
    const resolvedProviderID = key.providerID ?? "workers_ai";
    await this.kv.put(
      degradedInsightsCacheKey(
        installID,
        key.provider ?? "workers_ai",
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        resolvedProviderID,
        resolvedPromptVersion,
        resolvedRoutingVersion,
        resolvedModel
      ),
      JSON.stringify(response),
      { expirationTtl: DEGRADED_INSIGHTS_CACHE_TTL_SECONDS }
    );
  }

  async deleteDegradedInsightsCache(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<void> {
    const resolvedPromptVersion = key.promptVersion ?? this.promptVersion;
    const resolvedModel = key.model ?? this.model;
    const resolvedRoutingVersion =
      key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION;
    const resolvedProviderID = key.providerID ?? "workers_ai";
    await this.kv.delete(
      degradedInsightsCacheKey(
        installID,
        key.provider ?? "workers_ai",
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        resolvedProviderID,
        resolvedPromptVersion,
        resolvedRoutingVersion,
        resolvedModel
      )
    );
  }

  async getChatMemory(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<StoredChatMemory | null> {
    const resolvedPromptVersion = key.promptVersion ?? this.promptVersion;
    const resolvedModel = key.model ?? this.model;
    const resolvedRoutingVersion =
      key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION;
    const resolvedMemoryProfile = key.memoryProfile ?? "compact_v1";
    const resolvedMemoryCompatibilityKey =
      key.memoryCompatibilityKey ?? resolvedModel;
    const resolvedProviderID = key.providerID ?? "workers_ai";
    const primary = await this.kv.get<StoredChatMemory>(
      chatMemoryKey(
        installID,
        key.provider ?? "workers_ai",
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        resolvedProviderID,
        resolvedPromptVersion,
        resolvedRoutingVersion,
        resolvedMemoryCompatibilityKey,
        resolvedMemoryProfile
      ),
      "json"
    );

    if (primary) {
      return primary;
    }

    if ((key.provider ?? "workers_ai") !== "workers_ai") {
      return null;
    }

    return this.kv.get<StoredChatMemory>(
      legacyChatMemoryKey(
        installID,
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        resolvedPromptVersion,
        resolvedModel,
        resolvedMemoryProfile
      ),
      "json"
    );
  }

  async appendChatMemory(
    installID: string,
    key: ContextStorageKeyInput,
    baseTurns: CoachConversationTurn[],
    question: string,
    answerMarkdown: string
  ): Promise<StoredChatMemory> {
    const resolvedProviderID = key.providerID ?? "workers_ai";
    const memory: StoredChatMemory = {
      updatedAt: this.now().toISOString(),
      recentTurns: normalizeChatTurns([
        ...baseTurns,
        { role: "user", content: question },
        { role: "assistant", content: answerMarkdown },
      ]),
    };

    await this.kv.put(
      chatMemoryKey(
        installID,
        key.provider ?? "workers_ai",
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        resolvedProviderID,
        key.promptVersion ?? this.promptVersion,
        key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION,
        key.memoryCompatibilityKey ?? key.model ?? this.model,
        key.memoryProfile ?? "compact_v1"
      ),
      JSON.stringify(memory),
      { expirationTtl: CHAT_MEMORY_TTL_SECONDS }
    );

    return memory;
  }

  async createChatJob(input: CreateCoachChatJobInput): Promise<CoachChatJobRecord> {
    const existing = await this.getChatJobByClientRequestID(
      input.installID,
      input.clientRequestID,
      input.provider
    );
    if (existing) {
      return existing;
    }

    try {
      await this.insertChatJobRow(input);
    } catch (error) {
      const duplicated = await this.getChatJobByClientRequestID(
        input.installID,
        input.clientRequestID,
        input.provider
      );
      if (duplicated) {
        return duplicated;
      }

      const active = await this.findActiveChatJob(input.installID);
      if (active) {
        throw new ActiveCoachChatJobError(active.jobID, active.provider);
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
        storageKeyFromMetadata(
          job.contextHash,
          job.preparedRequest.metadata,
          job.promptVersion,
          job.preparedRequest.metadata?.selectedModel ?? job.model
        ),
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
        input.clientRequestID,
        input.provider
      );
    if (existingByClientRequestID) {
      return existingByClientRequestID;
    }

    const existingByFingerprint = await this.getWorkoutSummaryJobByFingerprint(
      input.installID,
      input.sessionID,
      input.fingerprint,
      this.promptVersion,
      input.model,
      input.provider
    );
    if (existingByFingerprint) {
      return existingByFingerprint;
    }

    try {
      await this.insertWorkoutSummaryJobRow(input);
    } catch (error) {
      const duplicatedByClientRequestID =
        await this.getWorkoutSummaryJobByClientRequestID(
          input.installID,
          input.clientRequestID,
          input.provider
        );
      if (duplicatedByClientRequestID) {
        return duplicatedByClientRequestID;
      }

      const duplicatedByFingerprint = await this.getWorkoutSummaryJobByFingerprint(
        input.installID,
        input.sessionID,
        input.fingerprint,
        this.promptVersion,
        input.model,
        input.provider
      );
      if (duplicatedByFingerprint) {
        return duplicatedByFingerprint;
      }

      throw error;
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

  async createProfileInsightsJob(
    input: CreateProfileInsightsJobInput
  ): Promise<CoachProfileInsightsJobRecord> {
    const existingByClientRequestID =
      await this.getProfileInsightsJobByClientRequestID(
        input.installID,
        input.clientRequestID,
        input.provider
      );
    if (existingByClientRequestID) {
      return existingByClientRequestID;
    }

    try {
      await this.insertProfileInsightsJobRow(input);
    } catch (error) {
      const duplicated = await this.getProfileInsightsJobByClientRequestID(
        input.installID,
        input.clientRequestID,
        input.provider
      );
      if (duplicated) {
        return duplicated;
      }
      throw error;
    }

    const created = await this.getProfileInsightsJobByID(input.jobID);
    if (!created) {
      throw new Error("Failed to read created profile insights job.");
    }

    return created;
  }

  async getProfileInsightsJob(
    jobID: string,
    installID: string
  ): Promise<CoachProfileInsightsJobRecord | null> {
    const row = await this.db
      .prepare(
        `
          SELECT * FROM coach_profile_insights_jobs
          WHERE job_id = ? AND install_id = ?
          LIMIT 1
        `
      )
      .bind(jobID, installID)
      .first<ProfileInsightsJobRow>();
    return row ? parseProfileInsightsJobRow(row) : null;
  }

  async getProfileInsightsJobByID(
    jobID: string
  ): Promise<CoachProfileInsightsJobRecord | null> {
    const row = await this.db
      .prepare(
        `SELECT * FROM coach_profile_insights_jobs WHERE job_id = ? LIMIT 1`
      )
      .bind(jobID)
      .first<ProfileInsightsJobRow>();
    return row ? parseProfileInsightsJobRow(row) : null;
  }

  async markProfileInsightsJobRunning(
    jobID: string,
    startedAt: string
  ): Promise<{ job: CoachProfileInsightsJobRecord | null; claimed: boolean }> {
    const updateResult = await this.db
      .prepare(
        `
          UPDATE coach_profile_insights_jobs
          SET
            status = 'running',
            started_at = COALESCE(started_at, ?)
          WHERE job_id = ? AND status = 'queued'
        `
      )
      .bind(startedAt, jobID)
      .run();

    return {
      job: await this.getProfileInsightsJobByID(jobID),
      claimed: d1Changes(updateResult) > 0,
    };
  }

  async completeProfileInsightsJob(
    jobID: string,
    input: CompleteProfileInsightsJobInput
  ): Promise<CoachProfileInsightsJobRecord> {
    await this.db
      .prepare(
        `
          UPDATE coach_profile_insights_jobs
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
        JSON.stringify(input.result),
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

    const job = await this.getProfileInsightsJobByID(jobID);
    if (!job) {
      throw new Error("Completed profile insights job was not found.");
    }

    return job;
  }

  async failProfileInsightsJob(
    jobID: string,
    input: FailProfileInsightsJobInput
  ): Promise<CoachProfileInsightsJobRecord> {
    await this.db
      .prepare(
        `
          UPDATE coach_profile_insights_jobs
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

    const job = await this.getProfileInsightsJobByID(jobID);
    if (!job) {
      throw new Error("Failed profile insights job was not found.");
    }

    return job;
  }

  async getBackupStatus(
    request: BackupStatusRequest
  ): Promise<BackupStatusResponse> {
    const current = await this.getCurrentInstallState(request.installID);
    const remote = current?.current_backup_version ? toBackupHead(current) : undefined;
    const status = buildBackupStatusDecision(request, current, remote);
    await this.persistBackupStatus(request, status);
    return status;
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
            install_secret_hash,
            auth_enrolled_at,
            last_seen_local_hash,
            last_seen_local_modified_at,
            last_status_sync_state,
            last_status_context_state,
            last_restore_offered_version,
            last_restore_decision,
            last_restore_decision_local_hash,
            last_restore_decision_at,
            context_ready_backup_hash,
            context_ready_coach_state_version,
            created_at,
            updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            context_ready_backup_hash = excluded.context_ready_backup_hash,
            context_ready_coach_state_version = excluded.context_ready_coach_state_version,
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
        current?.install_secret_hash ?? null,
        current?.auth_enrolled_at ?? null,
        backupHash,
        request.clientSourceModifiedAt ?? null,
        current?.last_status_sync_state ?? null,
        current?.last_status_context_state ?? null,
        current?.last_restore_offered_version ?? null,
        current?.last_restore_decision ?? null,
        current?.last_restore_decision_local_hash ?? null,
        current?.last_restore_decision_at ?? null,
        backupHash,
        coachStateVersion,
        createdAt,
        uploadedAt
      )
      .run();

    await this.enforceBackupRetention(request.installID, backupVersion);

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
            install_secret_hash,
            auth_enrolled_at,
            last_seen_local_hash,
            last_seen_local_modified_at,
            last_status_sync_state,
            last_status_context_state,
            last_restore_offered_version,
            last_restore_decision,
            last_restore_decision_local_hash,
            last_restore_decision_at,
            context_ready_backup_hash,
            context_ready_coach_state_version,
            created_at,
            updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(install_id) DO UPDATE SET
            coach_state_version = excluded.coach_state_version,
            selected_program_id = excluded.selected_program_id,
            program_comment = excluded.program_comment,
            context_ready_backup_hash = excluded.context_ready_backup_hash,
            context_ready_coach_state_version = excluded.context_ready_coach_state_version,
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
        current?.install_secret_hash ?? null,
        current?.auth_enrolled_at ?? null,
        current?.last_seen_local_hash ?? null,
        current?.last_seen_local_modified_at ?? null,
        current?.last_status_sync_state ?? null,
        current?.last_status_context_state ?? null,
        current?.last_restore_offered_version ?? null,
        current?.last_restore_decision ?? null,
        current?.last_restore_decision_local_hash ?? null,
        current?.last_restore_decision_at ?? null,
        current?.current_backup_hash ?? null,
        coachStateVersion,
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

  async recordRestoreDecision(
    request: BackupRestoreDecisionRequest
  ): Promise<void> {
    const current = await this.getCurrentInstallState(request.installID);
    const now = this.now().toISOString();
    await this.db
      .prepare(
        `
          UPDATE install_state
          SET
            last_restore_offered_version = ?,
            last_restore_decision = ?,
            last_restore_decision_local_hash = ?,
            last_restore_decision_at = ?,
            updated_at = ?
          WHERE install_id = ?
        `
      )
      .bind(
        request.remoteVersion,
        request.action,
        request.localBackupHash ?? null,
        now,
        now,
        request.installID
      )
      .run();

    if (!current) {
      return;
    }
  }

  async clearRemoteAIMemory(request: CoachMemoryClearRequest): Promise<void> {
    await this.deleteKVPrefix(`${request.installID}:chat-memory:`, request.providerID);
    if (request.clearInsightsCache) {
      await this.deleteKVPrefix(`${request.installID}:insights:`, request.providerID);
    }
  }

  async deleteRemoteBackup(request: BackupDeleteRequest): Promise<void> {
    const backups = await this.listBackupVersions(request.installID);
    if (backups.length > 0) {
      await this.r2.delete(backups.map((backup) => backup.r2_key));
    }

    await this.db
      .prepare(`DELETE FROM backup_versions WHERE install_id = ?`)
      .bind(request.installID)
      .run();
    await this.db
      .prepare(
        `
          UPDATE install_state
          SET
            current_backup_version = NULL,
            current_backup_hash = NULL,
            current_backup_r2_key = NULL,
            current_backup_schema_version = NULL,
            size_bytes = 0,
            uploaded_at = NULL,
            client_source_modified_at = NULL,
            last_restore_offered_version = NULL,
            last_restore_decision = NULL,
            last_restore_decision_local_hash = NULL,
            last_restore_decision_at = NULL,
            context_ready_backup_hash = NULL,
            context_ready_coach_state_version = NULL,
            updated_at = ?
          WHERE install_id = ?
        `
      )
      .bind(this.now().toISOString(), request.installID)
      .run();
  }

  async deleteInstallState(installID: string): Promise<void> {
    await this.clearRemoteAIMemory({
      installID,
      clearInsightsCache: true,
    });
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
      .prepare(`DELETE FROM coach_chat_jobs WHERE install_id = ?`)
      .bind(installID)
      .run();
    await this.db
      .prepare(`DELETE FROM coach_workout_summary_jobs WHERE install_id = ?`)
      .bind(installID)
      .run();
    await this.db
      .prepare(`DELETE FROM coach_profile_insights_jobs WHERE install_id = ?`)
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

  private async persistBackupStatus(
    request: BackupStatusRequest,
    status: BackupStatusResponse
  ): Promise<void> {
    const current = await this.getCurrentInstallState(request.installID);
    if (!current) {
      return;
    }

    const now = this.now().toISOString();
    const shouldTrackRestoreVersion =
      status.syncState === "restore_pending_decision" && status.remote?.backupVersion;
    await this.db
      .prepare(
        `
          UPDATE install_state
          SET
            last_seen_local_hash = ?,
            last_seen_local_modified_at = ?,
            last_status_sync_state = ?,
            last_status_context_state = ?,
            last_restore_offered_version = COALESCE(?, last_restore_offered_version),
            updated_at = ?
          WHERE install_id = ?
        `
      )
      .bind(
        request.localBackupHash ?? null,
        request.localSourceModifiedAt ?? null,
        status.syncState,
        status.contextState,
        shouldTrackRestoreVersion ? status.remote?.backupVersion ?? null : null,
        now,
        request.installID
      )
      .run();
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

  private async enforceBackupRetention(
    installID: string,
    currentBackupVersion: number
  ): Promise<void> {
    const backups = await this.listBackupVersions(installID);
    const cutoff = this.now().getTime() - 90 * 24 * 60 * 60 * 1_000;
    const deletable = backups.filter((backup, index) => {
      if (backup.backup_version === currentBackupVersion) {
        return false;
      }

      if (index >= 30) {
        return true;
      }

      return Date.parse(backup.uploaded_at) < cutoff;
    });

    if (deletable.length === 0) {
      return;
    }

    await this.r2.delete(deletable.map((backup) => backup.r2_key));
    for (const backup of deletable) {
      await this.db
        .prepare(
          `DELETE FROM backup_versions WHERE install_id = ? AND backup_version = ?`
        )
        .bind(installID, backup.backup_version)
        .run();
    }
  }

  private async deleteKVPrefix(
    prefix: string,
    providerID?: string
  ): Promise<void> {
    if (!this.kv.list) {
      return;
    }

    let cursor: string | undefined;
    do {
      const page = await this.kv.list({
        prefix,
        cursor,
        limit: 100,
      });
      for (const key of page.keys) {
        if (!providerID || key.name.includes(`:${providerID}:`)) {
          await this.kv.delete(key.name);
        }
      }
      cursor = page.cursor;
      if (page.list_complete) {
        break;
      }
    } while (cursor);
  }

  private async getChatJobByClientRequestID(
    installID: string,
    clientRequestID: string,
    provider: CoachAIProvider
  ): Promise<CoachChatJobRecord | null> {
    if (this.chatJobProviderColumnSupport !== false) {
      try {
        const row = await this.db
          .prepare(
            `
              SELECT * FROM coach_chat_jobs
              WHERE install_id = ? AND client_request_id = ? AND provider = ?
              LIMIT 1
            `
          )
          .bind(installID, clientRequestID, provider)
          .first<CoachChatJobRow>();
        this.chatJobProviderColumnSupport = true;
        return row ? parseCoachChatJobRow(row) : null;
      } catch (error) {
        if (!isMissingProviderColumnError(error)) {
          throw error;
        }
        this.markProviderColumnUnavailable("coach_chat_jobs", error);
      }
    }

    const candidates = legacyProviderScopedClientRequestIDCandidates(
      clientRequestID,
      provider
    );
    const results = await this.db
      .prepare(
        `
          SELECT * FROM coach_chat_jobs
          WHERE install_id = ?
            AND (client_request_id = ? OR client_request_id = ?)
          ORDER BY created_at DESC
          LIMIT 5
        `
      )
      .bind(installID, candidates[0], candidates[1])
      .all<CoachChatJobRow>();
    return (
      results.results
        .map((row) => parseCoachChatJobRow(row))
        .find((job) => job.provider === provider) ?? null
    );
  }

  private async getWorkoutSummaryJobByClientRequestID(
    installID: string,
    clientRequestID: string,
    provider: CoachAIProvider
  ): Promise<CoachWorkoutSummaryJobRecord | null> {
    if (this.workoutSummaryProviderColumnSupport !== false) {
      try {
        const row = await this.db
          .prepare(
            `
              SELECT * FROM coach_workout_summary_jobs
              WHERE install_id = ? AND client_request_id = ? AND provider = ?
              LIMIT 1
            `
          )
          .bind(installID, clientRequestID, provider)
          .first<WorkoutSummaryJobRow>();
        this.workoutSummaryProviderColumnSupport = true;
        return row ? parseWorkoutSummaryJobRow(row) : null;
      } catch (error) {
        if (!isMissingProviderColumnError(error)) {
          throw error;
        }
        this.markProviderColumnUnavailable("coach_workout_summary_jobs", error);
      }
    }

    const candidates = legacyProviderScopedClientRequestIDCandidates(
      clientRequestID,
      provider
    );
    const results = await this.db
      .prepare(
        `
          SELECT * FROM coach_workout_summary_jobs
          WHERE install_id = ?
            AND (client_request_id = ? OR client_request_id = ?)
          ORDER BY created_at DESC
          LIMIT 5
        `
      )
      .bind(installID, candidates[0], candidates[1])
      .all<WorkoutSummaryJobRow>();
    return (
      results.results
        .map((row) => parseWorkoutSummaryJobRow(row))
        .find((job) => job.provider === provider) ?? null
    );
  }

  private async getProfileInsightsJobByClientRequestID(
    installID: string,
    clientRequestID: string,
    provider: CoachAIProvider
  ): Promise<CoachProfileInsightsJobRecord | null> {
    if (this.profileInsightsJobProviderColumnSupport !== false) {
      try {
        const row = await this.db
          .prepare(
            `
              SELECT * FROM coach_profile_insights_jobs
              WHERE install_id = ? AND client_request_id = ? AND provider = ?
              LIMIT 1
            `
          )
          .bind(installID, clientRequestID, provider)
          .first<ProfileInsightsJobRow>();
        this.profileInsightsJobProviderColumnSupport = true;
        return row ? parseProfileInsightsJobRow(row) : null;
      } catch (error) {
        if (!isMissingProviderColumnError(error)) {
          throw error;
        }
        this.markProviderColumnUnavailable(
          "coach_profile_insights_jobs",
          error
        );
      }
    }

    const candidates = legacyProviderScopedClientRequestIDCandidates(
      clientRequestID,
      provider
    );
    const results = await this.db
      .prepare(
        `
          SELECT * FROM coach_profile_insights_jobs
          WHERE install_id = ?
            AND (client_request_id = ? OR client_request_id = ?)
          ORDER BY created_at DESC
          LIMIT 5
        `
      )
      .bind(installID, candidates[0], candidates[1])
      .all<ProfileInsightsJobRow>();
    return (
      results.results
        .map((row) => parseProfileInsightsJobRow(row))
        .find((job) => job.provider === provider) ?? null
    );
  }

  private async getWorkoutSummaryJobByFingerprint(
    installID: string,
    sessionID: string,
    fingerprint: string,
    promptVersion: string,
    model: string,
    provider: CoachAIProvider
  ): Promise<CoachWorkoutSummaryJobRecord | null> {
    if (this.workoutSummaryProviderColumnSupport !== false) {
      try {
        const row = await this.db
          .prepare(
            `
              SELECT * FROM coach_workout_summary_jobs
              WHERE install_id = ?
                AND session_id = ?
                AND fingerprint = ?
                AND prompt_version = ?
                AND model = ?
                AND provider = ?
                AND status IN ('queued', 'running', 'completed')
              ORDER BY created_at DESC
              LIMIT 1
            `
          )
          .bind(installID, sessionID, fingerprint, promptVersion, model, provider)
          .first<WorkoutSummaryJobRow>();
        this.workoutSummaryProviderColumnSupport = true;
        return row ? parseWorkoutSummaryJobRow(row) : null;
      } catch (error) {
        if (!isMissingProviderColumnError(error)) {
          throw error;
        }
        this.markProviderColumnUnavailable("coach_workout_summary_jobs", error);
      }
    }

    const results = await this.db
      .prepare(
        `
          SELECT * FROM coach_workout_summary_jobs
          WHERE install_id = ?
            AND session_id = ?
            AND fingerprint = ?
            AND prompt_version = ?
            AND model = ?
            AND status IN ('queued', 'running', 'completed')
          ORDER BY created_at DESC
          LIMIT 10
        `
      )
      .bind(installID, sessionID, fingerprint, promptVersion, model)
      .all<WorkoutSummaryJobRow>();
    return (
      results.results
        .map((row) => parseWorkoutSummaryJobRow(row))
        .find((job) => job.provider === provider) ?? null
    );
  }

  private async insertChatJobRow(input: CreateCoachChatJobInput): Promise<void> {
    if (this.chatJobProviderColumnSupport !== false) {
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
                model,
                provider
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            input.model,
            input.provider
          )
          .run();
        this.chatJobProviderColumnSupport = true;
        return;
      } catch (error) {
        if (!isMissingProviderColumnError(error)) {
          throw error;
        }
        this.markProviderColumnUnavailable("coach_chat_jobs", error);
      }
    }

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
        encodeLegacyProviderScopedClientRequestID(
          input.clientRequestID,
          input.provider
        ),
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
        input.model
      )
      .run();
  }

  private async insertWorkoutSummaryJobRow(
    input: CreateWorkoutSummaryJobInput
  ): Promise<void> {
    if (this.workoutSummaryProviderColumnSupport !== false) {
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
                model,
                provider
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            input.model,
            input.provider
          )
          .run();
        this.workoutSummaryProviderColumnSupport = true;
        return;
      } catch (error) {
        if (!isMissingProviderColumnError(error)) {
          throw error;
        }
        this.markProviderColumnUnavailable(
          "coach_workout_summary_jobs",
          error
        );
      }
    }

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
        encodeLegacyProviderScopedClientRequestID(
          input.clientRequestID,
          input.provider
        ),
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
        input.model
      )
      .run();
  }

  private async insertProfileInsightsJobRow(
    input: CreateProfileInsightsJobInput
  ): Promise<void> {
    if (this.profileInsightsJobProviderColumnSupport !== false) {
      try {
        await this.db
          .prepare(
            `
              INSERT INTO coach_profile_insights_jobs (
                job_id,
                install_id,
                client_request_id,
                status,
                prepared_request_json,
                created_at,
                context_hash,
                context_source,
                snapshot_bytes,
                program_comment_chars,
                recent_pr_count,
                relative_strength_count,
                preferred_program_workout_count,
                prompt_version,
                model,
                provider
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            input.snapshotBytes,
            input.programCommentChars,
            input.recentPrCount,
            input.relativeStrengthCount,
            input.preferredProgramWorkoutCount,
            this.promptVersion,
            input.model,
            input.provider
          )
          .run();
        this.profileInsightsJobProviderColumnSupport = true;
        return;
      } catch (error) {
        if (!isMissingProviderColumnError(error)) {
          throw error;
        }
        this.markProviderColumnUnavailable(
          "coach_profile_insights_jobs",
          error
        );
      }
    }

    await this.db
      .prepare(
        `
          INSERT INTO coach_profile_insights_jobs (
            job_id,
            install_id,
            client_request_id,
            status,
            prepared_request_json,
            created_at,
            context_hash,
            context_source,
            snapshot_bytes,
            program_comment_chars,
            recent_pr_count,
            relative_strength_count,
            preferred_program_workout_count,
            prompt_version,
            model
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `
      )
      .bind(
        input.jobID,
        input.installID,
        encodeLegacyProviderScopedClientRequestID(
          input.clientRequestID,
          input.provider
        ),
        "queued",
        stableJSONStringify(input.preparedRequest),
        input.createdAt,
        input.contextHash,
        input.contextSource,
        input.snapshotBytes,
        input.programCommentChars,
        input.recentPrCount,
        input.relativeStrengthCount,
        input.preferredProgramWorkoutCount,
        this.promptVersion,
        input.model
      )
      .run();
  }

  private markProviderColumnUnavailable(
    table:
      | "coach_chat_jobs"
      | "coach_workout_summary_jobs"
      | "coach_profile_insights_jobs",
    error: unknown
  ): void {
    const message =
      error instanceof Error ? error.message.slice(0, 300) : "Unknown error";
    if (table === "coach_chat_jobs") {
      this.chatJobProviderColumnSupport = false;
    } else if (table === "coach_workout_summary_jobs") {
      this.workoutSummaryProviderColumnSupport = false;
    } else {
      this.profileInsightsJobProviderColumnSupport = false;
    }
    console.warn(
      JSON.stringify({
        event: "provider_column_compatibility_fallback_enabled",
        table,
        reason: message,
      })
    );
  }
}

export class InMemoryCoachStateRepository implements CoachStateStore {
  private readonly backupHeads = new Map<string, BackupHead>();
  private readonly backups = new Map<string, Map<number, BackupEnvelopeV2>>();
  private readonly insightsCache = new Map<string, CoachProfileInsightsResponse>();
  private readonly degradedInsightsCache = new Map<
    string,
    { response: CoachProfileInsightsResponse; expiresAt: number }
  >();
  private readonly chatMemory = new Map<string, StoredChatMemory>();
  private readonly chatJobs = new Map<string, CoachChatJobRecord>();
  private readonly workoutSummaryJobs = new Map<string, CoachWorkoutSummaryJobRecord>();
  private readonly profileInsightsJobs = new Map<string, CoachProfileInsightsJobRecord>();
  private readonly coachStateVersions = new Map<string, number>();
  private readonly installSecretHashes = new Map<string, string>();
  private readonly restoreDecisions = new Map<
    string,
    { remoteVersion: number; action: "apply" | "ignore"; localBackupHash?: string }
  >();

  constructor(
    private readonly promptVersion: string,
    private readonly model: string,
    private readonly now: () => Date = () => new Date()
  ) {}

  async authorizeInstallAccess(input: {
    installID: string;
    providedSecret?: string;
    allowLegacyCompat?: boolean;
    enrollIfMissing?: boolean;
  }): Promise<InstallAuthorizationResult> {
    const storedSecretHash = this.installSecretHashes.get(input.installID);
    const providedSecret = input.providedSecret?.trim();

    if (storedSecretHash) {
      if (!providedSecret) {
        throw new InstallAccessError("install_proof_required");
      }
      const providedHash = await sha256Hex(providedSecret);
      if (providedHash !== storedSecretHash) {
        throw new InstallAccessError("install_proof_invalid");
      }
      return { authMode: "secret_valid" };
    }

    if (providedSecret) {
      if (
        input.enrollIfMissing !== false &&
        (this.backupHeads.has(input.installID) || this.coachStateVersions.has(input.installID))
      ) {
        await this.bindInstallSecret(input.installID, providedSecret);
        return { authMode: "secret_valid" };
      }
      return { authMode: "unbound_secret" };
    }

    if (input.allowLegacyCompat !== false) {
      return { authMode: "legacy_compat" };
    }

    throw new InstallAccessError("install_proof_required");
  }

  async bindInstallSecret(installID: string, providedSecret: string): Promise<void> {
    if (
      !this.backupHeads.has(installID) &&
      !this.backups.has(installID) &&
      !this.coachStateVersions.has(installID)
    ) {
      return;
    }

    this.installSecretHashes.set(installID, await sha256Hex(providedSecret.trim()));
  }

  async resolveCoachContext(
    request:
      | CoachProfileInsightsRequest
      | CoachChatRequest
      | {
          installID: string;
          localBackupHash?: string;
          snapshotHash?: string;
          snapshot?: CompactCoachSnapshot;
          runtimeContextDelta?: CoachRuntimeContextDelta;
        }
  ): Promise<ResolvedCoachContext> {
    const remote = this.backupHeads.get(request.installID);
    const remoteHashMismatch =
      Boolean(remote?.backupHash) &&
      Boolean(request.localBackupHash) &&
      request.localBackupHash !== remote?.backupHash;
    if (remote) {
      if (remoteHashMismatch && !request.snapshot) {
        throw new StaleRemoteStateError(remote.backupVersion);
      }
      const backup = remoteHashMismatch
        ? undefined
        : this.backups.get(request.installID)?.get(remote.backupVersion);
      if (backup) {
        const snapshot = overlayCoachAnalysisSettings(backup.snapshot, {
          selectedProgramID: remote.selectedProgramID,
          programComment: remote.programComment,
        });
        const compactSnapshot = buildCoachContextFromSnapshot({
          snapshot,
          selectedProgramID: remote.selectedProgramID,
          programComment: remote.programComment,
          runtimeContextDelta: request.runtimeContextDelta,
        });
        const finishedSessions = snapshot.history
          .filter((session) => Boolean(session.endedAt))
          .sort(
            (left, right) => Date.parse(right.startedAt) - Date.parse(left.startedAt)
          );
        const preferredProgram = snapshot.coachAnalysisSettings.selectedProgramID
          ? snapshot.programs.find(
              (program) => program.id === snapshot.coachAnalysisSettings.selectedProgramID
            )
          : snapshot.programs.find((program) => program.workouts.length > 0);
        return {
          snapshot: compactSnapshot,
          contextHash: `${remote.backupHash}:${remote.coachStateVersion}`,
          cacheAllowed: !request.runtimeContextDelta?.activeWorkout,
          source: "remote_full",
          backupHead: remote,
          contextVersion: DEFAULT_CONTEXT_VERSION,
          analyticsVersion: DEFAULT_ANALYTICS_VERSION,
          derivedAnalytics: buildDerivedCoachAnalyticsFromSnapshot({
            snapshot,
            preferredProgram,
            profile: snapshot.profile,
            consistencySummary: compactSnapshot.analytics.consistency,
            coachAnalysisSettings: snapshot.coachAnalysisSettings,
            finishedSessions,
          }),
        };
      }
    }

    if (request.snapshot) {
      const snapshot = withRuntimeContext(request.snapshot, request.runtimeContextDelta);
      return {
        snapshot,
        contextHash:
          request.snapshotHash || (await hashCoachContext(request.snapshot)),
        cacheAllowed: !request.runtimeContextDelta?.activeWorkout,
        source: "inline_legacy",
        contextVersion: DEFAULT_CONTEXT_VERSION,
        analyticsVersion: DEFAULT_ANALYTICS_VERSION,
        derivedAnalytics: buildDerivedCoachAnalyticsFromCompactSnapshot(snapshot),
      };
    }

    throw new MissingCoachContextError();
  }

  async getInsightsCache(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<CoachProfileInsightsResponse | null> {
    return (
      this.insightsCache.get(
        insightsCacheKey(
          installID,
          key.provider ?? "workers_ai",
          key.contextHash,
          key.contextProfile,
          key.contextVersion,
          key.analyticsVersion,
          key.providerID ?? "workers_ai",
          key.promptVersion ?? this.promptVersion,
          key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION,
          key.model ?? this.model
        )
      ) ??
      ((key.provider ?? "workers_ai") === "workers_ai"
        ? this.insightsCache.get(
            legacyInsightsCacheKey(
              installID,
              key.contextHash,
              key.contextProfile,
              key.contextVersion,
              key.analyticsVersion,
              key.promptVersion ?? this.promptVersion,
              key.model ?? this.model
            )
          )
        : undefined) ??
      null
    );
  }

  async getDegradedInsightsCache(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<CoachProfileInsightsResponse | null> {
    const cacheKey = degradedInsightsCacheKey(
      installID,
      key.provider ?? "workers_ai",
      key.contextHash,
      key.contextProfile,
      key.contextVersion,
      key.analyticsVersion,
      key.providerID ?? "workers_ai",
      key.promptVersion ?? this.promptVersion,
      key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION,
      key.model ?? this.model
    );
    const entry = this.degradedInsightsCache.get(cacheKey);
    if (!entry) {
      return null;
    }
    if (entry.expiresAt <= this.now().getTime()) {
      this.degradedInsightsCache.delete(cacheKey);
      return null;
    }
    return entry.response;
  }

  async storeInsightsCache(
    installID: string,
    key: ContextStorageKeyInput,
    response: CoachProfileInsightsResponse
  ): Promise<void> {
    this.insightsCache.set(
      insightsCacheKey(
        installID,
        key.provider ?? "workers_ai",
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        key.providerID ?? "workers_ai",
        key.promptVersion ?? this.promptVersion,
        key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION,
        key.model ?? this.model
      ),
      response
    );
  }

  async storeDegradedInsightsCache(
    installID: string,
    key: ContextStorageKeyInput,
    response: CoachProfileInsightsResponse
  ): Promise<void> {
    this.degradedInsightsCache.set(
      degradedInsightsCacheKey(
        installID,
        key.provider ?? "workers_ai",
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        key.providerID ?? "workers_ai",
        key.promptVersion ?? this.promptVersion,
        key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION,
        key.model ?? this.model
      ),
      {
        response,
        expiresAt:
          this.now().getTime() + DEGRADED_INSIGHTS_CACHE_TTL_SECONDS * 1_000,
      }
    );
  }

  async deleteDegradedInsightsCache(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<void> {
    this.degradedInsightsCache.delete(
      degradedInsightsCacheKey(
        installID,
        key.provider ?? "workers_ai",
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        key.providerID ?? "workers_ai",
        key.promptVersion ?? this.promptVersion,
        key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION,
        key.model ?? this.model
      )
    );
  }

  async getChatMemory(
    installID: string,
    key: ContextStorageKeyInput
  ): Promise<StoredChatMemory | null> {
    return (
      this.chatMemory.get(
        chatMemoryKey(
          installID,
          key.provider ?? "workers_ai",
          key.contextHash,
          key.contextProfile,
          key.contextVersion,
          key.analyticsVersion,
          key.providerID ?? "workers_ai",
          key.promptVersion ?? this.promptVersion,
          key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION,
          key.memoryCompatibilityKey ?? key.model ?? this.model,
          key.memoryProfile ?? "compact_v1"
        )
      ) ??
      ((key.provider ?? "workers_ai") === "workers_ai"
        ? this.chatMemory.get(
            legacyChatMemoryKey(
              installID,
              key.contextHash,
              key.contextProfile,
              key.contextVersion,
              key.analyticsVersion,
              key.promptVersion ?? this.promptVersion,
              key.model ?? this.model,
              key.memoryProfile ?? "compact_v1"
            )
          )
        : undefined) ??
      null
    );
  }

  async appendChatMemory(
    installID: string,
    key: ContextStorageKeyInput,
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
    this.chatMemory.set(
      chatMemoryKey(
        installID,
        key.provider ?? "workers_ai",
        key.contextHash,
        key.contextProfile,
        key.contextVersion,
        key.analyticsVersion,
        key.providerID ?? "workers_ai",
        key.promptVersion ?? this.promptVersion,
        key.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION,
        key.memoryCompatibilityKey ?? key.model ?? this.model,
        key.memoryProfile ?? "compact_v1"
      ),
      memory
    );
    return memory;
  }

  async createChatJob(input: CreateCoachChatJobInput): Promise<CoachChatJobRecord> {
    const existing = [...this.chatJobs.values()].find(
      (job) =>
        job.installID === input.installID &&
        job.clientRequestID === input.clientRequestID &&
        job.provider === input.provider
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
      throw new ActiveCoachChatJobError(active.jobID, active.provider);
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
      model: input.model,
      provider: input.provider,
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
        storageKeyFromMetadata(
          job.contextHash,
          job.preparedRequest.metadata,
          job.promptVersion,
          job.preparedRequest.metadata?.selectedModel ?? job.model
        ),
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
        job.clientRequestID === input.clientRequestID &&
        job.provider === input.provider
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
          job.promptVersion === this.promptVersion &&
          job.model === input.model &&
          job.provider === input.provider &&
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
      model: input.model,
      provider: input.provider,
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

  async createProfileInsightsJob(
    input: CreateProfileInsightsJobInput
  ): Promise<CoachProfileInsightsJobRecord> {
    const existing = [...this.profileInsightsJobs.values()].find(
      (job) =>
        job.installID === input.installID &&
        job.clientRequestID === input.clientRequestID &&
        job.provider === input.provider
    );
    if (existing) {
      return existing;
    }

    const created: CoachProfileInsightsJobRecord = {
      jobID: input.jobID,
      installID: input.installID,
      clientRequestID: input.clientRequestID,
      status: "queued",
      preparedRequest: input.preparedRequest,
      createdAt: input.createdAt,
      contextHash: input.contextHash,
      contextSource: input.contextSource,
      snapshotBytes: input.snapshotBytes,
      programCommentChars: input.programCommentChars,
      recentPrCount: input.recentPrCount,
      relativeStrengthCount: input.relativeStrengthCount,
      preferredProgramWorkoutCount: input.preferredProgramWorkoutCount,
      promptVersion: this.promptVersion,
      model: input.model,
      provider: input.provider,
    };
    this.profileInsightsJobs.set(created.jobID, created);
    return created;
  }

  async getProfileInsightsJob(
    jobID: string,
    installID: string
  ): Promise<CoachProfileInsightsJobRecord | null> {
    const job = this.profileInsightsJobs.get(jobID);
    if (!job || job.installID != installID) {
      return null;
    }

    return job;
  }

  async getProfileInsightsJobByID(
    jobID: string
  ): Promise<CoachProfileInsightsJobRecord | null> {
    return this.profileInsightsJobs.get(jobID) ?? null;
  }

  async markProfileInsightsJobRunning(
    jobID: string,
    startedAt: string
  ): Promise<{ job: CoachProfileInsightsJobRecord | null; claimed: boolean }> {
    const job = this.profileInsightsJobs.get(jobID);
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

  async completeProfileInsightsJob(
    jobID: string,
    input: CompleteProfileInsightsJobInput
  ): Promise<CoachProfileInsightsJobRecord> {
    const job = this.profileInsightsJobs.get(jobID);
    if (!job) {
      throw new Error("Completed profile insights job was not found.");
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

  async failProfileInsightsJob(
    jobID: string,
    input: FailProfileInsightsJobInput
  ): Promise<CoachProfileInsightsJobRecord> {
    const job = this.profileInsightsJobs.get(jobID);
    if (!job) {
      throw new Error("Failed profile insights job was not found.");
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

  async getBackupStatus(
    request: BackupStatusRequest
  ): Promise<BackupStatusResponse> {
    return buildBackupStatusDecision(
      request,
      inMemoryInstallStateRow(
        request.installID,
        this.backupHeads.get(request.installID),
        this.installSecretHashes.get(request.installID),
        this.restoreDecisions.get(request.installID)
      ),
      this.backupHeads.get(request.installID)
    );
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

  async recordRestoreDecision(
    request: BackupRestoreDecisionRequest
  ): Promise<void> {
    this.restoreDecisions.set(request.installID, {
      remoteVersion: request.remoteVersion,
      action: request.action,
      localBackupHash: request.localBackupHash,
    });
  }

  async clearRemoteAIMemory(request: CoachMemoryClearRequest): Promise<void> {
    for (const key of [...this.chatMemory.keys()]) {
      if (
        key.startsWith(`${request.installID}:chat-memory:`) &&
        (!request.providerID || key.includes(`:${request.providerID}:`))
      ) {
        this.chatMemory.delete(key);
      }
    }

    if (request.clearInsightsCache) {
      for (const key of [...this.insightsCache.keys()]) {
        if (
          key.startsWith(`${request.installID}:insights:`) &&
          (!request.providerID || key.includes(`:${request.providerID}:`))
        ) {
          this.insightsCache.delete(key);
        }
      }
      for (const key of [...this.degradedInsightsCache.keys()]) {
        if (
          key.startsWith(`${request.installID}:insights:`) &&
          (!request.providerID || key.includes(`:${request.providerID}:`))
        ) {
          this.degradedInsightsCache.delete(key);
        }
      }
    }
  }

  async deleteRemoteBackup(request: BackupDeleteRequest): Promise<void> {
    this.backupHeads.delete(request.installID);
    this.backups.delete(request.installID);
    this.restoreDecisions.delete(request.installID);
  }

  async deleteInstallState(installID: string): Promise<void> {
    this.backupHeads.delete(installID);
    this.backups.delete(installID);
    this.coachStateVersions.delete(installID);
    this.installSecretHashes.delete(installID);
    this.restoreDecisions.delete(installID);
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
    for (const [jobID, job] of this.profileInsightsJobs.entries()) {
      if (job.installID === installID) {
        this.profileInsightsJobs.delete(jobID);
      }
    }
    for (const key of [...this.insightsCache.keys()]) {
      if (key.startsWith(`${installID}:`)) {
        this.insightsCache.delete(key);
      }
    }
    for (const key of [...this.degradedInsightsCache.keys()]) {
      if (key.startsWith(`${installID}:`)) {
        this.degradedInsightsCache.delete(key);
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
  constructor(
    readonly jobID: string,
    readonly provider: CoachAIProvider = "workers_ai"
  ) {
    super("Coach chat job already in progress.");
    this.name = "ActiveCoachChatJobError";
  }
}

export class InstallAccessError extends Error {
  constructor(readonly code: "install_proof_required" | "install_proof_invalid") {
    super(
      code === "install_proof_required"
        ? "Install proof required."
        : "Install proof invalid."
    );
    this.name = "InstallAccessError";
  }
}

function buildBackupStatusDecision(
  request: BackupStatusRequest,
  current: InstallStateRow | null,
  remote: BackupHead | undefined
): BackupStatusResponse {
  const reasonCodes: string[] = [];

  if (!remote) {
    reasonCodes.push("remote_head_missing");
    return {
      syncState: "no_remote_backup",
      contextState: "reconcile_required",
      reasonCodes,
      actions: {
        canUseRemoteAIContextNow: false,
        shouldUpload:
          request.localStateKind === "user_data" && Boolean(request.localBackupHash),
        shouldOfferRestore: false,
        shouldBuildInlineFallback: Boolean(request.localBackupHash),
        shouldPromptUser: false,
      },
      authMode: "legacy_compat",
    };
  }

  if (request.localBackupHash && request.localBackupHash === remote.backupHash) {
    reasonCodes.push("hash_match");
    return {
      syncState: "remote_ready",
      contextState: "context_ready",
      reasonCodes,
      actions: {
        canUseRemoteAIContextNow: true,
        shouldUpload: false,
        shouldOfferRestore: false,
        shouldBuildInlineFallback: false,
        shouldPromptUser: false,
      },
      authMode: "legacy_compat",
      remote,
    };
  }

  if (request.localStateKind === "seed" || !request.localBackupHash) {
    const ignored =
      current?.last_restore_decision === "ignore" &&
      current.last_restore_offered_version === remote.backupVersion;
    reasonCodes.push("remote_head_newer");
    if (ignored) {
      reasonCodes.push("restore_previously_ignored");
    }
    return {
      syncState: ignored ? "remote_newer_than_local" : "restore_pending_decision",
      contextState: "context_stale",
      reasonCodes,
      actions: {
        canUseRemoteAIContextNow: false,
        shouldUpload: false,
        shouldOfferRestore: true,
        shouldBuildInlineFallback: Boolean(request.localBackupHash),
        shouldPromptUser: !ignored,
      },
      authMode: "legacy_compat",
      remote,
    };
  }

  const localModifiedAt = request.localSourceModifiedAt
    ? Date.parse(request.localSourceModifiedAt)
    : Number.NaN;
  const remoteModifiedAt = remote.clientSourceModifiedAt
    ? Date.parse(remote.clientSourceModifiedAt)
    : Date.parse(remote.uploadedAt);

  if (Number.isFinite(localModifiedAt) && Number.isFinite(remoteModifiedAt)) {
    if (localModifiedAt > remoteModifiedAt) {
      reasonCodes.push("local_dirty_since_remote");
      return {
        syncState: "upload_required",
        contextState: "context_stale",
        reasonCodes,
        actions: {
          canUseRemoteAIContextNow: false,
          shouldUpload: true,
          shouldOfferRestore: false,
          shouldBuildInlineFallback: true,
          shouldPromptUser: false,
        },
        authMode: "legacy_compat",
        remote,
      };
    }

    if (localModifiedAt < remoteModifiedAt) {
      const ignored =
        current?.last_restore_decision === "ignore" &&
        current.last_restore_offered_version === remote.backupVersion &&
        current.last_restore_decision_local_hash === request.localBackupHash;
      reasonCodes.push("remote_head_newer");
      if (ignored) {
        reasonCodes.push("restore_previously_ignored");
      }
      return {
        syncState: ignored ? "remote_newer_than_local" : "restore_pending_decision",
        contextState: "context_stale",
        reasonCodes,
        actions: {
          canUseRemoteAIContextNow: false,
          shouldUpload: false,
          shouldOfferRestore: true,
          shouldBuildInlineFallback: true,
          shouldPromptUser: !ignored,
        },
        authMode: "legacy_compat",
        remote,
      };
    }
  }

  reasonCodes.push("ambiguous_version_conflict");
  return {
    syncState: "conflict",
    contextState: "context_stale",
    reasonCodes,
    actions: {
      canUseRemoteAIContextNow: false,
      shouldUpload: false,
      shouldOfferRestore: true,
      shouldBuildInlineFallback: true,
      shouldPromptUser: true,
    },
    authMode: "legacy_compat",
    remote,
  };
}

function inMemoryInstallStateRow(
  installID: string,
  remote: BackupHead | undefined,
  installSecretHash?: string,
  restoreDecision?: { remoteVersion: number; action: "apply" | "ignore"; localBackupHash?: string }
): InstallStateRow | null {
  if (!remote && !installSecretHash && !restoreDecision) {
    return null;
  }

  const now = new Date().toISOString();
  return {
    install_id: installID,
    current_backup_version: remote?.backupVersion ?? null,
    current_backup_hash: remote?.backupHash ?? null,
    current_backup_r2_key: remote?.r2Key ?? null,
    current_backup_schema_version: remote?.schemaVersion ?? null,
    compression: (remote?.compression as "gzip" | "identity" | undefined) ?? "gzip",
    size_bytes: remote?.sizeBytes ?? 0,
    uploaded_at: remote?.uploadedAt ?? null,
    client_source_modified_at: remote?.clientSourceModifiedAt ?? null,
    coach_state_version: remote?.coachStateVersion ?? 0,
    selected_program_id: remote?.selectedProgramID ?? null,
    program_comment: remote?.programComment ?? "",
    install_secret_hash: installSecretHash ?? null,
    auth_enrolled_at: installSecretHash ? now : null,
    last_seen_local_hash: null,
    last_seen_local_modified_at: null,
    last_status_sync_state: null,
    last_status_context_state: null,
    last_restore_offered_version: restoreDecision?.remoteVersion ?? null,
    last_restore_decision: restoreDecision?.action ?? null,
    last_restore_decision_local_hash: restoreDecision?.localBackupHash ?? null,
    last_restore_decision_at: restoreDecision ? now : null,
    context_ready_backup_hash: remote?.backupHash ?? null,
    context_ready_coach_state_version: remote?.coachStateVersion ?? null,
    created_at: now,
    updated_at: now,
  };
}

async function sha256Hex(input: string): Promise<string> {
  const encoded = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", encoded);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
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
  const preparedRequest = JSON.parse(
    row.prepared_request_json
  ) as PreparedCoachChatJobRequest;
  const provider =
    row.provider ??
    preparedRequest.metadata?.provider ??
    preparedRequest.provider ??
    "workers_ai";
  return {
    jobID: row.job_id,
    installID: row.install_id,
    clientRequestID: decodeLegacyProviderScopedClientRequestID(
      row.client_request_id,
      provider
    ),
    status: row.status,
    preparedRequest,
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
    provider,
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
  const preparedRequest = JSON.parse(
    row.prepared_request_json
  ) as PreparedWorkoutSummaryJobRequest;
  const provider =
    row.provider ??
    preparedRequest.metadata?.provider ??
    preparedRequest.provider ??
    "workers_ai";
  return {
    jobID: row.job_id,
    installID: row.install_id,
    clientRequestID: decodeLegacyProviderScopedClientRequestID(
      row.client_request_id,
      provider
    ),
    sessionID: row.session_id,
    fingerprint: row.fingerprint,
    status: row.status,
    preparedRequest,
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
    provider,
    promptBytes: nullableNumber(row.prompt_bytes),
    fallbackPromptBytes: nullableNumber(row.fallback_prompt_bytes),
    modelDurationMs: nullableNumber(row.model_duration_ms),
    fallbackModelDurationMs: nullableNumber(row.fallback_model_duration_ms),
    totalJobDurationMs: nullableNumber(row.total_job_duration_ms),
    inferenceMode: row.inference_mode ?? undefined,
    generationStatus: row.generation_status ?? undefined,
  };
}

function parseProfileInsightsJobRow(
  row: ProfileInsightsJobRow
): CoachProfileInsightsJobRecord {
  const preparedRequest = JSON.parse(
    row.prepared_request_json
  ) as PreparedProfileInsightsJobRequest;
  const provider =
    row.provider ??
    preparedRequest.metadata?.provider ??
    preparedRequest.provider ??
    "workers_ai";
  return {
    jobID: row.job_id,
    installID: row.install_id,
    clientRequestID: decodeLegacyProviderScopedClientRequestID(
      row.client_request_id,
      provider
    ),
    status: row.status,
    preparedRequest,
    result: row.response_json
      ? (JSON.parse(row.response_json) as CoachProfileInsightsJobResult)
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
    snapshotBytes: row.snapshot_bytes,
    programCommentChars: row.program_comment_chars,
    recentPrCount: row.recent_pr_count,
    relativeStrengthCount: row.relative_strength_count,
    preferredProgramWorkoutCount: row.preferred_program_workout_count,
    promptVersion: row.prompt_version,
    model: row.model,
    provider,
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

function isMissingProviderColumnError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }

  const message = error.message.toLowerCase();
  return (
    message.includes("no such column: provider") ||
    message.includes("has no column named provider")
  );
}

function encodeLegacyProviderScopedClientRequestID(
  clientRequestID: string,
  provider: CoachAIProvider
): string {
  return `${provider}:${clientRequestID}`;
}

function legacyProviderScopedClientRequestIDCandidates(
  clientRequestID: string,
  provider: CoachAIProvider
): [string, string] {
  return [
    encodeLegacyProviderScopedClientRequestID(clientRequestID, provider),
    clientRequestID,
  ];
}

function decodeLegacyProviderScopedClientRequestID(
  storedClientRequestID: string,
  provider: CoachAIProvider
): string {
  const prefix = `${provider}:`;
  return storedClientRequestID.startsWith(prefix)
    ? storedClientRequestID.slice(prefix.length)
    : storedClientRequestID;
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
    code === "workflow_runtime_interrupted" ||
    code === "workflow_canceled" ||
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
  provider: CoachAIProvider,
  contextHash: string,
  contextProfile: CoachContextProfile,
  contextVersion: string,
  analyticsVersion: string,
  providerID: string,
  promptVersion: string,
  routingVersion: string,
  model: string
): string {
  return `${installID}:insights:${providerID}:${contextHash}:${contextProfile}:${contextVersion}:${analyticsVersion}:${promptVersion}:${routingVersion}:${model}`;
}

function legacyInsightsCacheKey(
  installID: string,
  contextHash: string,
  contextProfile: CoachContextProfile,
  contextVersion: string,
  analyticsVersion: string,
  promptVersion: string,
  model: string
): string {
  return `${installID}:insights:${contextHash}:${contextProfile}:${contextVersion}:${analyticsVersion}:${promptVersion}:${model}`;
}

function degradedInsightsCacheKey(
  installID: string,
  provider: CoachAIProvider,
  contextHash: string,
  contextProfile: CoachContextProfile,
  contextVersion: string,
  analyticsVersion: string,
  providerID: string,
  promptVersion: string,
  routingVersion: string,
  model: string
): string {
  return `${insightsCacheKey(
    installID,
    provider,
    contextHash,
    contextProfile,
    contextVersion,
    analyticsVersion,
    providerID,
    promptVersion,
    routingVersion,
    model
  )}:degraded`;
}

function chatMemoryKey(
  installID: string,
  provider: CoachAIProvider,
  contextHash: string,
  contextProfile: CoachContextProfile,
  contextVersion: string,
  analyticsVersion: string,
  providerID: string,
  promptVersion: string,
  routingVersion: string,
  memoryCompatibilityKey: string,
  memoryProfile: CoachMemoryProfile
): string {
  return `${installID}:chat-memory:${providerID}:${contextHash}:${contextProfile}:${memoryProfile}:${contextVersion}:${analyticsVersion}:${promptVersion}:${routingVersion}:${memoryCompatibilityKey}`;
}

function legacyChatMemoryKey(
  installID: string,
  contextHash: string,
  contextProfile: CoachContextProfile,
  contextVersion: string,
  analyticsVersion: string,
  promptVersion: string,
  model: string,
  memoryProfile: CoachMemoryProfile
): string {
  return `${installID}:chat-memory:${contextHash}:${contextProfile}:${memoryProfile}:${contextVersion}:${analyticsVersion}:${promptVersion}:${model}`;
}

export function storageKeyFromMetadata(
  contextHash: string,
  metadata: Partial<CoachExecutionMetadata> | undefined,
  promptVersion: string,
  model: string
): ContextStorageKeyInput {
  const providerID = metadata?.providerID ?? "workers_ai";
  return {
    contextHash,
    provider: metadata?.provider ?? "workers_ai",
    contextProfile: metadata?.contextProfile ?? "compact_sync_v2",
    contextVersion: metadata?.contextVersion ?? DEFAULT_CONTEXT_VERSION,
    analyticsVersion: metadata?.analyticsVersion ?? DEFAULT_ANALYTICS_VERSION,
    providerID,
    promptVersion,
    model,
    memoryProfile: metadata?.memoryProfile ?? "compact_v1",
    routingVersion: metadata?.routingVersion ?? DEFAULT_MODEL_ROUTING_VERSION,
    memoryCompatibilityKey:
      `${providerID}:` +
      (
      metadata?.memoryCompatibilityKey ??
      metadata?.selectedModel ??
      model
      ),
  };
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
