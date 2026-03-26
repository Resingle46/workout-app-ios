import XCTest
@testable import WorkoutApp

final class WorkoutSummaryFeatureTests: XCTestCase {
    @MainActor
    func testFinalFingerprintIgnoresCompletionTimestamps() throws {
        let exercise = makeExercise(name: "Bench Press")
        let baseSetID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000001")!
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000010")!
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let sessionA = WorkoutSession(
            id: sessionID,
            workoutTemplateID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000020")!,
            title: "Push",
            startedAt: startedAt,
            endedAt: Date(timeIntervalSince1970: 1_700_000_600),
            exercises: [
                WorkoutExerciseLog(
                    templateExerciseID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000030")!,
                    exerciseID: exercise.id,
                    groupKind: .regular,
                    groupID: nil,
                    sets: [
                        WorkoutSetLog(
                            id: baseSetID,
                            reps: 8,
                            weight: 80,
                            completedAt: Date(timeIntervalSince1970: 1_700_000_100)
                        )
                    ]
                )
            ]
        )

        var sessionB = sessionA
        sessionB.endedAt = Date(timeIntervalSince1970: 1_700_010_000)
        sessionB.exercises[0].sets[0].completedAt = Date(timeIntervalSince1970: 1_700_010_100)

        let store = makeAppStore(exercises: [exercise], history: [])
        let requestA = try WorkoutSummaryRequestBuilder.finalRequest(
            for: sessionA,
            using: store,
            installID: "install-1"
        )
        let requestB = try WorkoutSummaryRequestBuilder.finalRequest(
            for: sessionB,
            using: store,
            installID: "install-1"
        )

        XCTAssertEqual(requestA.fingerprint, requestB.fingerprint)
    }

    @MainActor
    func testPrewarmProjectedFinalMarksSingleRemainingSetCompleted() throws {
        let exercise = makeExercise(name: "Squat")
        let session = WorkoutSession(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000040")!,
            workoutTemplateID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000041")!,
            title: "Legs",
            startedAt: Date(timeIntervalSince1970: 1_700_100_000),
            endedAt: nil,
            exercises: [
                WorkoutExerciseLog(
                    templateExerciseID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000042")!,
                    exerciseID: exercise.id,
                    groupKind: .regular,
                    groupID: nil,
                    sets: [
                        WorkoutSetLog(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000043")!,
                            reps: 6,
                            weight: 100,
                            completedAt: Date(timeIntervalSince1970: 1_700_100_120)
                        ),
                        WorkoutSetLog(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000044")!,
                            reps: 6,
                            weight: 100,
                            completedAt: nil
                        )
                    ]
                )
            ]
        )

        let store = makeAppStore(exercises: [exercise], history: [])
        let preparedRequest = try XCTUnwrap(
            WorkoutSummaryRequestBuilder.prewarmRequest(
                for: session,
                using: store,
                installID: "install-1"
            )
        )

        XCTAssertEqual(preparedRequest.request.trigger, .prewarmOneRemainingSet)
        XCTAssertEqual(preparedRequest.request.currentWorkout.completedSetsCount, 2)
        XCTAssertEqual(preparedRequest.request.currentWorkout.totalSetsCount, 2)
        XCTAssertEqual(
            preparedRequest.request.currentWorkout.exercises[0].sets.map(\.isCompleted),
            [true, true]
        )
    }

