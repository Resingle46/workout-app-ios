import Foundation
import Observation
import UIKit

protocol DebugEventRecording: Sendable {
    func log(
        category: DebugLogCategory,
        level: DebugLogLevel,
        message: String,
        metadata: [String: String]
    )

    func traceNetwork(
        method: String,
        path: String,
        statusCode: Int?,
        durationMs: Int,
        startedAt: Date,
        requestID: String?,
        clientRequestID: String?,
        errorDescription: String?
    )
}

extension DebugEventRecording {
    func log(
        category: DebugLogCategory,
        level: DebugLogLevel = .info,
        message: String,
        metadata: [String: String] = [:]
    ) {
        log(
            category: category,
            level: level,
            message: message,
            metadata: metadata
        )
    }
}

enum DebugLogCategory: String, Codable, Hashable, Sendable {
    case appLifecycle = "app_lifecycle"
    case backup = "backup"
    case cloudSync = "cloud_sync"
    case coach = "coach"
    case network = "network"
    case developerMenu = "developer_menu"
}

enum DebugLogLevel: String, Codable, Hashable, Sendable {
    case info
    case warning
    case error
}

struct DebugLogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    var category: DebugLogCategory
    var level: DebugLogLevel
    var message: String
    var metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        category: DebugLogCategory,
        level: DebugLogLevel,
        message: String,
        metadata: [String: String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}

struct DebugNetworkTrace: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var method: String
    var path: String
    var statusCode: Int?
    var durationMs: Int
    var startedAt: Date
    var requestID: String?
    var clientRequestID: String?
    var errorDescription: String?

    init(
        id: UUID = UUID(),
        method: String,
        path: String,
        statusCode: Int?,
        durationMs: Int,
        startedAt: Date,
        requestID: String?,
        clientRequestID: String?,
        errorDescription: String?
    ) {
        self.id = id
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.startedAt = startedAt
        self.requestID = requestID
        self.clientRequestID = clientRequestID
        self.errorDescription = errorDescription
    }
}

struct DebugEventSnapshot: Codable, Hashable, Sendable {
    var logs: [DebugLogEntry]
    var networkTraces: [DebugNetworkTrace]
}

struct NoopDebugEventRecorder: DebugEventRecording {
    func log(
        category _: DebugLogCategory,
        level _: DebugLogLevel,
        message _: String,
        metadata _: [String: String]
    ) {}

    func traceNetwork(
        method _: String,
        path _: String,
        statusCode _: Int?,
        durationMs _: Int,
        startedAt _: Date,
        requestID _: String?,
        clientRequestID _: String?,
        errorDescription _: String?
    ) {}
}

final class DebugEventStore: @unchecked Sendable {
    private let maxLogEntries: Int
    private let maxNetworkEntries: Int
    private let lock = NSLock()
    private var logs: [DebugLogEntry] = []
    private var networkTraces: [DebugNetworkTrace] = []

    init(
        maxLogEntries: Int = 400,
        maxNetworkEntries: Int = 400
    ) {
        self.maxLogEntries = max(1, maxLogEntries)
        self.maxNetworkEntries = max(1, maxNetworkEntries)
    }

    func recordLog(_ entry: DebugLogEntry) {
        lock.withLock {
            logs.append(entry)
            trim(&logs, limit: maxLogEntries)
        }
    }

    func recordNetworkTrace(_ trace: DebugNetworkTrace) {
        lock.withLock {
            networkTraces.append(trace)
            trim(&networkTraces, limit: maxNetworkEntries)
        }
    }

    func snapshot() -> DebugEventSnapshot {
        lock.withLock {
            DebugEventSnapshot(logs: logs, networkTraces: networkTraces)
        }
    }

    func clearAll() {
        lock.withLock {
            logs.removeAll(keepingCapacity: true)
            networkTraces.removeAll(keepingCapacity: true)
        }
    }

    private func trim<Entry>(_ entries: inout [Entry], limit: Int) {
        guard entries.count > limit else {
            return
        }

        entries.removeFirst(entries.count - limit)
    }
}

