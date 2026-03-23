import XCTest
@testable import WorkoutApp

final class BackupCoordinatorTests: XCTestCase {
    func testBackupEnvelopeRoundTripsSnapshot() throws {
        let snapshot = makeSnapshot()
        let createdAt = Date(timeIntervalSince1970: 1_710_000_000)
        let envelope = try BackupEnvelope.make(
            snapshot: snapshot,
            createdAt: createdAt,
            appVersion: "2.1",
            buildNumber: "7"
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(BackupEnvelope.self, from: data)

        XCTAssertEqual(decoded, envelope)
    }

    func testSnapshotHashChangesWhenSnapshotChanges() throws {
        let snapshot = makeSnapshot()
        var changedSnapshot = snapshot
        changedSnapshot.profile.weight = 92

        XCTAssertNotEqual(
            try BackupHashing.hash(for: snapshot),
            try BackupHashing.hash(for: changedSnapshot)
        )
    }

    func testBackupWritesJSONFileToSelectedFolder() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let status = try await fixture.coordinator.selectBackupFolder(fixture.folderURL)
        XCTAssertEqual(status.availability, .ready)

        let backupStatus = await fixture.coordinator.backupNow(snapshot: makeSnapshot())
        let files = try backupFiles(in: fixture.folderURL)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(backupStatus.latestBackup?.fileName, files.first?.lastPathComponent)
        XCTAssertEqual(backupStatus.availability, .ready)
    }

    func testRotationKeepsOnlyThreeLatestBackups() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.coordinator.selectBackupFolder(fixture.folderURL)

        for index in 0..<4 {
            fixture.clock.currentDate = Date(timeIntervalSince1970: 1_710_000_000 + TimeInterval(index * 60))
            var snapshot = makeSnapshot()
            snapshot.profile.age += index
            _ = await fixture.coordinator.backupNow(snapshot: snapshot)
        }

