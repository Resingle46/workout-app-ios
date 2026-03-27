import { z } from "zod";

const uuidSchema = z.uuid();
const isoDateTimeSchema = z.string().refine(
  (value) => !Number.isNaN(Date.parse(value)),
  "Expected ISO-8601 datetime string"
);
const nonEmptyStringSchema = z.string().trim().min(1);
const optionalTrimmedStringSchema = z.string().trim().min(1).optional();
const installIDSchema = z.string().trim().min(1).max(200);
const snapshotHashSchema = z.string().trim().min(1).max(200);
const workoutSummaryGroupKindSchema = z.enum(["regular", "superset"]);
const COACH_CHAT_MARKDOWN_MAX_LENGTH = 6_000;

const userProfileSchema = z
  .object({
    sex: nonEmptyStringSchema,
    age: z.int().min(0),
    weight: z.number().finite(),
    height: z.number().finite(),
    appLanguageCode: optionalTrimmedStringSchema,
    primaryGoal: nonEmptyStringSchema,
    experienceLevel: nonEmptyStringSchema,
    weeklyWorkoutTarget: z.int().min(0),
    targetBodyWeight: z.number().finite().optional(),
  })
  .strict();

const plannedExerciseContextSchema = z
  .object({
    templateExerciseID: uuidSchema,
    exerciseID: uuidSchema,
    exerciseName: nonEmptyStringSchema,
    setsCount: z.int().min(0),
    reps: z.int().min(0),
    suggestedWeight: z.number().finite(),
    groupKind: nonEmptyStringSchema,
  })
  .strict();

const workoutDayContextSchema = z
  .object({
    id: uuidSchema,
    title: nonEmptyStringSchema,
    focus: z.string(),
    exerciseCount: z.int().min(0),
    exercises: z.array(plannedExerciseContextSchema),
  })
  .strict();

const programContextSchema = z
  .object({
    id: uuidSchema,
    title: nonEmptyStringSchema,
    workoutCount: z.int().min(0),
    workouts: z.array(workoutDayContextSchema),
  })
  .strict();

const coachAnalysisSettingsSchema = z
  .object({
    selectedProgramID: uuidSchema.optional(),
    programComment: z.string().max(500),
  })
  .strict();

const activeWorkoutContextSchema = z
  .object({
    workoutTemplateID: uuidSchema,
    title: nonEmptyStringSchema,
    startedAt: isoDateTimeSchema,
    exerciseCount: z.int().min(0),
    completedSetsCount: z.int().min(0),
    totalSetsCount: z.int().min(0),
  })
  .strict();

const progressSnapshotContextSchema = z
  .object({
    totalFinishedWorkouts: z.int().min(0),
    recentExercisesCount: z.int().min(0),
    recentVolume: z.number().finite(),
    averageDurationSeconds: z.number().finite().optional(),
    lastWorkoutDate: isoDateTimeSchema.optional(),
  })
  .strict();

const goalContextSchema = z
  .object({
    primaryGoal: nonEmptyStringSchema,
    currentWeight: z.number().finite(),
    targetBodyWeight: z.number().finite().optional(),
    weeklyWorkoutTarget: z.int().min(0),
    safeWeeklyChangeLowerBound: z.number().finite().optional(),
    safeWeeklyChangeUpperBound: z.number().finite().optional(),
    etaWeeksLowerBound: z.int().min(0).optional(),
    etaWeeksUpperBound: z.int().min(0).optional(),
    usesCurrentWeightOnly: z.boolean(),
  })
  .strict();

const trainingRecommendationContextSchema = z
  .object({
    currentWeeklyTarget: z.int().min(0),
    recommendedWeeklyTargetLowerBound: z.int().min(0),
    recommendedWeeklyTargetUpperBound: z.int().min(0),
    mainRepLowerBound: z.int().min(0),
    mainRepUpperBound: z.int().min(0),
    accessoryRepLowerBound: z.int().min(0),
    accessoryRepUpperBound: z.int().min(0),
    weeklySetsLowerBound: z.int().min(0),
    weeklySetsUpperBound: z.int().min(0),
    split: nonEmptyStringSchema,
    splitWorkoutDays: z.int().min(0).optional(),
    splitProgramTitle: optionalTrimmedStringSchema,
    isGenericFallback: z.boolean(),
  })
  .strict();

