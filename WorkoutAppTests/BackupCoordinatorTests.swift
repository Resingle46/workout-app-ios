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

    func testAutomaticUploadRequiresMissingOrStaleCloudBackup() {
        let now = Date(timeIntervalSince1970: 1_710_000_000)

        XCTAssertFalse(
            BackupPolicy.shouldUploadAutomatically(
                localSnapshotExists: false,
                snapshotHash: "hash-a",
                latestCloudBackup: nil,
                now: now
            )
        )

        XCTAssertFalse(
            BackupPolicy.shouldUploadAutomatically(
                localSnapshotExists: true,
                snapshotHash: "hash-a",
                latestCloudBackup: BackupMetadata(
                    createdAt: now.addingTimeInterval(-4_000),
                    snapshotHash: "hash-a",
                    schemaVersion: 1,
                    appVersion: "1.0",
                    buildNumber: "1"
                ),
                now: now
            )
        )

        XCTAssertTrue(
            BackupPolicy.shouldUploadAutomatically(
                localSnapshotExists: true,
                snapshotHash: "hash-b",
                latestCloudBackup: BackupMetadata(
                    createdAt: now.addingTimeInterval(-(25 * 60 * 60)),
                    snapshotHash: "hash-a",
                    schemaVersion: 1,
                    appVersion: "1.0",
                    buildNumber: "1"
                ),
                now: now
            )
        )
    }

    func testRestorePromptIsShownForMissingLocalSnapshot() {
        let cloudBackup = BackupMetadata(
            createdAt: Date(timeIntervalSince1970: 1_710_000_000),
            snapshotHash: "hash-a",
            schemaVersion: 1,
            appVersion: "1.0",
            buildNumber: "1"
        )

        let prompt = BackupPolicy.restorePrompt(
            localSnapshotExists: false,
            localSnapshotModifiedAt: nil,
            cloudBackup: cloudBackup,
            dismissedSnapshotHash: nil
        )

        XCTAssertEqual(prompt?.kind, .emptyLocal)
    }

    func testRestorePromptIsShownWhenCloudBackupIsNewerThanLocal() {
        let prompt = BackupPolicy.restorePrompt(
            localSnapshotExists: true,
            localSnapshotModifiedAt: Date(timeIntervalSince1970: 1_710_000_000),
            cloudBackup: BackupMetadata(
                createdAt: Date(timeIntervalSince1970: 1_710_000_100),
                snapshotHash: "hash-a",
                schemaVersion: 1,
                appVersion: "1.0",
                buildNumber: "1"
            ),
            dismissedSnapshotHash: nil
        )

        XCTAssertEqual(prompt?.kind, .cloudNewerThanLocal)
    }

    func testRestorePromptIsSuppressedAfterDismissalUntilCloudChanges() {
        let cloudBackup = BackupMetadata(
            createdAt: Date(timeIntervalSince1970: 1_710_000_100),
            snapshotHash: "hash-a",
            schemaVersion: 1,
            appVersion: "1.0",
            buildNumber: "1"
        )

        let prompt = BackupPolicy.restorePrompt(
            localSnapshotExists: true,
            localSnapshotModifiedAt: Date(timeIntervalSince1970: 1_710_000_000),
            cloudBackup: cloudBackup,
            dismissedSnapshotHash: "hash-a"
        )

        XCTAssertNil(prompt)
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
