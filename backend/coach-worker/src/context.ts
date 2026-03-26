import type {
  AppSnapshotPayload,
  CompactCoachSnapshot,
  CoachAnalysisSettingsPayload,
  CoachProfile,
  CoachRuntimeContextDelta,
  ExercisePayload,
  ProfileGoalCompatibilityIssueKind,
  ProfileTrainingSplitIdentifier,
  WorkoutExerciseLogPayload,
  WorkoutExerciseTemplatePayload,
  WorkoutProgramPayload,
  WorkoutSessionPayload,
  WorkoutTemplatePayload,
} from "./schemas";

const RECENT_FINISHED_SESSIONS_LIMIT = 8;
const RECENT_PR_LIMIT = 3;
const THIRTY_DAYS_MS = 30 * 24 * 60 * 60 * 1000;
const CANONICAL_LIFT_NAMES: Record<string, string> = {
  benchPress: "Barbell Bench Press",
  backSquat: "Back Squat",
  deadlift: "Deadlift",
  overheadPress: "Overhead Press",
};

type SupportedLocale = "en" | "ru";

export interface ProgramCommentConstraints {
  rawComment: string;
  rollingSplitExecution: boolean;
  preserveWeeklyFrequency: boolean;
  preserveProgramWorkoutCount: boolean;
  statedWeeklyFrequency?: number;
}

export interface InferencePromptContext {
  localeIdentifier: string;
  profile: CompactCoachSnapshot["profile"];
  userConstraints: ProgramCommentConstraints;
  preferredProgram?: {
    id: string;
    title: string;
    workoutCount: number;
    workouts: Array<{
      id: string;
      title: string;
      focus: string;
      exerciseCount: number;
      exercises: Array<{
        templateExerciseID: string;
        exerciseID: string;
        exerciseName: string;
        setsCount: number;
        reps: number;
        suggestedWeight: number;
        groupKind: string;
      }>;
    }>;
  };
  activeWorkout?: {
    title: string;
    startedAt: string;
    exerciseCount: number;
    completedSetsCount: number;
    totalSetsCount: number;
  };
  analytics: {
    progress30Days: CompactCoachSnapshot["analytics"]["progress30Days"];
    consistency: CompactCoachSnapshot["analytics"]["consistency"] & {
      observedAverageWorkoutsPerWeek?: number;
    };
    recentPersonalRecords: Array<{
      exerciseName: string;
      achievedAt: string;
      weight: number;
      previousWeight: number;
      delta: number;
    }>;
    relativeStrength: CompactCoachSnapshot["analytics"]["relativeStrength"];
  };
  recentFinishedSessions: Array<{
    title: string;
    startedAt: string;
    endedAt?: string;
    durationSeconds?: number;
    completedSetsCount: number;
    totalVolume: number;
    exercises: Array<{
      exerciseName: string;
      groupKind: string;
      completedSetsCount: number;
      bestWeight?: number;
      totalVolume: number;
      averageReps?: number;
    }>;
  }>;
}

const ROTATION_PATTERNS = [
  /\brotate\b/i,
  /\brotating\b/i,
  /\brotation\b/i,
  /\bcycle through\b/i,
  /\bin order\b/i,
  /\bsequentially\b/i,
  /по\s*очеред/i,
  /поочеред/i,
  /по\s*кругу/i,
  /черед/i,
  /ротац/i,
];

const PRESERVE_WEEKLY_FREQUENCY_PATTERNS = [
  /не\s+предлагай.*(?:частот|кол-?во|количество).*(?:трениров|занят).*(?:в\s+недел|\/нед)/i,
  /не\s+меняй.*(?:частот|кол-?во|количество).*(?:трениров|занят).*(?:в\s+недел|\/нед)/i,
  /не\s+предлагай.*изменени.*(?:трениров|занят).*(?:в\s+недел|\/нед)/i,
  /не\s+меняй.*недельн.*частот/i,
  /\bdo not\b.*(?:change|adjust).*(?:training|workout|session).*(?:per\s+week|weekly)/i,
  /\bdon't\b.*(?:change|adjust).*(?:training|workout|session).*(?:per\s+week|weekly)/i,
  /\bdo not\b.*change.*weekly.*frequency/i,
  /\bdon't\b.*change.*weekly.*frequency/i,
];

const PRESERVE_PROGRAM_COUNT_PATTERNS = [
  /не\s+предлагай.*(?:изменени|меняй).*(?:кол-?во|количество).*(?:тренировок|дней).*(?:в\s+програм|сплит)/i,
  /не\s+меняй.*(?:кол-?во|количество).*(?:тренировок|дней).*(?:в\s+програм|сплит)/i,
  /\bdo not\b.*change.*(?:number|count).*(?:workouts|days).*(?:program|split)/i,
  /\bdon't\b.*change.*(?:number|count).*(?:workouts|days).*(?:program|split)/i,
];

const STATED_WEEKLY_FREQUENCY_PATTERNS = [
  /(\d+)\s*(?:раза?|трениров(?:ки|ок)?|занят(?:ия|ий)?)\s*в\s*недел/i,
  /(\d+)\s*(?:days?|sessions?|workouts?)\s*(?:per|a)\s*week/i,
];

interface GoalSummary {
  primaryGoal: CoachProfile["primaryGoal"];
  currentWeight: number;
  targetBodyWeight?: number;
  weeklyWorkoutTarget: number;
  safeWeeklyChangeLowerBound?: number;
  safeWeeklyChangeUpperBound?: number;
  etaWeeksLowerBound?: number;
  etaWeeksUpperBound?: number;
  usesCurrentWeightOnly: boolean;
}

