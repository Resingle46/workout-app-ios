import Foundation
import Observation

@Observable
final class AppStore {
    var categories: [ExerciseCategory]
    var exercises: [Exercise]
    var programs: [WorkoutProgram]
    var activeSession: WorkoutSession?
    var history: [WorkoutSession]
    var lastFinishedSession: WorkoutSession?
    var profile: UserProfile

    private let persistence = PersistenceController()

    init() {
        let seed = SeedData.make()
        let snapshot = persistence.load() ?? AppSnapshot(programs: seed.programs, exercises: seed.exercises, history: [], profile: .empty)
        self.categories = seed.categories
        self.exercises = snapshot.exercises
        self.programs = snapshot.programs
        self.activeSession = nil
        self.history = snapshot.history.sorted { $0.startedAt > $1.startedAt }
        self.lastFinishedSession = nil
        self.profile = snapshot.profile
    }

    func save() {
        persistence.save(snapshot: AppSnapshot(programs: programs, exercises: exercises, history: history, profile: profile))
    }

    func exercises(for categoryID: UUID?) -> [Exercise] {
        guard let categoryID else { return exercises }
        return exercises.filter { $0.categoryID == categoryID }
    }

    func category(for id: UUID) -> ExerciseCategory? {
        categories.first { $0.id == id }
    }

    func exercise(for id: UUID) -> Exercise? {
        exercises.first { $0.id == id }
    }

    func startWorkout(template: WorkoutTemplate) {
        let logs = template.exercises.map { item in
            WorkoutExerciseLog(
                templateExerciseID: item.id,
                exerciseID: item.exerciseID,
                groupKind: item.groupKind,
                groupID: item.groupID,
                sets: item.sets.map { WorkoutSetLog(reps: $0.reps, weight: $0.suggestedWeight) }
            )
        }
        activeSession = WorkoutSession(workoutTemplateID: template.id, title: template.title, exercises: logs)
    }

    func finishActiveWorkout() {
        guard var session = activeSession else { return }
        session.endedAt = .now
        history.insert(session, at: 0)
        lastFinishedSession = session
        activeSession = nil
        save()
    }

    func updateActiveSession(_ updater: (inout WorkoutSession) -> Void) {
        guard var session = activeSession else { return }
        updater(&session)
        activeSession = session
    }

    func addProgram(title: String) {
        programs.insert(WorkoutProgram(title: title, workouts: []), at: 0)
        save()
    }

    func addWorkout(programID: UUID, title: String, focus: String) {
        guard let index = programs.firstIndex(where: { $0.id == programID }) else { return }
        programs[index].workouts.append(WorkoutTemplate(title: title, focus: focus, exercises: []))
        save()
    }

    func addExercise(to workoutID: UUID, exerciseID: UUID, reps: Int, setsCount: Int, groupKind: WorkoutExerciseTemplate.GroupKind = .regular, groupID: UUID? = nil) {
        for programIndex in programs.indices {
            if let workoutIndex = programs[programIndex].workouts.firstIndex(where: { $0.id == workoutID }) {
                let sets = Array(repeating: WorkoutSetTemplate(reps: reps), count: setsCount)
                programs[programIndex].workouts[workoutIndex].exercises.append(
                    WorkoutExerciseTemplate(exerciseID: exerciseID, sets: sets, groupKind: groupKind, groupID: groupID)
                )
                save()
                return
            }
        }
    }


    func addCustomExercise(name: String, categoryID: UUID, equipment: String, notes: String) -> Exercise {
        let exercise = Exercise(name: name, categoryID: categoryID, equipment: equipment, notes: notes)
        exercises.insert(exercise, at: 0)
        save()
        return exercise
    }

    func removeSetFromActiveWorkout(exerciseIndex: Int, setIndex: Int) {
        updateActiveSession { session in
            guard session.exercises.indices.contains(exerciseIndex),
                  session.exercises[exerciseIndex].sets.indices.contains(setIndex),
                  session.exercises[exerciseIndex].sets.count > 1 else { return }
            session.exercises[exerciseIndex].sets.remove(at: setIndex)
        }
    }

    func chartPoints(for exerciseID: UUID) -> [(Date, Double)] {
        history.compactMap { session in
            let values = session.exercises
                .filter { $0.exerciseID == exerciseID }
                .flatMap(\.sets)
                .map(\.weight)
            guard let maxWeight = values.max(), maxWeight > 0 else { return nil }
            return (session.startedAt, maxWeight)
        }
        .sorted { $0.0 < $1.0 }
    }
}

struct AppSnapshot: Codable {
    var programs: [WorkoutProgram]
    var exercises: [Exercise]
    var history: [WorkoutSession]
    var profile: UserProfile
}

struct PersistenceController {
    private var fileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("workout-app-snapshot.json")
    }

    func load() -> AppSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AppSnapshot.self, from: data)
    }

    func save(snapshot: AppSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