const compatibilityIssueContextSchema = z
  .object({
    kind: nonEmptyStringSchema,
    message: nonEmptyStringSchema,
  })
  .strict();

const compatibilityContextSchema = z
  .object({
    isAligned: z.boolean(),
    issues: z.array(compatibilityIssueContextSchema),
  })
  .strict();

const weeklyActivityContextSchema = z
  .object({
    weekStart: isoDateTimeSchema,
    workoutsCount: z.int().min(0),
    meetsTarget: z.boolean(),
  })
  .strict();

const consistencyContextSchema = z
  .object({
    workoutsThisWeek: z.int().min(0),
    weeklyTarget: z.int().min(0),
    streakWeeks: z.int().min(0),
    mostFrequentWeekday: z.int().min(1).max(7).optional(),
    recentWeeklyActivity: z.array(weeklyActivityContextSchema),
  })
  .strict();

const personalRecordContextSchema = z
  .object({
    exerciseID: uuidSchema,
    exerciseName: nonEmptyStringSchema,
    achievedAt: isoDateTimeSchema,
    weight: z.number().finite(),
    previousWeight: z.number().finite(),
    delta: z.number().finite(),
  })
  .strict();

const relativeStrengthContextSchema = z
  .object({
    lift: nonEmptyStringSchema,
    bestLoad: z.number().finite().optional(),
    relativeToBodyWeight: z.number().finite().optional(),
  })
  .strict();

const splitExecutionInterpretationSchema = z
  .object({
    mode: z.enum([
      "rolling_rotation",
      "calendar_matched",
      "program_count_mismatch",
      "unknown",
    ]),
    shouldTreatProgramCountAsMismatch: z.boolean(),
    programWorkoutCount: z.int().min(0).optional(),
    weeklyTarget: z.int().min(0),
    statedWeeklyFrequency: z.int().min(0).optional(),
    explanation: nonEmptyStringSchema,
  })
  .strict();

const muscleExposureContextSchema = z
  .object({
    muscleGroup: nonEmptyStringSchema,
    recentCompletedSets: z.int().min(0),
    recentSessionsHit: z.int().min(0),
    plannedExerciseCount: z.int().min(0),
    lastHitDaysAgo: z.number().finite().min(0).optional(),
  })
  .strict();

const derivedAnalyticsSchema = z
  .object({
    splitExecution: splitExecutionInterpretationSchema,
    adherenceSummary: z
      .object({
        weeklyTarget: z.int().min(0),
        observedAverageWorkoutsPerWeek: z.number().finite().min(0).optional(),
        consistencyGap: z.number().finite().optional(),
      })
      .strict(),
    progressionSummary: z
      .object({
        recentPersonalRecordCount: z.int().min(0),
        topRecentPersonalRecordExercise: nonEmptyStringSchema.optional(),
        lastWorkoutDate: isoDateTimeSchema.optional(),
        completedWorkoutsLast30Days: z.int().min(0),
      })
      .strict(),
    muscleExposure: z.array(muscleExposureContextSchema),
    supportedClaims: z
      .object({
        splitExecution: z.boolean(),
        programFrequency: z.boolean(),
        muscleExposure: z.boolean(),
        laggingCandidates: z.boolean(),
      })
      .strict(),
  })
  .strict();

const recentSessionExerciseContextSchema = z
  .object({
    templateExerciseID: uuidSchema,
    exerciseID: uuidSchema,
    exerciseName: nonEmptyStringSchema,
    groupKind: nonEmptyStringSchema,
    completedSetsCount: z.int().min(0),
    bestWeight: z.number().finite().optional(),
    totalVolume: z.number().finite(),
    averageReps: z.number().finite().optional(),
  })
  .strict();

