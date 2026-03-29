import Foundation
import XCTest
@testable import WorkoutApp

final class ActiveWorkoutRecoveryTests: XCTestCase {
    func testCheckpointStoreRoundTripPreservesSessionIDAndExcludesFromBackup() throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fixture = makeRecoveryFixture()
        let checkpointStore = ActiveWorkoutCheckpointStore(baseDirectoryURL: tempDirectory)
        let savedURL = try checkpointStore.save(
            ActiveWorkoutCheckpoint(
                savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                session: fixture.session
            )
        )

        let loadedCheckpoint = try XCTUnwrap(checkpointStore.load())
        let resourceValues = try savedURL.resourceValues(forKeys: [.isExcludedFromBackupKey])

        XCTAssertEqual(loadedCheckpoint.session.id, fixture.session.id)
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
    }

    @MainActor
    func testHandleAppLaunchRestoresFreshCheckpointPreservingSessionID() async throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fixture = makeRecoveryFixture()
        let checkpointStore = ActiveWorkoutCheckpointStore(baseDirectoryURL: tempDirectory)
        let store = makeRecoveryAppStore(
            snapshot: fixture.snapshot,
            checkpointStore: checkpointStore
        )

        try checkpointStore.save(
            ActiveWorkoutCheckpoint(
                savedAt: Date().addingTimeInterval(-300),
                session: fixture.session
            )
        )

        await store.handleAppLaunch()

        XCTAssertEqual(store.activeSession?.id, fixture.session.id)
        XCTAssertEqual(store.restoredWorkoutBanner?.sessionID, fixture.session.id)
        XCTAssertNil(store.pendingStaleWorkoutCheckpoint)
        XCTAssertEqual(store.selectedTab, .workout)
    }

    @MainActor
    func testHandleAppLaunchStagesStaleCheckpointInsteadOfAutoRestoring() async throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fixture = makeRecoveryFixture()
        let checkpointStore = ActiveWorkoutCheckpointStore(baseDirectoryURL: tempDirectory)
        let store = makeRecoveryAppStore(
            snapshot: fixture.snapshot,
            checkpointStore: checkpointStore
        )

        try checkpointStore.save(
            ActiveWorkoutCheckpoint(
                savedAt: Date().addingTimeInterval(-(24 * 60 * 60 + 60)),
                session: fixture.session
            )
        )

        await store.handleAppLaunch()

        XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.pendingStaleWorkoutCheckpoint?.session.id, fixture.session.id)
        XCTAssertNil(store.restoredWorkoutBanner)
    }

    @MainActor
    func testHandleAppLaunchClearsCheckpointWhenRequiredExerciseIsMissing() async throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fixture = makeRecoveryFixture()
        let checkpointStore = ActiveWorkoutCheckpointStore(baseDirectoryURL: tempDirectory)
        let invalidSnapshot = AppSnapshot(
            programs: fixture.snapshot.programs,
            exercises: [],
            history: [],
            profile: fixture.snapshot.profile
        )
        let store = makeRecoveryAppStore(
            snapshot: invalidSnapshot,
            checkpointStore: checkpointStore
        )

        try checkpointStore.save(
            ActiveWorkoutCheckpoint(
                savedAt: Date().addingTimeInterval(-60),
                session: fixture.session
            )
        )

        await store.handleAppLaunch()

        XCTAssertNil(store.activeSession)
        XCTAssertNil(store.pendingStaleWorkoutCheckpoint)
        XCTAssertNil(try checkpointStore.load())
    }

    @MainActor
    func testFinishActiveWorkoutIsDuplicateSafeAndClearsCheckpoint() throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fixture = makeRecoveryFixture()
        let checkpointStore = ActiveWorkoutCheckpointStore(baseDirectoryURL: tempDirectory)
        var finishedSession = fixture.session
        finishedSession.endedAt = finishedSession.startedAt.addingTimeInterval(1_200)
        let snapshot = AppSnapshot(
            programs: fixture.snapshot.programs,
            exercises: fixture.snapshot.exercises,
            history: [finishedSession],
            profile: fixture.snapshot.profile
        )
        let store = makeRecoveryAppStore(
            snapshot: snapshot,
            checkpointStore: checkpointStore
        )

        store.activeSession = fixture.session
        try checkpointStore.save(ActiveWorkoutCheckpoint(savedAt: .now, session: fixture.session))

        store.finishActiveWorkout()

        XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(store.history.first?.id, finishedSession.id)
        XCTAssertNil(try checkpointStore.load())
    }

    @MainActor
    func testApplySnapshotClearsRecoveryCheckpoint() throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fixture = makeRecoveryFixture()
        let checkpointStore = ActiveWorkoutCheckpointStore(baseDirectoryURL: tempDirectory)
        let store = makeRecoveryAppStore(
            snapshot: fixture.snapshot,
            checkpointStore: checkpointStore
        )

        try checkpointStore.save(ActiveWorkoutCheckpoint(savedAt: .now, session: fixture.session))
        store.pendingStaleWorkoutCheckpoint = PendingStaleWorkoutCheckpoint(
            checkpoint: ActiveWorkoutCheckpoint(savedAt: .now, session: fixture.session)
        )
        store.restoredWorkoutBanner = ActiveWorkoutRestoreBanner(sessionID: fixture.session.id)

        store.apply(snapshot: fixture.snapshot)

        XCTAssertNil(try checkpointStore.load())
        XCTAssertNil(store.pendingStaleWorkoutCheckpoint)
        XCTAssertNil(store.restoredWorkoutBanner)
        XCTAssertNil(store.activeSession)
    }

    @MainActor
    func testApplyRemoteRestoreClearsRecoveryCheckpoint() throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fixture = makeRecoveryFixture()
        let checkpointStore = ActiveWorkoutCheckpointStore(baseDirectoryURL: tempDirectory)
        let store = makeRecoveryAppStore(
            snapshot: fixture.snapshot,
            checkpointStore: checkpointStore
        )

        try checkpointStore.save(ActiveWorkoutCheckpoint(savedAt: .now, session: fixture.session))
        store.pendingStaleWorkoutCheckpoint = PendingStaleWorkoutCheckpoint(
            checkpoint: ActiveWorkoutCheckpoint(savedAt: .now, session: fixture.session)
        )

        store.applyRemoteRestore(snapshot: fixture.snapshot, remoteBackupHash: "remote-hash")

        XCTAssertNil(try checkpointStore.load())
        XCTAssertNil(store.pendingStaleWorkoutCheckpoint)
        XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.localBackupHash, "remote-hash")
    }

    @MainActor
    func testDraftCoordinatorFlushCanRunBeforeLifecycleCheckpointSave() async throws {
        let tempDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fixture = makeRecoveryFixture()
        let checkpointStore = ActiveWorkoutCheckpointStore(baseDirectoryURL: tempDirectory)
        let store = makeRecoveryAppStore(
            snapshot: fixture.snapshot,
            checkpointStore: checkpointStore
        )
        let coordinator = ActiveWorkoutDraftCoordinator()

        store.startWorkout(template: fixture.template)
        coordinator.registerFlushAction(id: UUID()) {
            store.updateActiveSession { session in
                session.exercises[0].sets[0].weight = 95
            }
        }

        coordinator.flushAll()
        await store.handleSceneWillResignActive()

        let loadedCheckpoint = try XCTUnwrap(checkpointStore.load())
        XCTAssertEqual(loadedCheckpoint.session.exercises[0].sets[0].weight, 95)
    }
}

