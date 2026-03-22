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