interface TrainingRecommendationSummary {
  currentWeeklyTarget: number;
  recommendedWeeklyTargetLowerBound: number;
  recommendedWeeklyTargetUpperBound: number;
  mainRepLowerBound: number;
  mainRepUpperBound: number;
  accessoryRepLowerBound: number;
  accessoryRepUpperBound: number;
  weeklySetsLowerBound: number;
  weeklySetsUpperBound: number;
  split: ProfileTrainingSplitIdentifier;
  splitWorkoutDays?: number;
  splitProgramTitle?: string;
  isGenericFallback: boolean;
}

interface CompatibilityIssue {
  kind: ProfileGoalCompatibilityIssueKind;
  currentWeeklyTarget?: number;
  recommendedWeeklyTargetLowerBound?: number;
  programWorkoutCount?: number;
  observedWorkoutsPerWeek?: number;
  etaWeeksUpperBound?: number;
}

interface ConsistencySummary {
  workoutsThisWeek: number;
  weeklyTarget: number;
  streakWeeks: number;
  mostFrequentWeekday?: number;
  recentWeeklyActivity: CompactCoachSnapshot["analytics"]["consistency"]["recentWeeklyActivity"];
}

interface PersonalRecord {
  exerciseID: string;
  exerciseName: string;
  achievedAt: string;
  weight: number;
  previousWeight: number;
  delta: number;
}

interface RelativeStrengthLift {
  lift: string;
  bestLoad?: number;
  relativeToBodyWeight?: number;
}

export function normalizeLanguageCode(value?: string): SupportedLocale {
  const normalized = value?.trim().toLowerCase();
  return normalized?.startsWith("ru") ? "ru" : "en";
}

export function normalizeCoachAnalysisSettings(
  settings: CoachAnalysisSettingsPayload | undefined,
  availablePrograms: WorkoutProgramPayload[]
): CoachAnalysisSettingsPayload {
  const normalizedProgramComment = settings?.programComment?.trim() ?? "";
  const limitedProgramComment = normalizedProgramComment.slice(0, 500);
  const selectedProgramID =
    settings?.selectedProgramID &&
    availablePrograms.some((program) => program.id === settings.selectedProgramID)
      ? settings.selectedProgramID
      : undefined;

  return {
    selectedProgramID,
    programComment: limitedProgramComment,
  };
}

export function extractProgramCommentConstraints(
  comment: string | undefined
): ProgramCommentConstraints {
  const rawComment = comment?.trim() ?? "";
  const rollingSplitExecution = ROTATION_PATTERNS.some((pattern) =>
    pattern.test(rawComment)
  );
  const preserveWeeklyFrequency = PRESERVE_WEEKLY_FREQUENCY_PATTERNS.some(
    (pattern) => pattern.test(rawComment)
  );
  const preserveProgramWorkoutCount = PRESERVE_PROGRAM_COUNT_PATTERNS.some(
    (pattern) => pattern.test(rawComment)
  );
  const statedWeeklyFrequency = STATED_WEEKLY_FREQUENCY_PATTERNS.reduce<
    number | undefined
  >((result, pattern) => {
    if (result !== undefined) {
      return result;
    }

    const match = rawComment.match(pattern);
    const parsed = Number(match?.[1]);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
  }, undefined);

  return {
    rawComment,
    rollingSplitExecution,
    preserveWeeklyFrequency,
    preserveProgramWorkoutCount,
    statedWeeklyFrequency,
  };
}

export function buildInferencePromptContext(
  snapshot: CompactCoachSnapshot
): InferencePromptContext {
  const userConstraints = extractProgramCommentConstraints(
    snapshot.coachAnalysisSettings.programComment
  );

  return {
    localeIdentifier: snapshot.localeIdentifier,
    profile: snapshot.profile,
    userConstraints,
    preferredProgram: snapshot.preferredProgram
      ? {
          id: snapshot.preferredProgram.id,
          title: snapshot.preferredProgram.title,
          workoutCount: snapshot.preferredProgram.workoutCount,
          workouts: snapshot.preferredProgram.workouts.map((workout) => ({
            id: workout.id,
            title: workout.title,
            focus: workout.focus,
            exerciseCount: workout.exerciseCount,
            exercises: workout.exercises.map((exercise) => ({
              templateExerciseID: exercise.templateExerciseID,
              exerciseID: exercise.exerciseID,
              exerciseName: exercise.exerciseName,
              setsCount: exercise.setsCount,
              reps: exercise.reps,
              suggestedWeight: exercise.suggestedWeight,
              groupKind: exercise.groupKind,
            })),
          })),
        }
      : undefined,
    activeWorkout: snapshot.activeWorkout
      ? {
          title: snapshot.activeWorkout.title,
          startedAt: snapshot.activeWorkout.startedAt,
          exerciseCount: snapshot.activeWorkout.exerciseCount,
          completedSetsCount: snapshot.activeWorkout.completedSetsCount,
          totalSetsCount: snapshot.activeWorkout.totalSetsCount,
        }
      : undefined,
    analytics: {
      progress30Days: snapshot.analytics.progress30Days,
      consistency: {
        ...snapshot.analytics.consistency,
        observedAverageWorkoutsPerWeek: observedAverageWorkoutsPerWeek(
          snapshot.analytics.consistency
        ),
      },
      recentPersonalRecords: snapshot.analytics.recentPersonalRecords.map((record) => ({
        exerciseName: record.exerciseName,
        achievedAt: record.achievedAt,
        weight: record.weight,
        previousWeight: record.previousWeight,
        delta: record.delta,
      })),
      relativeStrength: snapshot.analytics.relativeStrength,
    },
    recentFinishedSessions: snapshot.recentFinishedSessions.map((session) => ({
      title: session.title,
      startedAt: session.startedAt,
      endedAt: session.endedAt,
      durationSeconds: session.durationSeconds,
      completedSetsCount: session.completedSetsCount,
      totalVolume: session.totalVolume,
      exercises: session.exercises.map((exercise) => ({
        exerciseName: exercise.exerciseName,
        groupKind: exercise.groupKind,
        completedSetsCount: exercise.completedSetsCount,
        bestWeight: exercise.bestWeight,
        totalVolume: exercise.totalVolume,
        averageReps: exercise.averageReps,
      })),
    })),
  };
}