const recentSessionContextSchema = z
  .object({
    id: uuidSchema,
    workoutTemplateID: uuidSchema,
    title: nonEmptyStringSchema,
    startedAt: isoDateTimeSchema,
    endedAt: isoDateTimeSchema.optional(),
    durationSeconds: z.number().finite().optional(),
    completedSetsCount: z.int().min(0),
    totalVolume: z.number().finite(),
    exercises: z.array(recentSessionExerciseContextSchema),
  })
  .strict();

const analyticsContextSchema = z
  .object({
    progress30Days: progressSnapshotContextSchema,
    goal: goalContextSchema,
    training: trainingRecommendationContextSchema,
    compatibility: compatibilityContextSchema,
    consistency: consistencyContextSchema,
    recentPersonalRecords: z.array(personalRecordContextSchema),
    relativeStrength: z.array(relativeStrengthContextSchema),
    derivedAnalytics: derivedAnalyticsSchema.optional(),
  })
  .strict();

export const coachContextPayloadSchema = z
  .object({
    localeIdentifier: nonEmptyStringSchema,
    historyMode: nonEmptyStringSchema,
    profile: userProfileSchema,
    coachAnalysisSettings: coachAnalysisSettingsSchema,
    preferredProgram: programContextSchema.optional(),
    activeWorkout: activeWorkoutContextSchema.optional(),
    analytics: analyticsContextSchema,
    recentFinishedSessions: z.array(recentSessionContextSchema),
  })
  .strict();

export const capabilityScopeSchema = z.enum(["draft_changes"]);

export const snapshotEnvelopeSchema = z
  .object({
    installID: installIDSchema,
    snapshotHash: snapshotHashSchema,
    snapshot: coachContextPayloadSchema.optional(),
    snapshotUpdatedAt: isoDateTimeSchema.optional(),
  })
  .strict();

const coachConversationTurnSchema = z
  .object({
    role: z.enum(["user", "assistant"]),
    content: nonEmptyStringSchema.max(COACH_CHAT_MARKDOWN_MAX_LENGTH),
  })
  .strict();

export const runtimeContextDeltaSchema = z
  .object({
    activeWorkout: activeWorkoutContextSchema.optional(),
  })
  .strict();

export const profileInsightsRequestSchema = z
  .object({
    locale: nonEmptyStringSchema,
    installID: installIDSchema,
    snapshotHash: snapshotHashSchema.optional(),
    snapshot: coachContextPayloadSchema.optional(),
    snapshotUpdatedAt: isoDateTimeSchema.optional(),
    runtimeContextDelta: runtimeContextDeltaSchema.optional(),
    capabilityScope: capabilityScopeSchema,
    forceRefresh: z.boolean().optional().default(false),
  })
  .strict();

export const chatRequestSchema = z
  .object({
    locale: nonEmptyStringSchema,
    question: nonEmptyStringSchema,
    installID: installIDSchema,
    snapshotHash: snapshotHashSchema.optional(),
    snapshot: coachContextPayloadSchema.optional(),
    snapshotUpdatedAt: isoDateTimeSchema.optional(),
    runtimeContextDelta: runtimeContextDeltaSchema.optional(),
    clientRecentTurns: z.array(coachConversationTurnSchema).max(12).default([]),
    capabilityScope: capabilityScopeSchema,
  })
  .strict();

export const chatJobCreateRequestSchema = chatRequestSchema
  .extend({
    clientRequestID: z.uuid(),
  })
  .strict();

const workoutSummarySetSchema = z
  .object({
    index: z.int().min(0),
    reps: z.int().min(0),
    weight: z.number().finite(),
    isCompleted: z.boolean(),
  })
  .strict();

