import Foundation

enum RootTab: Hashable, Sendable {
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

struct UserProfile: Codable, Hashable, Sendable {
    var sex: String
    var age: Int
    var weight: Double
    var height: Double
    var appLanguageCode: String?

    static let empty = UserProfile(sex: "M", age: 25, weight: 70, height: 175, appLanguageCode: nil)
}

extension Exercise {
    var localizedName: String {
        guard let localizationKey = Self.seedLocalizationKeys[name] else { return name }
        return Bundle.main.localizedString(forKey: localizationKey, value: name, table: nil)
    }

    var searchableNames: [String] {
        Array(Set([name, localizedName]))
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
        "Russian Twist": "exercise.seed.russian_twist"
    ]
}
