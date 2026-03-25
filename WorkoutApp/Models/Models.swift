import Foundation

enum RootTab: CaseIterable, Hashable, Sendable {
    case programs
    case workout
    case statistics
    case profile
}

struct ExerciseCategory: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var nameKey: String
    var symbol: String

    init(id: UUID = UUID(), nameKey: String, symbol: String) {
        self.id = id
        self.nameKey = nameKey
        self.symbol = symbol
    }
}

struct Exercise: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var categoryID: UUID
    var equipment: String
    var notes: String

    init(id: UUID = UUID(), name: String, categoryID: UUID, equipment: String = "", notes: String = "") {
        self.id = id
        self.name = name
        self.categoryID = categoryID
        self.equipment = equipment
        self.notes = notes
    }
}

struct WorkoutSetTemplate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var reps: Int
    var suggestedWeight: Double

    init(id: UUID = UUID(), reps: Int, suggestedWeight: Double = 0) {
        self.id = id
        self.reps = reps
        self.suggestedWeight = suggestedWeight
    }
}

struct WorkoutExerciseTemplate: Identifiable, Codable, Hashable, Sendable {
    enum GroupKind: String, Codable, CaseIterable, Hashable, Sendable {
        case regular
        case superset
    }

    let id: UUID
    var exerciseID: UUID
    var sets: [WorkoutSetTemplate]
    var groupKind: GroupKind
    var groupID: UUID?

    init(id: UUID = UUID(), exerciseID: UUID, sets: [WorkoutSetTemplate], groupKind: GroupKind = .regular, groupID: UUID? = nil) {
        self.id = id
        self.exerciseID = exerciseID
        self.sets = sets
        self.groupKind = groupKind
        self.groupID = groupID
    }
}

struct WorkoutTemplate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var focus: String
    var exercises: [WorkoutExerciseTemplate]

    init(id: UUID = UUID(), title: String, focus: String, exercises: [WorkoutExerciseTemplate]) {
        self.id = id
        self.title = title
        self.focus = focus
        self.exercises = exercises
    }
}

struct WorkoutProgram: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var workouts: [WorkoutTemplate]

    init(id: UUID = UUID(), title: String, workouts: [WorkoutTemplate]) {
        self.id = id
        self.title = title
        self.workouts = workouts
    }
}

struct WorkoutSetLog: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var reps: Int
    var weight: Double
    var completedAt: Date?

    init(id: UUID = UUID(), reps: Int, weight: Double = 0, completedAt: Date? = nil) {
        self.id = id
        self.reps = reps
        self.weight = weight
        self.completedAt = completedAt
    }
}

struct WorkoutExerciseLog: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var templateExerciseID: UUID
    var exerciseID: UUID
    var groupKind: WorkoutExerciseTemplate.GroupKind
    var groupID: UUID?
    var sets: [WorkoutSetLog]

    init(id: UUID = UUID(), templateExerciseID: UUID, exerciseID: UUID, groupKind: WorkoutExerciseTemplate.GroupKind, groupID: UUID?, sets: [WorkoutSetLog]) {
        self.id = id
        self.templateExerciseID = templateExerciseID
        self.exerciseID = exerciseID
        self.groupKind = groupKind
        self.groupID = groupID
        self.sets = sets
    }
}

struct WorkoutExerciseDraft: Hashable, Sendable {
    var exerciseID: UUID
    var reps: Int
    var setsCount: Int
    var suggestedWeight: Double
    var groupKind: WorkoutExerciseTemplate.GroupKind
    var groupID: UUID?
}

struct WorkoutSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workoutTemplateID: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var exercises: [WorkoutExerciseLog]

    init(id: UUID = UUID(), workoutTemplateID: UUID, title: String, startedAt: Date = .now, endedAt: Date? = nil, exercises: [WorkoutExerciseLog]) {
        self.id = id
        self.workoutTemplateID = workoutTemplateID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exercises = exercises
    }

    var isFinished: Bool { endedAt != nil }
}

struct RecentWorkoutExerciseSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var exerciseID: UUID
    var exerciseName: String
    var performedAt: Date
    var sets: [WorkoutSetLog]
}

struct WeeklyStrengthSummary: Hashable, Sendable {
    var percentChange: Int
    var currentVolume: Double
    var previousVolume: Double

    var isPositive: Bool {
        percentChange > 0
    }
}

struct ExerciseSessionAverage: Identifiable, Hashable, Sendable {
    let id: UUID
    var date: Date
    var averageWeight: Double
    var averageReps: Double
    var setsCount: Int
}

