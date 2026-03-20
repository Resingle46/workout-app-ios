import Foundation

enum RootTab: Hashable {
    case programs
    case workout
    case statistics
    case profile
}

struct ExerciseCategory: Identifiable, Codable, Hashable {
    let id: UUID
    var nameKey: String
    var symbol: String

    init(id: UUID = UUID(), nameKey: String, symbol: String) {
        self.id = id
        self.nameKey = nameKey
        self.symbol = symbol
    }
}

struct Exercise: Identifiable, Codable, Hashable {
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

struct WorkoutSetTemplate: Identifiable, Codable, Hashable {
    let id: UUID
    var reps: Int
    var suggestedWeight: Double

    init(id: UUID = UUID(), reps: Int, suggestedWeight: Double = 0) {
        self.id = id
        self.reps = reps
        self.suggestedWeight = suggestedWeight
    }
}

struct WorkoutExerciseTemplate: Identifiable, Codable, Hashable {
    enum GroupKind: String, Codable, CaseIterable, Hashable {
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

struct WorkoutTemplate: Identifiable, Codable, Hashable {
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

struct WorkoutProgram: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var workouts: [WorkoutTemplate]

    init(id: UUID = UUID(), title: String, workouts: [WorkoutTemplate]) {
        self.id = id
        self.title = title
        self.workouts = workouts
    }
}

struct WorkoutSetLog: Identifiable, Codable, Hashable {
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

struct WorkoutExerciseLog: Identifiable, Codable, Hashable {
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

struct WorkoutSession: Identifiable, Codable, Hashable {
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

struct RecentWorkoutExerciseSummary: Identifiable, Hashable {
    let id: UUID
    var exerciseID: UUID
    var exerciseName: String
    var performedAt: Date
    var sets: [WorkoutSetLog]
}

struct UserProfile: Codable, Hashable {
    var sex: String
    var age: Int
    var weight: Double
    var height: Double

    static let empty = UserProfile(sex: "M", age: 25, weight: 70, height: 175)
}
