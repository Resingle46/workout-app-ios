import Foundation
import Observation
import ObjectiveC

@MainActor
@Observable
final class AppStore {
    var categories: [ExerciseCategory]
    var exercises: [Exercise]
    var programs: [WorkoutProgram]
    var activeSession: WorkoutSession?
    var history: [WorkoutSession]
    var lastFinishedSession: WorkoutSession?
    var profile: UserProfile
    var selectedTab: RootTab = .programs
    var backupStatus = BackupStatus()
    var pendingRestorePrompt: BackupRestorePrompt?

    var canCreateCloudBackup: Bool {
        hasPersistedSnapshot && backupStatus.canBackupNow
    }

    var localStateUpdatedAt: Date? {
        localSnapshotModifiedAt
    }

    private let persistence = PersistenceController()
    private let backupCoordinator = BackupCoordinator()
    private var hasPersistedSnapshot: Bool
    private var localSnapshotModifiedAt: Date?

    init() {
        let seed = SeedData.make()
        let storedSnapshot = persistence.loadStoredSnapshot()
        let snapshot = storedSnapshot?.snapshot ?? AppSnapshot(
            programs: seed.programs,
            exercises: seed.exercises,
            history: [],
            profile: .empty
        )

        self.categories = seed.categories
        self.exercises = snapshot.exercises
        self.programs = snapshot.programs
        self.activeSession = nil
        self.history = snapshot.history.sorted { $0.startedAt > $1.startedAt }
        self.lastFinishedSession = snapshot.history.sorted { $0.startedAt > $1.startedAt }.first(where: { $0.isFinished })
        self.profile = AppStore.normalizedProfile(snapshot.profile)
        self.hasPersistedSnapshot = storedSnapshot != nil
        self.localSnapshotModifiedAt = storedSnapshot?.modifiedAt
        Bundle.overrideLocalization(languageCode: selectedLanguageCode)
    }

    func currentSnapshot() -> AppSnapshot {
        AppSnapshot(
            programs: programs,
            exercises: exercises,
            history: history,
            profile: Self.normalizedProfile(profile)
        )
    }

    func apply(snapshot: AppSnapshot) {
        let normalizedSnapshot = normalizedSnapshot(from: snapshot)
        programs = normalizedSnapshot.programs
        exercises = normalizedSnapshot.exercises
        history = normalizedSnapshot.history.sorted { $0.startedAt > $1.startedAt }
        lastFinishedSession = history.first(where: { $0.isFinished })
        activeSession = nil
        profile = normalizedSnapshot.profile
        Bundle.overrideLocalization(languageCode: selectedLanguageCode)
        localSnapshotModifiedAt = persistence.save(snapshot: normalizedSnapshot)
        hasPersistedSnapshot = true
    }

    func save() {
        let snapshot = currentSnapshot()
        profile = snapshot.profile
        Bundle.overrideLocalization(languageCode: selectedLanguageCode)
        localSnapshotModifiedAt = persistence.save(snapshot: snapshot)
        hasPersistedSnapshot = true
    }

    func handleAppLaunch() async {
        await runBackupSync(reason: .launch, allowRestorePrompt: true)
    }

    func handleSceneDidEnterBackground() async {
        await runBackupSync(reason: .sceneBackground, allowRestorePrompt: false)
    }

    func handleBackgroundBackupTask() async -> Bool {
        await runBackupSync(reason: .backgroundTask, allowRestorePrompt: false)
        return backupStatus.lastErrorDescription == nil
    }

    func refreshBackupStatus() async {
        let result = await backupCoordinator.refreshStatus(
            localSnapshotExists: hasPersistedSnapshot,
            localSnapshotModifiedAt: localSnapshotModifiedAt
        )
        applyBackupSyncResult(result, allowRestorePrompt: true)
    }

    func backupNow() async {
        guard hasPersistedSnapshot else {
            backupStatus.lastErrorDescription = Bundle.main.localizedString(forKey: "backup.error.no_local_data", value: nil, table: nil)
            return
        }

        backupStatus.isBackupInProgress = true
        backupStatus.lastErrorDescription = nil
        let status = await backupCoordinator.backupNow(snapshot: currentSnapshot())
        backupStatus = status
    }