const workoutSummaryCurrentWorkoutExerciseSchema = z
  .object({
    templateExerciseID: uuidSchema,
    exerciseID: uuidSchema,
    exerciseName: nonEmptyStringSchema,
    groupKind: workoutSummaryGroupKindSchema,
    groupID: uuidSchema.optional(),
    sets: z.array(workoutSummarySetSchema),
    completedSetsCount: z.int().min(0),
    totalSetsCount: z.int().min(0),
    totalVolume: z.number().finite(),
  })
  .strict();

const workoutSummaryCurrentWorkoutSchema = z
  .object({
    workoutTemplateID: uuidSchema,
    title: nonEmptyStringSchema,
    exerciseCount: z.int().min(0),
    completedSetsCount: z.int().min(0),
    totalSetsCount: z.int().min(0),
    totalVolume: z.number().finite(),
    exercises: z.array(workoutSummaryCurrentWorkoutExerciseSchema),
  })
  .strict();

const workoutSummaryHistorySetSchema = z
  .object({
    reps: z.int().min(0),
    weight: z.number().finite(),
  })
  .strict();

const workoutSummaryHistorySessionSchema = z
  .object({
    sessionID: uuidSchema,
    workoutTitle: nonEmptyStringSchema,
    startedAt: isoDateTimeSchema,
    completedSetsCount: z.int().min(0),
    bestWeight: z.number().finite().optional(),
    averageReps: z.number().finite().optional(),
    totalVolume: z.number().finite(),
    completedSets: z.array(workoutSummaryHistorySetSchema),
  })
  .strict();

const workoutSummaryExerciseHistorySchema = z
  .object({
    exerciseID: uuidSchema,
    exerciseName: nonEmptyStringSchema,
    sessions: z.array(workoutSummaryHistorySessionSchema).max(6),
  })
  .strict();

const jobMetadataSchema = z
  .object({
    jobDeadlineAt: isoDateTimeSchema.optional(),
    contextProfile: nonEmptyStringSchema.max(80).optional(),
    promptProfile: nonEmptyStringSchema.max(80).optional(),
    contextVersion: nonEmptyStringSchema.max(80).optional(),
    analyticsVersion: nonEmptyStringSchema.max(80).optional(),
    memoryProfile: nonEmptyStringSchema.max(80).optional(),
  })
  .strict();

export const workoutSummaryRequestModeSchema = z.enum(["prewarm", "final"]);
export const workoutSummaryTriggerSchema = z.enum([
  "prewarm_one_remaining_set",
  "prewarm_all_sets_completed",
  "final_after_finish",
]);
export const workoutSummaryInputModeSchema = z.enum([
  "projected_final",
  "finished_session",
]);

export const workoutSummaryJobCreateRequestSchema = z
  .object({
    locale: nonEmptyStringSchema,
    installID: installIDSchema,
    clientRequestID: z.uuid(),
    sessionID: uuidSchema,
    fingerprint: snapshotHashSchema,
    requestMode: workoutSummaryRequestModeSchema,
    trigger: workoutSummaryTriggerSchema,
    inputMode: workoutSummaryInputModeSchema,
    currentWorkout: workoutSummaryCurrentWorkoutSchema,
    recentExerciseHistory: z.array(workoutSummaryExerciseHistorySchema),
  })
  .strict();

export const snapshotSyncRequestSchema = z
  .object({
    installID: installIDSchema,
    snapshotHash: snapshotHashSchema,
    snapshot: coachContextPayloadSchema,
    snapshotUpdatedAt: isoDateTimeSchema,
  })
  .strict();

export const snapshotSyncResponseSchema = z
  .object({
    acceptedHash: snapshotHashSchema,
    storedAt: isoDateTimeSchema,
  })
  .strict();

const groupKindSchema = z.enum(["regular", "superset"]);
const localStateKindSchema = z.enum(["seed", "user_data"]);
const compressionSchema = z.enum(["gzip", "identity"]);

const exerciseSchema = z
  .object({
    id: uuidSchema,
    name: nonEmptyStringSchema,
    categoryID: uuidSchema,
    equipment: z.string(),
    notes: z.string(),
  })
  .strict();