export function overlayCoachAnalysisSettings(
  snapshot: AppSnapshotPayload,
  overrides: {
    selectedProgramID?: string | null;
    programComment?: string | null;
  }
): AppSnapshotPayload {
  const normalizedSettings = normalizeCoachAnalysisSettings(
    {
      selectedProgramID:
        overrides.selectedProgramID === null
          ? undefined
          : overrides.selectedProgramID ?? snapshot.coachAnalysisSettings?.selectedProgramID,
      programComment:
        overrides.programComment === null
          ? ""
          : overrides.programComment ?? snapshot.coachAnalysisSettings?.programComment ?? "",
    },
    snapshot.programs
  );

  return {
    ...snapshot,
    coachAnalysisSettings: normalizedSettings,
  };
}

export async function hashAppSnapshot(
  snapshot: AppSnapshotPayload
): Promise<string> {
  return sha256Hex(stableJSONStringify(snapshot));
}

export async function hashCoachContext(
  context: CompactCoachSnapshot
): Promise<string> {
  return sha256Hex(stableJSONStringify(context));
}

export async function sha256Hex(input: string): Promise<string> {
  const encoder = new TextEncoder();
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(input));
  return Array.from(new Uint8Array(digest))
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}

export function stableJSONStringify(value: unknown): string {
  return JSON.stringify(sortJSONValue(value));
}

export function sortJSONValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sortJSONValue);
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, nested]) => [key, sortJSONValue(nested)])
    );
  }

  return value;
}

export function jsonByteLength(value: unknown): number {
  return new TextEncoder().encode(JSON.stringify(value)).length;
}

export function buildCoachContextFromSnapshot(input: {
  snapshot: AppSnapshotPayload;
  selectedProgramID?: string | null;
  programComment?: string | null;
  runtimeContextDelta?: CoachRuntimeContextDelta;
}): CompactCoachSnapshot {
  const snapshot = overlayCoachAnalysisSettings(input.snapshot, {
    selectedProgramID: input.selectedProgramID,
    programComment: input.programComment,
  });
  const finishedSessions = sortedFinishedSessions(snapshot.history);
  const preferredProgram = resolvePreferredProgram({
    programs: snapshot.programs,
    coachAnalysisSettings: snapshot.coachAnalysisSettings,
    runtimeContextDelta: input.runtimeContextDelta,
    finishedSessions,
  });
  const progressSummary = profileProgressSummary(finishedSessions);
  const goalSummary = profileGoalSummary(snapshot.profile);
  const trainingSummary = profileTrainingRecommendationSummary({
    profile: snapshot.profile,
    preferredProgram,
  });
  const consistencySummary = profileConsistencySummary({
    finishedSessions,
    weeklyWorkoutTarget: snapshot.profile.weeklyWorkoutTarget,
  });
  const compatibilitySummary = profileGoalCompatibilitySummary({
    profile: snapshot.profile,
    goalSummary,
    preferredProgram,
    consistencySummary,
  });
  const personalRecords = recentPersonalRecords({
    exercises: snapshot.exercises,
    finishedSessions,
  });
  const relativeStrength = profileStrengthToBodyweightSummary({
    exercises: snapshot.exercises,
    finishedSessions,
    currentWeight: snapshot.profile.weight,
  });

  return {
    localeIdentifier: normalizeLanguageCode(snapshot.profile.appLanguageCode),
    historyMode: "summary_recent_history",
    profile: snapshot.profile,
    coachAnalysisSettings: snapshot.coachAnalysisSettings,
    preferredProgram: preferredProgram
      ? programToContext(preferredProgram, snapshot.exercises)
      : undefined,
    activeWorkout: input.runtimeContextDelta?.activeWorkout,
    analytics: {
      progress30Days: progressSummary,
      goal: goalSummary,
      training: trainingSummary,
      compatibility: compatibilitySummary,
      consistency: consistencySummary,
      recentPersonalRecords: personalRecords,
      relativeStrength,
    },
    recentFinishedSessions: finishedSessions
      .slice(0, RECENT_FINISHED_SESSIONS_LIMIT)
      .map((session) => recentSessionToContext(session, snapshot.exercises)),
  };
}

function sortedFinishedSessions(
  sessions: WorkoutSessionPayload[]
): WorkoutSessionPayload[] {
  return sessions
    .filter((session) => Boolean(session.endedAt))
    .sort(
      (left, right) =>
        dateValue(right.startedAt) - dateValue(left.startedAt)
    );
}

function resolvePreferredProgram(input: {
  programs: WorkoutProgramPayload[];
  coachAnalysisSettings?: CoachAnalysisSettingsPayload;
  runtimeContextDelta?: CoachRuntimeContextDelta;
  finishedSessions: WorkoutSessionPayload[];
}): WorkoutProgramPayload | undefined {
  const selectedProgramID = input.coachAnalysisSettings?.selectedProgramID;
  if (selectedProgramID) {
    const selectedProgram = input.programs.find(
      (program) => program.id === selectedProgramID
    );
    if (selectedProgram) {
      return selectedProgram;
    }
  }

  const activeWorkoutTemplateID =
    input.runtimeContextDelta?.activeWorkout?.workoutTemplateID;
  if (activeWorkoutTemplateID) {
    const activeProgram = input.programs.find((program) =>
      program.workouts.some((workout) => workout.id === activeWorkoutTemplateID)
    );
    if (activeProgram) {
      return activeProgram;
    }
  }

  for (const session of input.finishedSessions) {
    const program = input.programs.find((candidate) =>
      candidate.workouts.some(
        (workout) => workout.id === session.workoutTemplateID
      )
    );
    if (program) {
      return program;
    }
  }

  return input.programs.find((program) => program.workouts.length > 0);
}