struct DebugEventRecorder: DebugEventRecording, Sendable {
    private let store: DebugEventStore

    init(store: DebugEventStore) {
        self.store = store
    }

    func log(
        category: DebugLogCategory,
        level: DebugLogLevel,
        message: String,
        metadata: [String: String]
    ) {
        let sanitizedMessage = DebugDiagnosticsSanitizer.sanitizeMessage(message)
        guard !sanitizedMessage.isEmpty else {
            return
        }

        let sanitizedMetadata = DebugDiagnosticsSanitizer.sanitizeMetadata(metadata)
        store.recordLog(
            DebugLogEntry(
                category: category,
                level: level,
                message: sanitizedMessage,
                metadata: sanitizedMetadata
            )
        )
    }

    func traceNetwork(
        method: String,
        path: String,
        statusCode: Int?,
        durationMs: Int,
        startedAt: Date,
        requestID: String?,
        clientRequestID: String?,
        errorDescription: String?
    ) {
        store.recordNetworkTrace(
            DebugNetworkTrace(
                method: method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                path: DebugDiagnosticsSanitizer.sanitizePath(path),
                statusCode: statusCode,
                durationMs: max(0, durationMs),
                startedAt: startedAt,
                requestID: DebugDiagnosticsSanitizer.sanitizeIdentifier(requestID),
                clientRequestID: DebugDiagnosticsSanitizer.sanitizeIdentifier(clientRequestID),
                errorDescription: DebugDiagnosticsSanitizer.sanitizeMessage(errorDescription)
            )
        )
    }
}

enum DebugDiagnosticsSanitizer {
    private static let sensitiveKeyFragments = [
        "authorization",
        "bearer",
        "token",
        "cookie",
        "snapshot",
        "body",
        "question",
        "answer",
        "programcomment",
        "program_comment"
    ]
    private static let sensitiveValueFragments = [
        "bearer ",
        "token=",
        "authorization:",
        "cookie=",
        "\"snapshot\"",
        "\"question\"",
        "\"answer\"",
        "\"programcomment\"",
        "\"program_comment\""
    ]
    private static let maxMessageLength = 180
    private static let maxMetadataValueLength = 96
    private static let maxIdentifierLength = 128

    static func sanitizeMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [String: String]()) { result, item in
            let key = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !isSensitiveKey(key) else {
                return
            }

            let sanitizedValue = sanitizeMetadataValue(item.value)
            guard !sanitizedValue.isEmpty else {
                return
            }

            result[key] = sanitizedValue
        }
    }

    static func sanitizeMessage(_ value: String?) -> String {
        guard let value else {
            return ""
        }

        let collapsed = collapseWhitespace(value)
        guard !collapsed.isEmpty else {
            return ""
        }

        if containsSensitiveValue(collapsed) {
            return "redacted"
        }

        if collapsed.count > maxMessageLength {
            return String(collapsed.prefix(maxMessageLength)) + "..."
        }

        return collapsed
    }

    static func sanitizeIdentifier(_ value: String?) -> String? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            return nil
        }

        if containsSensitiveValue(value) {
            return nil
        }

        if value.count > maxIdentifierLength {
            return String(value.prefix(maxIdentifierLength))
        }

        return value
    }

    static func sanitizePath(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "/"
        }

        if let url = URL(string: trimmed), let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizePath(path)
        }

        if let pathOnly = trimmed.split(separator: "?", maxSplits: 1).first {
            return normalizePath(String(pathOnly))
        }

        return normalizePath(trimmed)
    }

    static func mask(_ value: String?) -> DebugMaskedValue? {
        guard let fullValue = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            return nil
        }

        if fullValue.count <= 12 {
            return DebugMaskedValue(
                displayValueMasked: fullValue,
                copyValueFull: fullValue
            )
        }

        return DebugMaskedValue(
            displayValueMasked: "\(fullValue.prefix(6))…\(fullValue.suffix(4))",
            copyValueFull: fullValue
        )
    }

    private static func sanitizeMetadataValue(_ value: String) -> String {
        let collapsed = collapseWhitespace(value)
        guard !collapsed.isEmpty else {
            return ""
        }

        let sanitizedValue = sanitizePathIfURLLike(collapsed)

        if containsSensitiveValue(sanitizedValue) {
            return "redacted"
        }

        if sanitizedValue.count > maxMetadataValueLength {
            return String(sanitizedValue.prefix(maxMetadataValueLength)) + "..."
        }

        return sanitizedValue
    }

    private static func sanitizePathIfURLLike(_ value: String) -> String {
        if value.contains("://") || value.hasPrefix("/") {
            return sanitizePath(value)
        }

        return value
    }

    private static func normalizePath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "/"
        }

        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func containsSensitiveValue(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            return false
        }

        return sensitiveValueFragments.contains(where: { normalized.contains($0) })
    }

    private static func isSensitiveKey(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        guard !normalized.isEmpty else {
            return false
        }

        return sensitiveKeyFragments.contains { fragment in
            normalized ==
                fragment
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
        }
    }
}

