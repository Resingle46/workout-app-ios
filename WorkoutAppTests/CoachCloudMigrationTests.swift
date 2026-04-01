import Foundation
import XCTest
@testable import WorkoutApp

final class CoachCloudMigrationTests: XCTestCase {
    func testCoachLocalStateStoreMigratesLegacyInstallIDFromDefaultsToKeychain() {
        let suiteName = "CoachCloudMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("legacy-install-id", forKey: "coach.runtime.install_id")
        let identityVault = InMemoryCoachIdentityVault()

        let store = CoachLocalStateStore(
            defaults: defaults,
            generatedInstallID: "generated-install-id",
            generatedInstallSecret: "generated-secret",
            identityVault: identityVault
        )

        XCTAssertEqual(store.installID, "legacy-install-id")
        XCTAssertEqual(store.identityStorageMode, "migrated_defaults_to_keychain")
        XCTAssertTrue(store.isKeychainBackedIdentityReady)
        XCTAssertEqual(
            identityVault.readValue(
                forKey: "\(Bundle.main.bundleIdentifier ?? "WorkoutApp").coach.install_id"
            ),
            "legacy-install-id"
        )
        XCTAssertEqual(
            identityVault.readValue(
                forKey: "\(Bundle.main.bundleIdentifier ?? "WorkoutApp").coach.install_secret"
            ),
            store.installSecret
        )
    }

    func testCoachLocalStateStoreBootstrapsNewIdentityWhenDefaultsAndKeychainAreEmpty() {
        let suiteName = "CoachCloudMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let identityVault = InMemoryCoachIdentityVault()
        let store = CoachLocalStateStore(
            defaults: defaults,
            generatedInstallID: "generated-install-id",
            generatedInstallSecret: "generated-secret",
            identityVault: identityVault
        )

        XCTAssertEqual(store.installID, "generated-install-id")
        XCTAssertEqual(store.installSecret, "generated-secret")
        XCTAssertEqual(store.identityStorageMode, "generated_new_identity")
        XCTAssertTrue(store.isKeychainBackedIdentityReady)
    }

    @MainActor
    func testCloudSyncStoreAdoptsRemoteBackupHashAfterSuccessfulUpload() async {
        let suiteName = "CoachCloudMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let persistence = PersistenceController()
        persistence.clearStoredSnapshot()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            persistence.clearStoredSnapshot()
        }

        let appStore = AppStore()
        appStore.apply(snapshot: AppSnapshot(
            programs: [],
            exercises: [],
            history: [],
            profile: UserProfile(
                sex: "M",
                age: 31,
                weight: 90,
                height: 182,
                appLanguageCode: "en"
            )
        ))
        let initialHash = appStore.localBackupHash
        let localStateStore = CoachLocalStateStore(
            defaults: defaults,
            generatedInstallID: "install-upload-adoption",
            generatedInstallSecret: "install-secret",
            identityVault: InMemoryCoachIdentityVault()
        )
        let statusRemote = CloudBackupHead(
            installID: localStateStore.installID,
            backupVersion: 1,
            backupHash: "remote-before-upload",
            r2Key: "installs/\(localStateStore.installID)/backups/v000001-remote-before-upload.json.gz",
            uploadedAt: Date(timeIntervalSince1970: 10),
            clientSourceModifiedAt: Date(timeIntervalSince1970: 10),
            selectedProgramID: nil,
            programComment: "",
            coachStateVersion: 1,
            schemaVersion: 2,
            compression: "gzip",
            sizeBytes: 512
        )
        let uploadedRemote = CloudBackupHead(
            installID: localStateStore.installID,
            backupVersion: 2,
            backupHash: "server-normalized-hash",
            r2Key: "installs/\(localStateStore.installID)/backups/v000002-server-normalized-hash.json.gz",
            uploadedAt: Date(timeIntervalSince1970: 20),
            clientSourceModifiedAt: Date(timeIntervalSince1970: 20),
            selectedProgramID: nil,
            programComment: "",
            coachStateVersion: 1,
            schemaVersion: 2,
            compression: "gzip",
            sizeBytes: 640
        )
        let client = StubCoachSyncClient(
            statusResponse: CloudBackupStatusResponse(
                syncState: .uploadRequired,
                contextState: .contextStale,
                reasonCodes: ["local_dirty_since_remote"],
                actions: CloudBackupStatusActions(
                    canUseRemoteAIContextNow: false,
                    shouldUpload: true,
                    shouldOfferRestore: false,
                    shouldBuildInlineFallback: true,
                    shouldPromptUser: false
                ),
                authMode: .secretValid,
                remote: statusRemote
            ),
            uploadResponse: uploadedRemote
        )
        let cloudSyncStore = CloudSyncStore(
            client: client,
            configuration: CoachRuntimeConfiguration(
                isFeatureEnabled: true,
                backendBaseURL: URL(string: "https://example.com"),
                internalBearerToken: "token"
            ),
            installID: localStateStore.installID,
            installSecretProvider: { localStateStore.installSecret },
            localStateStore: CloudSyncLocalStateStore(defaults: defaults)
        )