const workoutSetTemplateSchema = z
  .object({
    id: uuidSchema,
    reps: z.int().min(0),
    suggestedWeight: z.number().finite(),
  })
  .strict();

const workoutExerciseTemplateSchema = z
  .object({
    id: uuidSchema,
    exerciseID: uuidSchema,
    sets: z.array(workoutSetTemplateSchema),
    groupKind: groupKindSchema,
    groupID: uuidSchema.optional(),
  })
  .strict();

const workoutTemplateSchema = z
  .object({
    id: uuidSchema,
    title: nonEmptyStringSchema,
    focus: z.string(),
    exercises: z.array(workoutExerciseTemplateSchema),
  })
  .strict();

const workoutProgramSchema = z
  .object({
    id: uuidSchema,
    title: nonEmptyStringSchema,
    workouts: z.array(workoutTemplateSchema),
  })
  .strict();

const workoutSetLogSchema = z
  .object({
    id: uuidSchema,
    reps: z.int().min(0),
    weight: z.number().finite(),
    completedAt: isoDateTimeSchema.optional(),
  })
  .strict();

const workoutExerciseLogSchema = z
  .object({
    id: uuidSchema,
    templateExerciseID: uuidSchema,
    exerciseID: uuidSchema,
    groupKind: groupKindSchema,
    groupID: uuidSchema.optional(),
    sets: z.array(workoutSetLogSchema),
  })
  .strict();

const workoutSessionSchema = z
  .object({
    id: uuidSchema,
    workoutTemplateID: uuidSchema,
    title: nonEmptyStringSchema,
    startedAt: isoDateTimeSchema,
    endedAt: isoDateTimeSchema.optional(),
    exercises: z.array(workoutExerciseLogSchema),
  })
  .strict();

export const appSnapshotSchema = z
  .object({
    programs: z.array(workoutProgramSchema),
    exercises: z.array(exerciseSchema),
    history: z.array(workoutSessionSchema),
    profile: userProfileSchema,
    coachAnalysisSettings: coachAnalysisSettingsSchema.default({
      programComment: "",
    }),
  })
  .strict();

export const backupHeadSchema = z
  .object({
    installID: installIDSchema,
    backupVersion: z.int().min(1),
    backupHash: snapshotHashSchema,
    r2Key: nonEmptyStringSchema.max(500),
    uploadedAt: isoDateTimeSchema,
    clientSourceModifiedAt: isoDateTimeSchema.optional(),
    selectedProgramID: uuidSchema.optional(),
    programComment: z.string().max(500),
    coachStateVersion: z.int().min(0),
    schemaVersion: z.int().min(1),
    compression: compressionSchema,
    sizeBytes: z.int().min(0),
  })
  .strict();

export const backupEnvelopeV2Schema = z
  .object({
    schemaVersion: z.literal(2),
    installID: installIDSchema,
    backupHash: snapshotHashSchema,
    uploadedAt: isoDateTimeSchema,
    clientSourceModifiedAt: isoDateTimeSchema.optional(),
    appVersion: nonEmptyStringSchema.max(50),
    buildNumber: nonEmptyStringSchema.max(50),
    snapshot: appSnapshotSchema,
  })
  .strict();

export const backupReconcileRequestSchema = z
  .object({
    installID: installIDSchema,
    localBackupHash: snapshotHashSchema.optional(),
    localSourceModifiedAt: isoDateTimeSchema.optional(),
    lastSyncedRemoteVersion: z.int().min(1).optional(),
    lastSyncedBackupHash: snapshotHashSchema.optional(),
    localStateKind: localStateKindSchema,
  })
  .strict();

export const backupReconcileResponseSchema = z
  .object({
    action: z.enum(["upload", "download", "noop", "conflict"]),
    remote: backupHeadSchema.optional(),
  })
  .strict();

export const backupUploadRequestSchema = z
  .object({
    installID: installIDSchema,
    expectedRemoteVersion: z.int().min(1).optional(),
    backupHash: snapshotHashSchema.optional(),
    clientSourceModifiedAt: isoDateTimeSchema.optional(),
    appVersion: nonEmptyStringSchema.max(50),
    buildNumber: nonEmptyStringSchema.max(50),
    snapshot: appSnapshotSchema,
  })
  .strict();