struct DebugMaskedValue: Codable, Hashable, Sendable {
    var displayValueMasked: String
    var copyValueFull: String?
}

struct DebugDiagnosticsReport: Codable, Hashable, Sendable {
    struct RuntimeSection: Codable, Hashable, Sendable {
        var appVersion: String
        var buildNumber: String
        var installID: DebugMaskedValue?
        var installSecretReady: Bool
        var identityStorageMode: String?
        var backendBaseURL: String?
        var remoteCoachAvailable: Bool
        var selectedAIProvider: String?
    }

    struct CloudSyncSection: Codable, Hashable, Sendable {
        var syncState: String?
        var contextState: String?
        var remoteBackupVersion: Int?
        var installAuthMode: String?
        var pendingRemoteRestoreState: String?
        var lastSyncError: String?
    }

    struct CoachSection: Codable, Hashable, Sendable {
        var activeChatJobID: DebugMaskedValue?
        var activeChatProvider: String?
        var pendingWorkoutSummaryProvider: String?
        var canResumePendingChatJob: Bool
        var lastChatError: String?
        var lastChatProvider: String?
        var lastInsightsError: String?
        var lastInsightsProvider: String?
        var lastWorkoutSummaryProvider: String?
    }

    var generatedAt: Date
    var runtime: RuntimeSection
    var cloudSync: CloudSyncSection
    var coach: CoachSection
    var network: [DebugNetworkTrace]
    var logs: [DebugLogEntry]

    static let empty = DebugDiagnosticsReport(
        generatedAt: .now,
        runtime: RuntimeSection(
            appVersion: BackupConstants.appVersion,
            buildNumber: BackupConstants.buildNumber,
            installID: nil,
            installSecretReady: false,
            identityStorageMode: nil,
            backendBaseURL: nil,
            remoteCoachAvailable: false,
            selectedAIProvider: nil
        ),
        cloudSync: CloudSyncSection(
            syncState: nil,
            contextState: nil,
            remoteBackupVersion: nil,
            installAuthMode: nil,
            pendingRemoteRestoreState: nil,
            lastSyncError: nil
        ),
        coach: CoachSection(
            activeChatJobID: nil,
            activeChatProvider: nil,
            pendingWorkoutSummaryProvider: nil,
            canResumePendingChatJob: false,
            lastChatError: nil,
            lastChatProvider: nil,
            lastInsightsError: nil,
            lastInsightsProvider: nil,
            lastWorkoutSummaryProvider: nil
        ),
        network: [],
        logs: []
    )
}

struct DebugDiagnosticsExportPayload: Codable, Hashable, Sendable {
    struct RuntimeSection: Codable, Hashable, Sendable {
        var appVersion: String
        var buildNumber: String
        var installID: String?
        var installSecretReady: Bool
        var identityStorageMode: String?
        var backendBaseURL: String?
        var remoteCoachAvailable: Bool
        var selectedAIProvider: String?
    }