    @MainActor
    func testRecentExerciseHistoryExcludesCurrentSessionAndKeepsLatestThree() throws {
        let bench = makeExercise(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000050")!, name: "Bench Press")
        let currentSession = makeSession(
            sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000051")!,
            workoutTemplateID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000052")!,
            title: "Push A",
            exercise: bench,
            weight: 80,
            reps: 8,
            startedAt: Date(timeIntervalSince1970: 1_700_200_000),
            completed: true
        )
        let historySessions = [
            currentSession,
            makeSession(
                sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000053")!,
                workoutTemplateID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000054")!,
                title: "Push B",
                exercise: bench,
                weight: 82.5,
                reps: 8,
                startedAt: Date(timeIntervalSince1970: 1_700_190_000),
                completed: true
            ),
            makeSession(
                sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000055")!,
                workoutTemplateID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000056")!,
                title: "Push C",
                exercise: bench,
                weight: 85,
                reps: 7,
                startedAt: Date(timeIntervalSince1970: 1_700_180_000),
                completed: true
            ),
            makeSession(
                sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000057")!,
                workoutTemplateID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000058")!,
                title: "Push D",
                exercise: bench,
                weight: 87.5,
                reps: 6,
                startedAt: Date(timeIntervalSince1970: 1_700_170_000),
                completed: true
            ),
            makeSession(
                sessionID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000059")!,
                workoutTemplateID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000060")!,
                title: "Push E",
                exercise: bench,
                weight: 90,
                reps: 5,
                startedAt: Date(timeIntervalSince1970: 1_700_160_000),
                completed: true
            )
        ]
        let store = makeAppStore(exercises: [bench], history: historySessions)

        let request = try WorkoutSummaryRequestBuilder.finalRequest(
            for: currentSession,
            using: store,
            installID: "install-1"
        )
        let benchHistory = try XCTUnwrap(request.request.recentExerciseHistory.first)

        XCTAssertEqual(benchHistory.sessions.count, 3)
        XCTAssertEqual(
            benchHistory.sessions.map(\.sessionID),
            [
                UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000053")!,
                UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000055")!,
                UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000057")!
            ]
        )
    }

    @MainActor
    func testFinalizeReusesPreparedResultWithoutSecondCreate() async throws {
        let bench = makeExercise(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000070")!, name: "Bench Press")
        let activeSession = WorkoutSession(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000071")!,
            workoutTemplateID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000072")!,
            title: "Push",
            startedAt: Date(timeIntervalSince1970: 1_700_300_000),
            endedAt: nil,
            exercises: [
                WorkoutExerciseLog(
                    templateExerciseID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000073")!,
                    exerciseID: bench.id,
                    groupKind: .regular,
                    groupID: nil,
                    sets: [
                        WorkoutSetLog(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000074")!,
                            reps: 8,
                            weight: 80,
                            completedAt: Date(timeIntervalSince1970: 1_700_300_120)
                        ),
                        WorkoutSetLog(
                            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-000000000075")!,
                            reps: 8,
                            weight: 80,
                            completedAt: nil
                        )
                    ]
                )
            ]
        )
        var finishedSession = activeSession
        finishedSession.endedAt = Date(timeIntervalSince1970: 1_700_300_600)
        finishedSession.exercises[0].sets[1].completedAt = Date(timeIntervalSince1970: 1_700_300_300)

        let store = makeAppStore(exercises: [bench], history: [])
        let suiteName = "WorkoutSummaryFeatureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let localStateStore = CoachLocalStateStore(defaults: defaults, generatedInstallID: "install-test")
        let prewarmRequest = try XCTUnwrap(
            WorkoutSummaryRequestBuilder.prewarmRequest(
                for: activeSession,
                using: store,
                installID: localStateStore.installID
            )
        )
        let expectedResult = WorkoutSummaryJobResult(
            headline: "Strong close",
            summary: "You closed the workout cleanly.",
            highlights: ["All planned sets were completed."],
            nextWorkoutFocus: ["Add load only if the last set stays solid."],
            generationStatus: .model,
            inferenceMode: .structured,
            modelDurationMs: 1200,
            totalJobDurationMs: 1500
        )
        let client = WorkoutSummaryTestClient(
            createResponse: WorkoutSummaryJobCreateResponse(
                jobID: "job-1",
                sessionID: activeSession.id,
                fingerprint: prewarmRequest.fingerprint,
                status: .queued,
                createdAt: .now,
                pollAfterMs: 0,
                reusedExistingJob: false
            ),
            statusResponse: WorkoutSummaryJobStatusResponse(
                jobID: "job-1",
                sessionID: activeSession.id,
                fingerprint: prewarmRequest.fingerprint,
                status: .completed,
                createdAt: .now,
                startedAt: .now,
                completedAt: .now,
                result: expectedResult,
                error: nil
            )
        )
        let summaryStore = WorkoutSummaryStore(
            client: client,
            configuration: CoachRuntimeConfiguration(
                isFeatureEnabled: true,
                backendBaseURL: URL(string: "https://example.com"),
                internalBearerToken: "token"
            ),
            localStateStore: localStateStore,
            prewarmDebounceDuration: .zero,
            maxPollingDuration: 5,
            pollIntervalProvider: { _ in 0 }
        )

        await summaryStore.maybePrewarmSummary(for: activeSession, using: store)
        try? await Task.sleep(for: .milliseconds(50))
        await summaryStore.finalizeOrResumeSummary(for: finishedSession, using: store)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(await client.createCallCount, 1)
        XCTAssertEqual(await client.statusCallCount, 1)
        XCTAssertEqual(summaryStore.cardState(for: activeSession.id), .ready(expectedResult))
    }
}

private actor WorkoutSummaryTestClient: CoachAPIClient {
    let createResponse: WorkoutSummaryJobCreateResponse
    let statusResponse: WorkoutSummaryJobStatusResponse

    private(set) var createCallCount = 0
    private(set) var statusCallCount = 0

    init(
        createResponse: WorkoutSummaryJobCreateResponse,
        statusResponse: WorkoutSummaryJobStatusResponse
    ) {
        self.createResponse = createResponse
        self.statusResponse = statusResponse
    }

    func syncSnapshot(_ request: CoachSnapshotSyncRequest) async throws -> CoachSnapshotSyncResponse {
        throw CoachClientError.invalidResponse
    }

    func reconcileBackup(_ request: CloudBackupReconcileRequest) async throws -> CloudBackupReconcileResponse {
        throw CoachClientError.invalidResponse
    }

    func uploadBackup(_ request: CloudBackupUploadRequest) async throws -> CloudBackupHead {
        throw CoachClientError.invalidResponse
    }

    func downloadBackup(installID: String, version: Int?) async throws -> CloudBackupDownloadResponse {
        throw CoachClientError.invalidResponse
    }

    func updateCoachPreferences(_ request: CloudCoachPreferencesUpdateRequest) async throws -> CloudCoachPreferencesUpdateResponse {
        throw CoachClientError.invalidResponse
    }

    func fetchProfileInsights(
        locale: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?,
        forceRefresh: Bool
    ) async throws -> CoachProfileInsights {
        throw CoachClientError.invalidResponse
    }

    func createChatJob(
        locale: String,
        question: String,
        clientRequestID: String,
        clientRecentTurns: [CoachConversationMessage],
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?
    ) async throws -> CoachChatJobCreateResponse {
        throw CoachClientError.invalidResponse
    }

    func getChatJob(
        jobID: String,
        installID: String
    ) async throws -> CoachChatJobStatusResponse {
        throw CoachClientError.invalidResponse
    }

    func createWorkoutSummaryJob(
        _ request: WorkoutSummaryJobCreateRequest
    ) async throws -> WorkoutSummaryJobCreateResponse {
        createCallCount += 1
        return createResponse
    }

    func getWorkoutSummaryJob(
        jobID: String,
        installID: String
    ) async throws -> WorkoutSummaryJobStatusResponse {
        statusCallCount += 1
        return statusResponse
    }

    func sendChat(
        locale: String,
        question: String,
        clientRecentTurns: [CoachConversationMessage],
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?
    ) async throws -> CoachChatResponse {
        throw CoachClientError.invalidResponse
    }

    func deleteRemoteState(installID: String) async throws {
        throw CoachClientError.invalidResponse
    }
}

@MainActor
private func makeAppStore(
    exercises: [Exercise],
    history: [WorkoutSession]
) -> AppStore {
    let store = AppStore()
    store.apply(snapshot: AppSnapshot(
        programs: [],
        exercises: exercises,
        history: history,
        profile: UserProfile(sex: "M", age: 29, weight: 85, height: 180, appLanguageCode: "en")
    ))
    return store
}

private func makeExercise(
    id: UUID = UUID(),
    name: String
) -> Exercise {
    Exercise(
        id: id,
        name: name,
        categoryID: SeedData.chestCategoryID,
        equipment: "Barbell",
        notes: ""
    )
}

private func makeSession(
    sessionID: UUID,
    workoutTemplateID: UUID,
    title: String,
    exercise: Exercise,
    weight: Double,
    reps: Int,
    startedAt: Date,
    completed: Bool
) -> WorkoutSession {
    WorkoutSession(
        id: sessionID,
        workoutTemplateID: workoutTemplateID,
        title: title,
        startedAt: startedAt,
        endedAt: completed ? startedAt.addingTimeInterval(600) : nil,
        exercises: [
            WorkoutExerciseLog(
                templateExerciseID: UUID(),
                exerciseID: exercise.id,
                groupKind: .regular,
                groupID: nil,
                sets: [
                    WorkoutSetLog(
                        id: UUID(),
                        reps: reps,
                        weight: weight,
                        completedAt: completed ? startedAt.addingTimeInterval(120) : nil
                    )
                ]
            )
        ]
    )
}
