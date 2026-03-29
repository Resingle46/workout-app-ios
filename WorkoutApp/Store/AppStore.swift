import Foundation
import Observation
import ObjectiveC

private struct CoachProgramCommentConstraints: Equatable {
    var rawComment: String
    var rollingSplitExecution: Bool
    var preserveWeeklyFrequency: Bool
    var preserveProgramWorkoutCount: Bool
    var statedWeeklyFrequency: Int?
}

private struct CoachSplitExecutionInterpretation: Equatable {
    enum Mode: Equatable {
        case rollingRotation
        case calendarMatched
        case programCountMismatch
        case unknown
    }

    var mode: Mode
    var shouldTreatProgramCountAsMismatch: Bool
    var programWorkoutCount: Int?
    var weeklyTarget: Int
    var statedWeeklyFrequency: Int?
}

private let coachRotationPatterns: [NSRegularExpression] = [
    try! NSRegularExpression(pattern: #"\brotate\b"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\brotating\b"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\brotation\b"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\bcycle through\b"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\bin order\b"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\bsequentially\b"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"по\s*очеред"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"поочеред"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"по\s*кругу"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"черед"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"ротац"#, options: .caseInsensitive)
]

private let coachPreserveWeeklyFrequencyPatterns: [NSRegularExpression] = [
    try! NSRegularExpression(pattern: #"не\s+предлагай.*(?:частот|кол-?во|количество).*(?:трениров|занят).*(?:в\s+недел|/нед)"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"не\s+меняй.*(?:частот|кол-?во|количество).*(?:трениров|занят).*(?:в\s+недел|/нед)"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"не\s+предлагай.*изменени.*(?:трениров|занят).*(?:в\s+недел|/нед)"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"не\s+меняй.*недельн.*частот"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\bdo not\b.*(?:change|adjust).*(?:training|workout|session).*(?:per\s+week|weekly)"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\bdon't\b.*(?:change|adjust).*(?:training|workout|session).*(?:per\s+week|weekly)"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\bdo not\b.*change.*weekly.*frequency"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\bdon't\b.*change.*weekly.*frequency"#, options: .caseInsensitive)
]

private let coachPreserveProgramCountPatterns: [NSRegularExpression] = [
    try! NSRegularExpression(pattern: #"не\s+предлагай.*(?:изменени|меняй).*(?:кол-?во|количество).*(?:тренировок|дней).*(?:в\s+програм|сплит)"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"не\s+меняй.*(?:кол-?во|количество).*(?:тренировок|дней).*(?:в\s+програм|сплит)"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\bdo not\b.*change.*(?:number|count).*(?:workouts|days).*(?:program|split)"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"\bdon't\b.*change.*(?:number|count).*(?:workouts|days).*(?:program|split)"#, options: .caseInsensitive)
]

private let coachStatedWeeklyFrequencyPatterns: [NSRegularExpression] = [
    try! NSRegularExpression(pattern: #"(\d+)\s*(?:раза?|трениров(?:ки|ок)?|занят(?:ия|ий)?)\s*в\s*недел"#, options: .caseInsensitive),
    try! NSRegularExpression(pattern: #"(\d+)\s*(?:days?|sessions?|workouts?)\s*(?:per|a)\s*week"#, options: .caseInsensitive)
]

private enum ProgressionInputBuilder {
    static let maximumExposureCount = 4
    static let minimumUsableCompletedSetCount = 2
    static let maximumComparableSetCountDelta = 1
    static let maximumWithinSessionWeightSpread = 5.0
}

private func nsRange(for text: String) -> NSRange {
    NSRange(text.startIndex..<text.endIndex, in: text)
}

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
    var coachAnalysisSettings: CoachAnalysisSettings
    var selectedTab: RootTab = .programs

    var localStateUpdatedAt: Date? {
        localSnapshotModifiedAt
    }

    var localBackupHash: String? {
        localSnapshotBackupHash
    }

    var hasRollbackCheckpoint: Bool {
        persistence.hasRollbackCheckpoint()
    }

    var cloudLocalStateKind: CloudLocalStateKind {
        isSeedBaselineSnapshot ? .seed : .userData
    }

    private let persistence = PersistenceController()
    @ObservationIgnored private let debugRecorder: any DebugEventRecording
    private var hasPersistedSnapshot: Bool
    private var localSnapshotModifiedAt: Date?
    private var localSnapshotBackupHash: String?

    init(debugRecorder: any DebugEventRecording = NoopDebugEventRecorder()) {
        let seed = SeedData.make()
        let storedSnapshot = persistence.loadStoredSnapshot() ?? persistence.loadRollbackCheckpoint()
        let baseSnapshot = storedSnapshot?.snapshot ?? AppSnapshot(
            programs: seed.programs,
            exercises: seed.exercises,
            history: [],
            profile: .empty
        )
        let snapshot = AppStore.normalizedSnapshot(from: baseSnapshot)
        let hasStoredSnapshot = storedSnapshot != nil
        let didMigrateStoredSnapshot = storedSnapshot.map { $0.snapshot != snapshot } ?? false

        self.categories = seed.categories
        self.exercises = snapshot.exercises
        self.programs = snapshot.programs
        self.activeSession = nil
        self.history = snapshot.history.sorted { $0.startedAt > $1.startedAt }
        self.lastFinishedSession = snapshot.history.sorted { $0.startedAt > $1.startedAt }.first(where: { $0.isFinished })
        self.profile = AppStore.normalizedProfile(snapshot.profile)
        self.coachAnalysisSettings = Self.normalizedCoachAnalysisSettings(
            snapshot.coachAnalysisSettings,
            availablePrograms: snapshot.programs
        )
        self.debugRecorder = debugRecorder
        self.hasPersistedSnapshot = hasStoredSnapshot
        self.localSnapshotModifiedAt = storedSnapshot?.modifiedAt
        self.localSnapshotBackupHash = storedSnapshot?.backupHash
        Bundle.overrideLocalization(languageCode: selectedLanguageCode)

        if didMigrateStoredSnapshot {
            persistSnapshot(snapshot)
            self.hasPersistedSnapshot = true
        }
    }

    func currentSnapshot() -> AppSnapshot {
        Self.normalizedSnapshot(from: AppSnapshot(
            programs: programs,
            exercises: exercises,
            history: history,
            profile: Self.normalizedProfile(profile),
            coachAnalysisSettings: Self.normalizedCoachAnalysisSettings(
                coachAnalysisSettings,
                availablePrograms: programs
            )
        ))
    }

    func apply(snapshot: AppSnapshot) {
        let normalizedSnapshot = Self.normalizedSnapshot(from: snapshot)
        programs = normalizedSnapshot.programs
        exercises = normalizedSnapshot.exercises
        history = normalizedSnapshot.history.sorted { $0.startedAt > $1.startedAt }
        lastFinishedSession = history.first(where: { $0.isFinished })
        activeSession = nil
        profile = normalizedSnapshot.profile
        coachAnalysisSettings = normalizedSnapshot.coachAnalysisSettings
        Bundle.overrideLocalization(languageCode: selectedLanguageCode)
        persistSnapshot(normalizedSnapshot)
        hasPersistedSnapshot = true
    }

    func save() {
        let snapshot = currentSnapshot()
        profile = snapshot.profile
        Bundle.overrideLocalization(languageCode: selectedLanguageCode)
        persistSnapshot(snapshot)
        hasPersistedSnapshot = true
    }

    func handleAppLaunch() async {
        let hadRollbackCheckpoint = persistence.hasRollbackCheckpoint()
        if hasPersistedSnapshot && hadRollbackCheckpoint {
            persistence.clearRollbackCheckpoint()
            debugRecorder.log(
                category: .backup,
                message: "rollback_checkpoint_cleared"
            )
        }
        debugRecorder.log(
            category: .appLifecycle,
            message: "app_launch",
            metadata: [
                "localCacheAvailable": hasPersistedSnapshot ? "true" : "false",
                "hasRollbackCheckpoint": hadRollbackCheckpoint ? "true" : "false"
            ]
        )
    }

    func handleSceneDidEnterBackground() async {
        debugRecorder.log(
            category: .appLifecycle,
            message: "scene_background",
            metadata: [
                "localCacheAvailable": hasPersistedSnapshot ? "true" : "false"
            ]
        )
    }

    func updateProfile(_ updater: (inout UserProfile) -> Void) {
        updater(&profile)
        save()
    }

    func updateCoachAnalysisSettings(_ updater: (inout CoachAnalysisSettings) -> Void) {
        updater(&coachAnalysisSettings)
        coachAnalysisSettings = Self.normalizedCoachAnalysisSettings(
            coachAnalysisSettings,
            availablePrograms: programs
        )
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

    static func statisticsCalendar(locale: Locale, timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }

    func updateLanguage(_ languageCode: String) {
        profile.appLanguageCode = Self.normalizedLanguageCode(languageCode)
        save()
    }

    func startWorkout(template: WorkoutTemplate) {
        let normalizedExercises = Self.normalizedSupersetTemplateExercises(template.exercises)
        let logs = normalizedExercises.map { item in
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

    func applyRemoteRestore(snapshot: AppSnapshot, remoteBackupHash: String? = nil) {
        let existingSnapshot = currentSnapshot()
        if let checkpoint = persistence.saveRollbackCheckpoint(snapshot: existingSnapshot) {
            debugRecorder.log(
                category: .backup,
                message: "rollback_checkpoint_created",
                metadata: [
                    "modifiedAt": checkpoint.modifiedAt?.ISO8601Format() ?? "unknown",
                    "backupHash": checkpoint.backupHash ?? "unknown"
                ]
            )
        }
        apply(snapshot: snapshot)
        if let remoteBackupHash {
            adoptRemoteBackupHash(remoteBackupHash)
        }
    }

    func dismissLastFinishedSession() {
        lastFinishedSession = nil
    }

    func updateActiveSession(_ updater: (inout WorkoutSession) -> Void) {
        guard var session = activeSession else { return }
        updater(&session)
        activeSession = session
    }

    func cancelActiveWorkout() {
        activeSession = nil
    }

    func addProgram(title: String) {
        programs.insert(WorkoutProgram(title: title, workouts: []), at: 0)
        save()
    }

    func updateProgram(id: UUID, title: String) {
        guard let programIndex = programs.firstIndex(where: { $0.id == id }) else { return }
        programs[programIndex].title = title
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

    func updateWorkout(programID: UUID, workoutID: UUID, title: String, focus: String) {
        guard let programIndex = programs.firstIndex(where: { $0.id == programID }),
              let workoutIndex = programs[programIndex].workouts.firstIndex(where: { $0.id == workoutID }) else {
            return
        }

        programs[programIndex].workouts[workoutIndex].title = title
        programs[programIndex].workouts[workoutIndex].focus = focus

        if activeSession?.workoutTemplateID == workoutID {
            activeSession?.title = title
        }

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
        addExercises(
            to: workoutID,
            drafts: [
                WorkoutExerciseDraft(
                    exerciseID: exerciseID,
                    reps: reps,
                    setsCount: setsCount,
                    suggestedWeight: suggestedWeight,
                    groupKind: groupKind,
                    groupID: groupID
                )
            ]
        )
    }

    func addExercises(to workoutID: UUID, drafts: [WorkoutExerciseDraft]) {
        guard !drafts.isEmpty else { return }

        for programIndex in programs.indices {
            if let workoutIndex = programs[programIndex].workouts.firstIndex(where: { $0.id == workoutID }) {
                let newExercises = drafts.map { draft in
                    WorkoutExerciseTemplate(
                        exerciseID: draft.exerciseID,
                        sets: (0..<draft.setsCount).map { _ in
                            WorkoutSetTemplate(
                                reps: draft.reps,
                                suggestedWeight: draft.suggestedWeight
                            )
                        },
                        groupKind: draft.groupKind,
                        groupID: draft.groupID
                    )
                }

                programs[programIndex].workouts[workoutIndex].exercises.append(contentsOf: newExercises)
                programs[programIndex].workouts[workoutIndex].exercises = Self.normalizedSupersetTemplateExercises(
                    programs[programIndex].workouts[workoutIndex].exercises
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
            updatedSets.append(
                contentsOf: (0..<(setsCount - updatedSets.count)).map { _ in
                    WorkoutSetTemplate(reps: reps, suggestedWeight: suggestedWeight)
                }
            )
        } else if updatedSets.count > setsCount {
            updatedSets.removeLast(updatedSets.count - setsCount)
        }

        for index in updatedSets.indices {
            updatedSets[index].reps = reps
            updatedSets[index].suggestedWeight = suggestedWeight
        }

        templateExercise.sets = updatedSets
        programs[location.programIndex].workouts[location.workoutIndex].exercises[location.exerciseIndex] = templateExercise

        if templateExercise.groupKind == .superset, let groupID = templateExercise.groupID {
            synchronizeSupersetSetCounts(
                programIndex: location.programIndex,
                workoutIndex: location.workoutIndex,
                groupID: groupID,
                targetSetCount: updatedSets.count,
                excludingTemplateExerciseID: templateExercise.id
            )
        }

        programs[location.programIndex].workouts[location.workoutIndex].exercises = Self.normalizedSupersetTemplateExercises(
            programs[location.programIndex].workouts[location.workoutIndex].exercises
        )
        save()
    }

    func swapTemplateExercise(
        programID: UUID,
        workoutID: UUID,
        templateExerciseID: UUID,
        replacementExerciseID: UUID
    ) -> Bool {
        guard exercise(for: replacementExerciseID) != nil,
              let location = templateExerciseLocation(programID: programID, workoutID: workoutID, templateExerciseID: templateExerciseID) else {
            return false
        }

        programs[location.programIndex].workouts[location.workoutIndex].exercises[location.exerciseIndex].exerciseID = replacementExerciseID
        save()
        return true
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

    func addCustomExercise(_ exercise: Exercise) {
        guard !exercises.contains(where: { $0.id == exercise.id }) else { return }
        exercises.insert(exercise, at: 0)
        save()
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
        history
            .filter(\.isFinished)
            .compactMap { session in
                let values = session.exercises
                .filter { $0.exerciseID == exerciseID }
                .flatMap(\.sets)
                .filter { $0.completedAt != nil }
                .map(\.weight)
                .filter { $0 > 0 }

                guard let maxWeight = values.max() else { return nil }
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

    func weeklyStrengthSummary(
        referenceDate: Date = .now,
        calendar: Calendar? = nil
    ) -> WeeklyStrengthSummary {
        let calendar = calendar ?? Self.statisticsCalendar(locale: locale)
        let currentWeekInterval = weekInterval(containing: referenceDate, calendar: calendar)
        let previousWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeekInterval.start) ?? currentWeekInterval.start
        let previousWeekInterval = DateInterval(start: previousWeekStart, end: currentWeekInterval.start)
        let currentWeekVolumes = weeklyExerciseVolumes(in: currentWeekInterval)
        let previousWeekVolumes = weeklyExerciseVolumes(in: previousWeekInterval)
        let matchedExerciseIDs = Set(currentWeekVolumes.keys).intersection(previousWeekVolumes.keys)
        let currentVolume = matchedExerciseIDs.reduce(into: 0.0) { partialResult, exerciseID in
            partialResult += currentWeekVolumes[exerciseID] ?? 0
        }
        let previousVolume = matchedExerciseIDs.reduce(into: 0.0) { partialResult, exerciseID in
            partialResult += previousWeekVolumes[exerciseID] ?? 0
        }

        guard !matchedExerciseIDs.isEmpty, previousVolume > 0 else {
            return WeeklyStrengthSummary(percentChange: 0, currentVolume: currentVolume, previousVolume: previousVolume)
        }

        let percentChange = Int((((currentVolume - previousVolume) / previousVolume) * 100).rounded())
        return WeeklyStrengthSummary(
            percentChange: percentChange,
            currentVolume: currentVolume,
            previousVolume: previousVolume
        )
    }

    func recentSessionAverages(for exerciseID: UUID, limit: Int = 3) -> [ExerciseSessionAverage] {
        history
            .filter(\.isFinished)
            .compactMap { session in
                let completedSets = session.exercises
                    .filter { $0.exerciseID == exerciseID }
                    .flatMap(\.sets)
                    .filter { $0.completedAt != nil }

                guard !completedSets.isEmpty else { return nil }

                let setsCount = completedSets.count
                let averageWeight = completedSets.reduce(0.0) { $0 + $1.weight } / Double(setsCount)
                let averageReps = Double(completedSets.reduce(0) { $0 + $1.reps }) / Double(setsCount)

                return ExerciseSessionAverage(
                    id: session.id,
                    date: session.startedAt,
                    averageWeight: averageWeight,
                    averageReps: averageReps,
                    setsCount: setsCount
                )
            }
            .prefix(limit)
            .map { $0 }
    }

    func progressionInputs(
        for session: WorkoutSession,
        maxHistoryCount: Int = ProgressionInputBuilder.maximumExposureCount
    ) -> [ProgressionEngineInput] {
        let cappedHistoryCount = max(1, maxHistoryCount)
        let referenceDate = finishedSessionDate(session)
        let calendar = Self.statisticsCalendar(locale: locale)
        let weeklySummary = weeklyStrengthSummary(
            referenceDate: referenceDate,
            calendar: calendar
        )
        let weeklyContext = ProgressionWeeklyContext(
            strengthPercentChange: weeklySummary.percentChange
        )
        let previousFinishedSessions = finishedSessionsSortedDescending().filter { $0.id != session.id }

        return orderedUniqueExerciseIDs(in: session).compactMap { exerciseID in
            guard let currentExposure = progressionExposure(
                in: session,
                exerciseID: exerciseID
            ) else {
                return nil
            }

            let previousExposures = previousFinishedSessions
                .compactMap { progressionExposure(in: $0, exerciseID: exerciseID) }
            let trimmedPreviousExposures = Array(previousExposures.prefix(max(cappedHistoryCount - 1, 0)))
            let currentTemplateExerciseID = session.exercises.first { $0.exerciseID == exerciseID }?.templateExerciseID
            let compatibility = progressionPrescriptionCompatibility(
                currentExposure: currentExposure,
                previousExposures: trimmedPreviousExposures,
                currentTemplateExerciseID: currentTemplateExerciseID
            )
            let exposures = progressionExposures(
                currentExposure: currentExposure,
                previousExposures: trimmedPreviousExposures
            )
            let daysSincePreviousExposure = trimmedPreviousExposures.first.map {
                max(
                    calendar.dateComponents([.day], from: $0.performedAt, to: referenceDate).day ?? 0,
                    0
                )
            }

            return ProgressionEngineInput(
                exerciseID: exerciseID,
                currentTemplateExerciseID: currentTemplateExerciseID,
                exposures: exposures,
                prescriptionCompatibility: compatibility,
                daysSincePreviousExposure: daysSincePreviousExposure,
                weeklyContext: weeklyContext
            )
        }
    }

    func profileProgressSummary(
        referenceDate: Date = .now,
        calendar: Calendar? = nil
    ) -> ProfileProgressSummary {
        let calendar = calendar ?? Self.statisticsCalendar(locale: locale)
        let finishedSessions = finishedSessionsSortedDescending()
        let startDate = calendar.date(byAdding: .day, value: -30, to: referenceDate) ?? referenceDate.addingTimeInterval(-(30 * 24 * 60 * 60))
        let recentSessions = finishedSessions.filter { session in
            let sessionDate = finishedSessionDate(session)
            return sessionDate >= startDate && sessionDate <= referenceDate
        }
        let recentVolume = recentSessions.reduce(into: 0.0) { result, session in
            for exerciseLog in session.exercises {
                let completedSets = exerciseLog.sets.filter { $0.completedAt != nil }
                result += completedSets.reduce(0.0) { partialResult, set in
                    partialResult + (set.weight * Double(set.reps))
                }
            }
        }
        let recentExercisesCount = recentSessions.reduce(into: 0) { result, session in
            result += session.exercises.reduce(0) { exerciseResult, exerciseLog in
                exerciseResult + (exerciseLog.sets.contains { $0.completedAt != nil } ? 1 : 0)
            }
        }
        let durations = recentSessions.compactMap { session -> TimeInterval? in
            guard let endedAt = session.endedAt else { return nil }
            let duration = endedAt.timeIntervalSince(session.startedAt)
            return duration > 0 ? duration : nil
        }

        return ProfileProgressSummary(
            totalFinishedWorkouts: finishedSessions.count,
            recentExercisesCount: recentExercisesCount,
            recentVolume: recentVolume,
            averageDuration: durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count),
            lastWorkoutDate: finishedSessions.first.map(finishedSessionDate)
        )
    }

    func recentPersonalRecords(limit: Int = 3) -> [ProfilePRItem] {
        guard limit > 0 else { return [] }

        let sessions = finishedSessionsSortedAscending()
        var previousBests: [UUID: Double] = [:]
        var records: [ProfilePRItem] = []

        for session in sessions {
            let exerciseGroups = Dictionary(grouping: session.exercises, by: \.exerciseID)

            for (exerciseID, exerciseLogs) in exerciseGroups {
                let completedSets = exerciseLogs
                    .flatMap(\.sets)
                    .filter { $0.completedAt != nil && $0.weight > 0 }

                guard let currentBest = completedSets.map(\.weight).max() else {
                    continue
                }

                let previousBest = previousBests[exerciseID] ?? 0
                if previousBest > 0, currentBest > previousBest {
                    let achievedAt = completedSets.compactMap(\.completedAt).max() ?? finishedSessionDate(session)
                    records.append(
                        ProfilePRItem(
                            id: "\(session.id.uuidString)-\(exerciseID.uuidString)-\(currentBest)",
                            exerciseID: exerciseID,
                            exerciseName: exercise(for: exerciseID)?.localizedName ?? exerciseID.uuidString,
                            achievedAt: achievedAt,
                            weight: currentBest,
                            previousWeight: previousBest
                        )
                    )
                }

                previousBests[exerciseID] = max(previousBest, currentBest)
            }
        }

        return Array(records.sorted { $0.achievedAt > $1.achievedAt }.prefix(limit))
    }

    func profileConsistencySummary(
        referenceDate: Date = .now,
        calendar: Calendar? = nil
    ) -> ProfileConsistencySummary {
        let calendar = calendar ?? Self.statisticsCalendar(locale: locale)
        let target = max(profile.weeklyWorkoutTarget, 1)
        let currentWeek = weekInterval(containing: referenceDate, calendar: calendar)
        let workoutsThisWeek = finishedSessionsCount(in: currentWeek)

        var streakWeeks = 0
        var intervalStart = currentWeek.start

        while true {
            let intervalEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: intervalStart) ?? currentWeek.end
            let interval = DateInterval(start: intervalStart, end: intervalEnd)

            if finishedSessionsCount(in: interval) >= target {
                streakWeeks += 1

                guard let previousStart = calendar.date(byAdding: .weekOfYear, value: -1, to: intervalStart) else {
                    break
                }
                intervalStart = previousStart
            } else {
                break
            }
        }

        let recentWeeklyActivity = stride(from: 3, through: 0, by: -1).compactMap { offset -> ProfileWeeklyActivity? in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -offset, to: currentWeek.start) else {
                return nil
            }

            let weekEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? currentWeek.end
            let interval = DateInterval(start: weekStart, end: weekEnd)
            let workoutsCount = finishedSessionsCount(in: interval)
            return ProfileWeeklyActivity(
                weekStart: weekStart,
                workoutsCount: workoutsCount,
                meetsTarget: workoutsCount >= target
            )
        }

        let weekdayWindowStart = calendar.date(byAdding: .weekOfYear, value: -7, to: currentWeek.start) ?? currentWeek.start
        let weekdayWindow = DateInterval(start: weekdayWindowStart, end: currentWeek.end)
        let weekdayCounts = finishedSessionsSortedDescending().reduce(into: [Int: Int]()) { result, session in
            let sessionDate = finishedSessionDate(session)
            guard weekdayWindow.contains(sessionDate) else { return }
            let weekday = calendar.component(.weekday, from: sessionDate)
            result[weekday, default: 0] += 1
        }
        let mostFrequentWeekday = weekdayCounts.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key

        return ProfileConsistencySummary(
            workoutsThisWeek: workoutsThisWeek,
            weeklyTarget: target,
            streakWeeks: streakWeeks,
            recentWeeklyActivity: recentWeeklyActivity,
            mostFrequentWeekday: mostFrequentWeekday
        )
    }

    func profileGoalSummary() -> ProfileGoalSummary {
        let safeWeightChange = profile.targetBodyWeight.flatMap { targetWeight in
            safeWeightChangeRange(currentWeight: profile.weight, targetWeight: targetWeight)
        }
        let etaWeeks = profile.targetBodyWeight.flatMap { targetWeight -> (lower: Int, upper: Int)? in
            guard let safeWeightChange else {
                return nil
            }
            return etaWeeksRange(
                currentWeight: profile.weight,
                targetWeight: targetWeight,
                safeWeightChangeRange: safeWeightChange
            )
        }

        return ProfileGoalSummary(
            primaryGoal: profile.primaryGoal,
            currentWeight: profile.weight,
            targetBodyWeight: profile.targetBodyWeight,
            weeklyWorkoutTarget: profile.weeklyWorkoutTarget,
            safeWeeklyChangeLowerBound: safeWeightChange?.lower,
            safeWeeklyChangeUpperBound: safeWeightChange?.upper,
            etaWeeksLowerBound: etaWeeks?.lower,
            etaWeeksUpperBound: etaWeeks?.upper,
            usesCurrentWeightOnly: true
        )
    }

    func profileMetabolismSummary(
        referenceDate: Date = .now,
        calendar: Calendar? = nil
    ) -> ProfileMetabolismSummary {
        let workoutAverage = recentAverageWorkoutsPerWeek(referenceDate: referenceDate, calendar: calendar)
        let baseActivityFactor = activityFactorBase(for: workoutAverage.average)
        let activityFactorLowerBound = max(baseActivityFactor - 0.05, 1.2)
        let activityFactorUpperBound = min(baseActivityFactor + 0.05, 1.75)
        let weight = profile.weight
        let height = profile.height
        let age = Double(profile.age)
        let baseBMR = (10 * weight) + (6.25 * height) - (5 * age)
        let bmr = baseBMR + (profile.sex.uppercased() == "F" ? -161 : 5)

        return ProfileMetabolismSummary(
            bmr: Int(bmr.rounded()),
            maintenanceCaloriesLowerBound: Int((bmr * activityFactorLowerBound).rounded()),
            maintenanceCaloriesUpperBound: Int((bmr * activityFactorUpperBound).rounded()),
            activityFactorLowerBound: activityFactorLowerBound,
            activityFactorUpperBound: activityFactorUpperBound,
            averageWorkoutsPerWeek: workoutAverage.average,
            estimateSource: workoutAverage.source
        )
    }

    func profileTrainingRecommendationSummary() -> ProfileTrainingRecommendationSummary {
        let isGenericFallback = profile.primaryGoal == .notSet || profile.experienceLevel == .notSet
        let preferredProgram = preferredProgramForProfileInsights()
        let splitExecution = splitExecutionInterpretation(for: preferredProgram)
        let splitWorkoutDays: Int?
        if let preferredProgram,
           !preferredProgram.workouts.isEmpty,
           splitExecution.mode == .calendarMatched {
            splitWorkoutDays = preferredProgram.workouts.count
        } else {
            splitWorkoutDays = nil
        }
        let split = splitWorkoutDays.map { splitRecommendation(for: $0) }
            ?? (isGenericFallback
                ? ProfileTrainingSplitRecommendation.fullBody
                : splitRecommendation(for: profile.weeklyWorkoutTarget))
        let splitProgramTitle = splitWorkoutDays == nil ? nil : preferredProgram?.title

        if isGenericFallback {
            return ProfileTrainingRecommendationSummary(
                primaryGoal: profile.primaryGoal,
                experienceLevel: profile.experienceLevel,
                currentWeeklyTarget: profile.weeklyWorkoutTarget,
                recommendedWeeklyTargetLowerBound: 3,
                recommendedWeeklyTargetUpperBound: 3,
                mainRepLowerBound: 6,
                mainRepUpperBound: 12,
                accessoryRepLowerBound: 6,
                accessoryRepUpperBound: 12,
                weeklySetsLowerBound: 6,
                weeklySetsUpperBound: 10,
                split: split,
                splitWorkoutDays: splitWorkoutDays,
                splitProgramTitle: splitProgramTitle,
                isGenericFallback: true
            )
        }

        let recommendation = recommendationRanges(
            for: profile.primaryGoal,
            experienceLevel: profile.experienceLevel
        )

        return ProfileTrainingRecommendationSummary(
            primaryGoal: profile.primaryGoal,
            experienceLevel: profile.experienceLevel,
            currentWeeklyTarget: profile.weeklyWorkoutTarget,
            recommendedWeeklyTargetLowerBound: recommendation.frequency.lower,
            recommendedWeeklyTargetUpperBound: recommendation.frequency.upper,
            mainRepLowerBound: recommendation.mainReps.lower,
            mainRepUpperBound: recommendation.mainReps.upper,
            accessoryRepLowerBound: recommendation.accessoryReps.lower,
            accessoryRepUpperBound: recommendation.accessoryReps.upper,
            weeklySetsLowerBound: recommendation.weeklySets.lower,
            weeklySetsUpperBound: recommendation.weeklySets.upper,
            split: split,
            splitWorkoutDays: splitWorkoutDays,
            splitProgramTitle: splitProgramTitle,
            isGenericFallback: false
        )
    }

    func profileGoalCompatibilitySummary(
        referenceDate: Date = .now,
        calendar: Calendar? = nil
    ) -> ProfileGoalCompatibilitySummary {
        let goalSummary = profileGoalSummary()
        let workoutAverage = recentAverageWorkoutsPerWeek(referenceDate: referenceDate, calendar: calendar)
        let preferredProgram = preferredProgramForProfileInsights()
        let splitExecution = splitExecutionInterpretation(for: preferredProgram)
        let usesObservedHistory = workoutAverage.source == .history
        var issues: [ProfileGoalCompatibilityIssue] = []

        if let targetBodyWeight = profile.targetBodyWeight {
            switch profile.primaryGoal {
            case .fatLoss where targetBodyWeight >= profile.weight:
                issues.append(
                    ProfileGoalCompatibilityIssue(
                        id: ProfileGoalCompatibilityIssueKind.goalTargetMismatch.rawValue,
                        kind: .goalTargetMismatch,
                        currentWeeklyTarget: nil,
                        recommendedWeeklyTargetLowerBound: nil,
                        observedWorkoutsPerWeek: nil,
                        etaWeeksUpperBound: nil,
                        systemImage: "arrow.left.arrow.right.circle.fill"
                    )
                )
            case .strength where targetBodyWeight < (profile.weight - 1),
                 .hypertrophy where targetBodyWeight < (profile.weight - 1):
                issues.append(
                    ProfileGoalCompatibilityIssue(
                        id: ProfileGoalCompatibilityIssueKind.goalTargetMismatch.rawValue,
                        kind: .goalTargetMismatch,
                        currentWeeklyTarget: nil,
                        recommendedWeeklyTargetLowerBound: nil,
                        observedWorkoutsPerWeek: nil,
                        etaWeeksUpperBound: nil,
                        systemImage: "arrow.left.arrow.right.circle.fill"
                    )
                )
            default:
                break
            }
        }

        switch profile.primaryGoal {
        case .strength where profile.weeklyWorkoutTarget < 3,
             .hypertrophy where profile.weeklyWorkoutTarget < 3:
            issues.append(
                ProfileGoalCompatibilityIssue(
                    id: "\(ProfileGoalCompatibilityIssueKind.frequencyTooLow.rawValue)-3",
                    kind: .frequencyTooLow,
                    currentWeeklyTarget: profile.weeklyWorkoutTarget,
                    recommendedWeeklyTargetLowerBound: 3,
                    observedWorkoutsPerWeek: nil,
                    etaWeeksUpperBound: nil,
                    systemImage: "calendar.badge.exclamationmark"
                )
            )
        case .fatLoss where profile.weeklyWorkoutTarget < 2:
            issues.append(
                ProfileGoalCompatibilityIssue(
                    id: "\(ProfileGoalCompatibilityIssueKind.frequencyTooLow.rawValue)-2",
                    kind: .frequencyTooLow,
                    currentWeeklyTarget: profile.weeklyWorkoutTarget,
                    recommendedWeeklyTargetLowerBound: 2,
                    observedWorkoutsPerWeek: nil,
                    etaWeeksUpperBound: nil,
                    systemImage: "calendar.badge.exclamationmark"
                )
            )
        default:
            break
        }

        if profile.experienceLevel == .beginner, profile.weeklyWorkoutTarget > 5 {
            issues.append(
                ProfileGoalCompatibilityIssue(
                    id: ProfileGoalCompatibilityIssueKind.frequencyTooHighForBeginner.rawValue,
                    kind: .frequencyTooHighForBeginner,
                    currentWeeklyTarget: profile.weeklyWorkoutTarget,
                    recommendedWeeklyTargetLowerBound: 5,
                    observedWorkoutsPerWeek: nil,
                    etaWeeksUpperBound: nil,
                    systemImage: "figure.cooldown"
                )
            )
        }

        if let programWorkoutCount = preferredProgram?.workouts.count,
           programWorkoutCount > 0,
           splitExecution.shouldTreatProgramCountAsMismatch {
            issues.append(
                ProfileGoalCompatibilityIssue(
                    id: ProfileGoalCompatibilityIssueKind.programFrequencyMismatch.rawValue,
                    kind: .programFrequencyMismatch,
                    currentWeeklyTarget: profile.weeklyWorkoutTarget,
                    recommendedWeeklyTargetLowerBound: nil,
                    programWorkoutCount: programWorkoutCount,
                    observedWorkoutsPerWeek: nil,
                    etaWeeksUpperBound: nil,
                    systemImage: "list.bullet.rectangle.portrait"
                )
            )
        }

        if usesObservedHistory, workoutAverage.average < Double(max(profile.weeklyWorkoutTarget - 1, 0)) {
            issues.append(
                ProfileGoalCompatibilityIssue(
                    id: ProfileGoalCompatibilityIssueKind.adherenceGap.rawValue,
                    kind: .adherenceGap,
                    currentWeeklyTarget: profile.weeklyWorkoutTarget,
                    recommendedWeeklyTargetLowerBound: nil,
                    observedWorkoutsPerWeek: workoutAverage.average,
                    etaWeeksUpperBound: nil,
                    systemImage: "chart.line.downtrend.xyaxis"
                )
            )
        }

        if let etaWeeksUpperBound = goalSummary.etaWeeksUpperBound, etaWeeksUpperBound > 24 {
            issues.append(
                ProfileGoalCompatibilityIssue(
                    id: ProfileGoalCompatibilityIssueKind.longGoalTimeline.rawValue,
                    kind: .longGoalTimeline,
                    currentWeeklyTarget: nil,
                    recommendedWeeklyTargetLowerBound: nil,
                    observedWorkoutsPerWeek: nil,
                    etaWeeksUpperBound: etaWeeksUpperBound,
                    systemImage: "flag.pattern.checkered.2.crossed"
                )
            )
        }

        if profile.primaryGoal == .notSet {
            issues.append(
                ProfileGoalCompatibilityIssue(
                    id: ProfileGoalCompatibilityIssueKind.missingGoal.rawValue,
                    kind: .missingGoal,
                    currentWeeklyTarget: nil,
                    recommendedWeeklyTargetLowerBound: nil,
                    observedWorkoutsPerWeek: nil,
                    etaWeeksUpperBound: nil,
                    systemImage: "questionmark.circle.fill"
                )
            )
        }

        return ProfileGoalCompatibilitySummary(
            primaryGoal: profile.primaryGoal,
            currentWeight: profile.weight,
            targetBodyWeight: profile.targetBodyWeight,
            weeklyWorkoutTarget: profile.weeklyWorkoutTarget,
            averageWorkoutsPerWeek: usesObservedHistory ? workoutAverage.average : nil,
            usesObservedHistory: usesObservedHistory,
            issues: issues
        )
    }

    func profileStrengthToBodyweightSummary() -> ProfileStrengthToBodyweightSummary {
        let liftIDs = canonicalLiftIDs()
        let bestLoads = bestCompletedWeightByExercise(for: Set(liftIDs.values))
        let currentWeight = max(profile.weight, 1)

        return ProfileStrengthToBodyweightSummary(
            currentWeight: currentWeight,
            lifts: CanonicalStrengthLift.allCases.map { lift in
                let bestLoad = liftIDs[lift].flatMap { bestLoads[$0] }
                return ProfileRelativeStrengthLift(
                    lift: lift,
                    bestLoad: bestLoad,
                    relativeToBodyWeight: bestLoad.map { $0 / currentWeight }
                )
            }
        )
    }

    func targetWeights(
        workoutTemplateID: UUID,
        templateExerciseIDs: Set<UUID>
    ) -> [UUID: Double] {
        guard !templateExerciseIDs.isEmpty,
              let workout = programs
                .lazy
                .flatMap(\.workouts)
                .first(where: { $0.id == workoutTemplateID }) else {
            return [:]
        }

        return workout.exercises.reduce(into: [UUID: Double]()) { result, templateExercise in
            guard templateExerciseIDs.contains(templateExercise.id) else { return }

            let weight = templateExercise.sets.first?.suggestedWeight ?? 0
            if weight > 0 {
                result[templateExercise.id] = weight
            }
        }
    }

    func lastUsedWeights(for exerciseIDs: Set<UUID>) -> [UUID: Double] {
        guard !exerciseIDs.isEmpty else { return [:] }

        var remainingExerciseIDs = exerciseIDs
        var result: [UUID: Double] = [:]

        for session in history where !remainingExerciseIDs.isEmpty {
            for exerciseLog in session.exercises where remainingExerciseIDs.contains(exerciseLog.exerciseID) {
                if let lastWeight = exerciseLog.sets.reversed().lazy.map(\.weight).first(where: { $0 > 0 }) {
                    result[exerciseLog.exerciseID] = lastWeight
                    remainingExerciseIDs.remove(exerciseLog.exerciseID)
                }
            }
        }

        return result
    }

    func targetWeight(workoutTemplateID: UUID, templateExerciseID: UUID) -> Double? {
        targetWeights(
            workoutTemplateID: workoutTemplateID,
            templateExerciseIDs: [templateExerciseID]
        )[templateExerciseID]
    }

    func lastUsedWeight(for exerciseID: UUID) -> Double? {
        lastUsedWeights(for: [exerciseID])[exerciseID]
    }

    private func recentAverageWorkoutsPerWeek(
        referenceDate: Date = .now,
        calendar: Calendar? = nil
    ) -> (average: Double, source: MetabolismEstimateSource) {
        let consistencySummary = profileConsistencySummary(referenceDate: referenceDate, calendar: calendar)
        let observedWorkouts = consistencySummary.recentWeeklyActivity.reduce(0) { $0 + $1.workoutsCount }

        if observedWorkouts >= 2 {
            let weeksCount = max(consistencySummary.recentWeeklyActivity.count, 1)
            return (Double(observedWorkouts) / Double(weeksCount), .history)
        }

        return (Double(max(profile.weeklyWorkoutTarget, 1)), .target)
    }

    private func activityFactorBase(for averageWorkoutsPerWeek: Double) -> Double {
        switch averageWorkoutsPerWeek {
        case ..<1.5:
            return 1.35
        case ..<3:
            return 1.45
        case ..<5:
            return 1.55
        default:
            return 1.65
        }
    }

    private func safeWeightChangeRange(
        currentWeight: Double,
        targetWeight: Double
    ) -> (lower: Double, upper: Double)? {
        guard targetWeight != currentWeight else {
            return nil
        }

        if targetWeight < currentWeight {
            let lower = max(currentWeight * 0.0025, 0.2)
            let upper = min(max(currentWeight * 0.0075, lower), 0.9)
            return (lower, upper)
        }

        let lower = max(currentWeight * 0.001, 0.1)
        let upper = min(max(currentWeight * 0.0025, lower), 0.25)
        return (lower, upper)
    }

    private func etaWeeksRange(
        currentWeight: Double,
        targetWeight: Double,
        safeWeightChangeRange: (lower: Double, upper: Double)
    ) -> (lower: Int, upper: Int)? {
        let delta = abs(targetWeight - currentWeight)
        guard delta > 0 else {
            return nil
        }

        let minimumWeeks = Int(ceil(delta / safeWeightChangeRange.upper))
        let maximumWeeks = Int(ceil(delta / safeWeightChangeRange.lower))
        return (minimumWeeks, maximumWeeks)
    }

    private func recommendationRanges(
        for goal: TrainingGoal,
        experienceLevel: ExperienceLevel
    ) -> (
        frequency: (lower: Int, upper: Int),
        mainReps: (lower: Int, upper: Int),
        accessoryReps: (lower: Int, upper: Int),
        weeklySets: (lower: Int, upper: Int)
    ) {
        switch (goal, experienceLevel) {
        case (.strength, .beginner):
            return ((3, 4), (3, 6), (6, 10), (8, 10))
        case (.strength, .intermediate):
            return ((3, 5), (3, 6), (6, 10), (10, 14))
        case (.strength, .advanced):
            return ((4, 6), (3, 6), (6, 10), (12, 16))
        case (.hypertrophy, .beginner):
            return ((3, 4), (6, 10), (10, 15), (8, 12))
        case (.hypertrophy, .intermediate):
            return ((4, 5), (6, 10), (10, 15), (10, 16))
        case (.hypertrophy, .advanced):
            return ((5, 6), (6, 10), (10, 15), (12, 20))
        case (.fatLoss, .beginner):
            return ((2, 4), (5, 8), (8, 15), (6, 10))
        case (.fatLoss, .intermediate):
            return ((3, 4), (5, 8), (8, 15), (8, 12))
        case (.fatLoss, .advanced):
            return ((3, 5), (5, 8), (8, 15), (8, 14))
        case (.generalFitness, .beginner):
            return ((2, 3), (6, 10), (10, 15), (6, 8))
        case (.generalFitness, .intermediate):
            return ((3, 4), (6, 10), (10, 15), (8, 10))
        case (.generalFitness, .advanced):
            return ((3, 5), (6, 10), (10, 15), (8, 12))
        default:
            return ((3, 3), (6, 12), (6, 12), (6, 10))
        }
    }

    private func splitRecommendation(for weeklyWorkoutTarget: Int) -> ProfileTrainingSplitRecommendation {
        switch weeklyWorkoutTarget {
        case ...2:
            return .fullBody
        case 3:
            return .upperLowerHybrid
        case 4:
            return .upperLower
        case 5:
            return .upperLowerPlusSpecialization
        default:
            return .highFrequencySplit
        }
    }

    private func preferredProgramForProfileInsights() -> WorkoutProgram? {
        if let selectedProgramID = coachAnalysisSettings.selectedProgramID,
           let selectedProgram = program(for: selectedProgramID),
           !selectedProgram.workouts.isEmpty {
            return selectedProgram
        }

        if let workoutTemplateID = activeSession?.workoutTemplateID,
           let program = program(containingWorkoutTemplateID: workoutTemplateID) {
            return program
        }

        if let workoutTemplateID = lastFinishedSession?.workoutTemplateID,
           let program = program(containingWorkoutTemplateID: workoutTemplateID) {
            return program
        }

        if let workoutTemplateID = history.first(where: \.isFinished)?.workoutTemplateID,
           let program = program(containingWorkoutTemplateID: workoutTemplateID) {
            return program
        }

        return programs.first(where: { !$0.workouts.isEmpty })
    }

    private func programCommentConstraints() -> CoachProgramCommentConstraints {
        let rawComment = coachAnalysisSettings.programComment
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let rollingSplitExecution = coachRotationPatterns.contains {
            $0.firstMatch(in: rawComment, options: [], range: nsRange(for: rawComment)) != nil
        }
        let preserveWeeklyFrequency = coachPreserveWeeklyFrequencyPatterns.contains {
            $0.firstMatch(in: rawComment, options: [], range: nsRange(for: rawComment)) != nil
        }
        let preserveProgramWorkoutCount = coachPreserveProgramCountPatterns.contains {
            $0.firstMatch(in: rawComment, options: [], range: nsRange(for: rawComment)) != nil
        }
        let statedWeeklyFrequency = coachStatedWeeklyFrequencyPatterns.lazy.compactMap { pattern -> Int? in
            guard let match = pattern.firstMatch(
                in: rawComment,
                options: [],
                range: nsRange(for: rawComment)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: rawComment) else {
                return nil
            }

            return Int(String(rawComment[range]))
        }.first

        return CoachProgramCommentConstraints(
            rawComment: rawComment,
            rollingSplitExecution: rollingSplitExecution,
            preserveWeeklyFrequency: preserveWeeklyFrequency,
            preserveProgramWorkoutCount: preserveProgramWorkoutCount,
            statedWeeklyFrequency: statedWeeklyFrequency
        )
    }

    private func splitExecutionInterpretation(
        for preferredProgram: WorkoutProgram?
    ) -> CoachSplitExecutionInterpretation {
        let constraints = programCommentConstraints()
        let programWorkoutCount = preferredProgram?.workouts.count
        let statedWeeklyFrequency = constraints.statedWeeklyFrequency ?? profile.weeklyWorkoutTarget

        guard let programWorkoutCount, programWorkoutCount > 0 else {
            return CoachSplitExecutionInterpretation(
                mode: .unknown,
                shouldTreatProgramCountAsMismatch: false,
                programWorkoutCount: nil,
                weeklyTarget: profile.weeklyWorkoutTarget,
                statedWeeklyFrequency: statedWeeklyFrequency
            )
        }

        let effectiveWeeklyFrequency = constraints.statedWeeklyFrequency ?? profile.weeklyWorkoutTarget
        if constraints.rollingSplitExecution {
            return CoachSplitExecutionInterpretation(
                mode: .rollingRotation,
                shouldTreatProgramCountAsMismatch: false,
                programWorkoutCount: programWorkoutCount,
                weeklyTarget: profile.weeklyWorkoutTarget,
                statedWeeklyFrequency: statedWeeklyFrequency
            )
        }

        if programWorkoutCount == effectiveWeeklyFrequency {
            return CoachSplitExecutionInterpretation(
                mode: .calendarMatched,
                shouldTreatProgramCountAsMismatch: false,
                programWorkoutCount: programWorkoutCount,
                weeklyTarget: profile.weeklyWorkoutTarget,
                statedWeeklyFrequency: statedWeeklyFrequency
            )
        }

        if constraints.preserveWeeklyFrequency || constraints.preserveProgramWorkoutCount {
            return CoachSplitExecutionInterpretation(
                mode: .rollingRotation,
                shouldTreatProgramCountAsMismatch: false,
                programWorkoutCount: programWorkoutCount,
                weeklyTarget: profile.weeklyWorkoutTarget,
                statedWeeklyFrequency: statedWeeklyFrequency
            )
        }

        return CoachSplitExecutionInterpretation(
            mode: .programCountMismatch,
            shouldTreatProgramCountAsMismatch: true,
            programWorkoutCount: programWorkoutCount,
            weeklyTarget: profile.weeklyWorkoutTarget,
            statedWeeklyFrequency: statedWeeklyFrequency
        )
    }

    private func program(containingWorkoutTemplateID workoutTemplateID: UUID) -> WorkoutProgram? {
        programs.first { program in
            program.workouts.contains(where: { $0.id == workoutTemplateID })
        }
    }

    private func orderedUniqueExerciseIDs(in session: WorkoutSession) -> [UUID] {
        var seen = Set<UUID>()
        var orderedIDs: [UUID] = []

        for exerciseLog in session.exercises where !seen.contains(exerciseLog.exerciseID) {
            seen.insert(exerciseLog.exerciseID)
            orderedIDs.append(exerciseLog.exerciseID)
        }

        return orderedIDs
    }

    private func progressionExposure(
        in session: WorkoutSession,
        exerciseID: UUID
    ) -> ProgressionExerciseSession? {
        let matchingLogs = session.exercises.filter { $0.exerciseID == exerciseID }
        guard !matchingLogs.isEmpty else {
            return nil
        }

        let completedSets = matchingLogs
            .flatMap(\.sets)
            .filter { $0.completedAt != nil }
        let loadValues = completedSets
            .map(\.weight)
            .filter { $0 > 0 }
        let repsValues = completedSets.map(\.reps)
        let hasUsableLoadData = !completedSets.isEmpty && loadValues.count == completedSets.count
        let averageWeight = loadValues.isEmpty
            ? 0
            : loadValues.reduce(0, +) / Double(loadValues.count)
        let topWeight = loadValues.max() ?? 0
        let minimumWeight = loadValues.min() ?? 0
        let averageReps = repsValues.isEmpty
            ? 0
            : Double(repsValues.reduce(0, +)) / Double(repsValues.count)
        let totalVolume = completedSets.reduce(0.0) { partialResult, set in
            partialResult + (set.weight * Double(set.reps))
        }
        let metrics = ProgressionSessionMetrics(
            completedSetCount: completedSets.count,
            averageWeight: averageWeight,
            topWeight: topWeight,
            minimumWeight: minimumWeight,
            averageReps: averageReps,
            minimumReps: repsValues.min() ?? 0,
            maximumReps: repsValues.max() ?? 0,
            totalVolume: totalVolume,
            hasUsableLoadData: hasUsableLoadData
        )
        let dataQuality: ProgressionDataQuality =
            completedSets.count >= ProgressionInputBuilder.minimumUsableCompletedSetCount &&
            hasUsableLoadData &&
            metrics.weightSpread <= ProgressionInputBuilder.maximumWithinSessionWeightSpread &&
            averageReps > 0
            ? .usable
            : .sparseOrNoisy

        return ProgressionExerciseSession(
            sessionID: session.id,
            performedAt: finishedSessionDate(session),
            templateExerciseIDs: matchingLogs.map(\.templateExerciseID),
            metrics: metrics,
            dataQuality: dataQuality,
            comparability: dataQuality == .usable ? .comparable : .sparseOrNoisy
        )
    }

    private func progressionExposures(
        currentExposure: ProgressionExerciseSession,
        previousExposures: [ProgressionExerciseSession]
    ) -> [ProgressionExerciseSession] {
        let currentSetCount = currentExposure.metrics.completedSetCount
        let mappedPrevious = previousExposures.map { exposure -> ProgressionExerciseSession in
            var comparableExposure = exposure

            if exposure.dataQuality == .sparseOrNoisy {
                comparableExposure.comparability = .sparseOrNoisy
                return comparableExposure
            }

            let setCountDelta = abs(exposure.metrics.completedSetCount - currentSetCount)
            comparableExposure.comparability = setCountDelta > ProgressionInputBuilder.maximumComparableSetCountDelta
                ? .setShapeMismatch
                : .comparable
            return comparableExposure
        }

        return [currentExposure] + mappedPrevious
    }

    private func progressionPrescriptionCompatibility(
        currentExposure: ProgressionExerciseSession,
        previousExposures: [ProgressionExerciseSession],
        currentTemplateExerciseID: UUID?
    ) -> ProgressionPrescriptionCompatibility {
        guard currentExposure.dataQuality == .usable else {
            return .compatible
        }

        let usablePreviousExposures = previousExposures.filter { $0.dataQuality == .usable }
        guard !usablePreviousExposures.isEmpty else {
            return .compatible
        }

        let setCounts = usablePreviousExposures
            .map { $0.metrics.completedSetCount }
            .sorted()
        let averageReps = usablePreviousExposures
            .map { $0.metrics.averageReps }
            .sorted()
        let medianSetCount = setCounts[setCounts.count / 2]
        let medianAverageReps = averageReps[averageReps.count / 2]
        let setCountDelta = abs(currentExposure.metrics.completedSetCount - medianSetCount)
        let repsDelta = abs(currentExposure.metrics.averageReps - medianAverageReps)
        let hasTemplateMatch = currentTemplateExerciseID.map { currentTemplateExerciseID in
            usablePreviousExposures.contains { $0.templateExerciseIDs.contains(currentTemplateExerciseID) }
        } ?? false

        if setCountDelta >= 2 && repsDelta >= 4 {
            return hasTemplateMatch ? .partialMismatch : .mismatch
        }

        if setCountDelta >= 2 || repsDelta >= 3 {
            return hasTemplateMatch ? .compatible : .partialMismatch
        }

        return .compatible
    }

    private func bestCompletedWeightByExercise(for exerciseIDs: Set<UUID>) -> [UUID: Double] {
        guard !exerciseIDs.isEmpty else {
            return [:]
        }

        return history
            .filter(\.isFinished)
            .reduce(into: [UUID: Double]()) { result, session in
                for exerciseLog in session.exercises where exerciseIDs.contains(exerciseLog.exerciseID) {
                    let bestLoad = exerciseLog.sets
                        .filter { $0.completedAt != nil && $0.weight > 0 }
                        .map(\.weight)
                        .max()

                    guard let bestLoad else {
                        continue
                    }

                    result[exerciseLog.exerciseID] = max(result[exerciseLog.exerciseID] ?? 0, bestLoad)
                }
            }
    }

    private func canonicalLiftIDs() -> [CanonicalStrengthLift: UUID] {
        let liftNames: [CanonicalStrengthLift: String] = [
            .benchPress: "Barbell Bench Press",
            .backSquat: "Back Squat",
            .deadlift: "Deadlift",
            .overheadPress: "Overhead Press"
        ]

        return liftNames.reduce(into: [CanonicalStrengthLift: UUID]()) { result, item in
            if let exerciseID = exercises.first(where: { $0.name == item.value })?.id {
                result[item.key] = exerciseID
            }
        }
    }

    private func persistSnapshot(_ snapshot: AppSnapshot) {
        let metadata = persistence.save(snapshot: snapshot)
        localSnapshotModifiedAt = metadata?.modifiedAt
        localSnapshotBackupHash = metadata?.backupHash
    }

    func adoptRemoteBackupHash(_ backupHash: String) {
        let trimmedBackupHash = backupHash.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBackupHash = trimmedBackupHash.isEmpty ? nil : trimmedBackupHash
        guard let normalizedBackupHash else {
            return
        }

        localSnapshotBackupHash = normalizedBackupHash
        persistence.overrideStoredSnapshotBackupHash(
            normalizedBackupHash,
            modifiedAt: localSnapshotModifiedAt
        )
    }

    private var isSeedBaselineSnapshot: Bool {
        let seed = SeedData.make()
        let baselineSnapshot = AppStore.normalizedSnapshot(
            from: AppSnapshot(
                programs: seed.programs,
                exercises: seed.exercises,
                history: [],
                profile: .empty
            )
        )

        return currentSnapshot() == baselineSnapshot
    }

    private static func normalizedSnapshot(from snapshot: AppSnapshot) -> AppSnapshot {
        let normalizedPrograms = normalizedPrograms(snapshot.programs)
        let normalizedHistory = snapshot.history.sorted { $0.startedAt > $1.startedAt }
        let referencedExerciseIDs = referencedExerciseIDs(
            programs: normalizedPrograms,
            history: normalizedHistory
        )

        return AppSnapshot(
            programs: normalizedPrograms,
            exercises: normalizedExercises(snapshot.exercises, referencedExerciseIDs: referencedExerciseIDs),
            history: normalizedHistory,
            profile: Self.normalizedProfile(snapshot.profile),
            coachAnalysisSettings: normalizedCoachAnalysisSettings(
                snapshot.coachAnalysisSettings,
                availablePrograms: normalizedPrograms
            )
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
        let normalizedWeeklyWorkoutTarget = min(max(profile.weeklyWorkoutTarget, 1), 14)
        let normalizedTargetBodyWeight = profile.targetBodyWeight.map { normalizedHalfStep(min(max($0, 30), 250)) }
        return UserProfile(
            sex: normalizedSex,
            age: normalizedAge,
            weight: normalizedWeight,
            height: normalizedHeight,
            appLanguageCode: normalizedLanguageCode,
            primaryGoal: profile.primaryGoal,
            experienceLevel: profile.experienceLevel,
            weeklyWorkoutTarget: normalizedWeeklyWorkoutTarget,
            targetBodyWeight: normalizedTargetBodyWeight
        )
    }

    private static func normalizedCoachAnalysisSettings(
        _ settings: CoachAnalysisSettings,
        availablePrograms: [WorkoutProgram]
    ) -> CoachAnalysisSettings {
        let normalizedProgramComment = settings.programComment
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limitedProgramComment = String(normalizedProgramComment.prefix(500))
        let selectedProgramID = settings.selectedProgramID.flatMap { programID in
            availablePrograms.contains(where: { $0.id == programID }) ? programID : nil
        }

        return CoachAnalysisSettings(
            selectedProgramID: selectedProgramID,
            programComment: limitedProgramComment
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

    private static func normalizedExercises(_ exercises: [Exercise], referencedExerciseIDs: Set<UUID>) -> [Exercise] {
        var result: [Exercise] = []
        var includedSeedNames = Set<String>()

        for exercise in exercises {
            if SeedData.isDeprecatedSeedExercise(named: exercise.name),
               !referencedExerciseIDs.contains(exercise.id) {
                continue
            }

            guard let definition = SeedData.definition(forExerciseNamed: exercise.name) else {
                var normalizedExercise = exercise
                normalizedExercise.categoryID = SeedData.canonicalCategoryID(for: exercise.categoryID)
                result.append(normalizedExercise)
                continue
            }

            includedSeedNames.insert(definition.name)

            result.append(
                Exercise(
                    id: exercise.id,
                    name: definition.name,
                    categoryID: definition.categoryID,
                    equipment: definition.equipment,
                    notes: exercise.notes
                )
            )
        }

        for definition in SeedData.exerciseDefinitions where !includedSeedNames.contains(definition.name) {
            result.append(
                Exercise(
                    name: definition.name,
                    categoryID: definition.categoryID,
                    equipment: definition.equipment
                )
            )
        }

        return result
    }

    private static func referencedExerciseIDs(
        programs: [WorkoutProgram],
        history: [WorkoutSession]
    ) -> Set<UUID> {
        var referencedIDs = Set<UUID>()

        for program in programs {
            for workout in program.workouts {
                for exercise in workout.exercises {
                    referencedIDs.insert(exercise.exerciseID)
                }
            }
        }

        for session in history {
            for exercise in session.exercises {
                referencedIDs.insert(exercise.exerciseID)
            }
        }

        return referencedIDs
    }

    private static func normalizedPrograms(_ programs: [WorkoutProgram]) -> [WorkoutProgram] {
        programs.map { program in
            var normalizedProgram = program
            normalizedProgram.workouts = program.workouts.map { workout in
                var normalizedWorkout = workout
                normalizedWorkout.exercises = normalizedSupersetTemplateExercises(workout.exercises)
                return normalizedWorkout
            }
            return normalizedProgram
        }
    }

    private static func normalizedSupersetTemplateExercises(_ items: [WorkoutExerciseTemplate]) -> [WorkoutExerciseTemplate] {
        var result: [WorkoutExerciseTemplate] = []
        var handled = Set<UUID>()

        for item in items {
            guard !handled.contains(item.id) else { continue }

            if item.groupKind == .superset, let groupID = item.groupID {
                let groupItems = items.filter { $0.groupKind == .superset && $0.groupID == groupID }
                groupItems.forEach { handled.insert($0.id) }

                guard groupItems.count > 1 else {
                    result.append(contentsOf: groupItems.map(Self.makeRegularTemplateExercise))
                    continue
                }

                let targetSetCount = groupItems.first?.sets.count ?? 0
                result.append(
                    contentsOf: groupItems.map { groupItem in
                        var normalizedItem = groupItem
                        normalizedItem.sets = resizedTemplateSets(groupItem.sets, targetCount: targetSetCount)
                        return normalizedItem
                    }
                )
            } else {
                handled.insert(item.id)
                result.append(item)
            }
        }

        return result
    }

    private static func resizedTemplateSets(_ sets: [WorkoutSetTemplate], targetCount: Int) -> [WorkoutSetTemplate] {
        guard targetCount > 0 else { return [] }

        var resized = sets

        if resized.count > targetCount {
            resized.removeLast(resized.count - targetCount)
            return resized
        }

        let fallback = resized.last ?? WorkoutSetTemplate(reps: 12, suggestedWeight: 0)
        if resized.count < targetCount {
            resized.append(
                contentsOf: (0..<(targetCount - resized.count)).map { _ in
                    WorkoutSetTemplate(
                        reps: fallback.reps,
                        suggestedWeight: fallback.suggestedWeight
                    )
                }
            )
        }

        return resized
    }

    private static func makeRegularTemplateExercise(_ item: WorkoutExerciseTemplate) -> WorkoutExerciseTemplate {
        var regularItem = item
        regularItem.groupKind = .regular
        regularItem.groupID = nil
        return regularItem
    }

    private func synchronizeSupersetSetCounts(
        programIndex: Int,
        workoutIndex: Int,
        groupID: UUID,
        targetSetCount: Int,
        excludingTemplateExerciseID: UUID
    ) {
        let exerciseIndices = programs[programIndex].workouts[workoutIndex].exercises.indices.filter {
            let item = programs[programIndex].workouts[workoutIndex].exercises[$0]
            return item.groupKind == .superset &&
                item.groupID == groupID &&
                item.id != excludingTemplateExerciseID
        }

        for exerciseIndex in exerciseIndices {
            programs[programIndex].workouts[workoutIndex].exercises[exerciseIndex].sets = Self.resizedTemplateSets(
                programs[programIndex].workouts[workoutIndex].exercises[exerciseIndex].sets,
                targetCount: targetSetCount
            )
        }
    }

    private func weekInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)
            ?? DateInterval(start: date, duration: 7 * 24 * 60 * 60)
    }

    private func finishedSessionsSortedDescending() -> [WorkoutSession] {
        history.filter(\.isFinished).sorted { finishedSessionDate($0) > finishedSessionDate($1) }
    }

    private func finishedSessionsSortedAscending() -> [WorkoutSession] {
        history.filter(\.isFinished).sorted { finishedSessionDate($0) < finishedSessionDate($1) }
    }

    private func finishedSessionDate(_ session: WorkoutSession) -> Date {
        session.endedAt ?? session.startedAt
    }

    private func finishedSessionsCount(in interval: DateInterval) -> Int {
        history.filter(\.isFinished).reduce(0) { result, session in
            result + (interval.contains(finishedSessionDate(session)) ? 1 : 0)
        }
    }

    private func weeklyExerciseVolumes(in interval: DateInterval) -> [UUID: Double] {
        history
            .filter(\.isFinished)
            .reduce(into: [UUID: Double]()) { result, session in
                let sessionDate = session.endedAt ?? session.startedAt
                guard interval.contains(sessionDate) else { return }

                for exerciseLog in session.exercises {
                    let completedSets = exerciseLog.sets.filter { $0.completedAt != nil }
                    guard !completedSets.isEmpty else { continue }

                    let volume = completedSets.reduce(0.0) { partialResult, set in
                        partialResult + (set.weight * Double(set.reps))
                    }

                    guard volume > 0 else { continue }
                    result[exerciseLog.exerciseID, default: 0] += volume
                }
            }
    }
}

struct CoachAnalysisSettings: Codable, Equatable, Hashable, Sendable {
    var selectedProgramID: UUID?
    var programComment: String

    static let empty = CoachAnalysisSettings(
        selectedProgramID: nil,
        programComment: ""
    )
}

struct AppSnapshot: Codable, Equatable, Sendable {
    var programs: [WorkoutProgram]
    var exercises: [Exercise]
    var history: [WorkoutSession]
    var profile: UserProfile
    var coachAnalysisSettings: CoachAnalysisSettings = .empty
}

extension AppSnapshot {
    private enum CodingKeys: String, CodingKey {
        case programs
        case exercises
        case history
        case profile
        case coachAnalysisSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        programs = try container.decode([WorkoutProgram].self, forKey: .programs)
        exercises = try container.decode([Exercise].self, forKey: .exercises)
        history = try container.decode([WorkoutSession].self, forKey: .history)
        profile = try container.decode(UserProfile.self, forKey: .profile)
        coachAnalysisSettings =
            try container.decodeIfPresent(CoachAnalysisSettings.self, forKey: .coachAnalysisSettings)
            ?? .empty
    }
}

struct StoredSnapshot: Sendable {
    var snapshot: AppSnapshot
    var modifiedAt: Date?
    var backupHash: String?
}

struct StoredSnapshotMetadata: Codable, Sendable {
    var modifiedAt: Date?
    var backupHash: String?
}

struct PersistenceController {
    private var fileURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("workout-app-snapshot.json")
    }

    private var manifestURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("workout-app-snapshot-manifest.json")
    }

    private var rollbackCheckpointURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("workout-app-restore-checkpoint.json")
    }

    private var rollbackCheckpointManifestURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("workout-app-restore-checkpoint-manifest.json")
    }

    func loadStoredSnapshot() -> StoredSnapshot? {
        loadSnapshot(from: fileURL, manifestURL: manifestURL)
    }

    @discardableResult
    func save(snapshot: AppSnapshot) -> StoredSnapshotMetadata? {
        writeSnapshot(snapshot, to: fileURL, manifestURL: manifestURL)
    }

    func overrideStoredSnapshotBackupHash(
        _ backupHash: String?,
        modifiedAt storedModifiedAt: Date? = nil
    ) {
        persistManifest(
            StoredSnapshotMetadata(
                modifiedAt: storedModifiedAt ?? modifiedAt(for: fileURL),
                backupHash: backupHash
            ),
            to: manifestURL
        )
    }

    @discardableResult
    func saveRollbackCheckpoint(snapshot: AppSnapshot) -> StoredSnapshotMetadata? {
        writeSnapshot(
            snapshot,
            to: rollbackCheckpointURL,
            manifestURL: rollbackCheckpointManifestURL
        )
    }

    func loadRollbackCheckpoint() -> StoredSnapshot? {
        loadSnapshot(from: rollbackCheckpointURL, manifestURL: rollbackCheckpointManifestURL)
    }

    func hasRollbackCheckpoint() -> Bool {
        FileManager.default.fileExists(atPath: rollbackCheckpointURL.path)
    }

    func clearRollbackCheckpoint() {
        try? FileManager.default.removeItem(at: rollbackCheckpointURL)
        try? FileManager.default.removeItem(at: rollbackCheckpointManifestURL)
    }

    func clearStoredSnapshot() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: manifestURL)
    }

    func snapshotModifiedAt() -> Date? {
        modifiedAt(for: fileURL)
    }

    private func loadSnapshot(from fileURL: URL, manifestURL: URL) -> StoredSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(AppSnapshot.self, from: data) else {
            return nil
        }

        let metadata = loadManifest(from: manifestURL, fallbackSnapshot: snapshot, fileURL: fileURL)
        return StoredSnapshot(
            snapshot: snapshot,
            modifiedAt: metadata.modifiedAt,
            backupHash: metadata.backupHash
        )
    }

    @discardableResult
    private func writeSnapshot(
        _ snapshot: AppSnapshot,
        to fileURL: URL,
        manifestURL: URL
    ) -> StoredSnapshotMetadata? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            return StoredSnapshotMetadata(
                modifiedAt: modifiedAt(for: fileURL),
                backupHash: nil
            )
        }
        try? data.write(to: fileURL, options: .atomic)

        let metadata = StoredSnapshotMetadata(
            modifiedAt: modifiedAt(for: fileURL),
            backupHash: try? CloudBackupHashing.hash(for: snapshot)
        )
        persistManifest(metadata, to: manifestURL)
        return metadata
    }

    private func modifiedAt(for fileURL: URL) -> Date? {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return values.contentModificationDate
    }

    private func loadManifest(
        from manifestURL: URL,
        fallbackSnapshot: AppSnapshot,
        fileURL: URL
    ) -> StoredSnapshotMetadata {
        if let data = try? Data(contentsOf: manifestURL),
           let metadata = try? JSONDecoder().decode(StoredSnapshotMetadata.self, from: data) {
            return metadata
        }

        return StoredSnapshotMetadata(
            modifiedAt: modifiedAt(for: fileURL),
            backupHash: try? CloudBackupHashing.hash(for: fallbackSnapshot)
        )
    }

    private func persistManifest(_ metadata: StoredSnapshotMetadata, to manifestURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(metadata) {
            try? data.write(to: manifestURL, options: .atomic)
        }
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