function programToContext(
  program: WorkoutProgramPayload,
  exercises: ExercisePayload[]
): CompactCoachSnapshot["preferredProgram"] {
  return {
    id: program.id,
    title: program.title,
    workoutCount: program.workouts.length,
    workouts: program.workouts.map((workout) =>
      workoutToContext(workout, exercises)
    ),
  };
}

function workoutToContext(
  workout: WorkoutTemplatePayload,
  exercises: ExercisePayload[]
) {
  const plannedExercises: NonNullable<
    CompactCoachSnapshot["preferredProgram"]
  >["workouts"][number]["exercises"] = [];

  for (const templateExercise of workout.exercises) {
    const context = templateExerciseToContext(templateExercise, exercises);
    if (context) {
      plannedExercises.push(context);
    }
  }

  return {
    id: workout.id,
    title: workout.title,
    focus: workout.focus,
    exerciseCount: workout.exercises.length,
    exercises: plannedExercises,
  };
}

function templateExerciseToContext(
  templateExercise: WorkoutExerciseTemplatePayload,
  exercises: ExercisePayload[]
) {
  const exercise = exercises.find(
    (candidate) => candidate.id === templateExercise.exerciseID
  );
  if (!exercise) {
    return undefined;
  }

  return {
    templateExerciseID: templateExercise.id,
    exerciseID: templateExercise.exerciseID,
    exerciseName: exercise.name,
    setsCount: templateExercise.sets.length,
    reps: templateExercise.sets[0]?.reps ?? 0,
    suggestedWeight: templateExercise.sets[0]?.suggestedWeight ?? 0,
    groupKind: templateExercise.groupKind,
  };
}

function recentSessionToContext(
  session: WorkoutSessionPayload,
  exercises: ExercisePayload[]
): CompactCoachSnapshot["recentFinishedSessions"][number] {
  const completedSets = session.exercises
    .flatMap((exercise) => exercise.sets)
    .filter((set) => Boolean(set.completedAt));
  const totalVolume = completedSets.reduce(
    (partialResult, set) => partialResult + set.weight * set.reps,
    0
  );

  return {
    id: session.id,
    workoutTemplateID: session.workoutTemplateID,
    title: session.title,
    startedAt: session.startedAt,
    endedAt: session.endedAt,
    durationSeconds: session.endedAt
      ? Math.max(
          (dateValue(session.endedAt) - dateValue(session.startedAt)) / 1000,
          0
        )
      : undefined,
    completedSetsCount: completedSets.length,
    totalVolume,
    exercises: session.exercises.map((exerciseLog) =>
      recentSessionExerciseToContext(exerciseLog, exercises)
    ),
  };
}

function recentSessionExerciseToContext(
  exerciseLog: WorkoutExerciseLogPayload,
  exercises: ExercisePayload[]
): CompactCoachSnapshot["recentFinishedSessions"][number]["exercises"][number] {
  const completedSets = exerciseLog.sets.filter((set) => Boolean(set.completedAt));
  const totalVolume = completedSets.reduce(
    (partialResult, set) => partialResult + set.weight * set.reps,
    0
  );
  const averageReps =
    completedSets.length > 0
      ? completedSets.reduce((partialResult, set) => partialResult + set.reps, 0) /
        completedSets.length
      : undefined;
  const exerciseName =
    exercises.find((exercise) => exercise.id === exerciseLog.exerciseID)?.name ??
    exerciseLog.exerciseID;

  return {
    templateExerciseID: exerciseLog.templateExerciseID,
    exerciseID: exerciseLog.exerciseID,
    exerciseName,
    groupKind: exerciseLog.groupKind,
    completedSetsCount: completedSets.length,
    bestWeight:
      completedSets.length > 0
        ? Math.max(...completedSets.map((set) => set.weight))
        : undefined,
    totalVolume,
    averageReps,
  };
}

function profileProgressSummary(
  finishedSessions: WorkoutSessionPayload[]
): CompactCoachSnapshot["analytics"]["progress30Days"] {
  const referenceTime = finishedSessions[0]
    ? dateValue(finishedSessionDate(finishedSessions[0]))
    : Date.now();
  const windowStart = referenceTime - THIRTY_DAYS_MS;
  const recentSessions = finishedSessions.filter((session) => {
    const sessionTime = dateValue(finishedSessionDate(session));
    return sessionTime >= windowStart && sessionTime <= referenceTime;
  });
  const recentVolume = recentSessions.reduce((partialResult, session) => {
    return (
      partialResult +
      session.exercises.reduce((sessionVolume, exerciseLog) => {
        return (
          sessionVolume +
          exerciseLog.sets
            .filter((set) => Boolean(set.completedAt))
            .reduce(
              (exerciseVolume, set) => exerciseVolume + set.weight * set.reps,
              0
            )
        );
      }, 0)
    );
  }, 0);
  const recentExercisesCount = recentSessions.reduce((partialResult, session) => {
    return (
      partialResult +
      session.exercises.reduce(
        (sessionCount, exerciseLog) =>
          sessionCount +
          (exerciseLog.sets.some((set) => Boolean(set.completedAt)) ? 1 : 0),
        0
      )
    );
  }, 0);
  const durations = recentSessions
    .filter((session) => Boolean(session.endedAt))
    .map((session) =>
      Math.max(
        (dateValue(session.endedAt as string) - dateValue(session.startedAt)) /
          1000,
        0
      )
    )
    .filter((duration) => duration > 0);

  return {
    totalFinishedWorkouts: finishedSessions.length,
    recentExercisesCount,
    recentVolume,
    averageDurationSeconds:
      durations.length > 0
        ? durations.reduce((partialResult, value) => partialResult + value, 0) /
          durations.length
        : undefined,
    lastWorkoutDate: finishedSessions[0]
      ? finishedSessionDate(finishedSessions[0])
      : undefined,
  };
}