export const backupUploadResponseSchema = backupHeadSchema;

export const backupDownloadResponseSchema = z
  .object({
    remote: backupHeadSchema,
    backup: backupEnvelopeV2Schema,
  })
  .strict();

export const coachPreferencesUpdateRequestSchema = z
  .object({
    installID: installIDSchema,
    selectedProgramID: uuidSchema.optional(),
    programComment: z.string().max(500),
  })
  .strict();

export const coachPreferencesUpdateResponseSchema = z
  .object({
    installID: installIDSchema,
    selectedProgramID: uuidSchema.optional(),
    programComment: z.string().max(500),
    coachStateVersion: z.int().min(0),
    updatedAt: isoDateTimeSchema,
  })
  .strict();

export const stateDeleteRequestSchema = z
  .object({
    installID: installIDSchema,
  })
  .strict();

export const coachResponseGenerationStatusSchema = z.enum(["model", "fallback"]);
export const profileInsightSourceSchema = z.enum([
  "fresh_model",
  "cached_model",
  "fallback",
]);

export const profileInsightsResponseSchema = z
  .object({
    summary: nonEmptyStringSchema.max(1200),
    recommendations: z.array(nonEmptyStringSchema.max(280)).max(8),
    generationStatus: coachResponseGenerationStatusSchema.default("fallback"),
    insightSource: profileInsightSourceSchema.default("fallback"),
  })
  .strict();

export const profileInsightsModelOutputSchema = z
  .object({
    summary: nonEmptyStringSchema.max(1200),
    recommendations: z.array(nonEmptyStringSchema.max(280)).max(8),
    suggestedChanges: z.array(z.unknown()).max(5).optional(),
  })
  .strict();

export const chatResponseSchema = z
  .object({
    answerMarkdown: nonEmptyStringSchema.max(COACH_CHAT_MARKDOWN_MAX_LENGTH),
    responseID: nonEmptyStringSchema.max(200),
    followUps: z.array(nonEmptyStringSchema.max(160)).max(4),
    generationStatus: coachResponseGenerationStatusSchema.default("fallback"),
  })
  .strict();

export const chatJobStatusSchema = z.enum([
  "queued",
  "running",
  "completed",
  "failed",
  "canceled",
]);

export const chatInferenceModeSchema = z.enum([
  "structured",
  "plain_text_fallback",
  "degraded_fallback",
]);

export const chatJobResultSchema = z
  .object({
    answerMarkdown: nonEmptyStringSchema.max(COACH_CHAT_MARKDOWN_MAX_LENGTH),
    responseID: nonEmptyStringSchema.max(200),
    followUps: z.array(nonEmptyStringSchema.max(160)).max(4),
    generationStatus: coachResponseGenerationStatusSchema.default("fallback"),
    inferenceMode: chatInferenceModeSchema,
    modelDurationMs: z.int().min(0).optional(),
    totalJobDurationMs: z.int().min(0).optional(),
  })
  .strict();

export const chatJobErrorSchema = z
  .object({
    code: nonEmptyStringSchema.max(200),
    message: nonEmptyStringSchema.max(500),
    retryable: z.boolean(),
  })
  .strict();

export const chatJobCreateResponseSchema = z
  .object({
    jobID: nonEmptyStringSchema.max(200),
    status: chatJobStatusSchema,
    createdAt: isoDateTimeSchema,
    pollAfterMs: z.int().min(0),
    metadata: jobMetadataSchema.optional(),
  })
  .strict();

export const chatJobStatusResponseSchema = z
  .object({
    jobID: nonEmptyStringSchema.max(200),
    status: chatJobStatusSchema,
    createdAt: isoDateTimeSchema,
    startedAt: isoDateTimeSchema.optional(),
    completedAt: isoDateTimeSchema.optional(),
    result: chatJobResultSchema.optional(),
    error: chatJobErrorSchema.optional(),
    metadata: jobMetadataSchema.optional(),
  })
  .strict();