    struct CloudSyncSection: Codable, Hashable, Sendable {
        var syncState: String?
        var contextState: String?
        var remoteBackupVersion: Int?
        var installAuthMode: String?
        var pendingRemoteRestoreState: String?
        var lastSyncError: String?
    }

    struct CoachSection: Codable, Hashable, Sendable {
        var activeChatJobID: String?
        var activeChatProvider: String?
        var pendingWorkoutSummaryProvider: String?
        var canResumePendingChatJob: Bool
        var lastChatError: String?
        var lastChatProvider: String?
        var lastInsightsError: String?
        var lastInsightsProvider: String?
        var lastWorkoutSummaryProvider: String?
    }

    var generatedAt: Date
    var runtime: RuntimeSection
    var cloudSync: CloudSyncSection
    var coach: CoachSection
    var network: [DebugNetworkTrace]
    var logs: [DebugLogEntry]
}

@MainActor
final class DebugDiagnosticsReportBuilder {
    private let eventStore: DebugEventStore
    private let appStoreProvider: @MainActor () -> AppStore
    private let coachStoreProvider: @MainActor () -> CoachStore
    private let workoutSummaryStoreProvider: @MainActor () -> WorkoutSummaryStore
    private let cloudSyncStoreProvider: @MainActor () -> CloudSyncStore
    private let coachLocalStateStoreProvider: () -> CoachLocalStateStore
    private let runtimeConfigurationProvider: () -> CoachRuntimeConfiguration

    init(
        eventStore: DebugEventStore,
        appStoreProvider: @escaping @MainActor () -> AppStore,
        coachStoreProvider: @escaping @MainActor () -> CoachStore,
        workoutSummaryStoreProvider: @escaping @MainActor () -> WorkoutSummaryStore,
        cloudSyncStoreProvider: @escaping @MainActor () -> CloudSyncStore,
        coachLocalStateStoreProvider: @escaping () -> CoachLocalStateStore,
        runtimeConfigurationProvider: @escaping () -> CoachRuntimeConfiguration
    ) {
        self.eventStore = eventStore
        self.appStoreProvider = appStoreProvider
        self.coachStoreProvider = coachStoreProvider
        self.workoutSummaryStoreProvider = workoutSummaryStoreProvider
        self.cloudSyncStoreProvider = cloudSyncStoreProvider
        self.coachLocalStateStoreProvider = coachLocalStateStoreProvider
        self.runtimeConfigurationProvider = runtimeConfigurationProvider
    }

