import Foundation
import XCTest
@testable import WorkoutApp

final class WorkoutLiveActivityExternalActionTests: XCTestCase {
    func testCommandStoreDeduplicatesSameSetCommand() throws {
        let tempDirectory = try makeTemporaryDirectory()
        let commandStore = WorkoutExternalCommandStore(baseDirectoryURL: tempDirectory)
        let command = WorkoutExternalCommand(
            kind: .completeCurrentSet,
            sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000401")!,
            currentSetID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000402")!,
            createdAt: Date(timeIntervalSince1970: 1_710_000_000)
        )

        XCTAssertTrue(try commandStore.enqueue(command))
        XCTAssertFalse(try commandStore.enqueue(command))
        XCTAssertEqual(try commandStore.pendingCommands(), [command])
    }

    func testCommandStoreAcknowledgementRemovesCommand() throws {
        let tempDirectory = try makeTemporaryDirectory()
        let commandStore = WorkoutExternalCommandStore(baseDirectoryURL: tempDirectory)
        let command = WorkoutExternalCommand(
            kind: .completeCurrentSet,
            sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000403")!,
            currentSetID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000404")!,
            createdAt: Date(timeIntervalSince1970: 1_710_000_100)
        )

        XCTAssertTrue(try commandStore.enqueue(command))
        try commandStore.acknowledge(command)

        XCTAssertTrue(try (commandStore.pendingCommands().isEmpty))
    }

    @MainActor
    func testCompleteCurrentSetUsesCurrentTargetAndIgnoresRepeatedTapForSameSet() throws {
        let fixture = makeWorkoutFixture()
        let checkpointStore = ActiveWorkoutCheckpointStore(baseDirectoryURL: try makeTemporaryDirectory())
        let store = makeExternalActionStore(
            exercises: fixture.exercises,
            checkpointStore: checkpointStore
        )
        store.activeSession = fixture.session

        let completedAt = Date(timeIntervalSince1970: 1_710_000_200)
        let firstResult = store.completeCurrentSet(
            expectedSessionID: fixture.session.id,
            expectedSetID: fixture.firstSetID,
            completedAt: completedAt
        )
        let secondResult = store.completeCurrentSet(
            expectedSessionID: fixture.session.id,
            expectedSetID: fixture.firstSetID,
            completedAt: completedAt.addingTimeInterval(10)
        )

        XCTAssertEqual(
            firstResult,
            .completed(
                WorkoutCurrentSetCompletionOutcome(
                    sessionID: fixture.session.id,
                    setID: fixture.firstSetID,
                    completedAt: completedAt
                )
            )
        )
        XCTAssertEqual(secondResult, .ignored(.setMismatch))
        XCTAssertEqual(
            store.activeSession?.exercises[0].sets[0].completedAt,
            completedAt
        )
        XCTAssertNil(store.activeSession?.exercises[0].sets[1].completedAt)
    }

    @MainActor
    func testProcessingExternalCommandUpdatesCheckpointAndSyncsLiveActivity() async throws {
        let tempDirectory = try makeTemporaryDirectory()
        let checkpointStore = ActiveWorkoutCheckpointStore(baseDirectoryURL: tempDirectory)
        let commandStore = WorkoutExternalCommandStore(baseDirectoryURL: tempDirectory)
        let fixture = makeWorkoutFixture()
        let store = makeExternalActionStore(
            exercises: fixture.exercises,
            checkpointStore: checkpointStore
        )
        store.activeSession = fixture.session

        let completedAt = Date(timeIntervalSince1970: 1_710_000_300)
        try commandStore.enqueue(
            WorkoutExternalCommand(
                kind: .completeCurrentSet,
                sessionID: fixture.session.id,
                currentSetID: fixture.firstSetID,
                createdAt: completedAt
            )
        )

        let processor = WorkoutLiveActivityCommandProcessor(commandStore: commandStore)
        let synchronizer = WorkoutLiveActivitySynchronizerSpy()
        let didMutate = await processor.processPendingCommands(
            using: store,
            liveActivitySynchronizer: synchronizer
        )

        XCTAssertTrue(didMutate)
        XCTAssertEqual(synchronizer.syncedSessionIDs, [fixture.session.id])
        XCTAssertTrue(try (commandStore.pendingCommands().isEmpty))
        XCTAssertEqual(
            try checkpointStore.load()?.session.exercises[0].sets[0].completedAt,
            completedAt
        )
    }
}

@MainActor
private final class WorkoutLiveActivitySynchronizerSpy: WorkoutLiveActivitySynchronizing {
    private(set) var syncedSessionIDs: [UUID] = []

    func sync(activeSession: WorkoutSession?, using store: AppStore) async {
        if let sessionID = activeSession?.id {
            syncedSessionIDs.append(sessionID)
        }
    }
}

@MainActor
private func makeExternalActionStore(
    exercises: [Exercise],
    checkpointStore: ActiveWorkoutCheckpointStore
) -> AppStore {
    let store = AppStore(activeWorkoutCheckpointStore: checkpointStore)
    store.apply(snapshot: AppSnapshot(
        programs: [],
        exercises: exercises,
        history: [],
        profile: UserProfile(
            sex: "M",
            age: 29,
            weight: 85,
            height: 180,
            appLanguageCode: "en"
        )
    ))
    return store
}

private func makeWorkoutFixture() -> (
    exercises: [Exercise],
    session: WorkoutSession,
    firstSetID: UUID
) {
    let bench = Exercise(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000405")!,
        name: "Bench Press",
        categoryID: SeedData.chestCategoryID,
        equipment: "Barbell",
        notes: ""
    )
    let squat = Exercise(
        id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000406")!,
        name: "Back Squat",
        categoryID: SeedData.legsCategoryID,
        equipment: "Barbell",
        notes: ""
    )
    let firstSetID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000407")!
    let secondSetID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000408")!

    return (
        exercises: [bench, squat],
        session: WorkoutSession(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000409")!,
            workoutTemplateID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000410")!,
            title: "Upper + Lower",
            startedAt: Date(timeIntervalSince1970: 1_710_000_000),
            endedAt: nil,
            exercises: [
                WorkoutExerciseLog(
                    templateExerciseID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000411")!,
                    exerciseID: bench.id,
                    groupKind: .regular,
                    groupID: nil,
                    sets: [
                        WorkoutSetLog(
                            id: firstSetID,
                            reps: 8,
                            weight: 80,
                            completedAt: nil
                        ),
                        WorkoutSetLog(
                            id: secondSetID,
                            reps: 8,
                            weight: 80,
                            completedAt: nil
                        )
                    ]
                ),
                WorkoutExerciseLog(
                    templateExerciseID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000412")!,
                    exerciseID: squat.id,
                    groupKind: .regular,
                    groupID: nil,
                    sets: [
                        WorkoutSetLog(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000413")!,
                            reps: 6,
                            weight: 100,
                            completedAt: nil
                        )
                    ]
                )
            ]
        ),
        firstSetID: firstSetID
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}