export const workoutSummaryResponseSchema = z
  .object({
    headline: nonEmptyStringSchema.max(160),
    summary: nonEmptyStringSchema.max(900),
    highlights: z.array(nonEmptyStringSchema.max(240)).min(1).max(4),
    nextWorkoutFocus: z.array(nonEmptyStringSchema.max(220)).max(3),
    generationStatus: coachResponseGenerationStatusSchema.default("fallback"),
  })
  .strict();

export const workoutSummaryModelOutputSchema = z
  .object({
    headline: nonEmptyStringSchema.max(160),
    summary: nonEmptyStringSchema.max(900),
    highlights: z.array(nonEmptyStringSchema.max(240)).min(1).max(4),
    nextWorkoutFocus: z.array(nonEmptyStringSchema.max(220)).max(3),
    suggestedChanges: z.array(z.unknown()).max(5).optional(),
  })
  .strict();

export const workoutSummaryJobResultSchema = z
  .object({
    headline: nonEmptyStringSchema.max(160),
    summary: nonEmptyStringSchema.max(900),
    highlights: z.array(nonEmptyStringSchema.max(240)).min(1).max(4),
    nextWorkoutFocus: z.array(nonEmptyStringSchema.max(220)).max(3),
    generationStatus: coachResponseGenerationStatusSchema.default("fallback"),
    inferenceMode: chatInferenceModeSchema,
    modelDurationMs: z.int().min(0).optional(),
    totalJobDurationMs: z.int().min(0).optional(),
  })
  .strict();

export const workoutSummaryJobCreateResponseSchema = z
  .object({
    jobID: nonEmptyStringSchema.max(200),
    sessionID: uuidSchema,
    fingerprint: snapshotHashSchema,
    status: chatJobStatusSchema,
    createdAt: isoDateTimeSchema,
    pollAfterMs: z.int().min(0),
    reusedExistingJob: z.boolean(),
    metadata: jobMetadataSchema.optional(),
  })
  .strict();

export const workoutSummaryJobStatusResponseSchema = z
  .object({
    jobID: nonEmptyStringSchema.max(200),
    sessionID: uuidSchema,
    fingerprint: snapshotHashSchema,
    status: chatJobStatusSchema,
    createdAt: isoDateTimeSchema,
    startedAt: isoDateTimeSchema.optional(),
    completedAt: isoDateTimeSchema.optional(),
    result: workoutSummaryJobResultSchema.optional(),
    error: chatJobErrorSchema.optional(),
    metadata: jobMetadataSchema.optional(),
  })
  .strict();

export const chatResponseModelOutputSchema = z
  .object({
    answerMarkdown: nonEmptyStringSchema.max(COACH_CHAT_MARKDOWN_MAX_LENGTH),
    responseID: nonEmptyStringSchema.max(200).optional(),
    followUps: z.array(nonEmptyStringSchema.max(160)).max(4),
    suggestedChanges: z.array(z.unknown()).max(5).optional(),
  })
  .strict();

export type CoachProfileInsightsRequest = z.infer<
  typeof profileInsightsRequestSchema
>;
export type CoachChatRequest = z.infer<typeof chatRequestSchema>;
export type CoachChatJobCreateRequest = z.infer<typeof chatJobCreateRequestSchema>;
export type CoachSnapshotSyncRequest = z.infer<typeof snapshotSyncRequestSchema>;
export type CoachSnapshotSyncResponse = z.infer<
  typeof snapshotSyncResponseSchema
>;
export type BackupReconcileRequest = z.infer<
  typeof backupReconcileRequestSchema
>;
export type BackupReconcileResponse = z.infer<
  typeof backupReconcileResponseSchema
>;
export type BackupUploadRequest = z.infer<typeof backupUploadRequestSchema>;
export type BackupUploadResponse = z.infer<typeof backupUploadResponseSchema>;
export type BackupDownloadResponse = z.infer<
  typeof backupDownloadResponseSchema