        let files = try backupFiles(in: fixture.folderURL)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.first?.lastPathComponent, "WorkoutApp-backup-2024-03-09-16-03-00.json")
    }

    func testRestoreLatestReturnsNewestValidSnapshot() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.coordinator.selectBackupFolder(fixture.folderURL)

        var firstSnapshot = makeSnapshot()
        firstSnapshot.profile.weight = 80
        fixture.clock.currentDate = Date(timeIntervalSince1970: 1_710_000_000)
        _ = await fixture.coordinator.backupNow(snapshot: firstSnapshot)

        var secondSnapshot = makeSnapshot()
        secondSnapshot.profile.weight = 96
        fixture.clock.currentDate = Date(timeIntervalSince1970: 1_710_000_120)
        _ = await fixture.coordinator.backupNow(snapshot: secondSnapshot)

        let restored = try await fixture.coordinator.restoreLatestBackup()
        XCTAssertEqual(restored.snapshot, secondSnapshot)
    }

    func testBackupIsSkippedWhenSnapshotDidNotChange() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.coordinator.selectBackupFolder(fixture.folderURL)

        let snapshot = makeSnapshot()
        fixture.clock.currentDate = Date(timeIntervalSince1970: 1_710_000_000)
        _ = await fixture.coordinator.backupNow(snapshot: snapshot)

        fixture.clock.currentDate = Date(timeIntervalSince1970: 1_710_000_120)
        _ = await fixture.coordinator.backupNow(snapshot: snapshot)

        let files = try backupFiles(in: fixture.folderURL)
        XCTAssertEqual(files.count, 1)
    }

    func testRefreshStatusMarksLostFolderAccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.coordinator.selectBackupFolder(fixture.folderURL)
        try FileManager.default.removeItem(at: fixture.folderURL)

        let status = await fixture.coordinator.refreshStatus()
        XCTAssertEqual(status.availability, .accessLost)
    }

    @MainActor
    func testAppStoreApplyReplacesLocalSnapshot() {
        let store = AppStore()
        let snapshot = makeSnapshot()

        store.startWorkout(template: WorkoutTemplate(title: "Temporary", focus: "Temp", exercises: []))
        store.apply(snapshot: snapshot)

        XCTAssertEqual(store.currentSnapshot(), snapshot)
        XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.history, snapshot.history.sorted { $0.startedAt > $1.startedAt })
        XCTAssertEqual(store.profile, snapshot.profile)
    }

    @MainActor
    func testAppStoreApplyNormalizesSeedExerciseCategoriesAndAppendsMissingSeedCatalog() {
        let legacyCategoryID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let benchID = UUID(uuidString: "ABCDEFAB-CDEF-CDEF-CDEF-ABCDEFABCDEF")!
        let customID = UUID(uuidString: "FEDCBAFE-DCBA-DCBA-DCBA-FEDCBAFEDCBA")!

        let snapshot = AppSnapshot(
            programs: [],
            exercises: [
                Exercise(id: benchID, name: "Barbell Bench Press", categoryID: legacyCategoryID, equipment: "Something Old", notes: "seed"),
                Exercise(id: customID, name: "My Custom Curl", categoryID: legacyCategoryID, equipment: "Band", notes: "custom")
            ],
            history: [],
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "en")
        )

        let store = AppStore()
        store.apply(snapshot: snapshot)

        let migratedBench = try? XCTUnwrap(store.exercises.first(where: { $0.id == benchID }))
        XCTAssertEqual(migratedBench?.categoryID, SeedData.chestCategoryID)
        XCTAssertEqual(migratedBench?.equipment, "Barbell")
        XCTAssertEqual(store.exercises.first(where: { $0.id == customID })?.categoryID, legacyCategoryID)
        XCTAssertEqual(
            store.exercises.filter { $0.name == "Barbell Bench Press" }.count,
            1
        )
        XCTAssertNotNil(store.exercises.first(where: { $0.name == "Mountain Climber" }))
    }

    @MainActor
    func testLocalizedEquipmentUsesRussianTranslationsForSeedEquipment() {
        let exercise = Exercise(
            name: "My Custom Lift",
            categoryID: SeedData.backCategoryID,
            equipment: "Barbell / Bench",
            notes: ""
        )
        let snapshot = AppSnapshot(
            programs: [],
            exercises: [exercise],
            history: [],
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "ru")
        )

        let store = AppStore()
        store.apply(snapshot: snapshot)

        let localizedExercise = try? XCTUnwrap(store.exercises.first(where: { $0.name == "My Custom Lift" }))
        XCTAssertEqual(localizedExercise?.localizedEquipment, "Штанга / Скамья")
    }

    @MainActor
    func testAppStoreAddCustomExercisePreservesProvidedIdentifier() {
        let store = AppStore()
        let exerciseID = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!
        let exercise = Exercise(
            id: exerciseID,
            name: "Tempo Row",
            categoryID: SeedData.backCategoryID,
            equipment: "Cable",
            notes: "Custom"
        )

        store.addCustomExercise(exercise)

        XCTAssertEqual(store.exercises.first(where: { $0.id == exerciseID })?.name, "Tempo Row")
    }

    func testWorkoutDurationFormatterUsesMinuteSecondBelowOneHour() {
        XCTAssertEqual(WorkoutTimeTextFormatter.formatDuration(elapsedSeconds: 3_599), "59:59")
    }

    func testWorkoutDurationFormatterUsesHourMinuteSecondFromOneHour() {
        XCTAssertEqual(WorkoutTimeTextFormatter.formatDuration(elapsedSeconds: 3_605), "01:00:05")
    }

    func testWorkoutLiveRestFormatterReturnsFallbackWithoutLastCompletedSetDate() {
        XCTAssertEqual(
            WorkoutTimeTextFormatter.liveRestString(
                lastCompletedSetDate: nil,
                now: Date(timeIntervalSince1970: 1_710_000_120),
                fallback: "--"
            ),
            "--"
        )
    }

    func testTabBarPresentationResolverReturnsExpandedOutsideWorkoutTab() {
        XCTAssertEqual(
            RootTabBarPresentationResolver.resolve(
                selectedTab: .programs,
                hasActiveWorkout: true,
                workoutTabsExpanded: false
            ),
            .expanded
        )
    }

    func testTabBarPresentationResolverReturnsExpandedWhenNoActiveWorkout() {
        XCTAssertEqual(
            RootTabBarPresentationResolver.resolve(
                selectedTab: .workout,
                hasActiveWorkout: false,
                workoutTabsExpanded: false
            ),
            .expanded
        )
    }

    func testTabBarPresentationResolverReturnsCollapsedWorkoutByDefault() {
        XCTAssertEqual(
            RootTabBarPresentationResolver.resolve(
                selectedTab: .workout,
                hasActiveWorkout: true,
                workoutTabsExpanded: false
            ),
            .collapsedWorkout
        )
    }

    func testTabBarPresentationResolverReturnsExpandedFromWorkoutAfterToggle() {
        XCTAssertEqual(
            RootTabBarPresentationResolver.resolve(
                selectedTab: .workout,
                hasActiveWorkout: true,
                workoutTabsExpanded: true
            ),
            .expandedFromWorkout
        )
    }

    @MainActor
    func testWeeklyStrengthSummaryCountsOnlyMatchedExercisesFromCurrentWeek() {
        let exerciseA = makeExercise(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Bench")
        let exerciseB = makeExercise(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Row")
        let exerciseC = makeExercise(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, name: "Squat")
        let currentWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 20, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 20, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(60, 5, true), (60, 5, true)]),
                makeExerciseLog(exerciseID: exerciseC.id, sets: [(100, 5, true)])
            ]
        )
        let previousWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 13, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 13, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(30, 5, true), (30, 5, true)]),
                makeExerciseLog(exerciseID: exerciseB.id, sets: [(200, 10, true)])
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeStatisticsSnapshot(exercises: [exerciseA, exerciseB, exerciseC], history: [currentWeekSession, previousWeekSession]))

        let summary = store.weeklyStrengthSummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 21, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "ru_RU")
        )

        XCTAssertEqual(summary.currentVolume, 600, accuracy: 0.001)
        XCTAssertEqual(summary.previousVolume, 300, accuracy: 0.001)
        XCTAssertEqual(summary.percentChange, 100)
    }

    @MainActor
    func testWeeklyStrengthSummaryReturnsNegativeChangeWhenVolumeDrops() {
        let exerciseA = makeExercise(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, name: "Press")
        let currentWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 20, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 20, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(20, 5, true), (20, 5, true)])
            ]
        )
        let previousWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 14, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 14, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(40, 5, true), (40, 5, true)])
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeStatisticsSnapshot(exercises: [exerciseA], history: [currentWeekSession, previousWeekSession]))

        let summary = store.weeklyStrengthSummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 21, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "ru_RU")
        )

        XCTAssertEqual(summary.percentChange, -50)
    }

    @MainActor
    func testWeeklyStrengthSummaryReturnsZeroWhenWeeksDoNotShareExercises() {
        let exerciseA = makeExercise(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, name: "Bench")
        let exerciseB = makeExercise(id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!, name: "Row")
        let currentWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 20, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 20, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(60, 5, true)])
            ]
        )
        let previousWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 13, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 13, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseB.id, sets: [(60, 5, true)])
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeStatisticsSnapshot(exercises: [exerciseA, exerciseB], history: [currentWeekSession, previousWeekSession]))

        let summary = store.weeklyStrengthSummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 21, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "ru_RU")
        )

        XCTAssertEqual(summary.currentVolume, 0, accuracy: 0.001)
        XCTAssertEqual(summary.previousVolume, 0, accuracy: 0.001)
        XCTAssertEqual(summary.percentChange, 0)
    }

    @MainActor
    func testWeeklyStrengthSummaryUsesWeekBoundariesFromCalendar() {
        let exerciseA = makeExercise(id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!, name: "Squat")
        let sundaySession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 17, hour: 20),
            endedAt: makeDate(year: 2024, month: 3, day: 17, hour: 21),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(40, 5, true)])
            ]
        )
        let mondaySession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 18, hour: 8),
            endedAt: makeDate(year: 2024, month: 3, day: 18, hour: 9),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(60, 5, true)])
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeStatisticsSnapshot(exercises: [exerciseA], history: [mondaySession, sundaySession]))

        let summary = store.weeklyStrengthSummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 20, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "ru_RU")
        )

        XCTAssertEqual(summary.currentVolume, 300, accuracy: 0.001)
        XCTAssertEqual(summary.previousVolume, 200, accuracy: 0.001)
        XCTAssertEqual(summary.percentChange, 50)
    }

    @MainActor
    func testRecentSessionAveragesReturnsLatestThreeCompletedSessionsForExercise() {
        let exerciseA = makeExercise(id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!, name: "Bench")
        let exerciseB = makeExercise(id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!, name: "Row")
        let newestSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 20, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 20, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(100, 5, true), (90, 8, true)]),
                makeExerciseLog(exerciseID: exerciseB.id, sets: [(70, 8, true)])
            ]
        )
        let secondSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 17, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 17, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(80, 10, true), (75, 8, false)])
            ]
        )
        let ignoredSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 15, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 15, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseB.id, sets: [(85, 6, true)])
            ]
        )
        let thirdSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 12, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 12, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(70, 12, true)])
            ]
        )
        let unfinishedSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 11, hour: 10),
            endedAt: nil,
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(120, 3, true)])
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeStatisticsSnapshot(exercises: [exerciseA, exerciseB], history: [newestSession, secondSession, ignoredSession, thirdSession, unfinishedSession]))

        let averages = store.recentSessionAverages(for: exerciseA.id)

        XCTAssertEqual(averages.map(\.id), [newestSession.id, secondSession.id, thirdSession.id])
        XCTAssertEqual(averages[0].averageWeight, 95, accuracy: 0.001)
        XCTAssertEqual(averages[0].averageReps, 6.5, accuracy: 0.001)
        XCTAssertEqual(averages[0].setsCount, 2)
        XCTAssertEqual(averages[1].averageWeight, 80, accuracy: 0.001)
        XCTAssertEqual(averages[1].averageReps, 10, accuracy: 0.001)
        XCTAssertEqual(averages[1].setsCount, 1)
        XCTAssertEqual(averages[2].averageWeight, 70, accuracy: 0.001)
        XCTAssertEqual(averages[2].averageReps, 12, accuracy: 0.001)
        XCTAssertEqual(averages[2].setsCount, 1)
    }

    private func backupFiles(in folderURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.lastPathComponent.hasPrefix(BackupConstants.filePrefix) &&
            $0.pathExtension == BackupConstants.fileExtension
        }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func makeFixture() throws -> BackupTestFixture {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)

        let suiteName = "BackupCoordinatorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let clock = TestClock(currentDate: Date(timeIntervalSince1970: 1_710_000_000))
        let coordinator = BackupCoordinator(
            defaults: defaults,
            now: { clock.currentDate },
            fileManager: .default
        )

        return BackupTestFixture(
            folderURL: folderURL,
            defaultsSuiteName: suiteName,
            defaults: defaults,
            clock: clock,
            coordinator: coordinator
        )
    }

    private func makeSnapshot() -> AppSnapshot {
        let categoryID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let exerciseID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let templateExerciseID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let workoutID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let programID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!

        let exercise = Exercise(
            id: exerciseID,
            name: "Incline Bench",
            categoryID: categoryID,
            equipment: "Barbell",
            notes: "Heavy day"
        )
        let template = WorkoutExerciseTemplate(
            id: templateExerciseID,
            exerciseID: exerciseID,
            sets: [
                WorkoutSetTemplate(reps: 8, suggestedWeight: 80),
                WorkoutSetTemplate(reps: 6, suggestedWeight: 85)
            ]
        )
        let workout = WorkoutTemplate(
            id: workoutID,
            title: "Push Day",
            focus: "Chest",
            exercises: [template]
        )
        let session = WorkoutSession(
            workoutTemplateID: workoutID,
            title: "Push Day",
            startedAt: Date(timeIntervalSince1970: 1_710_000_000),
            endedAt: Date(timeIntervalSince1970: 1_710_000_900),
            exercises: [
                WorkoutExerciseLog(
                    templateExerciseID: templateExerciseID,
                    exerciseID: exerciseID,
                    groupKind: .regular,
                    groupID: nil,
                    sets: [
                        WorkoutSetLog(reps: 8, weight: 80, completedAt: Date(timeIntervalSince1970: 1_710_000_200)),
                        WorkoutSetLog(reps: 6, weight: 85, completedAt: Date(timeIntervalSince1970: 1_710_000_500))
                    ]
                )
            ]
        )

        return AppSnapshot(
            programs: [
                WorkoutProgram(id: programID, title: "Strength", workouts: [workout])
            ],
            exercises: [exercise],
            history: [session],
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "en")
        )
    }

    private func makeStatisticsSnapshot(exercises: [Exercise], history: [WorkoutSession]) -> AppSnapshot {
        AppSnapshot(
            programs: [],
            exercises: exercises,
            history: history,
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "ru")
        )
    }

    private func makeExercise(id: UUID, name: String) -> Exercise {
        Exercise(
            id: id,
            name: name,
            categoryID: UUID(uuidString: "AAAAAAAA-1111-1111-1111-AAAAAAAAAAAA")!,
            equipment: "",
            notes: ""
        )
    }

    private func makeSession(
        startedAt: Date,
        endedAt: Date?,
        exerciseLogs: [WorkoutExerciseLog]
    ) -> WorkoutSession {
        WorkoutSession(
            workoutTemplateID: UUID(uuidString: "BBBBBBBB-1111-1111-1111-BBBBBBBBBBBB")!,
            title: "Session",
            startedAt: startedAt,
            endedAt: endedAt,
            exercises: exerciseLogs
        )
    }

    private func makeExerciseLog(
        exerciseID: UUID,
        sets: [(weight: Double, reps: Int, completed: Bool)]
    ) -> WorkoutExerciseLog {
        WorkoutExerciseLog(
            templateExerciseID: UUID(),
            exerciseID: exerciseID,
            groupKind: .regular,
            groupID: nil,
            sets: sets.enumerated().map { index, set in
                WorkoutSetLog(
                    reps: set.reps,
                    weight: set.weight,
                    completedAt: set.completed
                        ? Date(timeIntervalSince1970: 1_710_000_000 + TimeInterval(index * 60))
                        : nil
                )
            }
        )
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.calendar = statisticsCalendar(localeIdentifier: "ru_RU")
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = 0
        components.second = 0
        return components.date!
    }

    private func statisticsCalendar(localeIdentifier: String) -> Calendar {
        AppStore.statisticsCalendar(
            locale: Locale(identifier: localeIdentifier),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }
}

private struct BackupTestFixture {
    let folderURL: URL
    let defaultsSuiteName: String
    let defaults: UserDefaults
    let clock: TestClock
    let coordinator: BackupCoordinator

    func cleanup() {
        try? FileManager.default.removeItem(at: folderURL)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

private final class TestClock: @unchecked Sendable {
    var currentDate: Date

    init(currentDate: Date) {
        self.currentDate = currentDate
    }
}