        let preparation = await cloudSyncStore.syncIfNeeded(using: appStore, allowUserPrompt: false)
        let reloadedStore = AppStore()

        XCTAssertNotEqual(initialHash, uploadedRemote.backupHash)
        XCTAssertEqual(appStore.localBackupHash, uploadedRemote.backupHash)
        XCTAssertEqual(preparation.localBackupHash, uploadedRemote.backupHash)
        XCTAssertTrue(preparation.canUseRemoteAIContextNow)
        XCTAssertEqual(reloadedStore.localBackupHash, uploadedRemote.backupHash)
    }

    @MainActor
    func testAppStoreCreatesRollbackCheckpointBeforeApplyingRemoteRestore() {
        let persistence = PersistenceController()
        persistence.clearRollbackCheckpoint()
        defer {
            persistence.clearRollbackCheckpoint()
        }

        let appStore = AppStore()
        let originalSnapshot = AppSnapshot(
            programs: [],
            exercises: [],
            history: [],
            profile: UserProfile(
                sex: "M",
                age: 31,
                weight: 90,
                height: 182,
                appLanguageCode: "en"
            )
        )
        appStore.apply(snapshot: originalSnapshot)

        let remoteSnapshot = AppSnapshot(
            programs: [],
            exercises: [],
            history: [],
            profile: UserProfile(
                sex: "F",
                age: 28,
                weight: 62,
                height: 168,
                appLanguageCode: "en"
            )
        )
        appStore.applyRemoteRestore(snapshot: remoteSnapshot)

        let checkpoint = persistence.loadRollbackCheckpoint()
        XCTAssertNotNil(checkpoint)
        XCTAssertEqual(checkpoint?.snapshot.profile.sex, originalSnapshot.profile.sex)
        XCTAssertEqual(appStore.profile.sex, remoteSnapshot.profile.sex)
    }

    @MainActor
    func testAppStoreDeleteHistorySessionRemovesWorkoutAndIsIdempotent() {
        let persistence = PersistenceController()
        persistence.clearStoredSnapshot()
        defer {
            persistence.clearStoredSnapshot()
        }

        let exercise = makeHistoryDeletionExercise()
        let newestSession = makeHistoryDeletionSession(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
            exerciseID: exercise.id,
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 360)
        )
        let deletedSession = makeHistoryDeletionSession(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000002")!,
            exerciseID: exercise.id,
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 260)
        )
        let oldestSession = makeHistoryDeletionSession(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000003")!,
            exerciseID: exercise.id,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 160)
        )

        let appStore = AppStore(persistence: persistence)
        appStore.apply(snapshot: AppSnapshot(
            programs: [],
            exercises: [exercise],
            history: [deletedSession, oldestSession, newestSession],
            profile: .empty
        ))

        XCTAssertTrue(appStore.deleteHistorySession(id: deletedSession.id))
        XCTAssertEqual(appStore.history.map(\.id), [newestSession.id, oldestSession.id])
        XCTAssertEqual(appStore.lastFinishedSession?.id, newestSession.id)
        XCTAssertFalse(appStore.deleteHistorySession(id: deletedSession.id))
    }

    @MainActor
    func testAppStoreDeleteHistorySessionRecomputesLastFinishedSession() {
        let persistence = PersistenceController()
        persistence.clearStoredSnapshot()
        defer {
            persistence.clearStoredSnapshot()
        }

        let exercise = makeHistoryDeletionExercise()
        let newestSession = makeHistoryDeletionSession(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!,
            exerciseID: exercise.id,
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 360)
        )
        let olderSession = makeHistoryDeletionSession(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000002")!,
            exerciseID: exercise.id,
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 260)
        )

        let appStore = AppStore(persistence: persistence)
        appStore.apply(snapshot: AppSnapshot(
            programs: [],
            exercises: [exercise],
            history: [olderSession, newestSession],
            profile: .empty
        ))

        XCTAssertEqual(appStore.lastFinishedSession?.id, newestSession.id)
        XCTAssertTrue(appStore.deleteHistorySession(id: newestSession.id))
        XCTAssertEqual(appStore.lastFinishedSession?.id, olderSession.id)
        XCTAssertTrue(appStore.deleteHistorySession(id: olderSession.id))
        XCTAssertNil(appStore.lastFinishedSession)
        XCTAssertTrue(appStore.history.isEmpty)
    }

    @MainActor
    func testAppStoreDeleteHistorySessionPersistsEmptyHistory() {
        let persistence = PersistenceController()
        persistence.clearStoredSnapshot()
        defer {
            persistence.clearStoredSnapshot()
        }

        let exercise = makeHistoryDeletionExercise()
        let onlySession = makeHistoryDeletionSession(
            id: UUID(uuidString: "72000000-0000-0000-0000-000000000001")!,
            exerciseID: exercise.id,
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 360)
        )

        let appStore = AppStore(persistence: persistence)
        appStore.apply(snapshot: AppSnapshot(
            programs: [],
            exercises: [exercise],
            history: [onlySession],
            profile: .empty
        ))

        XCTAssertTrue(appStore.deleteHistorySession(id: onlySession.id))

        let reloadedStore = AppStore(persistence: persistence)
        XCTAssertTrue(reloadedStore.history.isEmpty)
        XCTAssertNil(reloadedStore.lastFinishedSession)
    }

    @MainActor
    func testCloudSyncStoreSyncSnapshotAfterLocalMutationUploadsHistoryWithoutDeletedWorkout() async {
        let suiteName = "CoachCloudMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let persistence = PersistenceController()
        persistence.clearStoredSnapshot()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            persistence.clearStoredSnapshot()
        }

        let localStateStore = CoachLocalStateStore(
            defaults: defaults,
            generatedInstallID: "install-delete-sync",
            generatedInstallSecret: "install-secret",
            identityVault: InMemoryCoachIdentityVault()
        )
        let client = RecordingHistoryDeletionSyncClient(installID: localStateStore.installID)
        let cloudSyncStore = CloudSyncStore(
            client: client,
            configuration: CoachRuntimeConfiguration(
                isFeatureEnabled: true,
                backendBaseURL: URL(string: "https://example.com"),
                internalBearerToken: "token"
            ),
            installID: localStateStore.installID,
            installSecretProvider: { localStateStore.installSecret },
            localStateStore: CloudSyncLocalStateStore(defaults: defaults)
        )
        let exercise = makeHistoryDeletionExercise()
        let keptSession = makeHistoryDeletionSession(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000001")!,
            exerciseID: exercise.id,
            startedAt: Date(timeIntervalSince1970: 300),
            endedAt: Date(timeIntervalSince1970: 360)
        )
        let deletedSession = makeHistoryDeletionSession(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000002")!,
            exerciseID: exercise.id,
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 260)
        )

        let appStore = AppStore(persistence: persistence)
        appStore.apply(snapshot: AppSnapshot(
            programs: [],
            exercises: [exercise],
            history: [keptSession, deletedSession],
            profile: .empty
        ))
        XCTAssertTrue(appStore.deleteHistorySession(id: deletedSession.id))

        let result = await cloudSyncStore.syncSnapshotAfterLocalMutation(using: appStore)
        let uploadRequests = await client.uploadRequests

        XCTAssertTrue(result.attemptedRemoteSync)
        XCTAssertTrue(result.remoteUpdated)
        XCTAssertNil(result.errorDescription)
        XCTAssertEqual(uploadRequests.count, 1)
        XCTAssertEqual(uploadRequests.first?.snapshot.history.map(\.id), [keptSession.id])
    }

    @MainActor
    func testCloudSyncStoreDismissesPendingRemoteRestoreAndMarksContextStale() async {
        let suiteName = "CoachCloudMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let localStateStore = CoachLocalStateStore(
            defaults: defaults,
            generatedInstallID: "install-dismiss-restore",
            generatedInstallSecret: "install-secret",
            identityVault: InMemoryCoachIdentityVault()
        )
        let client = RecordingCoachRemoteMaintenanceClient()
        let cloudSyncStore = CloudSyncStore(
            client: client,
            configuration: CoachRuntimeConfiguration(
                isFeatureEnabled: true,
                backendBaseURL: URL(string: "https://example.com"),
                internalBearerToken: "token"
            ),
            installID: localStateStore.installID,
            installSecretProvider: { localStateStore.installSecret },
            localStateStore: CloudSyncLocalStateStore(defaults: defaults)
        )

        let remoteHead = CloudBackupHead(
            installID: localStateStore.installID,
            backupVersion: 7,
            backupHash: "remote-hash",
            r2Key: "installs/\(localStateStore.installID)/backups/v000007-remote-hash.json.gz",
            uploadedAt: Date(timeIntervalSince1970: 10),
            clientSourceModifiedAt: nil,
            selectedProgramID: nil,
            programComment: "",
            coachStateVersion: 2,
            schemaVersion: 2,
            compression: "gzip",
            sizeBytes: 1024
        )
        cloudSyncStore.pendingRemoteRestore = CloudPendingRemoteRestore(
            mode: .restore,
            response: CloudBackupDownloadResponse(
                remote: remoteHead,
                backup: CloudBackupEnvelope(
                    schemaVersion: 2,
                    installID: localStateStore.installID,
                    backupHash: remoteHead.backupHash,
                    uploadedAt: remoteHead.uploadedAt,
                    clientSourceModifiedAt: nil,
                    appVersion: "1.0",
                    buildNumber: "1",
                    snapshot: AppSnapshot(
                        programs: [],
                        exercises: [],
                        history: [],
                        profile: .empty
                    )
                )
            ),
            localBackupHash: "local-hash"
        )

        await cloudSyncStore.dismissPendingRemoteRestore()

        XCTAssertNil(cloudSyncStore.pendingRemoteRestore)
        XCTAssertEqual(cloudSyncStore.lastBackupStatus?.syncState, .remoteNewerThanLocal)
        XCTAssertEqual(cloudSyncStore.lastBackupStatus?.contextState, .contextStale)
        let recordedDecisions = await client.recordedRestoreDecisions
        XCTAssertEqual(recordedDecisions.last?.action, .ignore)
    }

    @MainActor
    func testCoachStoreClearRemoteConversationClearsLocalTranscriptAndCallsServer() async {
        let localStateStore = CoachLocalStateStore(
            defaults: UserDefaults(suiteName: "CoachCloudMigrationTests.\(UUID().uuidString)")!,
            generatedInstallID: "install-clear-remote-chat",
            generatedInstallSecret: "install-secret",
            identityVault: InMemoryCoachIdentityVault()
        )
        let client = RecordingCoachRemoteMaintenanceClient()
        let configuration = CoachRuntimeConfiguration(
            isFeatureEnabled: true,
            backendBaseURL: URL(string: "https://example.com"),
            internalBearerToken: "token"
        )
        let cloudSyncStore = CloudSyncStore(
            client: client,
            configuration: configuration,
            installID: localStateStore.installID,
            installSecretProvider: { localStateStore.installSecret },
            localStateStore: CloudSyncLocalStateStore(defaults: localStateStore.userDefaults)
        )
        let coachStore = CoachStore(
            client: client,
            configuration: configuration,
            localStateStore: localStateStore,
            cloudSyncStore: cloudSyncStore
        )
        coachStore.messages = [
            CoachChatMessage(role: .user, content: "Hello"),
            CoachChatMessage(role: .assistant, content: "Hi")
        ]

        await coachStore.clearRemoteConversation()

        XCTAssertTrue(coachStore.messages.isEmpty)
        let clearRequests = await client.recordedMemoryClearRequests
        XCTAssertEqual(clearRequests.count, 1)
        XCTAssertEqual(clearRequests.first?.installID, localStateStore.installID)
        XCTAssertEqual(clearRequests.first?.providerID, "workers_ai")
        XCTAssertEqual(clearRequests.first?.clearInsightsCache, true)
    }

    @MainActor
    func testPersistedPendingChatJobIsIgnoredForDifferentInstallAfterRelaunch() {
        let suiteName = "CoachCloudMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let persistedState = [
            "jobID": "job-123",
            "installID": "old-install",
            "pollStartedAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 10)),
            "nextPollAfterMs": 1500,
            "providerID": "workers_ai"
        ] as [String: Any]
        let data = try! JSONSerialization.data(withJSONObject: persistedState, options: [])
        defaults.set(data, forKey: "coach.runtime.pending_chat_job_state")

        let localStateStore = CoachLocalStateStore(
            defaults: defaults,
            generatedInstallID: "new-install",
            generatedInstallSecret: "install-secret",
            identityVault: InMemoryCoachIdentityVault()
        )
        let coachStore = CoachStore(
            client: RecordingCoachRemoteMaintenanceClient(),
            configuration: CoachRuntimeConfiguration(
                isFeatureEnabled: true,
                backendBaseURL: URL(string: "https://example.com"),
                internalBearerToken: "token"
            ),
            localStateStore: localStateStore
        )

        XCTAssertNil(coachStore.activeChatJobID)
        XCTAssertNil(defaults.data(forKey: "coach.runtime.pending_chat_job_state"))
    }
}