>;
export type BackupEnvelopeV2 = z.infer<typeof backupEnvelopeV2Schema>;
export type BackupHead = z.infer<typeof backupHeadSchema>;
export type CoachPreferencesUpdateRequest = z.infer<
  typeof coachPreferencesUpdateRequestSchema
>;
export type CoachPreferencesUpdateResponse = z.infer<
  typeof coachPreferencesUpdateResponseSchema
>;
export type CoachStateDeleteRequest = z.infer<typeof stateDeleteRequestSchema>;
export type CoachProfileInsightsResponse = z.infer<
  typeof profileInsightsResponseSchema
>;
export type CoachChatResponse = z.infer<typeof chatResponseSchema>;
export type CoachChatJobStatus = z.infer<typeof chatJobStatusSchema>;
export type CoachChatInferenceMode = z.infer<typeof chatInferenceModeSchema>;
export type CoachChatJobResult = z.infer<typeof chatJobResultSchema>;
export type CoachChatJobError = z.infer<typeof chatJobErrorSchema>;
export type CoachChatJobCreateResponse = z.infer<
  typeof chatJobCreateResponseSchema
>;
export type CoachChatJobStatusResponse = z.infer<
  typeof chatJobStatusResponseSchema
>;
export type CoachWorkoutSummaryRequestMode = z.infer<
  typeof workoutSummaryRequestModeSchema
>;
export type CoachWorkoutSummaryTrigger = z.infer<
  typeof workoutSummaryTriggerSchema
>;
export type CoachWorkoutSummaryInputMode = z.infer<
  typeof workoutSummaryInputModeSchema
>;
export type CoachWorkoutSummaryJobCreateRequest = z.infer<
  typeof workoutSummaryJobCreateRequestSchema
>;
export type CoachWorkoutSummaryResponse = z.infer<
  typeof workoutSummaryResponseSchema
>;
export type CoachWorkoutSummaryJobResult = z.infer<
  typeof workoutSummaryJobResultSchema
>;
export type CoachWorkoutSummaryJobCreateResponse = z.infer<
  typeof workoutSummaryJobCreateResponseSchema
>;
export type CoachWorkoutSummaryJobStatusResponse = z.infer<
  typeof workoutSummaryJobStatusResponseSchema
>;
export type CompactCoachSnapshot = z.infer<typeof coachContextPayloadSchema>;
export type CoachConversationTurn = z.infer<typeof coachConversationTurnSchema>;
export type CoachRuntimeContextDelta = z.infer<typeof runtimeContextDeltaSchema>;
export type CoachProfile = z.infer<typeof userProfileSchema>;
export type CoachAnalysisSettingsPayload = z.infer<
  typeof coachAnalysisSettingsSchema
>;
export type AppSnapshotPayload = z.infer<typeof appSnapshotSchema>;
export type ExercisePayload = z.infer<typeof exerciseSchema>;
export type WorkoutProgramPayload = z.infer<typeof workoutProgramSchema>;
export type WorkoutTemplatePayload = z.infer<typeof workoutTemplateSchema>;
export type WorkoutExerciseTemplatePayload = z.infer<
  typeof workoutExerciseTemplateSchema
>;
export type WorkoutSessionPayload = z.infer<typeof workoutSessionSchema>;
export type WorkoutExerciseLogPayload = z.infer<
  typeof workoutExerciseLogSchema
>;
export type ProfileTrainingSplitIdentifier =
  | "full_body"
  | "upper_lower_hybrid"
  | "upper_lower"
  | "upper_lower_plus_specialization"
  | "high_frequency_split";
export type ProfileGoalCompatibilityIssueKind =
  | "missing_goal"
  | "goal_target_mismatch"
  | "frequency_too_low"
  | "frequency_too_high_for_beginner"
  | "program_frequency_mismatch"
  | "adherence_gap"
  | "long_goal_timeline";