enum TrainingGoal: String, Codable, CaseIterable, Hashable, Sendable {
    case notSet = "not_set"
    case strength
    case hypertrophy
    case fatLoss = "fat_loss"
    case generalFitness = "general_fitness"
}

enum ExperienceLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case notSet = "not_set"
    case beginner
    case intermediate
    case advanced
}

struct ProfileProgressSummary: Hashable, Sendable {
    var totalFinishedWorkouts: Int
    var recentExercisesCount: Int
    var recentVolume: Double
    var averageDuration: TimeInterval?
    var lastWorkoutDate: Date?
}

struct ProfilePRItem: Identifiable, Hashable, Sendable {
    let id: String
    var exerciseID: UUID
    var exerciseName: String
    var achievedAt: Date
    var weight: Double
    var previousWeight: Double

    var delta: Double {
        weight - previousWeight
    }
}

struct ProfileWeeklyActivity: Hashable, Sendable {
    var weekStart: Date
    var workoutsCount: Int
    var meetsTarget: Bool
}

struct ProfileConsistencySummary: Hashable, Sendable {
    var workoutsThisWeek: Int
    var weeklyTarget: Int
    var streakWeeks: Int
    var recentWeeklyActivity: [ProfileWeeklyActivity]
    var mostFrequentWeekday: Int?
}

enum ProfileGoalDirection: Hashable, Sendable {
    case lose
    case gain
    case maintain
}

struct ProfileGoalSummary: Hashable, Sendable {
    var primaryGoal: TrainingGoal
    var currentWeight: Double
    var targetBodyWeight: Double?
    var weeklyWorkoutTarget: Int
    var safeWeeklyChangeLowerBound: Double?
    var safeWeeklyChangeUpperBound: Double?
    var etaWeeksLowerBound: Int?
    var etaWeeksUpperBound: Int?
    var usesCurrentWeightOnly: Bool

    var remainingWeightDelta: Double? {
        targetBodyWeight.map { $0 - currentWeight }
    }

    var direction: ProfileGoalDirection? {
        guard let delta = remainingWeightDelta else {
            return nil
        }

        if delta < 0 {
            return .lose
        }
        if delta > 0 {
            return .gain
        }
        return .maintain
    }

    var hasReachedTarget: Bool {
        remainingWeightDelta == 0
    }
}

enum MetabolismEstimateSource: Hashable, Sendable {
    case history
    case target
}

struct ProfileMetabolismSummary: Hashable, Sendable {
    var bmr: Int
    var maintenanceCaloriesLowerBound: Int
    var maintenanceCaloriesUpperBound: Int
    var activityFactorLowerBound: Double
    var activityFactorUpperBound: Double
    var averageWorkoutsPerWeek: Double
    var estimateSource: MetabolismEstimateSource
}

enum ProfileTrainingSplitRecommendation: Hashable, Sendable {
    case fullBody
    case upperLowerHybrid
    case upperLower
    case upperLowerPlusSpecialization
    case highFrequencySplit
}

struct ProfileTrainingRecommendationSummary: Hashable, Sendable {
    var primaryGoal: TrainingGoal
    var experienceLevel: ExperienceLevel
    var currentWeeklyTarget: Int
    var recommendedWeeklyTargetLowerBound: Int
    var recommendedWeeklyTargetUpperBound: Int
    var mainRepLowerBound: Int
    var mainRepUpperBound: Int
    var accessoryRepLowerBound: Int
    var accessoryRepUpperBound: Int
    var weeklySetsLowerBound: Int
    var weeklySetsUpperBound: Int
    var split: ProfileTrainingSplitRecommendation
    var splitWorkoutDays: Int? = nil
    var splitProgramTitle: String? = nil
    var isGenericFallback: Bool
}

enum ProfileGoalCompatibilityIssueKind: String, Hashable, Sendable {
    case missingGoal
    case goalTargetMismatch
    case frequencyTooLow
    case frequencyTooHighForBeginner
    case programFrequencyMismatch
    case adherenceGap
    case longGoalTimeline
}

struct ProfileGoalCompatibilityIssue: Identifiable, Hashable, Sendable {
    let id: String
    var kind: ProfileGoalCompatibilityIssueKind
    var currentWeeklyTarget: Int?
    var recommendedWeeklyTargetLowerBound: Int?
    var programWorkoutCount: Int? = nil
    var observedWorkoutsPerWeek: Double?
    var etaWeeksUpperBound: Int?
    var systemImage: String
}