function profileGoalSummary(profile: CoachProfile): GoalSummary {
  const safeWeightChange = profile.targetBodyWeight
    ? safeWeightChangeRange(profile.weight, profile.targetBodyWeight)
    : undefined;
  const etaWeeks =
    profile.targetBodyWeight && safeWeightChange
      ? etaWeeksRange(profile.weight, profile.targetBodyWeight, safeWeightChange)
      : undefined;

  return {
    primaryGoal: profile.primaryGoal,
    currentWeight: profile.weight,
    targetBodyWeight: profile.targetBodyWeight,
    weeklyWorkoutTarget: profile.weeklyWorkoutTarget,
    safeWeeklyChangeLowerBound: safeWeightChange?.lower,
    safeWeeklyChangeUpperBound: safeWeightChange?.upper,
    etaWeeksLowerBound: etaWeeks?.lower,
    etaWeeksUpperBound: etaWeeks?.upper,
    usesCurrentWeightOnly: true,
  };
}

function profileTrainingRecommendationSummary(input: {
  profile: CoachProfile;
  preferredProgram?: WorkoutProgramPayload;
}): TrainingRecommendationSummary {
  const isGenericFallback =
    input.profile.primaryGoal === "not_set" ||
    input.profile.experienceLevel === "not_set";
  const splitWorkoutDays =
    input.preferredProgram && input.preferredProgram.workouts.length > 0
      ? input.preferredProgram.workouts.length
      : undefined;
  const split = splitWorkoutDays
    ? splitRecommendation(splitWorkoutDays)
    : isGenericFallback
      ? "full_body"
      : splitRecommendation(input.profile.weeklyWorkoutTarget);
  const splitProgramTitle = splitWorkoutDays
    ? input.preferredProgram?.title
    : undefined;

  if (isGenericFallback) {
    return {
      currentWeeklyTarget: input.profile.weeklyWorkoutTarget,
      recommendedWeeklyTargetLowerBound: 3,
      recommendedWeeklyTargetUpperBound: 3,
      mainRepLowerBound: 6,
      mainRepUpperBound: 12,
      accessoryRepLowerBound: 6,
      accessoryRepUpperBound: 12,
      weeklySetsLowerBound: 6,
      weeklySetsUpperBound: 10,
      split,
      splitWorkoutDays,
      splitProgramTitle,
      isGenericFallback: true,
    };
  }

  const recommendation = recommendationRanges(
    input.profile.primaryGoal,
    input.profile.experienceLevel
  );

  return {
    currentWeeklyTarget: input.profile.weeklyWorkoutTarget,
    recommendedWeeklyTargetLowerBound: recommendation.frequency.lower,
    recommendedWeeklyTargetUpperBound: recommendation.frequency.upper,
    mainRepLowerBound: recommendation.mainReps.lower,
    mainRepUpperBound: recommendation.mainReps.upper,
    accessoryRepLowerBound: recommendation.accessoryReps.lower,
    accessoryRepUpperBound: recommendation.accessoryReps.upper,
    weeklySetsLowerBound: recommendation.weeklySets.lower,
    weeklySetsUpperBound: recommendation.weeklySets.upper,
    split,
    splitWorkoutDays,
    splitProgramTitle,
    isGenericFallback: false,
  };
}

function profileConsistencySummary(input: {
  finishedSessions: WorkoutSessionPayload[];
  weeklyWorkoutTarget: number;
}): ConsistencySummary {
  const target = Math.max(input.weeklyWorkoutTarget, 1);
  const currentWeek = weekIntervalContaining(Date.now());
  const workoutsThisWeek = finishedSessionsCount(input.finishedSessions, currentWeek);

  let streakWeeks = 0;
  let intervalStart = currentWeek.start;

  while (true) {
    const interval = {
      start: intervalStart,
      end: intervalStart + 7 * 24 * 60 * 60 * 1000,
    };
    if (finishedSessionsCount(input.finishedSessions, interval) >= target) {
      streakWeeks += 1;
      intervalStart -= 7 * 24 * 60 * 60 * 1000;
      continue;
    }
    break;
  }

  const recentWeeklyActivity = Array.from({ length: 4 }, (_, index) => {
    const offset = 3 - index;
    const start = currentWeek.start - offset * 7 * 24 * 60 * 60 * 1000;
    const interval = { start, end: start + 7 * 24 * 60 * 60 * 1000 };
    const workoutsCount = finishedSessionsCount(input.finishedSessions, interval);
    return {
      weekStart: new Date(start).toISOString(),
      workoutsCount,
      meetsTarget: workoutsCount >= target,
    };
  });

  const weekdayWindowStart = currentWeek.start - 7 * 7 * 24 * 60 * 60 * 1000;
  const weekdayCounts = new Map<number, number>();
  for (const session of input.finishedSessions) {
    const sessionTime = dateValue(finishedSessionDate(session));
    if (sessionTime < weekdayWindowStart || sessionTime > currentWeek.end) {
      continue;
    }
    const weekday = weekdayUTC(sessionTime);
    weekdayCounts.set(weekday, (weekdayCounts.get(weekday) ?? 0) + 1);
  }

  const mostFrequentWeekday = Array.from(weekdayCounts.entries()).sort((left, right) => {
    if (left[1] === right[1]) {
      return left[0] - right[0];
    }
    return right[1] - left[1];
  })[0]?.[0];

  return {
    workoutsThisWeek,
    weeklyTarget: target,
    streakWeeks,
    mostFrequentWeekday,
    recentWeeklyActivity,
  };
}