    func buildReport() -> DebugDiagnosticsReport {
        let snapshot = eventStore.snapshot()
        _ = appStoreProvider()
        let runtimeConfiguration = runtimeConfigurationProvider()
        let coachStore = coachStoreProvider()
        let workoutSummaryStore = workoutSummaryStoreProvider()
        let cloudSyncStore = cloudSyncStoreProvider()
        let coachLocalStateStore = coachLocalStateStoreProvider()

        return DebugDiagnosticsReport(
            generatedAt: .now,
            runtime: DebugDiagnosticsReport.RuntimeSection(
                appVersion: BackupConstants.appVersion,
                buildNumber: BackupConstants.buildNumber,
                installID: DebugDiagnosticsSanitizer.mask(coachLocalStateStore.installID),
                installSecretReady: coachLocalStateStore.isKeychainBackedIdentityReady,
                identityStorageMode: coachLocalStateStore.identityStorageMode,
                backendBaseURL: runtimeConfiguration.backendBaseURL?.absoluteString,
                remoteCoachAvailable: runtimeConfiguration.canUseRemoteCoach,
                selectedAIProvider: runtimeConfiguration.provider.rawValue
            ),
            cloudSync: DebugDiagnosticsReport.CloudSyncSection(
                syncState: cloudSyncStore.lastBackupStatus?.syncState.rawValue,
                contextState: cloudSyncStore.lastBackupStatus?.contextState.rawValue,
                remoteBackupVersion: cloudSyncStore.lastBackupStatus?.remote?.backupVersion,
                installAuthMode: cloudSyncStore.lastBackupStatus?.authMode.rawValue,
                pendingRemoteRestoreState: pendingRestoreState(from: cloudSyncStore.pendingRemoteRestore),
                lastSyncError: DebugDiagnosticsSanitizer.sanitizeMessage(
                    cloudSyncStore.lastSyncErrorDescription
                ).nilIfEmpty
            ),
            coach: DebugDiagnosticsReport.CoachSection(
                activeChatJobID: DebugDiagnosticsSanitizer.mask(coachStore.activeChatJobID),
                activeChatProvider: coachStore.activeChatProvider?.rawValue,
                pendingWorkoutSummaryProvider: workoutSummaryStore.pendingProviderDebugValue,
                canResumePendingChatJob: coachStore.canResumePendingChatJob,
                lastChatError: DebugDiagnosticsSanitizer.sanitizeMessage(
                    coachStore.lastChatErrorDescription
                ).nilIfEmpty,
                lastChatProvider: coachStore.lastChatProvider?.rawValue,
                lastInsightsError: DebugDiagnosticsSanitizer.sanitizeMessage(
                    coachStore.lastInsightsErrorDescription
                ).nilIfEmpty,
                lastInsightsProvider: coachStore.lastInsightsProvider?.rawValue,
                lastWorkoutSummaryProvider: workoutSummaryStore.lastSummaryProvider?.rawValue
            ),
            network: Array(snapshot.networkTraces.reversed()),
            logs: Array(snapshot.logs.reversed())
        )
    }

    func buildExportPayload() -> DebugDiagnosticsExportPayload {
        let snapshot = eventStore.snapshot()
        _ = appStoreProvider()
        let runtimeConfiguration = runtimeConfigurationProvider()
        let coachStore = coachStoreProvider()
        let workoutSummaryStore = workoutSummaryStoreProvider()
        let cloudSyncStore = cloudSyncStoreProvider()
        let coachLocalStateStore = coachLocalStateStoreProvider()

        return DebugDiagnosticsExportPayload(
            generatedAt: .now,
            runtime: DebugDiagnosticsExportPayload.RuntimeSection(
                appVersion: BackupConstants.appVersion,
                buildNumber: BackupConstants.buildNumber,
                installID: coachLocalStateStore.installID,
                installSecretReady: coachLocalStateStore.isKeychainBackedIdentityReady,
                identityStorageMode: coachLocalStateStore.identityStorageMode,
                backendBaseURL: runtimeConfiguration.backendBaseURL?.absoluteString,
                remoteCoachAvailable: runtimeConfiguration.canUseRemoteCoach,
                selectedAIProvider: runtimeConfiguration.provider.rawValue
            ),
            cloudSync: DebugDiagnosticsExportPayload.CloudSyncSection(
                syncState: cloudSyncStore.lastBackupStatus?.syncState.rawValue,
                contextState: cloudSyncStore.lastBackupStatus?.contextState.rawValue,
                remoteBackupVersion: cloudSyncStore.lastBackupStatus?.remote?.backupVersion,
                installAuthMode: cloudSyncStore.lastBackupStatus?.authMode.rawValue,
                pendingRemoteRestoreState: pendingRestoreState(from: cloudSyncStore.pendingRemoteRestore),
                lastSyncError: DebugDiagnosticsSanitizer.sanitizeMessage(
                    cloudSyncStore.lastSyncErrorDescription
                ).nilIfEmpty
            ),
            coach: DebugDiagnosticsExportPayload.CoachSection(
                activeChatJobID: coachStore.activeChatJobID,
                activeChatProvider: coachStore.activeChatProvider?.rawValue,
                pendingWorkoutSummaryProvider: workoutSummaryStore.pendingProviderDebugValue,
                canResumePendingChatJob: coachStore.canResumePendingChatJob,
                lastChatError: DebugDiagnosticsSanitizer.sanitizeMessage(
                    coachStore.lastChatErrorDescription
                ).nilIfEmpty,
                lastChatProvider: coachStore.lastChatProvider?.rawValue,
                lastInsightsError: DebugDiagnosticsSanitizer.sanitizeMessage(
                    coachStore.lastInsightsErrorDescription
                ).nilIfEmpty,
                lastInsightsProvider: coachStore.lastInsightsProvider?.rawValue,
                lastWorkoutSummaryProvider: workoutSummaryStore.lastSummaryProvider?.rawValue
            ),
            network: Array(snapshot.networkTraces.reversed()),
            logs: Array(snapshot.logs.reversed())
        )
    }