struct ProfileGoalCompatibilitySummary: Hashable, Sendable {
    var primaryGoal: TrainingGoal
    var currentWeight: Double
    var targetBodyWeight: Double?
    var weeklyWorkoutTarget: Int
    var averageWorkoutsPerWeek: Double?
    var usesObservedHistory: Bool
    var issues: [ProfileGoalCompatibilityIssue]

    var isAligned: Bool {
        issues.isEmpty
    }
}

enum CanonicalStrengthLift: String, CaseIterable, Hashable, Sendable {
    case benchPress
    case backSquat
    case deadlift
    case overheadPress
}

struct ProfileRelativeStrengthLift: Identifiable, Hashable, Sendable {
    var lift: CanonicalStrengthLift
    var bestLoad: Double?
    var relativeToBodyWeight: Double?

    var id: CanonicalStrengthLift {
        lift
    }
}

struct ProfileStrengthToBodyweightSummary: Hashable, Sendable {
    var currentWeight: Double
    var lifts: [ProfileRelativeStrengthLift]
}

struct UserProfile: Codable, Hashable, Sendable {
    var sex: String
    var age: Int
    var weight: Double
    var height: Double
    var appLanguageCode: String?
    var primaryGoal: TrainingGoal = .notSet
    var experienceLevel: ExperienceLevel = .notSet
    var weeklyWorkoutTarget: Int = 3
    var targetBodyWeight: Double? = nil

    static let empty = UserProfile(
        sex: "M",
        age: 25,
        weight: 70,
        height: 175,
        appLanguageCode: nil,
        primaryGoal: .notSet,
        experienceLevel: .notSet,
        weeklyWorkoutTarget: 3,
        targetBodyWeight: nil
    )
}

extension TrainingGoal {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .notSet
    }
}

extension ExperienceLevel {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .notSet
    }
}

extension UserProfile {
    private enum CodingKeys: String, CodingKey {
        case sex
        case age
        case weight
        case height
        case appLanguageCode
        case primaryGoal
        case experienceLevel
        case weeklyWorkoutTarget
        case targetBodyWeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        sex = try container.decodeIfPresent(String.self, forKey: .sex) ?? "M"
        age = try container.decodeIfPresent(Int.self, forKey: .age) ?? 25
        weight = try container.decodeIfPresent(Double.self, forKey: .weight) ?? 70
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 175
        appLanguageCode = try container.decodeIfPresent(String.self, forKey: .appLanguageCode)
        primaryGoal = try container.decodeIfPresent(TrainingGoal.self, forKey: .primaryGoal) ?? .notSet
        experienceLevel = try container.decodeIfPresent(ExperienceLevel.self, forKey: .experienceLevel) ?? .notSet
        weeklyWorkoutTarget = try container.decodeIfPresent(Int.self, forKey: .weeklyWorkoutTarget) ?? 3
        targetBodyWeight = try container.decodeIfPresent(Double.self, forKey: .targetBodyWeight)
    }
}

extension Exercise {
    var localizedName: String {
        guard let localizationKey = Self.seedLocalizationKeys[name] else { return name }
        return Bundle.main.localizedString(forKey: localizationKey, value: name, table: nil)
    }

    var localizedEquipment: String {
        let trimmed = equipment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let parts = trimmed
            .components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let localizedParts = parts.map { part -> String in
            guard let localizationKey = Self.equipmentLocalizationKeys[part] else { return part }
            return Bundle.main.localizedString(forKey: localizationKey, value: part, table: nil)
        }

        return localizedParts.joined(separator: " / ")
    }

    var searchableTexts: [String] {
        Array(Set([name, localizedName, equipment, localizedEquipment].filter { !$0.isEmpty }))
    }

