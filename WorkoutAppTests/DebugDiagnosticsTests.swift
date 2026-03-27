import Foundation
import XCTest
@testable import WorkoutApp

final class DebugDiagnosticsTests: XCTestCase {
    func testDebugEventStoreTrimsLogsAndNetworkTracesToConfiguredRingBuffer() {
        let eventStore = DebugEventStore(maxLogEntries: 2, maxNetworkEntries: 2)
        let recorder = DebugEventRecorder(store: eventStore)

        recorder.log(category: .backup, message: "first")
        recorder.log(category: .backup, message: "second")
        recorder.log(category: .backup, message: "third")

        recorder.traceNetwork(
            method: "GET",
            path: "/one",
            statusCode: 200,
            durationMs: 10,
            startedAt: Date(timeIntervalSince1970: 1),
            requestID: nil,
            clientRequestID: nil,
            errorDescription: nil
        )
        recorder.traceNetwork(
            method: "GET",
            path: "/two",
            statusCode: 200,
            durationMs: 12,
            startedAt: Date(timeIntervalSince1970: 2),
            requestID: nil,
            clientRequestID: nil,
            errorDescription: nil
        )
        recorder.traceNetwork(
            method: "GET",
            path: "/three",
            statusCode: 200,
            durationMs: 14,
            startedAt: Date(timeIntervalSince1970: 3),
            requestID: nil,
            clientRequestID: nil,
            errorDescription: nil
        )

        let snapshot = eventStore.snapshot()

        XCTAssertEqual(snapshot.logs.map(\.message), ["second", "third"])
        XCTAssertEqual(snapshot.networkTraces.map(\.path), ["/two", "/three"])
    }

    func testRecorderSanitizesSensitiveMetadataAndNetworkPath() {
        let eventStore = DebugEventStore()
        let recorder = DebugEventRecorder(store: eventStore)

        recorder.log(
            category: .coach,
            message: "chat_job_failed",
            metadata: [
                "hasQuestion": "true",
                "recentTurnsCount": "4",
                "includedInlineSnapshot": "false",
                "hasProgramComment": "true",
                "question": "How should I train today?",
                "answer": "Lift heavy today.",
                "token": "secret-token",
                "snapshot": "{\"profile\":\"secret\"}",
                "programComment": "Sensitive coach note",
                "url": "https://example.com/v1/coach/chat?token=secret"
            ]
        )
        recorder.traceNetwork(
            method: "post",
            path: "https://example.com/v1/coach/chat?installID=abc&token=secret",
            statusCode: 500,
            durationMs: 88,
            startedAt: Date(timeIntervalSince1970: 5),
            requestID: "req-123",
            clientRequestID: "client-123",
            errorDescription: "Bearer secret-token"
        )

        let snapshot = eventStore.snapshot()
        let log = try XCTUnwrap(snapshot.logs.first)
        let trace = try XCTUnwrap(snapshot.networkTraces.first)

        XCTAssertEqual(log.metadata["hasQuestion"], "true")
        XCTAssertEqual(log.metadata["recentTurnsCount"], "4")
        XCTAssertEqual(log.metadata["includedInlineSnapshot"], "false")
        XCTAssertEqual(log.metadata["hasProgramComment"], "true")
        XCTAssertNil(log.metadata["question"])
        XCTAssertNil(log.metadata["answer"])
        XCTAssertNil(log.metadata["token"])
        XCTAssertNil(log.metadata["snapshot"])
        XCTAssertNil(log.metadata["programComment"])
        XCTAssertEqual(log.metadata["url"], "/v1/coach/chat")
        XCTAssertEqual(trace.method, "POST")
        XCTAssertEqual(trace.path, "/v1/coach/chat")
        XCTAssertEqual(trace.errorDescription, "redacted")
    }

    @MainActor
    func testDiagnosticsReportBuilderMasksDisplayValuesAndKeepsFullExportValues() {
        let suiteName = "DebugDiagnosticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let localStateStore = CoachLocalStateStore(
            defaults: defaults,
            generatedInstallID: "install-abcdef1234567890",
            identityVault: InMemoryCoachIdentityVault()
        )
        let remoteHead = CloudBackupHead(
            installID: localStateStore.installID,
            backupVersion: 12,
            backupHash: "hash-abcdef1234567890",
            r2Key: "backup-key",
            uploadedAt: Date(timeIntervalSince1970: 10),
            clientSourceModifiedAt: nil,
            selectedProgramID: nil,
            programComment: "",
            coachStateVersion: 1,
            schemaVersion: 1,
            compression: "none",
            sizeBytes: 512
        )