function profileGoalCompatibilitySummary(input: {
  profile: CoachProfile;
  goalSummary: GoalSummary;
  preferredProgram?: WorkoutProgramPayload;
  consistencySummary: ConsistencySummary;
}): CompactCoachSnapshot["analytics"]["compatibility"] {
  const workoutAverage = recentAverageWorkoutsPerWeek(input.consistencySummary);
  const usesObservedHistory = workoutAverage.source === "history";
  const issues: CompatibilityIssue[] = [];

  if (input.profile.targetBodyWeight !== undefined) {
    const targetBodyWeight = input.profile.targetBodyWeight;
    if (
      input.profile.primaryGoal === "fat_loss" &&
      targetBodyWeight >= input.profile.weight
    ) {
      issues.push({ kind: "goal_target_mismatch" });
    } else if (
      (input.profile.primaryGoal === "strength" ||
        input.profile.primaryGoal === "hypertrophy") &&
      targetBodyWeight < input.profile.weight - 1
    ) {
      issues.push({ kind: "goal_target_mismatch" });
    }
  }

  if (
    (input.profile.primaryGoal === "strength" ||
      input.profile.primaryGoal === "hypertrophy") &&
    input.profile.weeklyWorkoutTarget < 3
  ) {
    issues.push({
      kind: "frequency_too_low",
      currentWeeklyTarget: input.profile.weeklyWorkoutTarget,
      recommendedWeeklyTargetLowerBound: 3,
    });
  } else if (
    input.profile.primaryGoal === "fat_loss" &&
    input.profile.weeklyWorkoutTarget < 2
  ) {
    issues.push({
      kind: "frequency_too_low",
      currentWeeklyTarget: input.profile.weeklyWorkoutTarget,
      recommendedWeeklyTargetLowerBound: 2,
    });
  }

  if (
    input.profile.experienceLevel === "beginner" &&
    input.profile.weeklyWorkoutTarget > 5
  ) {
    issues.push({
      kind: "frequency_too_high_for_beginner",
      currentWeeklyTarget: input.profile.weeklyWorkoutTarget,
      recommendedWeeklyTargetLowerBound: 5,
    });
  }

  const programWorkoutCount = input.preferredProgram?.workouts.length;
  if (
    programWorkoutCount &&
    programWorkoutCount > 0 &&
    programWorkoutCount !== input.profile.weeklyWorkoutTarget
  ) {
    issues.push({
      kind: "program_frequency_mismatch",
      currentWeeklyTarget: input.profile.weeklyWorkoutTarget,
      programWorkoutCount,
    });
  }

  if (
    usesObservedHistory &&
    workoutAverage.average <
      Math.max(input.profile.weeklyWorkoutTarget - 1, 0)
  ) {
    issues.push({
      kind: "adherence_gap",
      currentWeeklyTarget: input.profile.weeklyWorkoutTarget,
      observedWorkoutsPerWeek: workoutAverage.average,
    });
  }

  if (
    input.goalSummary.etaWeeksUpperBound !== undefined &&
    input.goalSummary.etaWeeksUpperBound > 24
  ) {
    issues.push({
      kind: "long_goal_timeline",
      etaWeeksUpperBound: input.goalSummary.etaWeeksUpperBound,
    });
  }

  if (input.profile.primaryGoal === "not_set") {
    issues.push({ kind: "missing_goal" });
  }

  const locale = normalizeLanguageCode(input.profile.appLanguageCode);
  return {
    isAligned: issues.length === 0,
    issues: issues.map((issue) => ({
      kind: issue.kind,
      message: compatibilityMessage(locale, issue),
    })),
  };
}

function recentPersonalRecords(input: {
  exercises: ExercisePayload[];
  finishedSessions: WorkoutSessionPayload[];
}): PersonalRecord[] {
  const previousBests = new Map<string, number>();
  const records: PersonalRecord[] = [];
  const ascendingSessions = [...input.finishedSessions].sort(
    (left, right) =>
      dateValue(finishedSessionDate(left)) - dateValue(finishedSessionDate(right))
  );

  for (const session of ascendingSessions) {
    const byExercise = new Map<string, WorkoutExerciseLogPayload[]>();
    for (const exerciseLog of session.exercises) {
      const existing = byExercise.get(exerciseLog.exerciseID) ?? [];
      existing.push(exerciseLog);
      byExercise.set(exerciseLog.exerciseID, existing);
    }

    for (const [exerciseID, exerciseLogs] of byExercise.entries()) {
      const completedSets = exerciseLogs
        .flatMap((exerciseLog) => exerciseLog.sets)
        .filter((set) => Boolean(set.completedAt) && set.weight > 0);
      if (completedSets.length === 0) {
        continue;
      }

      const currentBest = Math.max(...completedSets.map((set) => set.weight));
      const previousBest = previousBests.get(exerciseID) ?? 0;
      if (previousBest > 0 && currentBest > previousBest) {
        const achievedAt =
          completedSets
            .map((set) => set.completedAt)
            .filter((value): value is string => Boolean(value))
            .sort((left, right) => dateValue(right) - dateValue(left))[0] ??
          finishedSessionDate(session);
        records.push({
          exerciseID,
          exerciseName:
            input.exercises.find((exercise) => exercise.id === exerciseID)?.name ??
            exerciseID,
          achievedAt,
          weight: currentBest,
          previousWeight: previousBest,
          delta: currentBest - previousBest,
        });
      }

      previousBests.set(exerciseID, Math.max(previousBest, currentBest));
    }
  }

  return records
    .sort((left, right) => dateValue(right.achievedAt) - dateValue(left.achievedAt))
    .slice(0, RECENT_PR_LIMIT);
}