    private static let seedLocalizationKeys: [String: String] = [
        "Barbell Bench Press": "exercise.seed.barbell_bench_press",
        "Incline Dumbbell Press": "exercise.seed.incline_dumbbell_press",
        "Chest Fly": "exercise.seed.chest_fly",
        "Push-Up": "exercise.seed.push_up",
        "Pull-Up": "exercise.seed.pull_up",
        "Lat Pulldown": "exercise.seed.lat_pulldown",
        "Barbell Row": "exercise.seed.barbell_row",
        "Seated Cable Row": "exercise.seed.seated_cable_row",
        "Back Squat": "exercise.seed.back_squat",
        "Romanian Deadlift": "exercise.seed.romanian_deadlift",
        "Leg Press": "exercise.seed.leg_press",
        "Walking Lunges": "exercise.seed.walking_lunges",
        "Overhead Press": "exercise.seed.overhead_press",
        "Lateral Raise": "exercise.seed.lateral_raise",
        "Rear Delt Fly": "exercise.seed.rear_delt_fly",
        "Arnold Press": "exercise.seed.arnold_press",
        "Barbell Curl": "exercise.seed.barbell_curl",
        "Hammer Curl": "exercise.seed.hammer_curl",
        "Triceps Pushdown": "exercise.seed.triceps_pushdown",
        "Skull Crusher": "exercise.seed.skull_crusher",
        "Plank": "exercise.seed.plank",
        "Cable Crunch": "exercise.seed.cable_crunch",
        "Hanging Leg Raise": "exercise.seed.hanging_leg_raise",
        "Russian Twist": "exercise.seed.russian_twist",
        "Incline Bench Press": "exercise.seed.incline_bench_press",
        "Decline Bench Press": "exercise.seed.decline_bench_press",
        "Chest Dip": "exercise.seed.chest_dip",
        "Machine Chest Press": "exercise.seed.machine_chest_press",
        "Pec Deck Fly": "exercise.seed.pec_deck_fly",
        "Dumbbell Bench Press": "exercise.seed.dumbbell_bench_press",
        "Chin-Up": "exercise.seed.chin_up",
        "One Arm Dumbbell Row": "exercise.seed.one_arm_dumbbell_row",
        "Face Pull": "exercise.seed.cable_face_pull",
        "Cable Face Pull": "exercise.seed.cable_face_pull",
        "Straight Arm Pulldown": "exercise.seed.straight_arm_pulldown",
        "Deadlift": "exercise.seed.deadlift",
        "Bent Over Shrug": "exercise.seed.bent_over_shrug",
        "Front Squat": "exercise.seed.front_squat",
        "Bulgarian Split Squat": "exercise.seed.bulgarian_split_squat",
        "Leg Extension": "exercise.seed.leg_extension",
        "Seated Leg Curl": "exercise.seed.seated_leg_curl",
        "Standing Calf Raise": "exercise.seed.standing_calf_raise",
        "Hip Thrust": "exercise.seed.hip_thrust",
        "Step-Up": "exercise.seed.step_up",
        "Seated Dumbbell Press": "exercise.seed.seated_dumbbell_press",
        "Front Raise": "exercise.seed.front_raise",
        "Upright Row": "exercise.seed.upright_row",
        "Reverse Pec Deck": "exercise.seed.reverse_pec_deck",
        "Push Press": "exercise.seed.push_press",
        "Cable Lateral Raise": "exercise.seed.cable_lateral_raise",
        "Incline Dumbbell Curl": "exercise.seed.incline_dumbbell_curl",
        "Preacher Curl": "exercise.seed.preacher_curl",
        "Concentration Curl": "exercise.seed.concentration_curl",
        "Close Grip Bench Press": "exercise.seed.close_grip_bench_press",
        "Overhead Dumbbell Triceps Extension": "exercise.seed.overhead_dumbbell_triceps_extension",
        "Bench Dip": "exercise.seed.bench_dip",
        "Cable Curl": "exercise.seed.cable_curl",
        "Crunch": "exercise.seed.crunch",
        "Hanging Knee Raise": "exercise.seed.hanging_knee_raise",
        "Ab Wheel Rollout": "exercise.seed.ab_wheel_rollout",
        "Bicycle Crunch": "exercise.seed.bicycle_crunch",
        "Sit-Up": "exercise.seed.sit_up",
        "Dead Bug": "exercise.seed.dead_bug",
        "Mountain Climber": "exercise.seed.mountain_climber"
    ]

    private static let equipmentLocalizationKeys: [String: String] = [
        "Ab Wheel": "equipment.ab_wheel",
        "Barbell": "equipment.barbell",
        "Bench": "equipment.bench",
        "Bodyweight": "equipment.bodyweight",
        "Cable": "equipment.cable",
        "Dip Bars": "equipment.dip_bars",
        "Dumbbell": "equipment.dumbbell",
        "Dumbbells": "equipment.dumbbells",
        "EZ-bar": "equipment.ez_bar",
        "Machine": "equipment.machine",
        "Plate": "equipment.plate",
        "Pull-up Bar": "equipment.pull_up_bar",
        "Rope": "equipment.rope"
    ]
}