        let eventStore = DebugEventStore()
        let appStore = AppStore()
        let configuration = CoachRuntimeConfiguration(
            isFeatureEnabled: true,
            backendBaseURL: URL(string: "https://example.com"),
            internalBearerToken: "super-secret"
        )
        let client = DebugDiagnosticsTestClient()
        let cloudSyncStore = CloudSyncStore(
            client: client,
            configuration: configuration,
            installID: localStateStore.installID,
            localStateStore: CloudSyncLocalStateStore(defaults: defaults)
        )
        cloudSyncStore.lastBackupStatus = CloudBackupStatusResponse(
            syncState: .remoteReady,
            contextState: .contextReady,
            reasonCodes: ["hash_match"],
            actions: CloudBackupStatusActions(
                canUseRemoteAIContextNow: true,
                shouldUpload: false,
                shouldOfferRestore: false,
                shouldBuildInlineFallback: false,
                shouldPromptUser: false
            ),
            authMode: .secretValid,
            remote: remoteHead
        )
        cloudSyncStore.lastSyncErrorDescription = "sync failed"
        cloudSyncStore.pendingRemoteRestore = CloudPendingRemoteRestore(
            mode: .conflict,
            response: CloudBackupDownloadResponse(
                remote: remoteHead,
                backup: CloudBackupEnvelope(
                    schemaVersion: 1,
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

        let coachStore = CoachStore(
            client: client,
            configuration: configuration,
            localStateStore: localStateStore,
            cloudSyncStore: cloudSyncStore
        )
        let workoutSummaryStore = WorkoutSummaryStore(
            client: client,
            configuration: configuration,
            localStateStore: localStateStore
        )
        coachStore.activeChatJobID = "job-abcdef1234567890"
        coachStore.lastChatErrorDescription = "chat failed"
        coachStore.lastInsightsErrorDescription = "insights failed"

        let builder = DebugDiagnosticsReportBuilder(
            eventStore: eventStore,
            appStoreProvider: { appStore },
            coachStoreProvider: { coachStore },
            workoutSummaryStoreProvider: { workoutSummaryStore },
            cloudSyncStoreProvider: { cloudSyncStore },
            coachLocalStateStoreProvider: { localStateStore },
            runtimeConfigurationProvider: { configuration }
        )

        let report = builder.buildReport()
        let exportPayload = builder.buildExportPayload()

        XCTAssertEqual(report.runtime.installID?.displayValueMasked, "instal…7890")
        XCTAssertEqual(report.runtime.installID?.copyValueFull, "install-abcdef1234567890")
        XCTAssertEqual(exportPayload.runtime.installID, "install-abcdef1234567890")
        XCTAssertEqual(report.cloudSync.remoteBackupVersion, 12)
        XCTAssertEqual(exportPayload.cloudSync.remoteBackupVersion, 12)
        XCTAssertEqual(report.cloudSync.pendingRemoteRestoreState, "conflict@v12")
    }

    @MainActor
    func testHTTPTracingCaptures2xx4xxAnd5xxRequestIdentifiers() async throws {
        let eventStore = DebugEventStore()
        let recorder = DebugEventRecorder(store: eventStore)
        let configuration = CoachRuntimeConfiguration(
            isFeatureEnabled: true,
            backendBaseURL: URL(string: "https://example.com"),
            internalBearerToken: "token"
        )

        let successSession = makeStubSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = try JSONEncoder.withISO8601.encode(
                CloudBackupStatusResponse(
                    syncState: .remoteReady,
                    contextState: .contextReady,
                    reasonCodes: ["hash_match"],
                    actions: CloudBackupStatusActions(
                        canUseRemoteAIContextNow: true,
                        shouldUpload: false,
                        shouldOfferRestore: false,
                        shouldBuildInlineFallback: false,
                        shouldPromptUser: false
                    ),
                    authMode: .secretValid,
                    remote: nil
                )
            )
            return (response, body)
        }

        let successClient = CoachAPIHTTPClient(
            configuration: configuration,
            session: successSession,
            profileInsightsSession: successSession,
            chatSession: successSession,
            debugRecorder: recorder
        )
        _ = try await successClient.getBackupStatus(
            CloudBackupStatusRequest(
                installID: "install-1",
                localBackupHash: "hash",
                localSourceModifiedAt: Date(timeIntervalSince1970: 10),
                localStateKind: .userData
            )
        )

        let conflictSession = makeStubSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 409,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {
              "error": {
                "code": "chat_job_in_progress",
                "message": "Coach chat job already in progress.",
                "requestID": "req-409"
              },
              "jobID": "job-1",
              "provider": "gemini"
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let conflictClient = CoachAPIHTTPClient(
            configuration: configuration,
            session: conflictSession,
            profileInsightsSession: conflictSession,
            chatSession: conflictSession,
            debugRecorder: recorder
        )

        do {
            _ = try await conflictClient.getChatJob(jobID: "job-1", installID: "install-1")
            XCTFail("Expected 409 error")
        } catch let error as CoachClientError {
            XCTAssertEqual(error.requestID, "req-409")
            XCTAssertEqual(error.activeChatJobProvider, .gemini)
        }

        let serverErrorSession = makeStubSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {
              "error": {
                "code": "internal_error",
                "message": "Internal server error.",
                "requestID": "req-500"
              }
            }
            """.data(using: .utf8)!
            return (response, body)
        }

        let serverErrorClient = CoachAPIHTTPClient(
            configuration: configuration,
            session: serverErrorSession,
            profileInsightsSession: serverErrorSession,
            chatSession: serverErrorSession,
            debugRecorder: recorder
        )

        do {
            try await serverErrorClient.recordRestoreDecision(
                CloudBackupRestoreDecisionRequest(
                    installID: "install-1",
                    remoteVersion: 1,
                    localBackupHash: "hash",
                    action: .ignore
                )
            )
            XCTFail("Expected 500 error")
        } catch let error as CoachClientError {
            XCTAssertEqual(error.requestID, "req-500")
        }

        let traces = eventStore.snapshot().networkTraces
        XCTAssertEqual(traces.count, 3)
        XCTAssertEqual(traces[0].path, "/v1/backup/status")
        XCTAssertEqual(traces[0].statusCode, 200)
        XCTAssertNil(traces[0].errorDescription)
        XCTAssertEqual(traces[1].path, "/v2/coach/chat-jobs/job-1")
        XCTAssertEqual(traces[1].statusCode, 409)
        XCTAssertEqual(traces[1].requestID, "req-409")
        XCTAssertEqual(traces[2].path, "/v1/backup/restore-decision")
        XCTAssertEqual(traces[2].statusCode, 500)
        XCTAssertEqual(traces[2].requestID, "req-500")
    }

    @MainActor
    func testPrepareDebugPayloadExportCreatesTemporaryFileAndCleanupRemovesIt() throws {
        let eventStore = DebugEventStore()
        let builder = DebugDiagnosticsReportBuilder(
            eventStore: eventStore,
            appStoreProvider: { AppStore() },
            coachStoreProvider: {
                CoachStore(
                    client: DebugDiagnosticsTestClient(),
                    configuration: CoachRuntimeConfiguration(
                        isFeatureEnabled: true,
                        backendBaseURL: URL(string: "https://example.com"),
                        internalBearerToken: "token"
                    )
                )
            },
            workoutSummaryStoreProvider: {
                WorkoutSummaryStore(
                    client: DebugDiagnosticsTestClient(),
                    configuration: CoachRuntimeConfiguration(
                        isFeatureEnabled: true,
                        backendBaseURL: URL(string: "https://example.com"),
                        internalBearerToken: "token"
                    )
                )
            },
            cloudSyncStoreProvider: {
                CloudSyncStore(
                    client: DebugDiagnosticsTestClient(),
                    configuration: CoachRuntimeConfiguration(
                        isFeatureEnabled: true,
                        backendBaseURL: URL(string: "https://example.com"),
                        internalBearerToken: "token"
                    ),
                    installID: "install-1"
                )
            },
            coachLocalStateStoreProvider: { CoachLocalStateStore(generatedInstallID: "install-1") },
            cloudSyncLocalStateStoreProvider: { CloudSyncLocalStateStore() },
            runtimeConfigurationProvider: {
                CoachRuntimeConfiguration(
                    isFeatureEnabled: true,
                    backendBaseURL: URL(string: "https://example.com"),
                    internalBearerToken: "token"
                )
            }
        )
        let controller = DebugDiagnosticsController(
            reportBuilder: builder,
            eventStore: eventStore,
            healthCheckService: DebugHealthCheckService(
                runtimeConfigurationProvider: {
                    CoachRuntimeConfiguration(
                        isFeatureEnabled: true,
                        backendBaseURL: URL(string: "https://example.com"),
                        internalBearerToken: "token"
                    )
                },
                debugRecorder: NoopDebugEventRecorder()
            )
        )

        controller.prepareDebugPayloadExport()
        let payload = try XCTUnwrap(controller.sharePayload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.fileURL.path))
        XCTAssertEqual(payload.fileURL.pathExtension, "json")

        controller.clearPreparedExport()
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.fileURL.path))
    }

    private func makeStubSession(
        handler: @escaping StubURLProtocol.Handler
    ) -> URLSession {
        StubURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor DebugDiagnosticsTestClient: CoachAPIClient {
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

    func getChatJob(jobID: String, installID: String) async throws -> CoachChatJobStatusResponse {
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

private final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    static var requestHandler: Handler?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension JSONEncoder {
    static var withISO8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