function profileStrengthToBodyweightSummary(input: {
  exercises: ExercisePayload[];
  finishedSessions: WorkoutSessionPayload[];
  currentWeight: number;
}): RelativeStrengthLift[] {
  const bestLoads = bestCompletedWeightByExercise(
    input.finishedSessions,
    new Set(
      Object.values(CANONICAL_LIFT_NAMES)
        .map(
          (name) =>
            input.exercises.find((exercise) => exercise.name === name)?.id
        )
        .filter((value): value is string => Boolean(value))
    )
  );
  const currentWeight = Math.max(input.currentWeight, 1);

  return Object.entries(CANONICAL_LIFT_NAMES).map(([lift, name]) => {
    const exerciseID = input.exercises.find((exercise) => exercise.name === name)?.id;
    const bestLoad = exerciseID ? bestLoads.get(exerciseID) : undefined;
    return {
      lift,
      bestLoad,
      relativeToBodyWeight:
        bestLoad !== undefined ? bestLoad / currentWeight : undefined,
    };
  });
}

function finishedSessionsCount(
  sessions: WorkoutSessionPayload[],
  interval: { start: number; end: number }
): number {
  return sessions.reduce((partialResult, session) => {
    const sessionTime = dateValue(finishedSessionDate(session));
    return (
      partialResult +
      (sessionTime >= interval.start && sessionTime < interval.end ? 1 : 0)
    );
  }, 0);
}

function weekIntervalContaining(timestampMs: number): { start: number; end: number } {
  const date = new Date(timestampMs);
  const day = date.getUTCDay();
  const isoDay = day === 0 ? 7 : day;
  const start = Date.UTC(
    date.getUTCFullYear(),
    date.getUTCMonth(),
    date.getUTCDate() - (isoDay - 1),
    0,
    0,
    0,
    0
  );
  return {
    start,
    end: start + 7 * 24 * 60 * 60 * 1000,
  };
}

function weekdayUTC(timestampMs: number): number {
  const day = new Date(timestampMs).getUTCDay();
  return day === 0 ? 7 : day;
}

function recentAverageWorkoutsPerWeek(summary: ConsistencySummary): {
  average: number;
  source: "history" | "target";
} {
  const observedWorkouts = summary.recentWeeklyActivity.reduce(
    (partialResult, activity) => partialResult + activity.workoutsCount,
    0
  );
  if (observedWorkouts >= 2) {
    return {
      average:
        observedWorkouts / Math.max(summary.recentWeeklyActivity.length, 1),
      source: "history",
    };
  }

  return {
    average: Math.max(summary.weeklyTarget, 1),
    source: "target",
  };
}

function observedAverageWorkoutsPerWeek(
  summary: CompactCoachSnapshot["analytics"]["consistency"]
): number | undefined {
  if (summary.recentWeeklyActivity.length === 0) {
    return undefined;
  }

  const total = summary.recentWeeklyActivity.reduce(
    (partialResult, item) => partialResult + item.workoutsCount,
    0
  );
  return total / summary.recentWeeklyActivity.length;
}

function compatibilityMessage(
  locale: SupportedLocale,
  issue: CompatibilityIssue
): string {
  switch (issue.kind) {
    case "missing_goal":
      return locale === "ru"
        ? "Цель тренировок не задана, поэтому рекомендации будут слишком общими."
        : "The training goal is not set, so recommendations will stay generic.";
    case "goal_target_mismatch":
      return locale === "ru"
        ? "Целевая масса тела не согласована с выбранной целью."
        : "The target body weight does not align with the selected goal.";
    case "frequency_too_low":
      return locale === "ru"
        ? `Текущая частота ${issue.currentWeeklyTarget ?? 0} тренировок в неделю ниже рекомендуемого минимума ${issue.recommendedWeeklyTargetLowerBound ?? 0}.`
        : `The current frequency of ${issue.currentWeeklyTarget ?? 0} sessions per week is below the recommended minimum of ${issue.recommendedWeeklyTargetLowerBound ?? 0}.`;
    case "frequency_too_high_for_beginner":
      return locale === "ru"
        ? `Для новичка ${issue.currentWeeklyTarget ?? 0} тренировок в неделю выглядит слишком агрессивно.`
        : `${issue.currentWeeklyTarget ?? 0} sessions per week is likely too aggressive for a beginner.`;
    case "program_frequency_mismatch":
      return locale === "ru"
        ? `В программе ${issue.programWorkoutCount ?? 0} тренировочных дней, а недельная цель установлена на ${issue.currentWeeklyTarget ?? 0}.`
        : `The current program has ${issue.programWorkoutCount ?? 0} workout days while the weekly target is ${issue.currentWeeklyTarget ?? 0}.`;
    case "adherence_gap":
      return locale === "ru"
        ? `Фактическая частота около ${formatDecimal(issue.observedWorkoutsPerWeek)} тренировок в неделю, что ниже заданной цели ${issue.currentWeeklyTarget ?? 0}.`
        : `Observed adherence is around ${formatDecimal(issue.observedWorkoutsPerWeek)} sessions per week, below the target of ${issue.currentWeeklyTarget ?? 0}.`;
    case "long_goal_timeline":
      return locale === "ru"
        ? `Текущий прогноз по сроку достижения цели слишком длинный: до ${issue.etaWeeksUpperBound ?? 0} недель.`
        : `The current goal timeline is unusually long at up to ${issue.etaWeeksUpperBound ?? 0} weeks.`;
  }
}

function splitRecommendation(
  weeklyWorkoutTarget: number
): ProfileTrainingSplitIdentifier {
  if (weeklyWorkoutTarget <= 2) {
    return "full_body";
  }
  if (weeklyWorkoutTarget === 3) {
    return "upper_lower_hybrid";
  }
  if (weeklyWorkoutTarget === 4) {
    return "upper_lower";
  }
  if (weeklyWorkoutTarget === 5) {
    return "upper_lower_plus_specialization";
  }
  return "high_frequency_split";
}

