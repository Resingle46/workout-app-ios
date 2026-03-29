import Foundation
import XCTest
@testable import WorkoutApp

final class WorkoutLiveActivityManagerTests: XCTestCase {
    @MainActor
    func testSnapshotUsesFirstIncompleteExerciseAndProgressCounts() {
        let bench = makeExercise(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000301")!,
            name: "Bench Press"
        )
        let squat = makeExercise(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000302")!,
            name: "Back Squat"
        )
        let session = WorkoutSession(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000303")!,
            workoutTemplateID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000304")!,
            title: "Push + Legs",
            startedAt: Date(timeIntervalSince1970: 1_700_500_000),
            endedAt: nil,
            exercises: [
                WorkoutExerciseLog(
                    templateExerciseID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000305")!,
                    exerciseID: bench.id,
                    groupKind: .regular,
                    groupID: nil,
                    sets: [
                        WorkoutSetLog(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000306")!,
                            reps: 8,
                            weight: 80,
                            completedAt: Date(timeIntervalSince1970: 1_700_500_120)
                        )
                    ]
                ),
                WorkoutExerciseLog(
                    templateExerciseID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000307")!,
                    exerciseID: squat.id,
                    groupKind: .regular,
                    groupID: nil,
                    sets: [
                        WorkoutSetLog(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000308")!,
                            reps: 6,
                            weight: 100,
                            completedAt: nil
                        ),
                        WorkoutSetLog(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000309")!,
                            reps: 6,
                            weight: 100,
                            completedAt: nil
                        )
                    ]
                )
            ]
        )
        let store = makeLiveActivityStore(exercises: [bench, squat])

        let snapshot = WorkoutLiveActivityManager.makeSnapshot(
            session: session,
            using: store,
            updatedAt: Date(timeIntervalSince1970: 1_700_500_200)
        )

        XCTAssertEqual(snapshot?.currentExerciseName, squat.name)
        XCTAssertEqual(snapshot?.currentSetLabel, "Set 1")
        XCTAssertEqual(snapshot?.completedSetCount, 1)
        XCTAssertEqual(snapshot?.totalSetCount, 3)
        XCTAssertEqual(snapshot?.lastCompletedSetAt, Date(timeIntervalSince1970: 1_700_500_120))
    }

    @MainActor
    func testSnapshotFallsBackToLastExerciseWhenAllSetsAreComplete() {
        let bench = makeExercise(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000320")!,
            name: "Bench Press"
        )
        let session = WorkoutSession(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000321")!,
            workoutTemplateID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000322")!,
            title: "Push",
            startedAt: Date(timeIntervalSince1970: 1_700_600_000),
            endedAt: nil,
            exercises: [
                WorkoutExerciseLog(
                    templateExerciseID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000323")!,
                    exerciseID: bench.id,
                    groupKind: .regular,
                    groupID: nil,
                    sets: [
                        WorkoutSetLog(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000324")!,
                            reps: 8,
                            weight: 80,
                            completedAt: Date(timeIntervalSince1970: 1_700_600_120)
                        )
                    ]
                )
            ]
        )
        let store = makeLiveActivityStore(exercises: [bench])

        let snapshot = WorkoutLiveActivityManager.makeSnapshot(session: session, using: store)

        XCTAssertEqual(snapshot?.currentExerciseName, bench.name)
        XCTAssertEqual(snapshot?.currentSetLabel, "Set 1")
        XCTAssertEqual(snapshot?.completedSetCount, 1)
        XCTAssertEqual(snapshot?.totalSetCount, 1)
    }
}

@MainActor
private func makeLiveActivityStore(exercises: [Exercise]) -> AppStore {
    let store = AppStore()
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

private func makeExercise(id: UUID, name: String) -> Exercise {
    Exercise(
        id: id,
        name: name,
        categoryID: SeedData.chestCategoryID,
        equipment: "Barbell",
        notes: ""
    )
}