    func buildExportJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(buildExportPayload())
        return String(decoding: data, as: UTF8.self)
    }

    var canPingHealth: Bool {
        runtimeConfigurationProvider().backendBaseURL != nil
    }

    private func pendingRestoreState(from pending: CloudPendingRemoteRestore?) -> String? {
        guard let pending else {
            return nil
        }

        let modeDescription: String
        switch pending.mode {
        case .restore:
            modeDescription = "restore"
        case .conflict:
            modeDescription = "conflict"
        }

        return "\(modeDescription)@v\(pending.response.remote.backupVersion)"
    }
}

struct DebugSharePayload: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let fileURL: URL

    init(title: String, fileURL: URL) {
        self.id = UUID()
        self.title = title
        self.fileURL = fileURL
    }
}

struct DebugHealthCheckResult: Sendable {
    var statusCode: Int?
    var summary: String
}

struct DebugHealthCheckService: Sendable {
    private let runtimeConfigurationProvider: @Sendable () -> CoachRuntimeConfiguration
    private let debugRecorder: any DebugEventRecording
    private let session: URLSession

    init(
        runtimeConfigurationProvider: @escaping @Sendable () -> CoachRuntimeConfiguration,
        debugRecorder: any DebugEventRecording,
        session: URLSession = .shared
    ) {
        self.runtimeConfigurationProvider = runtimeConfigurationProvider
        self.debugRecorder = debugRecorder
        self.session = session
    }

    var canPingHealth: Bool {
        runtimeConfigurationProvider().backendBaseURL != nil
    }