function recommendationRanges(
  goal: CoachProfile["primaryGoal"],
  experienceLevel: CoachProfile["experienceLevel"]
): {
  frequency: { lower: number; upper: number };
  mainReps: { lower: number; upper: number };
  accessoryReps: { lower: number; upper: number };
  weeklySets: { lower: number; upper: number };
} {
  switch (`${goal}:${experienceLevel}`) {
    case "strength:beginner":
      return { frequency: { lower: 3, upper: 4 }, mainReps: { lower: 3, upper: 6 }, accessoryReps: { lower: 6, upper: 10 }, weeklySets: { lower: 8, upper: 10 } };
    case "strength:intermediate":
      return { frequency: { lower: 3, upper: 5 }, mainReps: { lower: 3, upper: 6 }, accessoryReps: { lower: 6, upper: 10 }, weeklySets: { lower: 10, upper: 14 } };
    case "strength:advanced":
      return { frequency: { lower: 4, upper: 6 }, mainReps: { lower: 3, upper: 6 }, accessoryReps: { lower: 6, upper: 10 }, weeklySets: { lower: 12, upper: 16 } };
    case "hypertrophy:beginner":
      return { frequency: { lower: 3, upper: 4 }, mainReps: { lower: 6, upper: 10 }, accessoryReps: { lower: 10, upper: 15 }, weeklySets: { lower: 8, upper: 12 } };
    case "hypertrophy:intermediate":
      return { frequency: { lower: 4, upper: 5 }, mainReps: { lower: 6, upper: 10 }, accessoryReps: { lower: 10, upper: 15 }, weeklySets: { lower: 10, upper: 16 } };
    case "hypertrophy:advanced":
      return { frequency: { lower: 5, upper: 6 }, mainReps: { lower: 6, upper: 10 }, accessoryReps: { lower: 10, upper: 15 }, weeklySets: { lower: 12, upper: 20 } };
    case "fat_loss:beginner":
      return { frequency: { lower: 2, upper: 4 }, mainReps: { lower: 5, upper: 8 }, accessoryReps: { lower: 8, upper: 15 }, weeklySets: { lower: 6, upper: 10 } };
    case "fat_loss:intermediate":
      return { frequency: { lower: 3, upper: 4 }, mainReps: { lower: 5, upper: 8 }, accessoryReps: { lower: 8, upper: 15 }, weeklySets: { lower: 8, upper: 12 } };
    case "fat_loss:advanced":
      return { frequency: { lower: 3, upper: 5 }, mainReps: { lower: 5, upper: 8 }, accessoryReps: { lower: 8, upper: 15 }, weeklySets: { lower: 8, upper: 14 } };
    case "general_fitness:beginner":
      return { frequency: { lower: 2, upper: 3 }, mainReps: { lower: 6, upper: 10 }, accessoryReps: { lower: 10, upper: 15 }, weeklySets: { lower: 6, upper: 8 } };
    case "general_fitness:intermediate":
      return { frequency: { lower: 3, upper: 4 }, mainReps: { lower: 6, upper: 10 }, accessoryReps: { lower: 10, upper: 15 }, weeklySets: { lower: 8, upper: 10 } };
    case "general_fitness:advanced":
      return { frequency: { lower: 3, upper: 5 }, mainReps: { lower: 6, upper: 10 }, accessoryReps: { lower: 10, upper: 15 }, weeklySets: { lower: 8, upper: 12 } };
    default:
      return { frequency: { lower: 3, upper: 3 }, mainReps: { lower: 6, upper: 12 }, accessoryReps: { lower: 6, upper: 12 }, weeklySets: { lower: 6, upper: 10 } };
  }
}

function safeWeightChangeRange(
  currentWeight: number,
  targetWeight: number
): { lower: number; upper: number } | undefined {
  if (targetWeight === currentWeight) {
    return undefined;
  }
  if (targetWeight < currentWeight) {
    const lower = Math.max(currentWeight * 0.0025, 0.2);
    const upper = Math.min(Math.max(currentWeight * 0.0075, lower), 0.9);
    return { lower, upper };
  }

  const lower = Math.max(currentWeight * 0.001, 0.1);
  const upper = Math.min(Math.max(currentWeight * 0.0025, lower), 0.25);
  return { lower, upper };
}

function etaWeeksRange(
  currentWeight: number,
  targetWeight: number,
  safeRange: { lower: number; upper: number }
): { lower: number; upper: number } | undefined {
  const delta = Math.abs(targetWeight - currentWeight);
  if (delta <= 0) {
    return undefined;
  }

  return {
    lower: Math.ceil(delta / safeRange.upper),
    upper: Math.ceil(delta / safeRange.lower),
  };
}

function bestCompletedWeightByExercise(
  finishedSessions: WorkoutSessionPayload[],
  exerciseIDs: Set<string>
): Map<string, number> {
  const result = new Map<string, number>();
  for (const session of finishedSessions) {
    for (const exerciseLog of session.exercises) {
      if (!exerciseIDs.has(exerciseLog.exerciseID)) {
        continue;
      }

      const bestLoad = exerciseLog.sets
        .filter((set) => Boolean(set.completedAt) && set.weight > 0)
        .reduce<number | undefined>(
          (partialResult, set) =>
            partialResult === undefined
              ? set.weight
              : Math.max(partialResult, set.weight),
          undefined
        );
      if (bestLoad === undefined) {
        continue;
      }

      result.set(
        exerciseLog.exerciseID,
        Math.max(result.get(exerciseLog.exerciseID) ?? 0, bestLoad)
      );
    }
  }
  return result;
}

function finishedSessionDate(session: WorkoutSessionPayload): string {
  return session.endedAt ?? session.startedAt;
}

function dateValue(value: string): number {
  return new Date(value).getTime();
}

function formatDecimal(value?: number): string {
  if (value === undefined) {
    return "0";
  }

  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}