final class InMemoryCoachIdentityVault: CoachIdentityVault, @unchecked Sendable {
    private var storage: [String: String] = [:]

    func readValue(forKey key: String) -> String? {
        storage[key]
    }

    @discardableResult
    func writeValue(_ value: String, forKey key: String) -> Bool {
        storage[key] = value
        return true
    }

    func deleteValue(forKey key: String) {
        storage.removeValue(forKey: key)
    }
}

private func makeHistoryDeletionExercise() -> Exercise {
    Exercise(
        id: UUID(uuidString: "7A000000-0000-0000-0000-000000000001")!,
        name: "Bench Press",
        categoryID: SeedData.chestCategoryID,
        equipment: "Barbell",
        notes: ""
    )
}

private func makeHistoryDeletionSession(
    id: UUID,
    exerciseID: UUID,
    startedAt: Date,
    endedAt: Date?
) -> WorkoutSession {
    WorkoutSession(
        id: id,
        workoutTemplateID: UUID(uuidString: "7B000000-0000-0000-0000-000000000001")!,
        title: "Push",
        startedAt: startedAt,
        endedAt: endedAt,
        exercises: [
            WorkoutExerciseLog(
                templateExerciseID: UUID(uuidString: "7C000000-0000-0000-0000-000000000001")!,
                exerciseID: exerciseID,
                groupKind: .regular,
                groupID: nil,
                sets: [
                    WorkoutSetLog(
                        id: UUID(uuidString: "7D000000-0000-0000-0000-000000000001")!,
                        reps: 5,
                        weight: 100,
                        completedAt: endedAt
                    )
                ]
            )
        ]
    )
}

