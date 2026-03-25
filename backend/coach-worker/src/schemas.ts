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
  })
  .strict();

export const coachContextPayloadSchema = z
  .object({
    localeIdentifier: nonEmptyStringSchema,
    historyMode: nonEmptyStringSchema,
    profile: userProfileSchema,
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
    content: nonEmptyStringSchema.max(1200),
  })
  .strict();

export const profileInsightsRequestSchema = z
  .object({
    locale: nonEmptyStringSchema,
    installID: installIDSchema,
    snapshotHash: snapshotHashSchema,
    snapshot: coachContextPayloadSchema.optional(),
    snapshotUpdatedAt: isoDateTimeSchema.optional(),
    capabilityScope: capabilityScopeSchema,
  })
  .strict();

export const chatRequestSchema = z
  .object({
    locale: nonEmptyStringSchema,
    question: nonEmptyStringSchema,
    installID: installIDSchema,
    snapshotHash: snapshotHashSchema,
    snapshot: coachContextPayloadSchema.optional(),
    snapshotUpdatedAt: isoDateTimeSchema.optional(),
    clientRecentTurns: z.array(coachConversationTurnSchema).max(6).default([]),
    capabilityScope: capabilityScopeSchema,
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

export const stateDeleteRequestSchema = z
  .object({
    installID: installIDSchema,
  })
  .strict();

const suggestedChangeBaseSchema = {
  id: nonEmptyStringSchema.max(200),
  title: nonEmptyStringSchema.max(160),
  summary: nonEmptyStringSchema.max(600),
};

const setWeeklyWorkoutTargetChangeSchema = z
  .object({
    ...suggestedChangeBaseSchema,
    type: z.literal("setWeeklyWorkoutTarget"),
    weeklyWorkoutTarget: z.int().min(1),
  })
  .strict();

const addWorkoutDayChangeSchema = z
  .object({
    ...suggestedChangeBaseSchema,
    type: z.literal("addWorkoutDay"),
    programID: uuidSchema,
    workoutTitle: nonEmptyStringSchema.max(100),
    workoutFocus: z.string().max(100).optional(),
  })
  .strict();

const deleteWorkoutDayChangeSchema = z
  .object({
    ...suggestedChangeBaseSchema,
    type: z.literal("deleteWorkoutDay"),
    programID: uuidSchema,
    workoutID: uuidSchema,
  })
  .strict();

const swapWorkoutExerciseChangeSchema = z
  .object({
    ...suggestedChangeBaseSchema,
    type: z.literal("swapWorkoutExercise"),
    programID: uuidSchema,
    workoutID: uuidSchema,
    templateExerciseID: uuidSchema,
    replacementExerciseID: uuidSchema,
  })
  .strict();

const updateTemplateExercisePrescriptionChangeSchema = z
  .object({
    ...suggestedChangeBaseSchema,
    type: z.literal("updateTemplateExercisePrescription"),
    programID: uuidSchema,
    workoutID: uuidSchema,
    templateExerciseID: uuidSchema,
    reps: z.int().min(1),
    setsCount: z.int().min(1),
    suggestedWeight: z.number().finite().min(0),
  })
  .strict();

export const suggestedChangeSchema = z.discriminatedUnion("type", [
  setWeeklyWorkoutTargetChangeSchema,
  addWorkoutDayChangeSchema,
  deleteWorkoutDayChangeSchema,
  swapWorkoutExerciseChangeSchema,
  updateTemplateExercisePrescriptionChangeSchema,
]);

export const profileInsightsResponseSchema = z
  .object({
    summary: nonEmptyStringSchema.max(1200),
    recommendations: z.array(nonEmptyStringSchema.max(280)).max(8),
    suggestedChanges: z.array(suggestedChangeSchema).max(5),
  })
  .strict();

export const profileInsightsModelOutputSchema = z
  .object({
    summary: nonEmptyStringSchema.max(1200),
    recommendations: z.array(nonEmptyStringSchema.max(280)).max(8),
    suggestedChanges: z.array(z.unknown()).max(5).default([]),
  })
  .strict();

export const chatResponseSchema = z
  .object({
    answerMarkdown: nonEmptyStringSchema.max(6000),
    responseID: nonEmptyStringSchema.max(200),
    followUps: z.array(nonEmptyStringSchema.max(160)).max(4),
    suggestedChanges: z.array(suggestedChangeSchema).max(5),
  })
  .strict();

export const chatResponseModelOutputSchema = z
  .object({
    answerMarkdown: nonEmptyStringSchema.max(6000),
    responseID: nonEmptyStringSchema.max(200).optional(),
    followUps: z.array(nonEmptyStringSchema.max(160)).max(4),
    suggestedChanges: z.array(z.unknown()).max(5).default([]),
  })
  .strict();

export type CoachProfileInsightsRequest = z.infer<
  typeof profileInsightsRequestSchema
>;
export type CoachChatRequest = z.infer<typeof chatRequestSchema>;
export type CoachSnapshotSyncRequest = z.infer<typeof snapshotSyncRequestSchema>;
export type CoachSnapshotSyncResponse = z.infer<
  typeof snapshotSyncResponseSchema
>;
export type CoachStateDeleteRequest = z.infer<typeof stateDeleteRequestSchema>;
export type CoachProfileInsightsResponse = z.infer<
  typeof profileInsightsResponseSchema
>;
export type CoachChatResponse = z.infer<typeof chatResponseSchema>;
export type CompactCoachSnapshot = z.infer<typeof coachContextPayloadSchema>;
export type CoachConversationTurn = z.infer<typeof coachConversationTurnSchema>;