    func pingHealth() async -> DebugHealthCheckResult {
        let configuration = runtimeConfigurationProvider()
        guard let baseURL = configuration.backendBaseURL else {
            debugRecorder.log(
                category: .developerMenu,
                level: .warning,
                message: "health_ping_skipped",
                metadata: ["reason": "missing_base_url"]
            )
            return DebugHealthCheckResult(
                statusCode: nil,
                summary: debugDiagnosticsLocalizedString("developer.status.health_unavailable")
            )
        }

        let startedAt = Date()
        let url = baseURL.appending(path: "health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let healthStatus = parseHealthStatus(from: data)

            debugRecorder.traceNetwork(
                method: "GET",
                path: "/health",
                statusCode: statusCode,
                durationMs: durationMs,
                startedAt: startedAt,
                requestID: nil,
                clientRequestID: nil,
                errorDescription: nil
            )
            debugRecorder.log(
                category: .developerMenu,
                level: (statusCode ?? 500) >= 400 ? .warning : .info,
                message: "health_ping_completed",
                metadata: [
                    "statusCode": statusCode.map(String.init) ?? "none",
                    "healthStatus": healthStatus ?? "unknown"
                ]
            )

            let summary = [
                healthStatus.map { "status=\($0)" },
                statusCode.map { "http=\($0)" }
            ]
            .compactMap { $0 }
            .joined(separator: ", ")

            return DebugHealthCheckResult(
                statusCode: statusCode,
                summary: summary.isEmpty
                    ? debugDiagnosticsLocalizedString("developer.status.health_completed")
                    : summary
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            let description = DebugDiagnosticsSanitizer.sanitizeMessage(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
            debugRecorder.traceNetwork(
                method: "GET",
                path: "/health",
                statusCode: nil,
                durationMs: durationMs,
                startedAt: startedAt,
                requestID: nil,
                clientRequestID: nil,
                errorDescription: description.nilIfEmpty
            )
            debugRecorder.log(
                category: .developerMenu,
                level: .error,
                message: "health_ping_failed",
                metadata: ["error": description]
            )
            return DebugHealthCheckResult(
                statusCode: nil,
                summary: description.nilIfEmpty
                    ?? debugDiagnosticsLocalizedString("developer.status.health_failed")
            )
        }
    }

    private func parseHealthStatus(from data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = payload["status"] as? String else {
            return nil
        }

        return status.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

@MainActor
@Observable
final class DebugDiagnosticsController {
    var report: DebugDiagnosticsReport = .empty
    var isPingingHealth = false
    var actionStatusMessage: String?
    var sharePayload: DebugSharePayload?

    @ObservationIgnored private let reportBuilder: DebugDiagnosticsReportBuilder
    @ObservationIgnored private let eventStore: DebugEventStore
    @ObservationIgnored private let healthCheckService: DebugHealthCheckService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileManager: FileManager

    init(
        reportBuilder: DebugDiagnosticsReportBuilder,
        eventStore: DebugEventStore,
        healthCheckService: DebugHealthCheckService,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.reportBuilder = reportBuilder
        self.eventStore = eventStore
        self.healthCheckService = healthCheckService
        self.defaults = defaults
        self.fileManager = fileManager
        self.report = reportBuilder.buildReport()
    }

    var canPingHealth: Bool {
        healthCheckService.canPingHealth
    }

    func refreshReport() {
        report = reportBuilder.buildReport()
    }

    func clearDebugData() {
        eventStore.clearAll()
        refreshReport()
        actionStatusMessage = debugDiagnosticsLocalizedString("developer.status.logs_cleared")
    }

    func copyValue(_ value: String?) {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            return
        }

        UIPasteboard.general.string = value
        actionStatusMessage = debugDiagnosticsLocalizedString("developer.status.copied")
    }

    func copyDebugPayload() {
        do {
            let payload = try reportBuilder.buildExportJSON()
            UIPasteboard.general.string = payload
            actionStatusMessage = debugDiagnosticsLocalizedString("developer.status.payload_copied")
        } catch {
            actionStatusMessage = debugDiagnosticsLocalizedString("developer.status.payload_failed")
        }
    }

    func prepareDebugPayloadExport() {
        do {
            clearPreparedExport()
            let title = "WorkoutApp-DebugReport.json"
            let fileURL = try writeTemporaryExportFile(
                title: title,
                text: reportBuilder.buildExportJSON()
            )
            sharePayload = DebugSharePayload(
                title: title,
                fileURL: fileURL
            )
            actionStatusMessage = debugDiagnosticsLocalizedString("developer.status.payload_prepared")
        } catch {
            actionStatusMessage = debugDiagnosticsLocalizedString("developer.status.payload_failed")
        }
    }

    func clearPreparedExport() {
        if let fileURL = sharePayload?.fileURL {
            try? fileManager.removeItem(at: fileURL.deletingLastPathComponent())
            try? fileManager.removeItem(at: fileURL)
        }
        sharePayload = nil
    }

    private func writeTemporaryExportFile(title: String, text: String) throws -> URL {
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("WorkoutApp-DebugExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent(title, isDirectory: false)
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    func pingHealth() async {
        guard !isPingingHealth else {
            return
        }

        isPingingHealth = true
        defer { isPingingHealth = false }

        let result = await healthCheckService.pingHealth()
        refreshReport()
        actionStatusMessage = result.summary
    }

    func hideDeveloperMenu() {
        defaults.set(false, forKey: DeveloperMenuPreferences.unlockKey)
    }
}

enum DeveloperMenuPreferences {
    static let unlockKey = "developer_menu.unlocked"
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}

private func debugDiagnosticsLocalizedString(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