@MainActor
private func makeRecoveryAppStore(
    snapshot: AppSnapshot,
    checkpointStore: ActiveWorkoutCheckpointStore
) -> AppStore {
    let store = AppStore(activeWorkoutCheckpointStore: checkpointStore)
    store.apply(snapshot: snapshot)
    return store
}

private func makeRecoveryFixture(
    sessionID: UUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000200")!
) -> (
    snapshot: AppSnapshot,
    template: WorkoutTemplate,
    session: WorkoutSession
) {
    let exercise = Exercise(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000201")!,
        name: "Bench Press",
        categoryID: SeedData.chestCategoryID,
        equipment: "Barbell",
        notes: ""
    )
    let templateExerciseID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000202")!
    let template = WorkoutTemplate(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000203")!,
        title: "Push Day",
        focus: "Chest",
        exercises: [
            WorkoutExerciseTemplate(
                id: templateExerciseID,
                exerciseID: exercise.id,
                sets: [
                    WorkoutSetTemplate(
                        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000204")!,
                        reps: 8,
                        suggestedWeight: 80
                    )
                ]
            )
        ]
    )
    let session = WorkoutSession(
        id: sessionID,
        workoutTemplateID: template.id,
        title: template.title,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: nil,
        exercises: [
            WorkoutExerciseLog(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000205")!,
                templateExerciseID: templateExerciseID,
                exerciseID: exercise.id,
                groupKind: .regular,
                groupID: nil,
                sets: [
                    WorkoutSetLog(
                        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000206")!,
                        reps: 8,
                        weight: 80,
                        completedAt: nil
                    )
                ]
            )
        ]
    )
    let snapshot = AppSnapshot(
        programs: [
            WorkoutProgram(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000207")!,
                title: "Program A",
                workouts: [template]
            )
        ],
        exercises: [exercise],
        history: [],
        profile: UserProfile(
            sex: "M",
            age: 29,
            weight: 85,
            height: 180,
            appLanguageCode: "en"
        )
    )

    return (snapshot, template, session)
}

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActiveWorkoutRecoveryTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