private actor RecordingCoachRemoteMaintenanceClient: CoachAPIClient {
    private(set) var recordedRestoreDecisions: [CloudBackupRestoreDecisionRequest] = []
    private(set) var recordedMemoryClearRequests: [CloudCoachMemoryClearRequest] = []

    func getBackupStatus(_ request: CloudBackupStatusRequest) async throws -> CloudBackupStatusResponse {
        throw CoachClientError.invalidResponse
    }

    func uploadBackup(_ request: CloudBackupUploadRequest) async throws -> CloudBackupHead {
        throw CoachClientError.invalidResponse
    }

    func downloadBackup(installID: String, version: Int?) async throws -> CloudBackupDownloadResponse {
        throw CoachClientError.invalidResponse
    }

    func recordRestoreDecision(_ request: CloudBackupRestoreDecisionRequest) async throws {
        recordedRestoreDecisions.append(request)
    }

    func clearRemoteChatMemory(_ request: CloudCoachMemoryClearRequest) async throws {
        recordedMemoryClearRequests.append(request)
    }

    func deleteRemoteBackup(installID: String) async throws {
        throw CoachClientError.invalidResponse
    }

    func updateCoachPreferences(
        _ request: CloudCoachPreferencesUpdateRequest
    ) async throws -> CloudCoachPreferencesUpdateResponse {
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
        throw CoachClientError.invalidResponse
    }

    func getWorkoutSummaryJob(
        jobID: String,
        installID: String
    ) async throws -> WorkoutSummaryJobStatusResponse {
        throw CoachClientError.invalidResponse
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

private actor RecordingHistoryDeletionSyncClient: CoachAPIClient {
    let installID: String
    private(set) var uploadRequests: [CloudBackupUploadRequest] = []

    init(installID: String) {
        self.installID = installID
    }

    func getBackupStatus(_ request: CloudBackupStatusRequest) async throws -> CloudBackupStatusResponse {
        CloudBackupStatusResponse(
            syncState: .uploadRequired,
            contextState: .contextStale,
            reasonCodes: ["local_dirty_since_remote"],
            actions: CloudBackupStatusActions(
                canUseRemoteAIContextNow: false,
                shouldUpload: true,
                shouldOfferRestore: false,
                shouldBuildInlineFallback: true,
                shouldPromptUser: false
            ),
            authMode: .secretValid,
            remote: nil
        )
    }

    func uploadBackup(_ request: CloudBackupUploadRequest) async throws -> CloudBackupHead {
        uploadRequests.append(request)
        let backupHash = request.backupHash ?? "history-delete-hash"
        return CloudBackupHead(
            installID: installID,
            backupVersion: 1,
            backupHash: backupHash,
            r2Key: "installs/\(installID)/backups/v000001-\(backupHash).json.gz",
            uploadedAt: request.clientSourceModifiedAt ?? .now,
            clientSourceModifiedAt: request.clientSourceModifiedAt,
            selectedProgramID: request.snapshot.coachAnalysisSettings.selectedProgramID,
            programComment: request.snapshot.coachAnalysisSettings.programComment,
            coachStateVersion: 1,
            schemaVersion: 2,
            compression: "gzip",
            sizeBytes: 1024
        )
    }

    func downloadBackup(installID: String, version: Int?) async throws -> CloudBackupDownloadResponse {
        throw CoachClientError.invalidResponse
    }

    func recordRestoreDecision(_ request: CloudBackupRestoreDecisionRequest) async throws {}

    func clearRemoteChatMemory(_ request: CloudCoachMemoryClearRequest) async throws {}

    func deleteRemoteBackup(installID: String) async throws {}

    func updateCoachPreferences(
        _ request: CloudCoachPreferencesUpdateRequest
    ) async throws -> CloudCoachPreferencesUpdateResponse {
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
        throw CoachClientError.invalidResponse
    }

    func getWorkoutSummaryJob(
        jobID: String,
        installID: String
    ) async throws -> WorkoutSummaryJobStatusResponse {
        throw CoachClientError.invalidResponse
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

private actor StubCoachSyncClient: CoachAPIClient {
    let statusResponse: CloudBackupStatusResponse
    let uploadResponse: CloudBackupHead

    init(
        statusResponse: CloudBackupStatusResponse,
        uploadResponse: CloudBackupHead
    ) {
        self.statusResponse = statusResponse
        self.uploadResponse = uploadResponse
    }

    func getBackupStatus(_ request: CloudBackupStatusRequest) async throws -> CloudBackupStatusResponse {
        statusResponse
    }

    func uploadBackup(_ request: CloudBackupUploadRequest) async throws -> CloudBackupHead {
        uploadResponse
    }

    func downloadBackup(installID: String, version: Int?) async throws -> CloudBackupDownloadResponse {
        throw CoachClientError.invalidResponse
    }

    func recordRestoreDecision(_ request: CloudBackupRestoreDecisionRequest) async throws {}

    func clearRemoteChatMemory(_ request: CloudCoachMemoryClearRequest) async throws {}

    func deleteRemoteBackup(installID: String) async throws {}

    func updateCoachPreferences(
        _ request: CloudCoachPreferencesUpdateRequest
    ) async throws -> CloudCoachPreferencesUpdateResponse {
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
        throw CoachClientError.invalidResponse
    }

    func getWorkoutSummaryJob(
        jobID: String,
        installID: String
    ) async throws -> WorkoutSummaryJobStatusResponse {
        throw CoachClientError.invalidResponse
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
