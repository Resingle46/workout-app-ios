import CryptoKit
import Foundation
import Observation
import SwiftUI
import UIKit

struct CoachRuntimeConfiguration: Hashable, Sendable {
    var isFeatureEnabled: Bool
    var backendBaseURL: URL?
    var internalBearerToken: String?

    init(isFeatureEnabled: Bool, backendBaseURL: URL?, internalBearerToken: String? = nil) {
        self.isFeatureEnabled = isFeatureEnabled
        self.backendBaseURL = backendBaseURL
        self.internalBearerToken = internalBearerToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    init(bundle: Bundle) {
        let infoDictionary = bundle.infoDictionary ?? [:]
        let isFeatureEnabled = Self.parseBoolean(infoDictionary["CoachFeatureEnabled"])
        let baseURLString = (infoDictionary["CoachBackendBaseURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let internalBearerToken = (infoDictionary["CoachInternalBearerToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            isFeatureEnabled: isFeatureEnabled,
            backendBaseURL: Self.parseBackendBaseURL(baseURLString),
            internalBearerToken: internalBearerToken
        )
    }

    var canUseRemoteCoach: Bool {
        isFeatureEnabled && backendBaseURL != nil && internalBearerToken != nil
    }

    var backendBaseURLString: String {
        backendBaseURL?.absoluteString ?? ""
    }

    static func parseBackendBaseURL(_ value: String?) -> URL? {
        guard let trimmedValue = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty,
              let url = URL(string: trimmedValue),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host != nil else {
            return nil
        }

        return url
    }

    private static func parseBoolean(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        guard let value = value as? String else {
            return false
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }
}

final class CoachRuntimeConfigurationStore {
    var isFeatureEnabled: Bool
    var backendBaseURLText: String
    var internalBearerToken: String

    private let defaultConfiguration: CoachRuntimeConfiguration
    private let defaults: UserDefaults

    convenience init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.init(
            defaultConfiguration: CoachRuntimeConfiguration(bundle: bundle),
            defaults: defaults
        )
    }

    init(
        defaultConfiguration: CoachRuntimeConfiguration,
        defaults: UserDefaults = .standard
    ) {
        self.defaultConfiguration = defaultConfiguration
        self.defaults = defaults

        if let storedValue = defaults.object(forKey: PreferenceKey.featureEnabled) as? Bool {
            self.isFeatureEnabled = storedValue
        } else {
            self.isFeatureEnabled = defaultConfiguration.isFeatureEnabled
        }

        self.backendBaseURLText = (
            defaults.string(forKey: PreferenceKey.backendBaseURL)
            ?? defaultConfiguration.backendBaseURLString
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        self.internalBearerToken = (
            defaults.string(forKey: PreferenceKey.internalBearerToken)
            ?? defaultConfiguration.internalBearerToken
            ?? ""
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var runtimeConfiguration: CoachRuntimeConfiguration {
        CoachRuntimeConfiguration(
            isFeatureEnabled: isFeatureEnabled,
            backendBaseURL: CoachRuntimeConfiguration.parseBackendBaseURL(backendBaseURLText),
            internalBearerToken: internalBearerToken
        )
    }

    var hasLocalOverrides: Bool {
        defaults.object(forKey: PreferenceKey.featureEnabled) != nil ||
        defaults.object(forKey: PreferenceKey.backendBaseURL) != nil ||
        defaults.object(forKey: PreferenceKey.internalBearerToken) != nil
    }

    @discardableResult
    func save() -> CoachRuntimeConfiguration {
        backendBaseURLText = backendBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        internalBearerToken = internalBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)

        defaults.set(isFeatureEnabled, forKey: PreferenceKey.featureEnabled)

        if backendBaseURLText.isEmpty {
            defaults.removeObject(forKey: PreferenceKey.backendBaseURL)
        } else {
            defaults.set(backendBaseURLText, forKey: PreferenceKey.backendBaseURL)
        }

        if internalBearerToken.isEmpty {
            defaults.removeObject(forKey: PreferenceKey.internalBearerToken)
        } else {
            defaults.set(internalBearerToken, forKey: PreferenceKey.internalBearerToken)
        }

        return runtimeConfiguration
    }

    @discardableResult
    func resetToDefaults() -> CoachRuntimeConfiguration {
        defaults.removeObject(forKey: PreferenceKey.featureEnabled)
        defaults.removeObject(forKey: PreferenceKey.backendBaseURL)
        defaults.removeObject(forKey: PreferenceKey.internalBearerToken)

        isFeatureEnabled = defaultConfiguration.isFeatureEnabled
        backendBaseURLText = defaultConfiguration.backendBaseURLString
        internalBearerToken = defaultConfiguration.internalBearerToken ?? ""

        return runtimeConfiguration
    }

    private enum PreferenceKey {
        static let featureEnabled = "coach.runtime.feature_enabled"
        static let backendBaseURL = "coach.runtime.backend_base_url"
        static let internalBearerToken = "coach.runtime.internal_bearer_token"
    }
}

final class CoachLocalStateStore {
    let installID: String

    private let defaults: UserDefaults

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, generatedInstallID: UUID().uuidString)
    }

    init(defaults: UserDefaults, generatedInstallID: String) {
        self.defaults = defaults

        if let storedInstallID = defaults.string(forKey: PreferenceKey.installID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            self.installID = storedInstallID
        } else {
            self.installID = generatedInstallID
            defaults.set(generatedInstallID, forKey: PreferenceKey.installID)
        }
    }

    var lastAcceptedSnapshotHash: String? {
        defaults.string(forKey: PreferenceKey.lastAcceptedSnapshotHash)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var lastAcceptedSnapshotAt: Date? {
        defaults.object(forKey: PreferenceKey.lastAcceptedSnapshotAt) as? Date
    }

    func markSnapshotAccepted(hash: String, at date: Date = .now) {
        defaults.set(hash, forKey: PreferenceKey.lastAcceptedSnapshotHash)
        defaults.set(date, forKey: PreferenceKey.lastAcceptedSnapshotAt)
    }

    func resetSnapshotAcknowledgement() {
        defaults.removeObject(forKey: PreferenceKey.lastAcceptedSnapshotHash)
        defaults.removeObject(forKey: PreferenceKey.lastAcceptedSnapshotAt)
    }

    var userDefaults: UserDefaults {
        defaults
    }

    private enum PreferenceKey {
        static let installID = "coach.runtime.install_id"
        static let lastAcceptedSnapshotHash = "coach.runtime.last_accepted_snapshot_hash"
        static let lastAcceptedSnapshotAt = "coach.runtime.last_accepted_snapshot_at"
    }
}

final class CloudSyncLocalStateStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastSyncedRemoteVersion: Int? {
        integer(forKey: PreferenceKey.lastSyncedRemoteVersion)
    }

    var lastSyncedBackupHash: String? {
        string(forKey: PreferenceKey.lastSyncedBackupHash)
    }

    var lastKnownRemoteVersion: Int? {
        integer(forKey: PreferenceKey.lastKnownRemoteVersion)
    }

    var lastKnownRemoteBackupHash: String? {
        string(forKey: PreferenceKey.lastKnownRemoteBackupHash)
    }

    var lastAppliedRemoteVersion: Int? {
        integer(forKey: PreferenceKey.lastAppliedRemoteVersion)
    }

    var lastIgnoredRemoteVersion: Int? {
        integer(forKey: PreferenceKey.lastIgnoredRemoteVersion)
    }

    var lastAppliedLocalBackupHash: String? {
        string(forKey: PreferenceKey.lastAppliedLocalBackupHash)
    }

    func rememberRemoteHead(_ remote: CloudBackupHead?) {
        guard let remote else {
            return
        }

        defaults.set(remote.backupVersion, forKey: PreferenceKey.lastKnownRemoteVersion)
        defaults.set(remote.backupHash, forKey: PreferenceKey.lastKnownRemoteBackupHash)
    }

    func markSynced(remote: CloudBackupHead) {
        rememberRemoteHead(remote)
        defaults.set(remote.backupVersion, forKey: PreferenceKey.lastSyncedRemoteVersion)
        defaults.set(remote.backupHash, forKey: PreferenceKey.lastSyncedBackupHash)
        defaults.removeObject(forKey: PreferenceKey.lastIgnoredRemoteVersion)
    }

    func markRemoteRestoreApplied(remote: CloudBackupHead, localBackupHash: String) {
        markSynced(remote: remote)
        defaults.set(remote.backupVersion, forKey: PreferenceKey.lastAppliedRemoteVersion)
        defaults.set(remote.backupHash, forKey: PreferenceKey.lastAppliedRemoteBackupHash)
        defaults.set(localBackupHash, forKey: PreferenceKey.lastAppliedLocalBackupHash)
    }

    func canUseServerSideContext(for localBackupHash: String) -> Bool {
        (lastSyncedRemoteVersion != nil && lastSyncedBackupHash == localBackupHash) ||
        (lastAppliedRemoteVersion != nil && lastAppliedLocalBackupHash == localBackupHash)
    }

    func markIgnored(remoteVersion: Int) {
        defaults.set(remoteVersion, forKey: PreferenceKey.lastIgnoredRemoteVersion)
    }

    func resetSyncState() {
        defaults.removeObject(forKey: PreferenceKey.lastSyncedRemoteVersion)
        defaults.removeObject(forKey: PreferenceKey.lastSyncedBackupHash)
        defaults.removeObject(forKey: PreferenceKey.lastKnownRemoteVersion)
        defaults.removeObject(forKey: PreferenceKey.lastKnownRemoteBackupHash)
        defaults.removeObject(forKey: PreferenceKey.lastAppliedRemoteVersion)
        defaults.removeObject(forKey: PreferenceKey.lastAppliedRemoteBackupHash)
        defaults.removeObject(forKey: PreferenceKey.lastAppliedLocalBackupHash)
        defaults.removeObject(forKey: PreferenceKey.lastIgnoredRemoteVersion)
    }

    private func integer(forKey key: String) -> Int? {
        guard defaults.object(forKey: key) != nil else {
            return nil
        }

        let value = defaults.integer(forKey: key)
        return value > 0 ? value : nil
    }

    private func string(forKey key: String) -> String? {
        defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private enum PreferenceKey {
        static let lastSyncedRemoteVersion = "coach.cloud.last_synced_remote_version"
        static let lastSyncedBackupHash = "coach.cloud.last_synced_backup_hash"
        static let lastKnownRemoteVersion = "coach.cloud.last_known_remote_version"
        static let lastKnownRemoteBackupHash = "coach.cloud.last_known_remote_hash"
        static let lastAppliedRemoteVersion = "coach.cloud.last_applied_remote_version"
        static let lastAppliedRemoteBackupHash = "coach.cloud.last_applied_remote_hash"
        static let lastAppliedLocalBackupHash = "coach.cloud.last_applied_local_hash"
        static let lastIgnoredRemoteVersion = "coach.cloud.last_ignored_remote_version"
    }
}

enum CloudBackupHashing {
    static func hash(for snapshot: AppSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum CoachSnapshotHashing {
    static func hash(for snapshot: CompactCoachSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum CoachClientError: LocalizedError, Equatable {
    case featureDisabled
    case missingBaseURL
    case missingAuthToken
    case invalidResponse
    case httpStatus(Int)
    case api(statusCode: Int, code: String, message: String, jobID: String?)

    var errorDescription: String? {
        switch self {
        case .featureDisabled:
            return coachLocalizedString("coach.error.feature_disabled")
        case .missingBaseURL:
            return coachLocalizedString("coach.error.missing_base_url")
        case .missingAuthToken:
            return coachLocalizedString("coach.error.missing_auth_token")
        case .invalidResponse:
            return coachLocalizedString("coach.error.invalid_response")
        case .httpStatus(let code):
            return String(
                format: coachLocalizedString("coach.error.http_status"),
                code
            )
        case .api(_, _, let message, _):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? coachLocalizedString("coach.error.invalid_response")
        }
    }

    var activeChatJobID: String? {
        guard case .api(_, let code, _, let jobID) = self,
              code == "chat_job_in_progress" else {
            return nil
        }

        return jobID
    }

    var isTransientPollingFailure: Bool {
        switch self {
        case .httpStatus(let statusCode):
            return statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500
        case .api(let statusCode, let code, _, _):
            return statusCode == 408 ||
            statusCode == 425 ||
            statusCode == 429 ||
            statusCode >= 500 ||
            code.starts(with: "upstream_")
        case .invalidResponse:
            return true
        default:
            return false
        }
    }
}

enum CoachCapabilityScope: String, Codable, Hashable, Sendable {
    case draftChanges = "draft_changes"
}

enum CoachInsightsOrigin: Hashable, Sendable {
    case remote
    case fallback
}

enum CoachResponseGenerationStatus: String, Codable, Hashable, Sendable {
    case model
    case fallback
}

protocol CoachAPIClient: Sendable {
    func syncSnapshot(_ request: CoachSnapshotSyncRequest) async throws -> CoachSnapshotSyncResponse

    func reconcileBackup(_ request: CloudBackupReconcileRequest) async throws -> CloudBackupReconcileResponse

    func uploadBackup(_ request: CloudBackupUploadRequest) async throws -> CloudBackupHead

    func downloadBackup(installID: String, version: Int?) async throws -> CloudBackupDownloadResponse

    func updateCoachPreferences(_ request: CloudCoachPreferencesUpdateRequest) async throws -> CloudCoachPreferencesUpdateResponse

    func fetchProfileInsights(
        locale: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?
    ) async throws -> CoachProfileInsights

    func createChatJob(
        locale: String,
        question: String,
        clientRequestID: String,
        clientRecentTurns: [CoachConversationMessage],
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?
    ) async throws -> CoachChatJobCreateResponse

    func getChatJob(
        jobID: String,
        installID: String
    ) async throws -> CoachChatJobStatusResponse

    func sendChat(
        locale: String,
        question: String,
        clientRecentTurns: [CoachConversationMessage],
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?
    ) async throws -> CoachChatResponse

    func deleteRemoteState(installID: String) async throws
}

typealias CompactCoachSnapshot = CoachContextPayload

struct CoachSnapshotEnvelope: Hashable, Sendable {
    var installID: String
    var snapshotHash: String?
    var snapshot: CompactCoachSnapshot?
    var snapshotUpdatedAt: Date?
}

struct CoachSnapshotSyncRequest: Codable, Sendable {
    var installID: String
    var snapshotHash: String
    var snapshot: CompactCoachSnapshot
    var snapshotUpdatedAt: Date
}

struct CoachSnapshotSyncResponse: Codable, Hashable, Sendable {
    var acceptedHash: String
    var storedAt: Date
}

struct CoachProfileInsightsRequest: Codable, Sendable {
    var locale: String
    var installID: String
    var snapshotHash: String?
    var snapshot: CompactCoachSnapshot?
    var snapshotUpdatedAt: Date?
    var runtimeContextDelta: CoachRuntimeContextDelta?
    var capabilityScope: CoachCapabilityScope
}

struct CoachChatRequest: Codable, Sendable {
    var locale: String
    var question: String
    var installID: String
    var snapshotHash: String?
    var snapshot: CompactCoachSnapshot?
    var snapshotUpdatedAt: Date?
    var runtimeContextDelta: CoachRuntimeContextDelta?
    var clientRecentTurns: [CoachConversationMessage]
    var capabilityScope: CoachCapabilityScope
}

struct CoachChatJobCreateRequest: Codable, Sendable {
    var locale: String
    var question: String
    var installID: String
    var snapshotHash: String?
    var snapshot: CompactCoachSnapshot?
    var snapshotUpdatedAt: Date?
    var runtimeContextDelta: CoachRuntimeContextDelta?
    var clientRecentTurns: [CoachConversationMessage]
    var capabilityScope: CoachCapabilityScope
    var clientRequestID: String
}

enum CoachChatJobStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case completed
    case failed
    case canceled
}

enum CoachChatInferenceMode: String, Codable, Hashable, Sendable {
    case structured
    case plainTextFallback = "plain_text_fallback"
    case degradedFallback = "degraded_fallback"
}

enum CloudLocalStateKind: String, Codable, Hashable, Sendable {
    case seed
    case userData = "user_data"
}

enum CloudBackupReconcileAction: String, Codable, Hashable, Sendable {
    case upload
    case download
    case noop
    case conflict
}

struct CloudBackupHead: Codable, Hashable, Sendable {
    var installID: String
    var backupVersion: Int
    var backupHash: String
    var r2Key: String
    var uploadedAt: Date
    var clientSourceModifiedAt: Date?
    var selectedProgramID: UUID?
    var programComment: String
    var coachStateVersion: Int
    var schemaVersion: Int
    var compression: String
    var sizeBytes: Int
}

struct CloudBackupEnvelope: Codable, Sendable {
    var schemaVersion: Int
    var installID: String
    var backupHash: String
    var uploadedAt: Date
    var clientSourceModifiedAt: Date?
    var appVersion: String
    var buildNumber: String
    var snapshot: AppSnapshot
}

struct CloudBackupReconcileRequest: Codable, Sendable {
    var installID: String
    var localBackupHash: String?
    var localSourceModifiedAt: Date?
    var lastSyncedRemoteVersion: Int?
    var lastSyncedBackupHash: String?
    var localStateKind: CloudLocalStateKind
}

struct CloudBackupReconcileResponse: Codable, Hashable, Sendable {
    var action: CloudBackupReconcileAction
    var remote: CloudBackupHead?
}

struct CloudBackupUploadRequest: Codable, Sendable {
    var installID: String
    var expectedRemoteVersion: Int?
    var backupHash: String?
    var clientSourceModifiedAt: Date?
    var appVersion: String
    var buildNumber: String
    var snapshot: AppSnapshot
}

struct CloudBackupDownloadResponse: Codable, Sendable {
    var remote: CloudBackupHead
    var backup: CloudBackupEnvelope
}

struct CloudCoachPreferencesUpdateRequest: Codable, Sendable {
    var installID: String
    var selectedProgramID: UUID?
    var programComment: String
}

struct CloudCoachPreferencesUpdateResponse: Codable, Hashable, Sendable {
    var installID: String
    var selectedProgramID: UUID?
    var programComment: String
    var coachStateVersion: Int
    var updatedAt: Date
}

struct CoachProfileInsights: Codable, Hashable, Sendable {
    var summary: String
    var recommendations: [String]
    var generationStatus: CoachResponseGenerationStatus? = nil

    var isModelGenerated: Bool {
        generationStatus == .model
    }
}

struct CoachChatResponse: Codable, Hashable, Sendable {
    var answerMarkdown: String
    var responseID: String?
    var followUps: [String]
    var generationStatus: CoachResponseGenerationStatus? = nil

    var isModelGenerated: Bool {
        generationStatus == .model
    }
}

struct CoachChatJobCreateResponse: Codable, Hashable, Sendable {
    var jobID: String
    var status: CoachChatJobStatus
    var createdAt: Date
    var pollAfterMs: Int
}

struct CoachChatJobResult: Codable, Hashable, Sendable {
    var answerMarkdown: String
    var responseID: String
    var followUps: [String]
    var generationStatus: CoachResponseGenerationStatus? = nil
    var inferenceMode: CoachChatInferenceMode
    var modelDurationMs: Int?
    var totalJobDurationMs: Int?
}

struct CoachChatJobError: Codable, Hashable, Sendable {
    var code: String
    var message: String
    var retryable: Bool
}

struct CoachChatJobStatusResponse: Codable, Hashable, Sendable {
    var jobID: String
    var status: CoachChatJobStatus
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var result: CoachChatJobResult?
    var error: CoachChatJobError?
}

private struct CoachAPIErrorPayload: Codable, Hashable, Sendable {
    var code: String
    var message: String
    var requestID: String?
}

private struct CoachAPIErrorResponse: Codable, Hashable, Sendable {
    var error: CoachAPIErrorPayload
    var jobID: String?
}

struct CoachConversationMessage: Codable, Hashable, Sendable {
    var role: CoachChatRole
    var content: String
}

enum CoachChatRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
}

struct CoachChatMessage: Identifiable, Hashable, Sendable {
    var id: String
    var role: CoachChatRole
    var content: String
    var followUps: [String]
    var generationStatus: CoachResponseGenerationStatus? = nil
    var isLoading: Bool
    var isStatus: Bool

    init(
        id: String = UUID().uuidString,
        role: CoachChatRole,
        content: String,
        followUps: [String] = [],
        generationStatus: CoachResponseGenerationStatus? = nil,
        isLoading: Bool = false,
        isStatus: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.followUps = followUps
        self.generationStatus = generationStatus
        self.isLoading = isLoading
        self.isStatus = isStatus
    }
}

struct CoachContextPayload: Codable, Hashable, Sendable {
    var localeIdentifier: String
    var historyMode: String
    var profile: UserProfile
    var coachAnalysisSettings: CoachAnalysisSettings
    var preferredProgram: CoachProgramContext?
    var activeWorkout: CoachActiveWorkoutContext?
    var analytics: CoachAnalyticsContext
    var recentFinishedSessions: [CoachRecentSessionContext]
}

struct CoachProgramContext: Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var workoutCount: Int
    var workouts: [CoachWorkoutDayContext]
}

struct CoachWorkoutDayContext: Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var focus: String
    var exerciseCount: Int
    var exercises: [CoachPlannedExerciseContext]
}

struct CoachPlannedExerciseContext: Codable, Hashable, Sendable {
    var templateExerciseID: UUID
    var exerciseID: UUID
    var exerciseName: String
    var setsCount: Int
    var reps: Int
    var suggestedWeight: Double
    var groupKind: String
}

struct CoachActiveWorkoutContext: Codable, Hashable, Sendable {
    var workoutTemplateID: UUID
    var title: String
    var startedAt: Date
    var exerciseCount: Int
    var completedSetsCount: Int
    var totalSetsCount: Int
}

struct CoachRuntimeContextDelta: Codable, Hashable, Sendable {
    var activeWorkout: CoachActiveWorkoutContext?
}

struct CoachAnalyticsContext: Codable, Hashable, Sendable {
    var progress30Days: CoachProgressSnapshotContext
    var goal: CoachGoalContext
    var training: CoachTrainingRecommendationContext
    var compatibility: CoachCompatibilityContext
    var consistency: CoachConsistencyContext
    var recentPersonalRecords: [CoachPersonalRecordContext]
    var relativeStrength: [CoachRelativeStrengthContext]
}

struct CoachProgressSnapshotContext: Codable, Hashable, Sendable {
    var totalFinishedWorkouts: Int
    var recentExercisesCount: Int
    var recentVolume: Double
    var averageDurationSeconds: Double?
    var lastWorkoutDate: Date?
}

struct CoachGoalContext: Codable, Hashable, Sendable {
    var primaryGoal: String
    var currentWeight: Double
    var targetBodyWeight: Double?
    var weeklyWorkoutTarget: Int
    var safeWeeklyChangeLowerBound: Double?
    var safeWeeklyChangeUpperBound: Double?
    var etaWeeksLowerBound: Int?
    var etaWeeksUpperBound: Int?
    var usesCurrentWeightOnly: Bool
}

struct CoachTrainingRecommendationContext: Codable, Hashable, Sendable {
    var currentWeeklyTarget: Int
    var recommendedWeeklyTargetLowerBound: Int
    var recommendedWeeklyTargetUpperBound: Int
    var mainRepLowerBound: Int
    var mainRepUpperBound: Int
    var accessoryRepLowerBound: Int
    var accessoryRepUpperBound: Int
    var weeklySetsLowerBound: Int
    var weeklySetsUpperBound: Int
    var split: String
    var splitWorkoutDays: Int?
    var splitProgramTitle: String?
    var isGenericFallback: Bool
}

struct CoachCompatibilityContext: Codable, Hashable, Sendable {
    var isAligned: Bool
    var issues: [CoachCompatibilityIssueContext]
}

struct CoachCompatibilityIssueContext: Codable, Hashable, Sendable {
    var kind: String
    var message: String
}

struct CoachConsistencyContext: Codable, Hashable, Sendable {
    var workoutsThisWeek: Int
    var weeklyTarget: Int
    var streakWeeks: Int
    var mostFrequentWeekday: Int?
    var recentWeeklyActivity: [CoachWeeklyActivityContext]
}

struct CoachWeeklyActivityContext: Codable, Hashable, Sendable {
    var weekStart: Date
    var workoutsCount: Int
    var meetsTarget: Bool
}

struct CoachPersonalRecordContext: Codable, Hashable, Sendable {
    var exerciseID: UUID
    var exerciseName: String
    var achievedAt: Date
    var weight: Double
    var previousWeight: Double
    var delta: Double
}

struct CoachRelativeStrengthContext: Codable, Hashable, Sendable {
    var lift: String
    var bestLoad: Double?
    var relativeToBodyWeight: Double?
}

struct CoachRecentSessionContext: Codable, Hashable, Sendable {
    var id: UUID
    var workoutTemplateID: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double?
    var completedSetsCount: Int
    var totalVolume: Double
    var exercises: [CoachRecentSessionExerciseContext]
}

struct CoachRecentSessionExerciseContext: Codable, Hashable, Sendable {
    var templateExerciseID: UUID
    var exerciseID: UUID
    var exerciseName: String
    var groupKind: String
    var completedSetsCount: Int
    var bestWeight: Double?
    var totalVolume: Double
    var averageReps: Double?
}

struct CoachAPIHTTPClient: CoachAPIClient {
    private static let standardRequestTimeoutInterval: TimeInterval = 20
    private static let standardResourceTimeoutInterval: TimeInterval = 25
    private static let profileInsightsRequestTimeoutInterval: TimeInterval = 32
    private static let profileInsightsResourceTimeoutInterval: TimeInterval = 36
    private static let chatRequestTimeoutInterval: TimeInterval = 30
    private static let chatResourceTimeoutInterval: TimeInterval = 35

    private let configuration: CoachRuntimeConfiguration
    private let standardSession: URLSession
    private let profileInsightsSession: URLSession
    private let chatSession: URLSession

    init(
        configuration: CoachRuntimeConfiguration,
        session: URLSession? = nil,
        profileInsightsSession: URLSession? = nil,
        chatSession: URLSession? = nil
    ) {
        self.configuration = configuration
        self.standardSession = session ?? Self.makeSession(
            requestTimeoutInterval: Self.standardRequestTimeoutInterval,
            resourceTimeoutInterval: Self.standardResourceTimeoutInterval
        )
        self.profileInsightsSession = profileInsightsSession ?? Self.makeSession(
            requestTimeoutInterval: Self.profileInsightsRequestTimeoutInterval,
            resourceTimeoutInterval: Self.profileInsightsResourceTimeoutInterval
        )
        self.chatSession = chatSession ?? Self.makeSession(
            requestTimeoutInterval: Self.chatRequestTimeoutInterval,
            resourceTimeoutInterval: Self.chatResourceTimeoutInterval
        )
    }

    func syncSnapshot(_ request: CoachSnapshotSyncRequest) async throws -> CoachSnapshotSyncResponse {
        try await send(
            path: "v1/coach/snapshot",
            method: "PUT",
            body: request,
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            responseType: CoachSnapshotSyncResponse.self
        )
    }

    func reconcileBackup(_ request: CloudBackupReconcileRequest) async throws -> CloudBackupReconcileResponse {
        try await send(
            path: "v1/backup/reconcile",
            method: "POST",
            body: request,
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            responseType: CloudBackupReconcileResponse.self
        )
    }

    func uploadBackup(_ request: CloudBackupUploadRequest) async throws -> CloudBackupHead {
        try await send(
            path: "v1/backup",
            method: "PUT",
            body: request,
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            responseType: CloudBackupHead.self
        )
    }

    func downloadBackup(installID: String, version: Int?) async throws -> CloudBackupDownloadResponse {
        guard configuration.isFeatureEnabled else {
            throw CoachClientError.featureDisabled
        }
        guard let baseURL = configuration.backendBaseURL else {
            throw CoachClientError.missingBaseURL
        }
        guard let internalBearerToken = configuration.internalBearerToken else {
            throw CoachClientError.missingAuthToken
        }

        var components = URLComponents(
            url: baseURL.appending(path: "v1/backup/download"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "installID", value: installID),
            URLQueryItem(name: "version", value: version.map(String.init) ?? "current")
        ]

        guard let url = components?.url else {
            throw CoachClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.standardRequestTimeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(internalBearerToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await standardSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoachClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw Self.parseAPIErrorResponse(
                data: data,
                statusCode: httpResponse.statusCode
            )
        }

        do {
            return try Self.decoder.decode(CloudBackupDownloadResponse.self, from: data)
        } catch {
            throw CoachClientError.invalidResponse
        }
    }

    func updateCoachPreferences(_ request: CloudCoachPreferencesUpdateRequest) async throws -> CloudCoachPreferencesUpdateResponse {
        try await send(
            path: "v1/coach/preferences",
            method: "PATCH",
            body: request,
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            responseType: CloudCoachPreferencesUpdateResponse.self
        )
    }

    func fetchProfileInsights(
        locale: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?
    ) async throws -> CoachProfileInsights {
        try await send(
            path: "v1/coach/profile-insights",
            method: "POST",
            body: CoachProfileInsightsRequest(
                locale: locale,
                installID: snapshotEnvelope.installID,
                snapshotHash: snapshotEnvelope.snapshotHash,
                snapshot: snapshotEnvelope.snapshot,
                snapshotUpdatedAt: snapshotEnvelope.snapshotUpdatedAt,
                runtimeContextDelta: runtimeContextDelta,
                capabilityScope: capabilityScope
            ),
            session: profileInsightsSession,
            timeoutInterval: Self.profileInsightsRequestTimeoutInterval,
            responseType: CoachProfileInsights.self
        )
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
        try await send(
            path: "v2/coach/chat-jobs",
            method: "POST",
            body: CoachChatJobCreateRequest(
                locale: locale,
                question: question,
                installID: snapshotEnvelope.installID,
                snapshotHash: snapshotEnvelope.snapshotHash,
                snapshot: snapshotEnvelope.snapshot,
                snapshotUpdatedAt: snapshotEnvelope.snapshotUpdatedAt,
                runtimeContextDelta: runtimeContextDelta,
                clientRecentTurns: clientRecentTurns,
                capabilityScope: capabilityScope,
                clientRequestID: clientRequestID
            ),
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            responseType: CoachChatJobCreateResponse.self
        )
    }

    func getChatJob(
        jobID: String,
        installID: String
    ) async throws -> CoachChatJobStatusResponse {
        guard configuration.isFeatureEnabled else {
            throw CoachClientError.featureDisabled
        }
        guard let baseURL = configuration.backendBaseURL else {
            throw CoachClientError.missingBaseURL
        }
        guard let internalBearerToken = configuration.internalBearerToken else {
            throw CoachClientError.missingAuthToken
        }

        var components = URLComponents(
            url: baseURL.appending(path: "v2/coach/chat-jobs/\(jobID)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "installID", value: installID)
        ]

        guard let url = components?.url else {
            throw CoachClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.standardRequestTimeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(internalBearerToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await standardSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoachClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw Self.parseAPIErrorResponse(
                data: data,
                statusCode: httpResponse.statusCode
            )
        }

        do {
            return try Self.decoder.decode(CoachChatJobStatusResponse.self, from: data)
        } catch {
            throw CoachClientError.invalidResponse
        }
    }

    func sendChat(
        locale: String,
        question: String,
        clientRecentTurns: [CoachConversationMessage],
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?
    ) async throws -> CoachChatResponse {
        try await send(
            path: "v1/coach/chat",
            method: "POST",
            body: CoachChatRequest(
                locale: locale,
                question: question,
                installID: snapshotEnvelope.installID,
                snapshotHash: snapshotEnvelope.snapshotHash,
                snapshot: snapshotEnvelope.snapshot,
                snapshotUpdatedAt: snapshotEnvelope.snapshotUpdatedAt,
                runtimeContextDelta: runtimeContextDelta,
                clientRecentTurns: clientRecentTurns,
                capabilityScope: capabilityScope
            ),
            session: chatSession,
            timeoutInterval: Self.chatRequestTimeoutInterval,
            responseType: CoachChatResponse.self
        )
    }

    func deleteRemoteState(installID: String) async throws {
        struct DeleteRequest: Encodable {
            let installID: String
        }

        let _: EmptyCoachResponse = try await send(
            path: "v1/coach/state",
            method: "DELETE",
            body: DeleteRequest(installID: installID),
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            responseType: EmptyCoachResponse.self
        )
    }

    private func send<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        method: String,
        body: RequestBody,
        session: URLSession,
        timeoutInterval: TimeInterval,
        responseType: ResponseBody.Type
    ) async throws -> ResponseBody {
        guard configuration.isFeatureEnabled else {
            throw CoachClientError.featureDisabled
        }
        guard let baseURL = configuration.backendBaseURL else {
            throw CoachClientError.missingBaseURL
        }
        guard let internalBearerToken = configuration.internalBearerToken else {
            throw CoachClientError.missingAuthToken
        }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(internalBearerToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoachClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw Self.parseAPIErrorResponse(
                data: data,
                statusCode: httpResponse.statusCode
            )
        }

        do {
            return try Self.decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw CoachClientError.invalidResponse
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func parseAPIErrorResponse(
        data: Data,
        statusCode: Int
    ) -> CoachClientError {
        if let payload = try? decoder.decode(CoachAPIErrorResponse.self, from: data) {
            return .api(
                statusCode: statusCode,
                code: payload.error.code,
                message: payload.error.message,
                jobID: payload.jobID
            )
        }

        return .httpStatus(statusCode)
    }

    private static func makeSession(
        requestTimeoutInterval: TimeInterval,
        resourceTimeoutInterval: TimeInterval
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeoutInterval
        configuration.timeoutIntervalForResource = resourceTimeoutInterval
        return URLSession(configuration: configuration)
    }
}

private struct EmptyCoachResponse: Decodable, Sendable {}

struct CoachContextBuilder {
    private static let recentFinishedSessionsLimit = 8

    @MainActor
    func runtimeContextDelta(from store: AppStore) -> CoachRuntimeContextDelta? {
        guard let activeWorkout = activeWorkoutContext(from: store) else {
            return nil
        }

        return CoachRuntimeContextDelta(activeWorkout: activeWorkout)
    }

    @MainActor
    func build(from store: AppStore) -> CoachContextPayload {
        let progressSummary = store.profileProgressSummary()
        let goalSummary = store.profileGoalSummary()
        let trainingSummary = store.profileTrainingRecommendationSummary()
        let compatibilitySummary = store.profileGoalCompatibilitySummary()
        let consistencySummary = store.profileConsistencySummary()
        let recentPersonalRecords = store.recentPersonalRecords()
        let relativeStrengthSummary = store.profileStrengthToBodyweightSummary()
        let preferredProgram = CoachPreferredProgramResolver.resolve(
            from: store,
            preferredProgramID: store.coachAnalysisSettings.selectedProgramID
        )
        let recentSessions = store.history
            .filter(\.isFinished)
            .prefix(Self.recentFinishedSessionsLimit)

        return CoachContextPayload(
            localeIdentifier: store.selectedLanguageCode,
            historyMode: "summary_recent_history",
            profile: store.profile,
            coachAnalysisSettings: store.coachAnalysisSettings,
            preferredProgram: preferredProgram.map { program in
                CoachProgramContext(
                    id: program.id,
                    title: program.title,
                    workoutCount: program.workouts.count,
                    workouts: program.workouts.map { workout in
                        CoachWorkoutDayContext(
                            id: workout.id,
                            title: workout.title,
                            focus: workout.focus,
                            exerciseCount: workout.exercises.count,
                            exercises: workout.exercises.compactMap { templateExercise in
                                guard let exercise = store.exercise(for: templateExercise.exerciseID) else {
                                    return nil
                                }

                                return CoachPlannedExerciseContext(
                                    templateExerciseID: templateExercise.id,
                                    exerciseID: templateExercise.exerciseID,
                                    exerciseName: exercise.localizedName,
                                    setsCount: templateExercise.sets.count,
                                    reps: templateExercise.sets.first?.reps ?? 0,
                                    suggestedWeight: templateExercise.sets.first?.suggestedWeight ?? 0,
                                    groupKind: templateExercise.groupKind.rawValue
                                )
                            }
                        )
                    }
                )
            },
            activeWorkout: activeWorkoutContext(from: store),
            analytics: CoachAnalyticsContext(
                progress30Days: CoachProgressSnapshotContext(
                    totalFinishedWorkouts: progressSummary.totalFinishedWorkouts,
                    recentExercisesCount: progressSummary.recentExercisesCount,
                    recentVolume: progressSummary.recentVolume,
                    averageDurationSeconds: progressSummary.averageDuration,
                    lastWorkoutDate: progressSummary.lastWorkoutDate
                ),
                goal: CoachGoalContext(
                    primaryGoal: goalSummary.primaryGoal.rawValue,
                    currentWeight: goalSummary.currentWeight,
                    targetBodyWeight: goalSummary.targetBodyWeight,
                    weeklyWorkoutTarget: goalSummary.weeklyWorkoutTarget,
                    safeWeeklyChangeLowerBound: goalSummary.safeWeeklyChangeLowerBound,
                    safeWeeklyChangeUpperBound: goalSummary.safeWeeklyChangeUpperBound,
                    etaWeeksLowerBound: goalSummary.etaWeeksLowerBound,
                    etaWeeksUpperBound: goalSummary.etaWeeksUpperBound,
                    usesCurrentWeightOnly: goalSummary.usesCurrentWeightOnly
                ),
                training: CoachTrainingRecommendationContext(
                    currentWeeklyTarget: trainingSummary.currentWeeklyTarget,
                    recommendedWeeklyTargetLowerBound: trainingSummary.recommendedWeeklyTargetLowerBound,
                    recommendedWeeklyTargetUpperBound: trainingSummary.recommendedWeeklyTargetUpperBound,
                    mainRepLowerBound: trainingSummary.mainRepLowerBound,
                    mainRepUpperBound: trainingSummary.mainRepUpperBound,
                    accessoryRepLowerBound: trainingSummary.accessoryRepLowerBound,
                    accessoryRepUpperBound: trainingSummary.accessoryRepUpperBound,
                    weeklySetsLowerBound: trainingSummary.weeklySetsLowerBound,
                    weeklySetsUpperBound: trainingSummary.weeklySetsUpperBound,
                    split: coachSplitIdentifier(trainingSummary.split),
                    splitWorkoutDays: trainingSummary.splitWorkoutDays,
                    splitProgramTitle: trainingSummary.splitProgramTitle,
                    isGenericFallback: trainingSummary.isGenericFallback
                ),
                compatibility: CoachCompatibilityContext(
                    isAligned: compatibilitySummary.isAligned,
                    issues: compatibilitySummary.issues.map { issue in
                        CoachCompatibilityIssueContext(
                            kind: issue.kind.rawValue,
                            message: coachCompatibilityMessage(issue)
                        )
                    }
                ),
                consistency: CoachConsistencyContext(
                    workoutsThisWeek: consistencySummary.workoutsThisWeek,
                    weeklyTarget: consistencySummary.weeklyTarget,
                    streakWeeks: consistencySummary.streakWeeks,
                    mostFrequentWeekday: consistencySummary.mostFrequentWeekday,
                    recentWeeklyActivity: consistencySummary.recentWeeklyActivity.map { activity in
                        CoachWeeklyActivityContext(
                            weekStart: activity.weekStart,
                            workoutsCount: activity.workoutsCount,
                            meetsTarget: activity.meetsTarget
                        )
                    }
                ),
                recentPersonalRecords: recentPersonalRecords.map { record in
                    CoachPersonalRecordContext(
                        exerciseID: record.exerciseID,
                        exerciseName: record.exerciseName,
                        achievedAt: record.achievedAt,
                        weight: record.weight,
                        previousWeight: record.previousWeight,
                        delta: record.delta
                    )
                },
                relativeStrength: relativeStrengthSummary.lifts.map { lift in
                    CoachRelativeStrengthContext(
                        lift: lift.lift.rawValue,
                        bestLoad: lift.bestLoad,
                        relativeToBodyWeight: lift.relativeToBodyWeight
                    )
                }
            ),
            recentFinishedSessions: recentSessions.map { session in
                let completedSets = session.exercises
                    .flatMap(\.sets)
                    .filter { $0.completedAt != nil }
                let totalVolume = completedSets.reduce(0.0) { partialResult, set in
                    partialResult + (set.weight * Double(set.reps))
                }

                return CoachRecentSessionContext(
                    id: session.id,
                    workoutTemplateID: session.workoutTemplateID,
                    title: session.title,
                    startedAt: session.startedAt,
                    endedAt: session.endedAt,
                    durationSeconds: session.endedAt.map { $0.timeIntervalSince(session.startedAt) },
                    completedSetsCount: completedSets.count,
                    totalVolume: totalVolume,
                    exercises: session.exercises.map { exerciseLog in
                        let completedSets = exerciseLog.sets.filter { $0.completedAt != nil }
                        let totalExerciseVolume = completedSets.reduce(0.0) { partialResult, set in
                            partialResult + (set.weight * Double(set.reps))
                        }
                        let averageReps: Double? = completedSets.isEmpty
                            ? nil
                            : completedSets.reduce(0.0) { $0 + Double($1.reps) } / Double(completedSets.count)

                        return CoachRecentSessionExerciseContext(
                            templateExerciseID: exerciseLog.templateExerciseID,
                            exerciseID: exerciseLog.exerciseID,
                            exerciseName: store.exercise(for: exerciseLog.exerciseID)?.localizedName ?? exerciseLog.exerciseID.uuidString,
                            groupKind: exerciseLog.groupKind.rawValue,
                            completedSetsCount: completedSets.count,
                            bestWeight: completedSets.map(\.weight).max(),
                            totalVolume: totalExerciseVolume,
                            averageReps: averageReps
                        )
                    }
                )
            }
        )
    }
    @MainActor
    private func activeWorkoutContext(from store: AppStore) -> CoachActiveWorkoutContext? {
        store.activeSession.map { session in
            CoachActiveWorkoutContext(
                workoutTemplateID: session.workoutTemplateID,
                title: session.title,
                startedAt: session.startedAt,
                exerciseCount: session.exercises.count,
                completedSetsCount: session.exercises.flatMap(\.sets).filter { $0.completedAt != nil }.count,
                totalSetsCount: session.exercises.flatMap(\.sets).count
            )
        }
    }
}

struct CoachFallbackInsightsFactory {
    @MainActor
    static func make(from store: AppStore) -> CoachProfileInsights {
        let constraints = CoachProgramCommentConstraintExtractor.extract(
            from: store.coachAnalysisSettings.programComment
        )
        let consistencySummary = store.profileConsistencySummary()
        let recentPR = store.recentPersonalRecords(limit: 1).first
        var recommendations: [String] = []

        if constraints.rollingSplitExecution ||
            constraints.preserveWeeklyFrequency ||
            constraints.preserveProgramWorkoutCount {
            recommendations.append(coachLocalizedString("coach.fallback.comment_guardrail"))
        }

        if consistencySummary.workoutsThisWeek < consistencySummary.weeklyTarget {
            recommendations.append(
                String(
                    format: coachLocalizedString("coach.fallback.consistency_gap"),
                    consistencySummary.workoutsThisWeek,
                    consistencySummary.weeklyTarget
                )
            )
        } else if consistencySummary.streakWeeks > 0 {
            recommendations.append(
                String(
                    format: coachLocalizedString("coach.fallback.streak"),
                    consistencySummary.streakWeeks
                )
            )
        }

        if let recentPR {
            recommendations.append(
                String(
                    format: coachLocalizedString("coach.fallback.recent_pr"),
                    recentPR.exerciseName,
                    recentPR.delta.appNumberText
                )
            )
        }

        recommendations.append(coachLocalizedString("coach.fallback.progression_baseline"))

        let deduplicatedRecommendations = recommendations.reduce(into: [String]()) { result, item in
            guard !item.isEmpty, !result.contains(item) else { return }
            result.append(item)
        }

        return CoachProfileInsights(
            summary: coachLocalizedString("coach.fallback.summary.raw"),
            recommendations: Array(deduplicatedRecommendations.prefix(5)),
            generationStatus: .fallback
        )
    }
}

private struct CoachProgramCommentConstraints {
    var rawComment: String
    var rollingSplitExecution: Bool
    var preserveWeeklyFrequency: Bool
    var preserveProgramWorkoutCount: Bool
}

private enum CoachProgramCommentConstraintExtractor {
    private static let rotationPatterns = [
        #"(?i)\brotate\b"#,
        #"(?i)\brotating\b"#,
        #"(?i)\brotation\b"#,
        #"(?i)\bcycle through\b"#,
        #"(?i)\bin order\b"#,
        #"(?i)по\s*очеред"#,
        #"(?i)поочеред"#,
        #"(?i)по\s*кругу"#,
        #"(?i)черед"#,
        #"(?i)ротац"#
    ]

    private static let preserveWeeklyFrequencyPatterns = [
        #"(?i)не\s+предлагай.*(?:частот|кол-?во|количество).*(?:трениров|занят).*(?:в\s+недел|\/нед)"#,
        #"(?i)не\s+меняй.*(?:частот|кол-?во|количество).*(?:трениров|занят).*(?:в\s+недел|\/нед)"#,
        #"(?i)не\s+предлагай.*изменени.*(?:трениров|занят).*(?:в\s+недел|\/нед)"#,
        #"(?i)не\s+меняй.*недельн.*частот"#,
        #"(?i)\bdo not\b.*(?:change|adjust).*(?:training|workout|session).*(?:per\s+week|weekly)"#,
        #"(?i)\bdon't\b.*(?:change|adjust).*(?:training|workout|session).*(?:per\s+week|weekly)"#,
        #"(?i)\bdo not\b.*change.*weekly.*frequency"#,
        #"(?i)\bdon't\b.*change.*weekly.*frequency"#
    ]

    private static let preserveProgramWorkoutCountPatterns = [
        #"(?i)не\s+предлагай.*(?:изменени|меняй).*(?:кол-?во|количество).*(?:тренировок|дней).*(?:в\s+програм|сплит)"#,
        #"(?i)не\s+меняй.*(?:кол-?во|количество).*(?:тренировок|дней).*(?:в\s+програм|сплит)"#,
        #"(?i)\bdo not\b.*change.*(?:number|count).*(?:workouts|days).*(?:program|split)"#,
        #"(?i)\bdon't\b.*change.*(?:number|count).*(?:workouts|days).*(?:program|split)"#
    ]

    static func extract(from comment: String) -> CoachProgramCommentConstraints {
        let rawComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)

        func matchesAny(_ patterns: [String]) -> Bool {
            patterns.contains { pattern in
                rawComment.range(of: pattern, options: .regularExpression) != nil
            }
        }

        return CoachProgramCommentConstraints(
            rawComment: rawComment,
            rollingSplitExecution: matchesAny(rotationPatterns),
            preserveWeeklyFrequency: matchesAny(preserveWeeklyFrequencyPatterns),
            preserveProgramWorkoutCount: matchesAny(preserveProgramWorkoutCountPatterns)
        )
    }
}

private struct CoachPreferredProgramResolver {
    @MainActor
    static func resolve(
        from store: AppStore,
        preferredProgramID: UUID? = nil
    ) -> WorkoutProgram? {
        if let preferredProgramID,
           let preferredProgram = store.program(for: preferredProgramID) {
            return preferredProgram
        }

        if let workoutTemplateID = store.activeSession?.workoutTemplateID,
           let program = program(containing: workoutTemplateID, in: store.programs) {
            return program
        }

        if let workoutTemplateID = store.lastFinishedSession?.workoutTemplateID,
           let program = program(containing: workoutTemplateID, in: store.programs) {
            return program
        }

        if let workoutTemplateID = store.history.first(where: \.isFinished)?.workoutTemplateID,
           let program = program(containing: workoutTemplateID, in: store.programs) {
            return program
        }

        return store.programs.first(where: { !$0.workouts.isEmpty })
    }

    private static func program(containing workoutTemplateID: UUID, in programs: [WorkoutProgram]) -> WorkoutProgram? {
        programs.first { program in
            program.workouts.contains { $0.id == workoutTemplateID }
        }
    }
}

enum CloudRemoteDecisionMode: Hashable, Sendable {
    case restore
    case conflict
}

struct CloudPendingRemoteRestore: Identifiable, Sendable {
    let id: String
    var mode: CloudRemoteDecisionMode
    var response: CloudBackupDownloadResponse

    init(mode: CloudRemoteDecisionMode, response: CloudBackupDownloadResponse) {
        self.id = "\(mode)-\(response.remote.backupVersion)-\(response.remote.backupHash)"
        self.mode = mode
        self.response = response
    }
}

@MainActor
@Observable
final class CloudSyncStore {
    var isSyncInProgress = false
    var lastSyncErrorDescription: String?
    var pendingRemoteRestore: CloudPendingRemoteRestore?

    @ObservationIgnored private var client: any CoachAPIClient
    @ObservationIgnored private let localStateStore: CloudSyncLocalStateStore
    @ObservationIgnored private let installID: String
    private var configuration: CoachRuntimeConfiguration

    init(
        client: any CoachAPIClient,
        configuration: CoachRuntimeConfiguration,
        installID: String,
        localStateStore: CloudSyncLocalStateStore = CloudSyncLocalStateStore()
    ) {
        self.client = client
        self.configuration = configuration
        self.installID = installID
        self.localStateStore = localStateStore
    }

    func updateConfiguration(_ configuration: CoachRuntimeConfiguration) {
        self.configuration = configuration
        client = CoachAPIHTTPClient(configuration: configuration)
        pendingRemoteRestore = nil
        lastSyncErrorDescription = nil
        localStateStore.resetSyncState()
    }

    func handleAppLaunch(using appStore: AppStore) async {
        _ = await syncIfNeeded(using: appStore, allowUserPrompt: true)
    }

    func handleSceneDidEnterBackground(using appStore: AppStore) async {
        _ = await syncIfNeeded(using: appStore, allowUserPrompt: false)
    }

    @discardableResult
    func syncIfNeeded(
        using appStore: AppStore,
        allowUserPrompt: Bool = false
    ) async -> Bool {
        guard configuration.canUseRemoteCoach else {
            return false
        }
        guard !isSyncInProgress else {
            return false
        }

        isSyncInProgress = true
        defer { isSyncInProgress = false }

        do {
            let snapshot = appStore.currentSnapshot()
            let localBackupHash = try CloudBackupHashing.hash(for: snapshot)
            if pendingRemoteRestore == nil,
               localStateStore.canUseServerSideContext(for: localBackupHash) {
                lastSyncErrorDescription = nil
                return true
            }
            let reconcileResponse = try await client.reconcileBackup(
                CloudBackupReconcileRequest(
                    installID: installID,
                    localBackupHash: localBackupHash,
                    localSourceModifiedAt: appStore.localStateUpdatedAt,
                    lastSyncedRemoteVersion: localStateStore.lastSyncedRemoteVersion,
                    lastSyncedBackupHash: localStateStore.lastSyncedBackupHash,
                    localStateKind: appStore.cloudLocalStateKind
                )
            )

            localStateStore.rememberRemoteHead(reconcileResponse.remote)

            switch reconcileResponse.action {
            case .noop:
                if let remote = reconcileResponse.remote {
                    localStateStore.markSynced(remote: remote)
                    pendingRemoteRestore = nil
                    lastSyncErrorDescription = nil
                    return true
                }
                return false

            case .upload:
                let uploaded = try await client.uploadBackup(
                    CloudBackupUploadRequest(
                        installID: installID,
                        expectedRemoteVersion: reconcileResponse.remote?.backupVersion,
                        backupHash: localBackupHash,
                        clientSourceModifiedAt: appStore.localStateUpdatedAt,
                        appVersion: BackupConstants.appVersion,
                        buildNumber: BackupConstants.buildNumber,
                        snapshot: snapshot
                    )
                )
                localStateStore.markSynced(remote: uploaded)
                pendingRemoteRestore = nil
                lastSyncErrorDescription = nil
                return true

            case .download, .conflict:
                guard let remote = reconcileResponse.remote else {
                    return false
                }
                guard allowUserPrompt else {
                    return false
                }
                guard localStateStore.lastIgnoredRemoteVersion != remote.backupVersion else {
                    return false
                }

                let download = try await client.downloadBackup(installID: installID, version: nil)
                pendingRemoteRestore = CloudPendingRemoteRestore(
                    mode: reconcileResponse.action == .conflict ? .conflict : .restore,
                    response: download
                )
                lastSyncErrorDescription = nil
                return false
            }
        } catch {
            lastSyncErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func confirmPendingRemoteRestore(using appStore: AppStore) {
        guard let pendingRemoteRestore else {
            return
        }

        appStore.apply(snapshot: pendingRemoteRestore.response.backup.snapshot)
        let localBackupHash = (try? CloudBackupHashing.hash(for: appStore.currentSnapshot()))
            ?? pendingRemoteRestore.response.remote.backupHash
        localStateStore.markRemoteRestoreApplied(
            remote: pendingRemoteRestore.response.remote,
            localBackupHash: localBackupHash
        )
        self.pendingRemoteRestore = nil
        lastSyncErrorDescription = nil
    }

    func dismissPendingRemoteRestore() {
        guard let pendingRemoteRestore else {
            return
        }

        localStateStore.markIgnored(remoteVersion: pendingRemoteRestore.response.remote.backupVersion)
        self.pendingRemoteRestore = nil
    }

    func canUseServerSideContext(using appStore: AppStore) -> Bool {
        guard let localBackupHash = try? CloudBackupHashing.hash(for: appStore.currentSnapshot()) else {
            return false
        }

        return localStateStore.canUseServerSideContext(for: localBackupHash)
    }
}

@MainActor
@Observable
final class CoachStore {
    private static let initialChatPollAfterMs = 1_500
    private static let defaultMaxChatPollingDuration: TimeInterval = 90

    var profileInsights: CoachProfileInsights?
    var profileInsightsOrigin: CoachInsightsOrigin = .fallback
    var messages: [CoachChatMessage] = []
    var visibleQuickPromptKeys: [String] = []
    var isLoadingProfileInsights = false
    var isSendingMessage = false
    var activeChatJobID: String?
    var activeChatInstallID: String?
    var activeChatAwaitingResume = false
    var analysisSettingsSaveState: CoachAnalysisSettingsSaveState = .idle
    var lastInsightsErrorDescription: String?
    var lastChatErrorDescription: String?
    var selectedProgramIDDraft: UUID?
    var programCommentDraft: String = ""
    var draftQuestion: String = ""

    @ObservationIgnored private var client: any CoachAPIClient
    @ObservationIgnored private let cloudSyncStore: CloudSyncStore
    @ObservationIgnored private let contextBuilder: CoachContextBuilder
    @ObservationIgnored private let localStateStore: CoachLocalStateStore
    @ObservationIgnored private let allQuickPromptKeys: [String]
    @ObservationIgnored private var activeChatPlaceholderID: String?
    @ObservationIgnored private var activeChatPollingStartedAt: Date?
    @ObservationIgnored private var activeChatNextPollAfterMs = CoachStore.initialChatPollAfterMs
    @ObservationIgnored private var hasHydratedAnalysisSettingsDrafts = false
    @ObservationIgnored private let maxChatPollingDuration: TimeInterval
    private var configuration: CoachRuntimeConfiguration
    @ObservationIgnored private let capabilityScope: CoachCapabilityScope

    init(
        client: any CoachAPIClient,
        configuration: CoachRuntimeConfiguration,
        localStateStore: CoachLocalStateStore = CoachLocalStateStore(),
        cloudSyncStore: CloudSyncStore? = nil,
        contextBuilder: CoachContextBuilder = CoachContextBuilder(),
        capabilityScope: CoachCapabilityScope = .draftChanges,
        maxChatPollingDuration: TimeInterval = CoachStore.defaultMaxChatPollingDuration
    ) {
        self.client = client
        self.configuration = configuration
        self.localStateStore = localStateStore
        self.cloudSyncStore = cloudSyncStore ?? CloudSyncStore(
            client: client,
            configuration: configuration,
            installID: localStateStore.installID,
            localStateStore: CloudSyncLocalStateStore(defaults: localStateStore.userDefaults)
        )
        self.contextBuilder = contextBuilder
        self.capabilityScope = capabilityScope
        self.maxChatPollingDuration = maxChatPollingDuration
        self.allQuickPromptKeys = CoachStore.makeQuickPromptKeys()
        configureQuickPromptsIfNeeded()
    }

    var canUseRemoteCoach: Bool {
        configuration.canUseRemoteCoach
    }

    var isSavingAnalysisSettings: Bool {
        analysisSettingsSaveState == .saving
    }

    var canResumePendingChatJob: Bool {
        activeChatJobID != nil && !isSendingMessage
    }

    func updateConfiguration(_ configuration: CoachRuntimeConfiguration) {
        self.configuration = configuration
        client = CoachAPIHTTPClient(configuration: configuration)
        cloudSyncStore.updateConfiguration(configuration)
        localStateStore.resetSnapshotAcknowledgement()
        hasHydratedAnalysisSettingsDrafts = false
        profileInsights = nil
        profileInsightsOrigin = .fallback
        lastInsightsErrorDescription = nil
        resetConversation()
    }

    func syncAnalysisSettingsDrafts(using appStore: AppStore) {
        guard !hasHydratedAnalysisSettingsDrafts else {
            return
        }

        let savedSettings = appStore.coachAnalysisSettings
        let resolvedProgram = CoachPreferredProgramResolver.resolve(
            from: appStore,
            preferredProgramID: savedSettings.selectedProgramID
        )

        selectedProgramIDDraft = savedSettings.selectedProgramID ?? resolvedProgram?.id
        programCommentDraft = savedSettings.programComment
        hasHydratedAnalysisSettingsDrafts = true
    }

    func syncSnapshotIfNeeded(using appStore: AppStore) async {
        guard configuration.canUseRemoteCoach else {
            return
        }
        guard !cloudSyncStore.canUseServerSideContext(using: appStore) else {
            return
        }

        do {
            let snapshotPackage = try makeSnapshotPackage(
                from: appStore,
                forceInlineSnapshot: true
            )
            guard let snapshotHash = snapshotPackage.envelope.snapshotHash,
                  let snapshot = snapshotPackage.envelope.snapshot,
                  let snapshotUpdatedAt = snapshotPackage.envelope.snapshotUpdatedAt else {
                return
            }

            let response = try await client.syncSnapshot(
                CoachSnapshotSyncRequest(
                    installID: snapshotPackage.envelope.installID,
                    snapshotHash: snapshotHash,
                    snapshot: snapshot,
                    snapshotUpdatedAt: snapshotUpdatedAt
                )
            )
            localStateStore.markSnapshotAccepted(
                hash: response.acceptedHash,
                at: response.storedAt
            )
        } catch {
            // Keep proactive sync silent; request paths will still fall back safely.
        }
    }

    func refreshProfileInsights(using appStore: AppStore) async {
        isLoadingProfileInsights = true
        defer { isLoadingProfileInsights = false }

        let fallbackInsights = CoachFallbackInsightsFactory.make(from: appStore)

        guard configuration.canUseRemoteCoach else {
            profileInsights = fallbackInsights
            profileInsightsOrigin = .fallback
            lastInsightsErrorDescription = nil
            return
        }

        do {
            let canUseServerSideContext = await prepareCoachRequestState(
                using: appStore,
                allowUserPrompt: false
            )
            let snapshotPackage = try makeSnapshotPackage(
                from: appStore,
                preferServerSideContext: canUseServerSideContext
            )
            let remoteInsights = try await client.fetchProfileInsights(
                locale: appStore.selectedLanguageCode,
                snapshotEnvelope: snapshotPackage.envelope,
                capabilityScope: capabilityScope,
                runtimeContextDelta: canUseServerSideContext
                    ? contextBuilder.runtimeContextDelta(from: appStore)
                    : nil
            )
            profileInsights = remoteInsights
            profileInsightsOrigin = remoteInsights.isModelGenerated ? .remote : .fallback
            lastInsightsErrorDescription = nil
            markSnapshotAsAcceptedIfNeeded(snapshotPackage)
        } catch {
            profileInsights = fallbackInsights
            profileInsightsOrigin = .fallback
            lastInsightsErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func saveAnalysisSettings(using appStore: AppStore) async {
        guard analysisSettingsSaveState != .saving else {
            return
        }

        analysisSettingsSaveState = .saving
        let saveStartedAt = Date()

        let normalizedComment = String(
            programCommentDraft
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(500)
        )
        let selectedProgramID = selectedProgramIDDraft.flatMap { programID in
            appStore.program(for: programID) != nil ? programID : nil
        }

        appStore.updateCoachAnalysisSettings { settings in
            settings.selectedProgramID = selectedProgramID
            settings.programComment = normalizedComment
        }
        syncAnalysisSettingsDrafts(using: appStore)

        let canUseServerSideContext = await cloudSyncStore.syncIfNeeded(
            using: appStore,
            allowUserPrompt: false
        )
        if canUseServerSideContext {
            do {
                _ = try await client.updateCoachPreferences(
                    CloudCoachPreferencesUpdateRequest(
                        installID: localStateStore.installID,
                        selectedProgramID: selectedProgramID,
                        programComment: normalizedComment
                    )
                )
            } catch {
                // Leave the local save successful; the next sync can retry metadata propagation.
            }
        } else {
            await syncSnapshotIfNeeded(using: appStore)
        }

        await refreshProfileInsights(using: appStore)

        let minimumSavingStateDuration: TimeInterval = 1.35
        let elapsedSavingTime = Date().timeIntervalSince(saveStartedAt)
        let remainingSavingTime = minimumSavingStateDuration - elapsedSavingTime
        if remainingSavingTime > 0 {
            try? await Task.sleep(
                nanoseconds: UInt64(remainingSavingTime * 1_000_000_000)
            )
        }

        analysisSettingsSaveState = .saved
        try? await Task.sleep(nanoseconds: 2_400_000_000)
        if analysisSettingsSaveState == .saved {
            analysisSettingsSaveState = .idle
        }
    }

    func sendMessage(_ question: String, using appStore: AppStore) async {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            return
        }

        if activeChatJobID != nil {
            await resumePendingChatJobIfNeeded(using: appStore)
            return
        }

        guard !isSendingMessage else {
            return
        }

        let priorConversation = recentConversationMessages()
        let userMessageID = UUID().uuidString
        let placeholderID = UUID().uuidString

        messages.append(
            CoachChatMessage(
                id: userMessageID,
                role: .user,
                content: trimmedQuestion
            )
        )
        messages.append(
            CoachChatMessage(
                id: placeholderID,
                role: .assistant,
                content: coachLocalizedString("coach.loading.response"),
                isLoading: true,
                isStatus: true
            )
        )
        isSendingMessage = true
        lastChatErrorDescription = nil
        defer {
            isSendingMessage = false
        }

        guard configuration.canUseRemoteCoach else {
            let message = coachLocalizedString("coach.error.chat_unavailable")
            replaceMessage(
                id: placeholderID,
                with: CoachChatMessage(
                    id: placeholderID,
                    role: .assistant,
                    content: message,
                    isStatus: true
                )
            )
            lastChatErrorDescription = message
            return
        }

        do {
            let canUseServerSideContext = await prepareCoachRequestState(
                using: appStore,
                allowUserPrompt: false
            )
            let snapshotPackage = try makeSnapshotPackage(
                from: appStore,
                preferServerSideContext: canUseServerSideContext
            )
            let clientRequestID = UUID().uuidString.lowercased()

            do {
                let createResponse = try await client.createChatJob(
                    locale: appStore.selectedLanguageCode,
                    question: trimmedQuestion,
                    clientRequestID: clientRequestID,
                    clientRecentTurns: priorConversation,
                    snapshotEnvelope: snapshotPackage.envelope,
                    capabilityScope: capabilityScope,
                    runtimeContextDelta: canUseServerSideContext
                        ? contextBuilder.runtimeContextDelta(from: appStore)
                        : nil
                )
                draftQuestion = ""
                markSnapshotAsAcceptedIfNeeded(snapshotPackage)
                setActiveChatJob(
                    jobID: createResponse.jobID,
                    installID: snapshotPackage.envelope.installID,
                    placeholderID: placeholderID,
                    initialPollAfterMs: createResponse.pollAfterMs,
                    resetPollingStart: true
                )
            } catch let error as CoachClientError {
                if let existingJobID = error.activeChatJobID {
                    removeMessage(id: userMessageID)
                    removeMessage(id: placeholderID)
                    let recoveredPlaceholderID = ensureRecoveredChatPlaceholder()
                    setActiveChatJob(
                        jobID: existingJobID,
                        installID: snapshotPackage.envelope.installID,
                        placeholderID: recoveredPlaceholderID,
                        initialPollAfterMs: CoachStore.initialChatPollAfterMs,
                        resetPollingStart: activeChatPollingStartedAt == nil
                    )
                    await resumePendingChatJobIfNeeded(using: appStore)
                    return
                }

                throw error
            }

            guard let activeChatContext = currentActiveChatContext() else {
                return
            }

            if let jobResponse = try await awaitTerminalChatJob(
                jobID: activeChatContext.jobID,
                installID: activeChatContext.installID,
                initialPollAfterMs: activeChatNextPollAfterMs,
                placeholderID: activeChatContext.placeholderID,
                pollStartedAt: activeChatContext.pollStartedAt
            ) {
                finishActiveChatJob(
                    with: jobResponse,
                    placeholderID: activeChatContext.placeholderID
                )
            }
        } catch {
            clearActiveChatJob()
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastChatErrorDescription = description
            replaceMessage(
                id: placeholderID,
                with: CoachChatMessage(
                    id: placeholderID,
                    role: .assistant,
                    content: description,
                    isStatus: true
                )
            )
        }
    }

    func resumePendingChatJobIfNeeded(using _: AppStore) async {
        guard !isSendingMessage,
              let activeChatContext = currentActiveChatContext() else {
            return
        }

        isSendingMessage = true
        activeChatAwaitingResume = false
        lastChatErrorDescription = nil
        ensureActiveChatPlaceholder(
            id: activeChatContext.placeholderID,
            content: coachLocalizedString("coach.loading.response"),
            isLoading: true
        )
        defer {
            isSendingMessage = false
        }

        do {
            if let jobResponse = try await awaitTerminalChatJob(
                jobID: activeChatContext.jobID,
                installID: activeChatContext.installID,
                initialPollAfterMs: activeChatNextPollAfterMs,
                placeholderID: activeChatContext.placeholderID,
                pollStartedAt: activeChatContext.pollStartedAt
            ) {
                finishActiveChatJob(
                    with: jobResponse,
                    placeholderID: activeChatContext.placeholderID
                )
            }
        } catch {
            if isTransientPollingError(error) {
                suspendActiveChatJob(
                    placeholderID: activeChatContext.placeholderID,
                    nextPollAfterMs: activeChatNextPollAfterMs
                )
                return
            }

            clearActiveChatJob()
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastChatErrorDescription = description
            replaceMessage(
                id: activeChatContext.placeholderID,
                with: CoachChatMessage(
                    id: activeChatContext.placeholderID,
                    role: .assistant,
                    content: description,
                    isStatus: true
                )
            )
        }
    }

    func resetConversation() {
        messages = []
        draftQuestion = ""
        lastChatErrorDescription = nil
        isSendingMessage = false
        activeChatJobID = nil
        activeChatInstallID = nil
        activeChatAwaitingResume = false
        activeChatPlaceholderID = nil
        activeChatPollingStartedAt = nil
        activeChatNextPollAfterMs = CoachStore.initialChatPollAfterMs
    }

    func handleCoachScreenDidBecomeVisible(using appStore: AppStore) async {
        configureQuickPromptsIfNeeded()
        syncAnalysisSettingsDrafts(using: appStore)

        if activeChatJobID != nil {
            await resumePendingChatJobIfNeeded(using: appStore)
        }

        if profileInsights == nil {
            await refreshProfileInsights(using: appStore)
        }
    }

    func configureQuickPromptsIfNeeded() {
        guard visibleQuickPromptKeys.isEmpty else {
            return
        }

        visibleQuickPromptKeys = Array(allQuickPromptKeys.shuffled().prefix(3))
    }

    private func recentConversationMessages(limit: Int = 6) -> [CoachConversationMessage] {
        Array(
            messages
                .filter { !$0.isLoading && !$0.isStatus }
                .suffix(limit)
        ).map { message in
            CoachConversationMessage(
                role: message.role,
                content: message.content
            )
        }
    }

    private func awaitTerminalChatJob(
        jobID: String,
        installID: String,
        initialPollAfterMs: Int,
        placeholderID: String,
        pollStartedAt: Date
    ) async throws -> CoachChatJobStatusResponse? {
        var nextDelayMs = max(initialPollAfterMs, 0)
        var pollAttempt = 0

        while true {
            if hasExceededChatPollingDuration(since: pollStartedAt) {
                suspendActiveChatJob(
                    placeholderID: placeholderID,
                    nextPollAfterMs: nextDelayMs
                )
                return nil
            }

            do {
                let response = try await client.getChatJob(
                    jobID: jobID,
                    installID: installID
                )

                switch response.status {
                case .completed, .failed, .canceled:
                    return response
                case .queued, .running:
                    ensureActiveChatPlaceholder(
                        id: placeholderID,
                        content: coachLocalizedString("coach.loading.response"),
                        isLoading: true
                    )
                }
            } catch is CancellationError {
                suspendActiveChatJob(
                    placeholderID: placeholderID,
                    nextPollAfterMs: nextDelayMs
                )
                return nil
            } catch {
                if !isTransientPollingError(error) {
                    throw error
                }
            }

            if nextDelayMs > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(nextDelayMs) * 1_000_000)
                } catch is CancellationError {
                    suspendActiveChatJob(
                        placeholderID: placeholderID,
                        nextPollAfterMs: nextDelayMs
                    )
                    return nil
                }
            }

            pollAttempt += 1
            nextDelayMs = pollIntervalMs(for: pollAttempt)
            activeChatNextPollAfterMs = nextDelayMs
        }
    }

    private func pollIntervalMs(for attempt: Int) -> Int {
        switch attempt {
        case 0:
            return 1_500
        case 1:
            return 3_000
        default:
            return 5_000
        }
    }

    private func completedChatResponse(
        from jobResponse: CoachChatJobStatusResponse
    ) -> CoachChatResponse? {
        guard jobResponse.status == .completed, let result = jobResponse.result else {
            return nil
        }

        return CoachChatResponse(
            answerMarkdown: result.answerMarkdown,
            responseID: result.responseID,
            followUps: result.followUps,
            generationStatus: result.generationStatus
        )
    }

    private func chatJobFailureDescription(
        from jobResponse: CoachChatJobStatusResponse
    ) -> String {
        if let message = jobResponse.error?.message
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }

        return coachLocalizedString("coach.error.invalid_response")
    }

    private func currentActiveChatContext() -> (
        jobID: String,
        installID: String,
        placeholderID: String,
        pollStartedAt: Date
    )? {
        guard let jobID = activeChatJobID,
              let installID = activeChatInstallID else {
            return nil
        }

        let placeholderID = activeChatPlaceholderID ?? ensureRecoveredChatPlaceholder()

        return (
            jobID: jobID,
            installID: installID,
            placeholderID: placeholderID,
            pollStartedAt: activeChatPollingStartedAt ?? Date()
        )
    }

    private func setActiveChatJob(
        jobID: String,
        installID: String,
        placeholderID: String,
        initialPollAfterMs: Int,
        resetPollingStart: Bool
    ) {
        activeChatJobID = jobID
        activeChatInstallID = installID
        activeChatPlaceholderID = placeholderID
        activeChatNextPollAfterMs = max(initialPollAfterMs, 0)
        activeChatAwaitingResume = false
        if resetPollingStart || activeChatPollingStartedAt == nil {
            activeChatPollingStartedAt = Date()
        }
    }

    private func clearActiveChatJob() {
        activeChatJobID = nil
        activeChatInstallID = nil
        activeChatAwaitingResume = false
        activeChatPlaceholderID = nil
        activeChatPollingStartedAt = nil
        activeChatNextPollAfterMs = CoachStore.initialChatPollAfterMs
    }

    private func finishActiveChatJob(
        with jobResponse: CoachChatJobStatusResponse,
        placeholderID: String
    ) {
        defer {
            clearActiveChatJob()
        }

        guard let response = completedChatResponse(from: jobResponse) else {
            let description = chatJobFailureDescription(from: jobResponse)
            lastChatErrorDescription = description
            replaceMessage(
                id: placeholderID,
                with: CoachChatMessage(
                    id: placeholderID,
                    role: .assistant,
                    content: description,
                    isStatus: true
                )
            )
            return
        }

        lastChatErrorDescription = nil
        replaceMessage(
            id: placeholderID,
            with: CoachChatMessage(
                id: placeholderID,
                role: .assistant,
                content: response.answerMarkdown,
                followUps: response.followUps,
                generationStatus: response.generationStatus
            )
        )
    }

    private func ensureRecoveredChatPlaceholder() -> String {
        if let placeholderID = activeChatPlaceholderID {
            ensureActiveChatPlaceholder(
                id: placeholderID,
                content: coachLocalizedString("coach.loading.response"),
                isLoading: true
            )
            return placeholderID
        }

        if let existingPlaceholderID = messages.last(where: { $0.role == .assistant && $0.isStatus })?.id {
            ensureActiveChatPlaceholder(
                id: existingPlaceholderID,
                content: coachLocalizedString("coach.loading.response"),
                isLoading: true
            )
            return existingPlaceholderID
        }

        let placeholderID = UUID().uuidString
        ensureActiveChatPlaceholder(
            id: placeholderID,
            content: coachLocalizedString("coach.loading.response"),
            isLoading: true
        )
        return placeholderID
    }

    private func ensureActiveChatPlaceholder(
        id: String,
        content: String,
        isLoading: Bool
    ) {
        activeChatPlaceholderID = id
        replaceMessage(
            id: id,
            with: CoachChatMessage(
                id: id,
                role: .assistant,
                content: content,
                isLoading: isLoading,
                isStatus: true
            )
        )
    }

    private func suspendActiveChatJob(
        placeholderID: String,
        nextPollAfterMs: Int
    ) {
        activeChatPlaceholderID = placeholderID
        activeChatAwaitingResume = true
        activeChatNextPollAfterMs = max(nextPollAfterMs, CoachStore.initialChatPollAfterMs)
        ensureActiveChatPlaceholder(
            id: placeholderID,
            content: coachLocalizedString("coach.loading.response_delayed"),
            isLoading: false
        )
    }

    private func hasExceededChatPollingDuration(since startedAt: Date) -> Bool {
        Date().timeIntervalSince(startedAt) >= maxChatPollingDuration
    }

    private func isTransientPollingError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .dnsLookupFailed,
                 .resourceUnavailable:
                return true
            default:
                break
            }
        }

        if let clientError = error as? CoachClientError {
            return clientError.isTransientPollingFailure
        }

        return false
    }

    private static func makeQuickPromptKeys() -> [String] {
        (1...20).map { index in
            String(format: "coach.quick_prompt.%02d", index)
        }
    }

    private func prepareCoachRequestState(
        using appStore: AppStore,
        allowUserPrompt: Bool
    ) async -> Bool {
        let canUseServerSideContext = await cloudSyncStore.syncIfNeeded(
            using: appStore,
            allowUserPrompt: allowUserPrompt
        )
        if !canUseServerSideContext {
            await syncSnapshotIfNeeded(using: appStore)
        }
        return canUseServerSideContext
    }

    private func makeSnapshotPackage(
        from appStore: AppStore,
        preferServerSideContext: Bool = false,
        forceInlineSnapshot: Bool = false
    ) throws -> CoachSnapshotPackage {
        let snapshot = contextBuilder.build(from: appStore)
        let snapshotHash = try CoachSnapshotHashing.hash(for: snapshot)
        let shouldInlineSnapshot: Bool

        if forceInlineSnapshot {
            shouldInlineSnapshot = true
        } else if preferServerSideContext {
            shouldInlineSnapshot = false
        } else {
            shouldInlineSnapshot = snapshotHash != localStateStore.lastAcceptedSnapshotHash
        }

        return CoachSnapshotPackage(
            envelope: CoachSnapshotEnvelope(
                installID: localStateStore.installID,
                snapshotHash: shouldInlineSnapshot ? snapshotHash : nil,
                snapshot: shouldInlineSnapshot ? snapshot : nil,
                snapshotUpdatedAt: shouldInlineSnapshot ? Date() : nil
            ),
            includedInlineSnapshot: shouldInlineSnapshot
        )
    }

    private func markSnapshotAsAcceptedIfNeeded(_ package: CoachSnapshotPackage) {
        guard package.includedInlineSnapshot,
              let snapshotHash = package.envelope.snapshotHash else {
            return
        }

        localStateStore.markSnapshotAccepted(hash: snapshotHash)
    }

    private func replaceMessage(id: String, with message: CoachChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func removeMessage(id: String) {
        messages.removeAll { $0.id == id }
    }
}

private struct CoachSnapshotPackage {
    var envelope: CoachSnapshotEnvelope
    var includedInlineSnapshot: Bool
}

enum CoachAnalysisSettingsSaveState: Equatable {
    case idle
    case saving
    case saved
}

enum CoachFocusField: Hashable {
    case question
    case comment
}

@MainActor
struct CoachView: View {
    @Environment(AppStore.self) private var store
    @Environment(CoachStore.self) private var coachStore
    @Environment(\.appBottomRailInset) private var bottomRailInset
    @State private var refreshButtonScale: CGFloat = 1
    @State private var isEditingAnalysisContext = false
    @FocusState private var focusedField: CoachFocusField?

    private var availablePrograms: [WorkoutProgram] {
        store.programs
    }

    private var shouldShowQuickPrompts: Bool {
        coachStore.messages.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                AppPageHeaderModule(
                    titleKey: "header.coach.title",
                    subtitleKey: "header.coach.subtitle"
                ) {
                    Button {
                        focusedField = nil
                        animateRefreshTap()
                        Task {
                            await coachStore.refreshProfileInsights(using: store)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(AppTypography.icon(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .frame(width: 44, height: 44)
                            .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(AppTheme.border, lineWidth: 1)
                            )
                            .scaleEffect(refreshButtonScale)
                            .rotationEffect(.degrees(coachStore.isLoadingProfileInsights ? 360 : 0))
                            .animation(
                                coachStore.isLoadingProfileInsights
                                ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                : .easeOut(duration: 0.2),
                                value: coachStore.isLoadingProfileInsights
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(coachStore.isLoadingProfileInsights || coachStore.isSendingMessage)
                }

                CoachStatusCard(
                    isRemoteAvailable: coachStore.canUseRemoteCoach,
                    lastErrorDescription: coachStore.lastInsightsErrorDescription
                )

                CoachContextPreferencesCard(
                    selectedProgramID: Binding(
                        get: { coachStore.selectedProgramIDDraft },
                        set: { coachStore.selectedProgramIDDraft = $0 }
                    ),
                    programComment: Binding(
                        get: { coachStore.programCommentDraft },
                        set: { coachStore.programCommentDraft = String($0.prefix(500)) }
                    ),
                    programs: availablePrograms,
                    saveState: coachStore.analysisSettingsSaveState,
                    isExpanded: isEditingAnalysisContext,
                    savedProgramComment: store.coachAnalysisSettings.programComment,
                    commentFieldFocus: $focusedField,
                    onEdit: {
                        focusedField = nil
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            isEditingAnalysisContext = true
                        }
                    },
                    onSave: {
                        focusedField = nil
                        Task {
                            await coachStore.saveAnalysisSettings(using: store)
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                isEditingAnalysisContext = false
                            }
                        }
                    }
                )

                if let profileInsights = coachStore.profileInsights {
                    CoachInsightsOverviewCard(
                        insights: profileInsights,
                        origin: coachStore.profileInsightsOrigin
                    ) {
                        store.selectedTab = .profile
                    }
                } else if coachStore.isLoadingProfileInsights {
                    AppCard {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(AppTheme.accent)
                            Text("coach.loading.insights")
                                .font(AppTypography.body(size: 16, weight: .medium))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionTitle(titleKey: "coach.ask.title")

                        if !coachStore.messages.isEmpty {
                            CoachConversationThread(messages: coachStore.messages) { followUp in
                                sendQuestion(followUp)
                            }
                        }

                        TextField("coach.ask.placeholder", text: Binding(
                            get: { coachStore.draftQuestion },
                            set: { coachStore.draftQuestion = $0 }
                        ), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(AppTypography.body(size: 16))
                            .foregroundStyle(AppTheme.primaryText)
                            .focused($focusedField, equals: .question)
                            .disabled(coachStore.isSendingMessage)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(AppTheme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(AppTheme.border, lineWidth: 1)
                            )

                        Button {
                            focusedField = nil
                            if coachStore.canResumePendingChatJob &&
                                coachStore.draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Task {
                                    await coachStore.resumePendingChatJobIfNeeded(using: store)
                                }
                            } else {
                                sendQuestion(coachStore.draftQuestion)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if coachStore.isSendingMessage {
                                    ProgressView()
                                        .tint(.white)
                                }

                                if coachStore.isSendingMessage {
                                    Text("coach.loading.response_short")
                                } else if coachStore.canResumePendingChatJob &&
                                    coachStore.draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("coach.action.resume_waiting")
                                } else {
                                    Text("coach.action.send")
                                }
                            }
                        }
                        .buttonStyle(AppPrimaryButtonStyle())
                        .disabled(
                            (
                                coachStore.draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                !coachStore.canResumePendingChatJob
                            ) || coachStore.isSendingMessage || !coachStore.canUseRemoteCoach
                        )
                        .opacity(
                            (
                                coachStore.draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                                !coachStore.canResumePendingChatJob
                            ) || !coachStore.canUseRemoteCoach
                            ? 0.55
                                : 1
                        )

                        if shouldShowQuickPrompts {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("coach.quick_prompt.title")
                                    .font(AppTypography.caption(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.secondaryText)

                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(coachStore.visibleQuickPromptKeys, id: \.self) { promptKey in
                                        let prompt = coachLocalizedString(promptKey)
                                        Button {
                                            focusedField = nil
                                            sendQuestion(prompt)
                                        } label: {
                                            Text(prompt)
                                                .font(AppTypography.body(size: 15, weight: .semibold, relativeTo: .subheadline))
                                                .foregroundStyle(AppTheme.primaryText)
                                                .multilineTextAlignment(.leading)
                                                .lineLimit(2)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(CoachPromptButtonStyle())
                                        .disabled(!coachStore.canUseRemoteCoach || coachStore.isSendingMessage)
                                        .opacity(
                                            coachStore.canUseRemoteCoach && !coachStore.isSendingMessage
                                            ? 1
                                            : 0.55
                                        )
                                    }
                                }
                            }
                        }

                        if let chatError = coachStore.lastChatErrorDescription, !chatError.isEmpty {
                            Text(chatError)
                                .font(AppTypography.caption(size: 13, weight: .medium))
                                .foregroundStyle(AppTheme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 24 + bottomRailInset)
            .contentShape(Rectangle())
            .onTapGesture {
                focusedField = nil
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .task(id: store.selectedTab) {
            if store.selectedTab == .coach {
                await coachStore.handleCoachScreenDidBecomeVisible(using: store)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("action.done") {
                    focusedField = nil
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .appScreenBackground()
    }

    private func sendQuestion(_ question: String) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            return
        }

        Task {
            await coachStore.sendMessage(trimmedQuestion, using: store)
        }
    }

    private func animateRefreshTap() {
        withAnimation(.easeOut(duration: 0.12)) {
            refreshButtonScale = 0.88
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.58).delay(0.12)) {
            refreshButtonScale = 1
        }
    }
}

private struct CoachStatusCard: View {
    let isRemoteAvailable: Bool
    let lastErrorDescription: String?

    private var statusKey: LocalizedStringKey {
        isRemoteAvailable ? "coach.status.remote" : "coach.status.fallback"
    }

    private var descriptionKey: LocalizedStringKey {
        isRemoteAvailable ? "coach.status.remote_description" : "coach.status.fallback_description"
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isRemoteAvailable ? AppTheme.success : AppTheme.warning)
                        .frame(width: 10, height: 10)

                    Text(statusKey)
                        .font(AppTypography.body(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                }

                Text(descriptionKey)
                    .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastErrorDescription, !lastErrorDescription.isEmpty {
                    Text(lastErrorDescription)
                        .font(AppTypography.caption(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct CoachInsightsOverviewCard: View {
    let insights: CoachProfileInsights
    let origin: CoachInsightsOrigin
    let onOpenProfile: () -> Void

    private var sourceKey: LocalizedStringKey {
        origin == .remote ? "coach.insights.source.remote" : "coach.insights.source.fallback"
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            AppSectionTitle(titleKey: "coach.insights.title")
                            CoachGenerationStatusDot(generationStatus: insights.generationStatus)
                        }

                        Text(sourceKey)
                            .font(AppTypography.caption(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    Spacer(minLength: 12)

                    Button("coach.action.open_profile") {
                        onOpenProfile()
                    }
                    .buttonStyle(CoachPromptButtonStyle())
                }

                Text(coachNormalizedReadableText(insights.summary))
                    .font(AppTypography.body(size: 19, weight: .semibold, relativeTo: .title3))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(insights.recommendations.prefix(4).enumerated()), id: \.offset) { _, recommendation in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(AppTheme.accent)
                                .frame(width: 7, height: 7)
                                .padding(.top, 8)

                            Text(coachNormalizedReadableText(recommendation))
                                .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

private struct CoachContextPreferencesCard: View {
    @Binding var selectedProgramID: UUID?
    @Binding var programComment: String

    let programs: [WorkoutProgram]
    let saveState: CoachAnalysisSettingsSaveState
    let isExpanded: Bool
    let savedProgramComment: String
    let commentFieldFocus: FocusState<CoachFocusField?>.Binding
    let onEdit: () -> Void
    let onSave: () -> Void

    private var isSaving: Bool {
        saveState == .saving
    }

    private var isSaved: Bool {
        saveState == .saved
    }

    private var hasSavedComment: Bool {
        !savedProgramComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var collapsedStatusKey: LocalizedStringKey {
        hasSavedComment ? "coach.context.status.ready" : "coach.context.status.missing"
    }

    private var collapsedStatusColor: Color {
        hasSavedComment ? AppTheme.success : AppTheme.destructive
    }

    var body: some View {
        AppCard(padding: isExpanded ? 20 : 14) {
            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    AppSectionTitle(titleKey: "coach.context.title")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("coach.context.program")
                            .font(AppTypography.caption(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.secondaryText)

                        Picker(
                            coachLocalizedString("coach.context.program"),
                            selection: $selectedProgramID
                        ) {
                            if programs.isEmpty {
                                Text("coach.context.program.none")
                                    .tag(Optional<UUID>.none)
                            } else {
                                ForEach(programs) { program in
                                    Text(program.title)
                                        .tag(Optional(program.id))
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(programs.isEmpty || isSaving || isSaved)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(AppTheme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(AppTheme.border, lineWidth: 1)
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("coach.context.comment")
                            .font(AppTypography.caption(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.secondaryText)

                        TextField("coach.context.comment.placeholder", text: $programComment, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(AppTypography.body(size: 16))
                            .foregroundStyle(AppTheme.primaryText)
                            .focused(commentFieldFocus, equals: .comment)
                            .disabled(isSaving || isSaved)
                            .lineLimit(3...5)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(AppTheme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(AppTheme.border, lineWidth: 1)
                            )

                        Text("coach.context.comment.hint")
                            .font(AppTypography.caption(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    Button {
                        onSave()
                    } label: {
                        HStack(spacing: 10) {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                            } else if isSaved {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(AppTypography.icon(size: 16, weight: .semibold))
                            }

                            if isSaving {
                                Text("coach.context.saving")
                            } else if isSaved {
                                Text("coach.context.saved")
                            } else {
                                Text("action.save")
                            }
                        }
                    }
                    .buttonStyle(CoachContextSaveButtonStyle(state: saveState))
                    .disabled(isSaving || isSaved)
                    .opacity(isSaving || isSaved ? 0.92 : 1)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        AppSectionTitle(titleKey: "coach.context.title")

                        Spacer(minLength: 12)

                        Button("coach.context.edit") {
                            onEdit()
                        }
                        .buttonStyle(CoachCompactPromptButtonStyle())
                    }

                    HStack(spacing: 8) {
                        CoachStatusDot(color: collapsedStatusColor, size: 8)

                        Text(collapsedStatusKey)
                            .font(AppTypography.body(size: 14, weight: .medium, relativeTo: .subheadline))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
            }
        }
    }
}

private struct CoachConversationThread: View {
    let messages: [CoachChatMessage]
    let onFollowUpTap: (String) -> Void

    @State private var contentHeight: CGFloat = 0

    private let minConversationHeight: CGFloat = 270
    private let maxConversationHeight: CGFloat = 760

    private var resolvedConversationHeight: CGFloat {
        let measuredHeight = contentHeight + 12
        return min(max(measuredHeight, minConversationHeight), maxConversationHeight)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        CoachChatMessageCard(message: message) { followUp in
                            onFollowUpTap(followUp)
                        }
                        .id(message.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: CoachConversationContentHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                    }
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: resolvedConversationHeight)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: resolvedConversationHeight)
            .onPreferenceChange(CoachConversationContentHeightPreferenceKey.self) { newHeight in
                contentHeight = newHeight
            }
            .onChange(of: messages.last?.id) { _, lastMessageID in
                guard let lastMessageID else {
                    return
                }

                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastMessageID, anchor: .bottom)
                }
            }
            .task(id: messages.last?.id) {
                guard let lastMessageID = messages.last?.id else {
                    return
                }

                proxy.scrollTo(lastMessageID, anchor: .bottom)
            }
        }
    }
}

private struct CoachChatMessageCard: View {
    let message: CoachChatMessage
    let onFollowUpTap: (String) -> Void

    private var isAssistant: Bool {
        message.role == .assistant
    }

    private var authorKey: LocalizedStringKey {
        isAssistant ? "coach.message.coach" : "coach.message.you"
    }

    private var showsGenerationStatus: Bool {
        isAssistant && !message.isLoading && !message.isStatus
    }

    private var allowsCopy: Bool {
        isAssistant && !message.isLoading && !message.isStatus
    }

    @ViewBuilder
    var body: some View {
        if allowsCopy {
            messageCard
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = CoachMarkdownText.normalizedContent(from: message.content)
                    } label: {
                        Label("action.copy", systemImage: "doc.on.doc")
                    }
                }
        } else {
            messageCard
        }
    }

    private var messageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: leadingSystemImage)
                    .font(AppTypography.icon(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 32, height: 32)
                    .background(
                        (isAssistant ? AppTheme.accent.opacity(0.28) : AppTheme.surfaceElevated),
                        in: Circle()
                    )

                Text(authorKey)
                    .font(AppTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)

                if showsGenerationStatus {
                    CoachGenerationStatusDot(generationStatus: message.generationStatus)
                }
            }

            if message.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(AppTheme.accent)

                    Text(message.content)
                        .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                CoachMarkdownText(
                    content: message.content,
                    isAssistant: isAssistant,
                    isStatus: message.isStatus
                )
            }

            if !message.followUps.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(message.followUps, id: \.self) { followUp in
                        Button(followUp) {
                            onFollowUpTap(followUp)
                        }
                        .buttonStyle(CoachPromptButtonStyle())
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private var leadingSystemImage: String {
        if message.isLoading {
            return "hourglass"
        }

        if message.isStatus {
            return "exclamationmark.bubble"
        }

        return isAssistant ? "sparkles" : "person.fill"
    }

    private var backgroundColor: Color {
        if message.isStatus {
            return AppTheme.surface
        }

        return isAssistant ? AppTheme.surfaceElevated : AppTheme.surface
    }
}

private struct CoachGenerationStatusDot: View {
    let generationStatus: CoachResponseGenerationStatus?

    private var color: Color {
        generationStatus == .model ? AppTheme.success : AppTheme.destructive
    }

    var body: some View {
        CoachStatusDot(color: color, size: 8)
    }
}

private struct CoachMarkdownText: View {
    let content: String
    let isAssistant: Bool
    let isStatus: Bool

    var body: some View {
        if shouldRenderAsMarkdown,
           let attributedString = try? AttributedString(
                markdown: normalizedContent,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
           ) {
            Text(attributedString)
                .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(foregroundColor)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(verbatim: normalizedContent)
                .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(foregroundColor)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var normalizedContent: String {
        Self.normalizedContent(from: content)
    }

    static func normalizedContent(from content: String) -> String {
        coachNormalizedReadableText(
            content
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(
                    of: #"<br\s*/?>"#,
                    with: "\n",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var shouldRenderAsMarkdown: Bool {
        normalizedContent
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { rawLine in
                let line = String(rawLine).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else {
                    return false
                }

                if line.hasPrefix("#") ||
                    line.hasPrefix("- ") ||
                    line.hasPrefix("* ") ||
                    line.hasPrefix("> ") ||
                    line.contains("**") ||
                    line.contains("`") ||
                    line.contains("[") {
                    return true
                }

                return line.range(
                    of: #"^\d+[.)]\s"#,
                    options: .regularExpression
                ) != nil
            }
    }

    private var foregroundColor: Color {
        if isStatus {
            return AppTheme.secondaryText
        }

        return isAssistant ? AppTheme.primaryText : AppTheme.secondaryText
    }
}

private struct CoachStatusDot: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct CoachPromptButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.caption(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(configuration.isPressed ? AppTheme.surfacePressed : AppTheme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
    }
}

private struct CoachCompactPromptButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.caption(size: 12, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isPressed ? AppTheme.surfacePressed : AppTheme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
    }
}

private struct CoachContextSaveButtonStyle: ButtonStyle {
    let state: CoachAnalysisSettingsSaveState

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.button())
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                backgroundColor(isPressed: configuration.isPressed),
                in: Capsule()
            )
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch state {
        case .idle:
            return isPressed ? AppTheme.accent.opacity(0.86) : AppTheme.accent
        case .saving:
            return isPressed ? AppTheme.accent.opacity(0.82) : AppTheme.accent.opacity(0.92)
        case .saved:
            return isPressed ? AppTheme.success.opacity(0.82) : AppTheme.success
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentLineWidth: CGFloat = 0
        var currentLineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentLineWidth + size.width > maxWidth, currentLineWidth > 0 {
                totalWidth = max(totalWidth, currentLineWidth - spacing)
                totalHeight += currentLineHeight + spacing
                currentLineWidth = size.width + spacing
                currentLineHeight = size.height
            } else {
                currentLineWidth += size.width + spacing
                currentLineHeight = max(currentLineHeight, size.height)
            }
        }

        totalWidth = max(totalWidth, currentLineWidth > 0 ? currentLineWidth - spacing : 0)
        totalHeight += currentLineHeight

        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var point = bounds.origin
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x + size.width > bounds.maxX, point.x > bounds.minX {
                point.x = bounds.minX
                point.y += lineHeight + spacing
                lineHeight = 0
            }

            subview.place(
                at: point,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            point.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct CoachConversationContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private func coachLocalizedString(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

private func coachNormalizedReadableText(_ text: String) -> String {
    text.replacingOccurrences(
        of: #"([.!?])([A-ZА-ЯЁ])"#,
        with: "$1 $2",
        options: .regularExpression
    )
}

private func coachLocalizedSplitTitle(_ split: ProfileTrainingSplitRecommendation) -> String {
    let key: String

    switch split {
    case .fullBody:
        key = "profile.card.recommendations.split.full_body"
    case .upperLowerHybrid:
        key = "profile.card.recommendations.split.upper_lower_hybrid"
    case .upperLower:
        key = "profile.card.recommendations.split.upper_lower"
    case .upperLowerPlusSpecialization:
        key = "profile.card.recommendations.split.upper_lower_plus"
    case .highFrequencySplit:
        key = "profile.card.recommendations.split.high_frequency"
    }

    return coachLocalizedString(key)
}

private func coachSplitIdentifier(_ split: ProfileTrainingSplitRecommendation) -> String {
    switch split {
    case .fullBody:
        return "full_body"
    case .upperLowerHybrid:
        return "upper_lower_hybrid"
    case .upperLower:
        return "upper_lower"
    case .upperLowerPlusSpecialization:
        return "upper_lower_plus_specialization"
    case .highFrequencySplit:
        return "high_frequency_split"
    }
}

private func coachCompatibilityMessage(_ issue: ProfileGoalCompatibilityIssue) -> String {
    switch issue.kind {
    case .missingGoal:
        return coachLocalizedString("profile.card.compatibility.issue_missing_goal")
    case .goalTargetMismatch:
        return coachLocalizedString("profile.card.compatibility.issue_goal_target")
    case .frequencyTooLow:
        return String(
            format: coachLocalizedString("profile.card.compatibility.issue_frequency_low"),
            issue.recommendedWeeklyTargetLowerBound ?? 0,
            issue.currentWeeklyTarget ?? 0
        )
    case .frequencyTooHighForBeginner:
        return String(
            format: coachLocalizedString("profile.card.compatibility.issue_frequency_high_beginner"),
            issue.currentWeeklyTarget ?? 0
        )
    case .programFrequencyMismatch:
        return String(
            format: coachLocalizedString("profile.card.compatibility.issue_program_frequency_mismatch"),
            issue.programWorkoutCount ?? 0,
            issue.currentWeeklyTarget ?? 0
        )
    case .adherenceGap:
        return String(
            format: coachLocalizedString("profile.card.compatibility.issue_adherence_gap"),
            issue.observedWorkoutsPerWeek?.appNumberText ?? coachLocalizedString("common.no_data"),
            issue.currentWeeklyTarget ?? 0
        )
    case .longGoalTimeline:
        return String(
            format: coachLocalizedString("profile.card.compatibility.issue_long_eta"),
            issue.etaWeeksUpperBound ?? 0
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