    func prepareManualRestore() async {
        backupStatus.lastErrorDescription = nil
        let result = await backupCoordinator.manualRestorePrompt()
        applyBackupSyncResult(result, allowRestorePrompt: true)
    }

    func confirmPendingRestore() async {
        guard pendingRestorePrompt != nil else {
            return
        }

        backupStatus.isRestoreInProgress = true
        backupStatus.lastErrorDescription = nil

        do {
            let envelope = try await backupCoordinator.restoreLatestBackup()
            pendingRestorePrompt = nil
            apply(snapshot: envelope.snapshot)
            let refresh = await backupCoordinator.refreshStatus(
                localSnapshotExists: hasPersistedSnapshot,
                localSnapshotModifiedAt: localSnapshotModifiedAt
            )
            backupStatus = refresh.status
        } catch {
            backupStatus.lastErrorDescription = (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
        }

        backupStatus.isRestoreInProgress = false
    }

    func dismissPendingRestorePrompt() async {
        guard let prompt = pendingRestorePrompt else {
            return
        }

        if prompt.kind == .manualRestore {
            pendingRestorePrompt = nil
            return
        }

        await backupCoordinator.dismissRestorePrompt(for: prompt.metadata)
        pendingRestorePrompt = nil
        let refresh = await backupCoordinator.refreshStatus(
            localSnapshotExists: hasPersistedSnapshot,
            localSnapshotModifiedAt: localSnapshotModifiedAt
        )
        backupStatus = refresh.status
    }

    func updateProfile(_ updater: (inout UserProfile) -> Void) {
        updater(&profile)
        save()
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

    func program(for id: UUID) -> WorkoutProgram? {
        programs.first { $0.id == id }
    }

    func workout(programID: UUID, workoutID: UUID) -> WorkoutTemplate? {
        program(for: programID)?.workouts.first { $0.id == workoutID }
    }

    var selectedLanguageCode: String {
        Self.normalizedLanguageCode(profile.appLanguageCode)
    }

    var locale: Locale {
        Locale(identifier: selectedLanguageCode)
    }

    func updateLanguage(_ languageCode: String) {
        profile.appLanguageCode = Self.normalizedLanguageCode(languageCode)
        save()
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
        selectedTab = .workout
    }

    func finishActiveWorkout() {
        guard var session = activeSession else { return }
        session.endedAt = .now
        history.insert(session, at: 0)
        history.sort { $0.startedAt > $1.startedAt }
        lastFinishedSession = session
        activeSession = nil
        save()
    }

    func dismissLastFinishedSession() {
        lastFinishedSession = nil
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

    func deleteProgram(id: UUID) {
        programs.removeAll { $0.id == id }
        save()
    }

    func addWorkout(programID: UUID, title: String, focus: String) {
        guard let programIndex = programs.firstIndex(where: { $0.id == programID }) else { return }
        programs[programIndex].workouts.append(WorkoutTemplate(title: title, focus: focus, exercises: []))
        save()
    }

    func deleteWorkout(programID: UUID, workoutID: UUID) {
        guard let programIndex = programs.firstIndex(where: { $0.id == programID }) else { return }
        programs[programIndex].workouts.removeAll { $0.id == workoutID }
        save()
    }

    func addExercise(
        to workoutID: UUID,
        exerciseID: UUID,
        reps: Int,
        setsCount: Int,
        suggestedWeight: Double,
        groupKind: WorkoutExerciseTemplate.GroupKind = .regular,
        groupID: UUID? = nil
    ) {
        for programIndex in programs.indices {
            if let workoutIndex = programs[programIndex].workouts.firstIndex(where: { $0.id == workoutID }) {
                let sets = Array(repeating: WorkoutSetTemplate(reps: reps, suggestedWeight: suggestedWeight), count: setsCount)
                programs[programIndex].workouts[workoutIndex].exercises.append(
                    WorkoutExerciseTemplate(exerciseID: exerciseID, sets: sets, groupKind: groupKind, groupID: groupID)
                )
                save()
                return
            }
        }
    }

    func updateTemplateExercise(
        programID: UUID,
        workoutID: UUID,
        templateExerciseID: UUID,
        reps: Int,
        setsCount: Int,
        suggestedWeight: Double
    ) {
        guard let location = templateExerciseLocation(programID: programID, workoutID: workoutID, templateExerciseID: templateExerciseID) else {
            return
        }

        var templateExercise = programs[location.programIndex].workouts[location.workoutIndex].exercises[location.exerciseIndex]
        var updatedSets = templateExercise.sets

        if updatedSets.count < setsCount {
            updatedSets.append(contentsOf: Array(repeating: WorkoutSetTemplate(reps: reps, suggestedWeight: suggestedWeight), count: setsCount - updatedSets.count))
        } else if updatedSets.count > setsCount {
            updatedSets.removeLast(updatedSets.count - setsCount)
        }

        for index in updatedSets.indices {
            updatedSets[index].reps = reps
            updatedSets[index].suggestedWeight = suggestedWeight
        }

        templateExercise.sets = updatedSets
        programs[location.programIndex].workouts[location.workoutIndex].exercises[location.exerciseIndex] = templateExercise
        save()
    }

    func deleteTemplateExercise(programID: UUID, workoutID: UUID, templateExerciseID: UUID) {
        guard let programIndex = programs.firstIndex(where: { $0.id == programID }),
              let workoutIndex = programs[programIndex].workouts.firstIndex(where: { $0.id == workoutID }),
              let templateExercise = programs[programIndex].workouts[workoutIndex].exercises.first(where: { $0.id == templateExerciseID }) else {
            return
        }

        programs[programIndex].workouts[workoutIndex].exercises.removeAll { $0.id == templateExerciseID }

        if templateExercise.groupKind == .superset, let groupID = templateExercise.groupID {
            let remainingIndices = programs[programIndex].workouts[workoutIndex].exercises.indices.filter {
                programs[programIndex].workouts[workoutIndex].exercises[$0].groupKind == .superset &&
                programs[programIndex].workouts[workoutIndex].exercises[$0].groupID == groupID
            }

            if remainingIndices.count == 1 {
                let index = remainingIndices[0]
                programs[programIndex].workouts[workoutIndex].exercises[index].groupKind = .regular
                programs[programIndex].workouts[workoutIndex].exercises[index].groupID = nil
            }
        }

        save()
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

    func recentExercisesFromLastWorkout(limit: Int = 3) -> [RecentWorkoutExerciseSummary] {
        guard let session = lastFinishedSession ?? history.first(where: { $0.isFinished }) else { return [] }

        return session.exercises.prefix(limit).compactMap { exerciseLog in
            guard let exercise = exercise(for: exerciseLog.exerciseID) else { return nil }
            return RecentWorkoutExerciseSummary(
                id: exerciseLog.id,
                exerciseID: exercise.id,
                exerciseName: exercise.localizedName,
                performedAt: session.startedAt,
                sets: exerciseLog.sets
            )
        }
    }

    func targetWeight(workoutTemplateID: UUID, templateExerciseID: UUID) -> Double? {
        guard let templateExercise = programs
            .flatMap(\.workouts)
            .first(where: { $0.id == workoutTemplateID })?
            .exercises
            .first(where: { $0.id == templateExerciseID }) else {
            return nil
        }

        let weight = templateExercise.sets.first?.suggestedWeight ?? 0
        return weight > 0 ? weight : nil
    }

    func lastUsedWeight(for exerciseID: UUID) -> Double? {
        for session in history {
            guard let exerciseLog = session.exercises.first(where: { $0.exerciseID == exerciseID }) else { continue }
            if let lastWeight = exerciseLog.sets.reversed().map(\.weight).first(where: { $0 > 0 }) {
                return lastWeight
            }
        }

        return nil
    }

    private func runBackupSync(reason: BackupTriggerReason, allowRestorePrompt: Bool) async {
        let result = await backupCoordinator.syncIfNeeded(
            snapshot: currentSnapshot(),
            localSnapshotExists: hasPersistedSnapshot,
            localSnapshotModifiedAt: localSnapshotModifiedAt,
            reason: reason
        )
        applyBackupSyncResult(result, allowRestorePrompt: allowRestorePrompt)
    }

    private func applyBackupSyncResult(_ result: BackupSyncResult, allowRestorePrompt: Bool) {
        backupStatus = result.status
        if allowRestorePrompt {
            pendingRestorePrompt = result.restorePrompt
        }
    }

    private func normalizedSnapshot(from snapshot: AppSnapshot) -> AppSnapshot {
        AppSnapshot(
            programs: snapshot.programs,
            exercises: snapshot.exercises,
            history: snapshot.history.sorted { $0.startedAt > $1.startedAt },
            profile: Self.normalizedProfile(snapshot.profile)
        )
    }

    private func templateExerciseLocation(
        programID: UUID,
        workoutID: UUID,
        templateExerciseID: UUID
    ) -> (programIndex: Int, workoutIndex: Int, exerciseIndex: Int)? {
        guard let programIndex = programs.firstIndex(where: { $0.id == programID }),
              let workoutIndex = programs[programIndex].workouts.firstIndex(where: { $0.id == workoutID }),
              let exerciseIndex = programs[programIndex].workouts[workoutIndex].exercises.firstIndex(where: { $0.id == templateExerciseID }) else {
            return nil
        }

        return (programIndex, workoutIndex, exerciseIndex)
    }

    private static func normalizedProfile(_ profile: UserProfile) -> UserProfile {
        let normalizedSex = profile.sex.uppercased() == "F" ? "F" : "M"
        let normalizedAge = min(max(profile.age, 10), 100)
        let normalizedWeight = normalizedHalfStep(min(max(profile.weight, 30), 250))
        let normalizedHeight = min(max(profile.height, 120), 230)
        let normalizedLanguageCode = normalizedLanguageCode(profile.appLanguageCode)
        return UserProfile(
            sex: normalizedSex,
            age: normalizedAge,
            weight: normalizedWeight,
            height: normalizedHeight,
            appLanguageCode: normalizedLanguageCode
        )
    }

    private static func normalizedHalfStep(_ value: Double) -> Double {
        (value * 2).rounded() / 2
    }

    private static func normalizedLanguageCode(_ value: String?) -> String {
        let normalized = value?.lowercased()
        if normalized == "ru" {
            return "ru"
        }
        if normalized == "en" {
            return "en"
        }

        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("ru") ? "ru" : "en"
    }
}

struct AppSnapshot: Codable, Equatable, Sendable {
    var programs: [WorkoutProgram]
    var exercises: [Exercise]
    var history: [WorkoutSession]
    var profile: UserProfile
}

struct StoredSnapshot: Sendable {
    var snapshot: AppSnapshot
    var modifiedAt: Date?
}

struct PersistenceController {
    private var fileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("workout-app-snapshot.json")
    }

    func loadStoredSnapshot() -> StoredSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(AppSnapshot.self, from: data) else {
            return nil
        }

        return StoredSnapshot(snapshot: snapshot, modifiedAt: snapshotModifiedAt())
    }

    @discardableResult
    func save(snapshot: AppSnapshot) -> Date? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return snapshotModifiedAt() }
        try? data.write(to: fileURL, options: .atomic)
        return snapshotModifiedAt()
    }

    func snapshotModifiedAt() -> Date? {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }
}

private var bundleLanguageKey: UInt8 = 0

private final class LocalizedMainBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = objc_getAssociatedObject(self, &bundleLanguageKey) as? Bundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

private extension Bundle {
    static func overrideLocalization(languageCode: String) {
        object_setClass(Bundle.main, LocalizedMainBundle.self)
        let path = Bundle.main.path(forResource: languageCode, ofType: "lproj")
            ?? Bundle.main.path(forResource: "en", ofType: "lproj")
        let bundle = path.flatMap(Bundle.init(path:))
        objc_setAssociatedObject(Bundle.main, &bundleLanguageKey, bundle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
