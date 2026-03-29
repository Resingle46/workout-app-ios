import CryptoKit
import Foundation
import Observation
import Security
import SwiftUI
import UIKit

private let coachStoreDefaultMaxChatPollingDuration: TimeInterval = 180
private let coachDefaultProviderID = "workers_ai"

enum CoachAIProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case workersAI = "workers_ai"
    case gemini

    var debugName: String {
        switch self {
        case .workersAI:
            return "Cloudflare Workers AI"
        case .gemini:
            return "Gemini"
        }
    }
}

struct CoachRuntimeConfiguration: Hashable, Sendable {
    var isFeatureEnabled: Bool
    var backendBaseURL: URL?
    var internalBearerToken: String?
    var provider: CoachAIProvider

    init(
        isFeatureEnabled: Bool,
        backendBaseURL: URL?,
        internalBearerToken: String? = nil,
        provider: CoachAIProvider = .workersAI
    ) {
        self.isFeatureEnabled = isFeatureEnabled
        self.backendBaseURL = backendBaseURL
        self.internalBearerToken = internalBearerToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.provider = provider
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
            internalBearerToken: internalBearerToken,
            provider: .workersAI
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
    var provider: CoachAIProvider

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

        self.provider = Self.parseProvider(
            defaults.string(forKey: PreferenceKey.provider)
        ) ?? defaultConfiguration.provider
    }

    var runtimeConfiguration: CoachRuntimeConfiguration {
        CoachRuntimeConfiguration(
            isFeatureEnabled: isFeatureEnabled,
            backendBaseURL: CoachRuntimeConfiguration.parseBackendBaseURL(backendBaseURLText),
            internalBearerToken: internalBearerToken,
            provider: provider
        )
    }

    var hasLocalOverrides: Bool {
        defaults.object(forKey: PreferenceKey.featureEnabled) != nil ||
        defaults.object(forKey: PreferenceKey.backendBaseURL) != nil ||
        defaults.object(forKey: PreferenceKey.internalBearerToken) != nil ||
        defaults.object(forKey: PreferenceKey.provider) != nil
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

        defaults.set(provider.rawValue, forKey: PreferenceKey.provider)

        return runtimeConfiguration
    }

    @discardableResult
    func resetToDefaults() -> CoachRuntimeConfiguration {
        defaults.removeObject(forKey: PreferenceKey.featureEnabled)
        defaults.removeObject(forKey: PreferenceKey.backendBaseURL)
        defaults.removeObject(forKey: PreferenceKey.internalBearerToken)
        defaults.removeObject(forKey: PreferenceKey.provider)

        isFeatureEnabled = defaultConfiguration.isFeatureEnabled
        backendBaseURLText = defaultConfiguration.backendBaseURLString
        internalBearerToken = defaultConfiguration.internalBearerToken ?? ""
        provider = defaultConfiguration.provider

        return runtimeConfiguration
    }

    private static func parseProvider(_ value: String?) -> CoachAIProvider? {
        guard let value else {
            return nil
        }
        return CoachAIProvider(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private enum PreferenceKey {
        static let featureEnabled = "coach.runtime.feature_enabled"
        static let backendBaseURL = "coach.runtime.backend_base_url"
        static let internalBearerToken = "coach.runtime.internal_bearer_token"
        static let provider = "coach.runtime.provider"
    }
}

struct CoachInstallIdentity: Hashable, Sendable {
    var installID: String
    var installSecret: String
}

protocol CoachIdentityVault: Sendable {
    func readValue(forKey key: String) -> String?
    @discardableResult
    func writeValue(_ value: String, forKey key: String) -> Bool
    func deleteValue(forKey key: String)
}

struct SystemCoachIdentityVault: CoachIdentityVault {
    var service: String = Bundle.main.bundleIdentifier ?? "WorkoutApp"

    func readValue(forKey key: String) -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty else {
            return nil
        }

        return value
    }

    @discardableResult
    func writeValue(_ value: String, forKey key: String) -> Bool {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = normalizedValue.data(using: .utf8) else {
            return false
        }

        let query = baseQuery(forKey: key)
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    func deleteValue(forKey key: String) {
        SecItemDelete(baseQuery(forKey: key) as CFDictionary)
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

final class CoachLocalStateStore {
    let installID: String
    let installSecret: String

    private let defaults: UserDefaults
    private let identityVault: any CoachIdentityVault
    private let storageNamespace: String
    private let debugRecorder: any DebugEventRecording

    convenience init(
        defaults: UserDefaults = .standard,
        debugRecorder: any DebugEventRecording = NoopDebugEventRecorder()
    ) {
        self.init(
            defaults: defaults,
            generatedInstallID: UUID().uuidString,
            generatedInstallSecret: Self.makeInstallSecret(),
            identityVault: SystemCoachIdentityVault(),
            debugRecorder: debugRecorder
        )
    }

    init(
        defaults: UserDefaults,
        generatedInstallID: String,
        generatedInstallSecret: String = CoachLocalStateStore.makeInstallSecret(),
        identityVault: any CoachIdentityVault = SystemCoachIdentityVault(),
        storageNamespace: String = Bundle.main.bundleIdentifier ?? "WorkoutApp",
        debugRecorder: any DebugEventRecording = NoopDebugEventRecorder()
    ) {
        self.defaults = defaults
        self.identityVault = identityVault
        self.storageNamespace = storageNamespace
        self.debugRecorder = debugRecorder

        let installIDKey = Self.keychainKey(storageNamespace: storageNamespace, suffix: "install_id")
        let installSecretKey = Self.keychainKey(
            storageNamespace: storageNamespace,
            suffix: "install_secret"
        )
        let keychainInstallID = identityVault.readValue(forKey: installIDKey)
        let keychainInstallSecret = identityVault.readValue(forKey: installSecretKey)
        let defaultsInstallID = defaults.string(forKey: PreferenceKey.installID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        let resolvedInstallID = keychainInstallID ?? defaultsInstallID ?? generatedInstallID
        let resolvedInstallSecret = keychainInstallSecret ?? generatedInstallSecret

        self.installID = resolvedInstallID
        self.installSecret = resolvedInstallSecret

        defaults.set(resolvedInstallID, forKey: PreferenceKey.installID)

        let storedMode: String
        if keychainInstallID != nil && keychainInstallSecret != nil {
            storedMode = "keychain_existing"
        } else if defaultsInstallID != nil {
            storedMode = "migrated_defaults_to_keychain"
        } else {
            storedMode = "generated_new_identity"
        }

        let installIDStored = identityVault.writeValue(resolvedInstallID, forKey: installIDKey)
        let installSecretStored = identityVault.writeValue(
            resolvedInstallSecret,
            forKey: installSecretKey
        )
        defaults.set(storedMode, forKey: PreferenceKey.identityStorageMode)
        defaults.set(
            installIDStored && installSecretStored,
            forKey: PreferenceKey.identityKeychainReady
        )

        debugRecorder.log(
            category: .appLifecycle,
            message: installIDStored && installSecretStored
                ? "identity_keychain_ready"
                : "identity_keychain_fallback",
            metadata: [
                "mode": storedMode,
                "hasLegacyInstallID": defaultsInstallID != nil ? "true" : "false"
            ]
        )
    }

    var userDefaults: UserDefaults {
        defaults
    }

    var identityStorageMode: String? {
        defaults.string(forKey: PreferenceKey.identityStorageMode)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var isKeychainBackedIdentityReady: Bool {
        defaults.bool(forKey: PreferenceKey.identityKeychainReady)
    }

    private static func keychainKey(storageNamespace: String, suffix: String) -> String {
        "\(storageNamespace).coach.\(suffix)"
    }

    private static func makeInstallSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() +
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private enum PreferenceKey {
        static let installID = "coach.runtime.install_id"
        static let identityStorageMode = "coach.runtime.identity_storage_mode"
        static let identityKeychainReady = "coach.runtime.identity_keychain_ready"
    }
}

final class CloudSyncLocalStateStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastStatusSyncState: CloudBackupSyncState? {
        enumValue(forKey: PreferenceKey.lastStatusSyncState)
    }

    var lastStatusContextState: CloudBackupContextState? {
        enumValue(forKey: PreferenceKey.lastStatusContextState)
    }

    var lastStatusLocalBackupHash: String? {
        string(forKey: PreferenceKey.lastStatusLocalBackupHash)
    }

    func canUseServerSideContext(for localBackupHash: String) -> Bool {
        lastStatusContextState == .contextReady && lastStatusLocalBackupHash == localBackupHash
    }

    func applyStatus(_ status: CloudBackupStatusResponse, localBackupHash: String?) {
        defaults.set(status.syncState.rawValue, forKey: PreferenceKey.lastStatusSyncState)
        defaults.set(status.contextState.rawValue, forKey: PreferenceKey.lastStatusContextState)

        if status.actions.canUseRemoteAIContextNow {
            defaults.set(
                localBackupHash ?? status.remote?.backupHash,
                forKey: PreferenceKey.lastStatusLocalBackupHash
            )
        } else if localBackupHash != nil {
            defaults.removeObject(forKey: PreferenceKey.lastStatusLocalBackupHash)
        } else {
            defaults.removeObject(forKey: PreferenceKey.lastStatusLocalBackupHash)
        }
    }

    func resetSyncState() {
        defaults.removeObject(forKey: PreferenceKey.lastStatusSyncState)
        defaults.removeObject(forKey: PreferenceKey.lastStatusContextState)
        defaults.removeObject(forKey: PreferenceKey.lastStatusLocalBackupHash)
    }

    private func string(forKey key: String) -> String? {
        defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func enumValue<Value: RawRepresentable>(forKey key: String) -> Value?
    where Value.RawValue == String {
        string(forKey: key).flatMap(Value.init(rawValue:))
    }

    private enum PreferenceKey {
        static let lastStatusSyncState = "coach.cloud.last_status_sync_state"
        static let lastStatusContextState = "coach.cloud.last_status_context_state"
        static let lastStatusLocalBackupHash = "coach.cloud.last_status_local_hash"
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
    case api(
        statusCode: Int,
        code: String,
        message: String,
        requestID: String?,
        jobID: String?,
        provider: CoachAIProvider?
    )

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
        case .api(_, _, let message, _, _, _):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? coachLocalizedString("coach.error.invalid_response")
        }
    }

    var activeChatJobID: String? {
        guard case .api(_, let code, _, _, let jobID, _) = self,
              code == "chat_job_in_progress" else {
            return nil
        }

        return jobID
    }

    var activeChatJobProvider: CoachAIProvider? {
        guard case .api(_, let code, _, _, _, let provider) = self,
              code == "chat_job_in_progress" else {
            return nil
        }

        return provider
    }

    var requestID: String? {
        guard case .api(_, _, _, let requestID, _, _) = self else {
            return nil
        }

        return requestID
    }

    var isTransientPollingFailure: Bool {
        switch self {
        case .httpStatus(let statusCode):
            return statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500
        case .api(let statusCode, let code, _, _, _, _):
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

    var isRemoteHeadChanged: Bool {
        guard case .api(let statusCode, let code, _, _, _, _) = self else {
            return false
        }

        return statusCode == 409 && code == "remote_head_changed"
    }
}

enum CoachCapabilityScope: String, Codable, Hashable, Sendable {
    case draftChanges = "draft_changes"
}

enum CoachInsightsOrigin: String, Codable, Hashable, Sendable {
    case freshModel = "fresh_model"
    case cachedModel = "cached_model"
    case fallback

    var sourceColor: Color {
        switch self {
        case .freshModel:
            return AppTheme.success
        case .cachedModel:
            return AppTheme.warning
        case .fallback:
            return AppTheme.destructive
        }
    }

    var coachSourceKey: LocalizedStringKey {
        switch self {
        case .freshModel:
            return "coach.insights.source.fresh_model"
        case .cachedModel:
            return "coach.insights.source.cached_model"
        case .fallback:
            return "coach.insights.source.fallback"
        }
    }

    var profileSourceKey: LocalizedStringKey {
        switch self {
        case .freshModel:
            return "profile.card.ai.source.fresh_model"
        case .cachedModel:
            return "profile.card.ai.source.cached_model"
        case .fallback:
            return "profile.card.ai.source.fallback"
        }
    }
}

enum CoachResponseGenerationStatus: String, Codable, Hashable, Sendable {
    case model
    case fallback
}

protocol CoachAPIClient: Sendable {
    func getBackupStatus(_ request: CloudBackupStatusRequest) async throws -> CloudBackupStatusResponse

    func uploadBackup(_ request: CloudBackupUploadRequest) async throws -> CloudBackupHead

    func downloadBackup(installID: String, version: Int?) async throws -> CloudBackupDownloadResponse

    func recordRestoreDecision(_ request: CloudBackupRestoreDecisionRequest) async throws

    func clearRemoteChatMemory(_ request: CloudCoachMemoryClearRequest) async throws

    func deleteRemoteBackup(installID: String) async throws

    func updateCoachPreferences(_ request: CloudCoachPreferencesUpdateRequest) async throws -> CloudCoachPreferencesUpdateResponse

    func fetchProfileInsights(
        locale: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?,
        forceRefresh: Bool,
        allowDegradedCache: Bool
    ) async throws -> CoachProfileInsights

    func createProfileInsightsJob(
        locale: String,
        clientRequestID: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?,
        forceRefresh: Bool,
        allowDegradedCache: Bool
    ) async throws -> CoachProfileInsightsJobCreateResponse

    func getProfileInsightsJob(
        jobID: String,
        installID: String
    ) async throws -> CoachProfileInsightsJobStatusResponse

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

    func createWorkoutSummaryJob(
        _ request: WorkoutSummaryJobCreateRequest
    ) async throws -> WorkoutSummaryJobCreateResponse

    func getWorkoutSummaryJob(
        jobID: String,
        installID: String
    ) async throws -> WorkoutSummaryJobStatusResponse

    func deleteRemoteState(installID: String) async throws
}

extension CoachAPIClient {
    func createChatJob(
        locale: String,
        question: String,
        clientRequestID: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?
    ) async throws -> CoachChatJobCreateResponse {
        try await createChatJob(
            locale: locale,
            question: question,
            clientRequestID: clientRequestID,
            clientRecentTurns: [],
            snapshotEnvelope: snapshotEnvelope,
            capabilityScope: capabilityScope,
            runtimeContextDelta: runtimeContextDelta
        )
    }

    func sendChat(
        locale: String,
        question: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?
    ) async throws -> CoachChatResponse {
        try await sendChat(
            locale: locale,
            question: question,
            clientRecentTurns: [],
            snapshotEnvelope: snapshotEnvelope,
            capabilityScope: capabilityScope,
            runtimeContextDelta: runtimeContextDelta
        )
    }

    func getBackupStatus(_ request: CloudBackupStatusRequest) async throws -> CloudBackupStatusResponse {
        throw CoachClientError.invalidResponse
    }

    func createWorkoutSummaryJob(
        _ request: WorkoutSummaryJobCreateRequest
    ) async throws -> WorkoutSummaryJobCreateResponse {
        throw CoachClientError.invalidResponse
    }

    func createProfileInsightsJob(
        locale _: String,
        clientRequestID _: String,
        snapshotEnvelope _: CoachSnapshotEnvelope,
        capabilityScope _: CoachCapabilityScope,
        runtimeContextDelta _: CoachRuntimeContextDelta?,
        forceRefresh _: Bool,
        allowDegradedCache _: Bool
    ) async throws -> CoachProfileInsightsJobCreateResponse {
        throw CoachClientError.invalidResponse
    }

    func getProfileInsightsJob(
        jobID _: String,
        installID _: String
    ) async throws -> CoachProfileInsightsJobStatusResponse {
        throw CoachClientError.invalidResponse
    }

    func getWorkoutSummaryJob(
        jobID: String,
        installID: String
    ) async throws -> WorkoutSummaryJobStatusResponse {
        throw CoachClientError.invalidResponse
    }

    func recordRestoreDecision(_ request: CloudBackupRestoreDecisionRequest) async throws {}

    func clearRemoteChatMemory(_ request: CloudCoachMemoryClearRequest) async throws {}

    func deleteRemoteBackup(installID: String) async throws {}
}

typealias CompactCoachSnapshot = CoachContextPayload

struct CoachSnapshotEnvelope: Hashable, Sendable {
    var installID: String
    var localBackupHash: String?
    var snapshotHash: String?
    var snapshot: CompactCoachSnapshot?
    var snapshotUpdatedAt: Date?
}

struct CoachProfileInsightsRequest: Codable, Sendable {
    var locale: String
    var installID: String
    var provider: CoachAIProvider
    var localBackupHash: String?
    var snapshotHash: String?
    var snapshot: CompactCoachSnapshot?
    var snapshotUpdatedAt: Date?
    var runtimeContextDelta: CoachRuntimeContextDelta?
    var capabilityScope: CoachCapabilityScope
    var forceRefresh: Bool?
    var allowDegradedCache: Bool?
    var providerID: String?
}

struct CoachProfileInsightsJobCreateRequest: Codable, Sendable {
    var locale: String
    var installID: String
    var provider: CoachAIProvider
    var localBackupHash: String?
    var snapshotHash: String?
    var snapshot: CompactCoachSnapshot?
    var snapshotUpdatedAt: Date?
    var runtimeContextDelta: CoachRuntimeContextDelta?
    var capabilityScope: CoachCapabilityScope
    var forceRefresh: Bool?
    var allowDegradedCache: Bool?
    var providerID: String?
    var clientRequestID: String
}

struct CoachChatRequest: Codable, Sendable {
    var locale: String
    var question: String
    var installID: String
    var provider: CoachAIProvider
    var localBackupHash: String?
    var snapshotHash: String?
    var snapshot: CompactCoachSnapshot?
    var snapshotUpdatedAt: Date?
    var runtimeContextDelta: CoachRuntimeContextDelta?
    var capabilityScope: CoachCapabilityScope
    var providerID: String?
}

struct CoachChatJobCreateRequest: Codable, Sendable {
    var locale: String
    var question: String
    var installID: String
    var provider: CoachAIProvider
    var localBackupHash: String?
    var snapshotHash: String?
    var snapshot: CompactCoachSnapshot?
    var snapshotUpdatedAt: Date?
    var runtimeContextDelta: CoachRuntimeContextDelta?
    var capabilityScope: CoachCapabilityScope
    var clientRequestID: String
    var providerID: String?
}

enum CoachChatJobStatus: String, Hashable, Sendable {
    case queued
    case running
    case completed
    case failed
    case canceled

    var normalizedUserFacingStatus: CoachChatJobStatus {
        self == .canceled ? .failed : self
    }

    var isPending: Bool {
        self == .queued || self == .running
    }

    var isCompletedForUserFlow: Bool {
        normalizedUserFacingStatus == .completed
    }

    var isFailureForUserFlow: Bool {
        normalizedUserFacingStatus == .failed
    }

    var isTerminalForUserFlow: Bool {
        isCompletedForUserFlow || isFailureForUserFlow
    }
}

extension CoachChatJobStatus: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        if rawValue == Self.canceled.rawValue {
            self = .failed
            return
        }

        guard let status = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid CoachChatJobStatus value: \(rawValue)"
            )
        }

        self = status
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(normalizedUserFacingStatus.rawValue)
    }
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

enum CloudBackupSyncState: String, Codable, Hashable, Sendable {
    case noRemoteBackup = "no_remote_backup"
    case remoteReady = "remote_ready"
    case remoteNewerThanLocal = "remote_newer_than_local"
    case localNewerThanRemote = "local_newer_than_remote"
    case conflict
    case restorePendingDecision = "restore_pending_decision"
    case reconcileRequired = "reconcile_required"
    case uploadRequired = "upload_required"
    case remoteUnavailable = "remote_unavailable"
}

enum CloudBackupContextState: String, Codable, Hashable, Sendable {
    case contextReady = "context_ready"
    case contextStale = "context_stale"
    case reconcileRequired = "reconcile_required"
    case remoteUnavailable = "remote_unavailable"
}

enum CloudInstallAuthMode: String, Codable, Hashable, Sendable {
    case legacyCompat = "legacy_compat"
    case secretValid = "secret_valid"
    case unboundSecret = "unbound_secret"
}

enum CloudBackupRestoreDecisionAction: String, Codable, Hashable, Sendable {
    case apply
    case ignore
}

struct CloudBackupStatusActions: Codable, Hashable, Sendable {
    var canUseRemoteAIContextNow: Bool
    var shouldUpload: Bool
    var shouldOfferRestore: Bool
    var shouldBuildInlineFallback: Bool
    var shouldPromptUser: Bool
}

struct CloudBackupStatusRequest: Codable, Hashable, Sendable {
    var installID: String
    var localBackupHash: String?
    var localSourceModifiedAt: Date?
    var localStateKind: CloudLocalStateKind
}

struct CloudBackupStatusResponse: Codable, Hashable, Sendable {
    var syncState: CloudBackupSyncState
    var contextState: CloudBackupContextState
    var reasonCodes: [String]
    var actions: CloudBackupStatusActions
    var authMode: CloudInstallAuthMode
    var remote: CloudBackupHead?
}

struct CloudBackupRestoreDecisionRequest: Codable, Hashable, Sendable {
    var installID: String
    var remoteVersion: Int
    var localBackupHash: String?
    var action: CloudBackupRestoreDecisionAction
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

struct CloudCoachMemoryClearRequest: Codable, Hashable, Sendable {
    var installID: String
    var providerID: String?
    var clearInsightsCache: Bool
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
    var keyObservations: [String] = []
    var topConstraints: [String] = []
    var recommendations: [String]
    var confidenceNotes: [String] = []
    var executionContext: CoachProfileExecutionContext? = nil
    var generationStatus: CoachResponseGenerationStatus? = nil
    var insightSource: CoachInsightsOrigin? = nil
    var provider: CoachAIProvider? = nil
    var selectedModel: String? = nil

    var resolvedInsightSource: CoachInsightsOrigin {
        if let insightSource {
            return insightSource
        }

        return generationStatus == .model ? .freshModel : .fallback
    }

    var isModelGenerated: Bool {
        resolvedInsightSource != .fallback
    }
}

struct CoachProfileExecutionContext: Codable, Hashable, Sendable {
    var mode: String
    var effectiveWeeklyFrequency: Double
    var shouldTreatProgramCountAsMismatch: Bool
    var programWorkoutCount: Int?
    var weeklyTarget: Int
    var statedWeeklyFrequency: Int?
    var observedAverageWorkoutsPerWeek: Double?
    var templateRotationSemantics: String
    var authoritativeSignal: String
    var userNote: String?
    var explanation: String
    var evidence: [String]
}

struct CoachChatResponse: Codable, Hashable, Sendable {
    var answerMarkdown: String
    var responseID: String?
    var followUps: [String]
    var generationStatus: CoachResponseGenerationStatus? = nil
    var provider: CoachAIProvider? = nil
    var selectedModel: String? = nil

    var isModelGenerated: Bool {
        generationStatus == .model
    }
}

struct CoachJobMetadata: Codable, Hashable, Sendable {
    var provider: CoachAIProvider?
    var selectedModel: String?
    var jobDeadlineAt: Date?
    var contextProfile: String?
    var promptProfile: String?
    var contextVersion: String?
    var analyticsVersion: String?
    var memoryProfile: String?
    var providerID: String?
    var useCase: String?
    var modelRole: String?
    var allowedContextProfiles: [String]?
    var payloadTier: String?
    var routingVersion: String?
    var memoryCompatibilityKey: String?
    var promptFamily: String?
    var contextFamily: String?
    var routingReasonTags: [String]?

    init(
        provider: CoachAIProvider? = nil,
        selectedModel: String? = nil,
        jobDeadlineAt: Date? = nil,
        contextProfile: String? = nil,
        promptProfile: String? = nil,
        contextVersion: String? = nil,
        analyticsVersion: String? = nil,
        memoryProfile: String? = nil,
        providerID: String? = nil,
        useCase: String? = nil,
        modelRole: String? = nil,
        allowedContextProfiles: [String]? = nil,
        payloadTier: String? = nil,
        routingVersion: String? = nil,
        memoryCompatibilityKey: String? = nil,
        promptFamily: String? = nil,
        contextFamily: String? = nil,
        routingReasonTags: [String]? = nil
    ) {
        self.provider = provider
        self.selectedModel = selectedModel
        self.jobDeadlineAt = jobDeadlineAt
        self.contextProfile = contextProfile
        self.promptProfile = promptProfile
        self.contextVersion = contextVersion
        self.analyticsVersion = analyticsVersion
        self.memoryProfile = memoryProfile
        self.providerID = providerID
        self.useCase = useCase
        self.modelRole = modelRole
        self.allowedContextProfiles = allowedContextProfiles
        self.payloadTier = payloadTier
        self.routingVersion = routingVersion
        self.memoryCompatibilityKey = memoryCompatibilityKey
        self.promptFamily = promptFamily
        self.contextFamily = contextFamily
        self.routingReasonTags = routingReasonTags
    }
}

struct CoachProfileInsightsJobCreateResponse: Codable, Hashable, Sendable {
    var jobID: String
    var status: CoachChatJobStatus
    var createdAt: Date
    var pollAfterMs: Int
    var metadata: CoachJobMetadata?
}

struct CoachProfileInsightsJobResult: Codable, Hashable, Sendable {
    var summary: String
    var keyObservations: [String]
    var topConstraints: [String]
    var recommendations: [String]
    var confidenceNotes: [String]
    var executionContext: CoachProfileExecutionContext?
    var generationStatus: CoachResponseGenerationStatus? = nil
    var insightSource: CoachInsightsOrigin? = nil
    var selectedModel: String? = nil
    var inferenceMode: CoachChatInferenceMode
    var modelDurationMs: Int?
    var totalJobDurationMs: Int?
}

struct CoachProfileInsightsJobStatusResponse: Codable, Hashable, Sendable {
    var jobID: String
    var status: CoachChatJobStatus
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var result: CoachProfileInsightsJobResult?
    var error: CoachChatJobError?
    var metadata: CoachJobMetadata?
}

struct CoachChatJobCreateResponse: Codable, Hashable, Sendable {
    var jobID: String
    var status: CoachChatJobStatus
    var createdAt: Date
    var pollAfterMs: Int
    var metadata: CoachJobMetadata?
}

struct CoachChatJobResult: Codable, Hashable, Sendable {
    var answerMarkdown: String
    var responseID: String
    var followUps: [String]
    var generationStatus: CoachResponseGenerationStatus? = nil
    var provider: CoachAIProvider? = nil
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
    var metadata: CoachJobMetadata?
}

private struct CoachAPIErrorPayload: Codable, Hashable, Sendable {
    var code: String
    var message: String
    var requestID: String?
}

private struct CoachAPIErrorResponse: Codable, Hashable, Sendable {
    var error: CoachAPIErrorPayload
    var jobID: String?
    var provider: CoachAIProvider?
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
    var createdAt: Date
    var followUps: [String]
    var generationStatus: CoachResponseGenerationStatus? = nil
    var provider: CoachAIProvider? = nil
    var selectedModel: String? = nil
    var isLoading: Bool
    var isStatus: Bool

    init(
        id: String = UUID().uuidString,
        role: CoachChatRole,
        content: String,
        createdAt: Date = Date(),
        followUps: [String] = [],
        generationStatus: CoachResponseGenerationStatus? = nil,
        provider: CoachAIProvider? = nil,
        selectedModel: String? = nil,
        isLoading: Bool = false,
        isStatus: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.followUps = followUps
        self.generationStatus = generationStatus
        self.provider = provider
        self.selectedModel = selectedModel
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
    private static let requestRateLimiter = CoachAIRequestRateLimiter()

    private let configuration: CoachRuntimeConfiguration
    private let standardSession: URLSession
    private let profileInsightsSession: URLSession
    private let chatSession: URLSession
    private let installSecretProvider: @Sendable () -> String?
    private let debugRecorder: any DebugEventRecording

    init(
        configuration: CoachRuntimeConfiguration,
        session: URLSession? = nil,
        profileInsightsSession: URLSession? = nil,
        chatSession: URLSession? = nil,
        installSecretProvider: @escaping @Sendable () -> String? = { nil },
        debugRecorder: any DebugEventRecording = NoopDebugEventRecorder()
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
        self.installSecretProvider = installSecretProvider
        self.debugRecorder = debugRecorder
    }

    func getBackupStatus(_ request: CloudBackupStatusRequest) async throws -> CloudBackupStatusResponse {
        guard configuration.isFeatureEnabled else {
            throw CoachClientError.featureDisabled
        }
        guard let baseURL = configuration.backendBaseURL else {
            throw CoachClientError.missingBaseURL
        }

        var components = URLComponents(
            url: baseURL.appending(path: "v1/backup/status"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "installID", value: request.installID),
            URLQueryItem(name: "localStateKind", value: request.localStateKind.rawValue)
        ]
        if let localBackupHash = request.localBackupHash {
            queryItems.append(URLQueryItem(name: "localBackupHash", value: localBackupHash))
        }
        if let localSourceModifiedAt = request.localSourceModifiedAt {
            queryItems.append(
                URLQueryItem(
                    name: "localSourceModifiedAt",
                    value: localSourceModifiedAt.ISO8601Format()
                )
            )
        }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw CoachClientError.invalidResponse
        }

        return try await sendGet(
            url: url,
            path: "v1/backup/status",
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            installID: request.installID,
            responseType: CloudBackupStatusResponse.self
        )
    }

    func uploadBackup(_ request: CloudBackupUploadRequest) async throws -> CloudBackupHead {
        try await send(
            path: "v1/backup",
            method: "PUT",
            body: request,
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            clientRequestID: nil,
            installID: request.installID,
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
        return try await sendGet(
            url: url,
            path: "v1/backup/download",
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            installID: installID,
            responseType: CloudBackupDownloadResponse.self
        )
    }

    func updateCoachPreferences(_ request: CloudCoachPreferencesUpdateRequest) async throws -> CloudCoachPreferencesUpdateResponse {
        try await send(
            path: "v1/coach/preferences",
            method: "PATCH",
            body: request,
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            clientRequestID: nil,
            installID: request.installID,
            responseType: CloudCoachPreferencesUpdateResponse.self
        )
    }

    func fetchProfileInsights(
        locale: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?,
        forceRefresh: Bool,
        allowDegradedCache: Bool
    ) async throws -> CoachProfileInsights {
        try await send(
            path: "v1/coach/profile-insights",
            method: "POST",
            body: CoachProfileInsightsRequest(
                locale: locale,
                installID: snapshotEnvelope.installID,
                provider: configuration.provider,
                localBackupHash: snapshotEnvelope.localBackupHash,
                snapshotHash: snapshotEnvelope.snapshotHash,
                snapshot: snapshotEnvelope.snapshot,
                snapshotUpdatedAt: snapshotEnvelope.snapshotUpdatedAt,
                runtimeContextDelta: runtimeContextDelta,
                capabilityScope: capabilityScope,
                forceRefresh: forceRefresh ? true : nil,
                allowDegradedCache: allowDegradedCache ? nil : false,
                providerID: coachDefaultProviderID
            ),
            session: profileInsightsSession,
            timeoutInterval: Self.profileInsightsRequestTimeoutInterval,
            clientRequestID: nil,
            installID: snapshotEnvelope.installID,
            responseType: CoachProfileInsights.self
        )
    }

    func createProfileInsightsJob(
        locale: String,
        clientRequestID: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope,
        runtimeContextDelta: CoachRuntimeContextDelta?,
        forceRefresh: Bool,
        allowDegradedCache: Bool
    ) async throws -> CoachProfileInsightsJobCreateResponse {
        try await send(
            path: "v2/coach/profile-insights-jobs",
            method: "POST",
            body: CoachProfileInsightsJobCreateRequest(
                locale: locale,
                installID: snapshotEnvelope.installID,
                provider: configuration.provider,
                localBackupHash: snapshotEnvelope.localBackupHash,
                snapshotHash: snapshotEnvelope.snapshotHash,
                snapshot: snapshotEnvelope.snapshot,
                snapshotUpdatedAt: snapshotEnvelope.snapshotUpdatedAt,
                runtimeContextDelta: runtimeContextDelta,
                capabilityScope: capabilityScope,
                forceRefresh: forceRefresh ? true : nil,
                allowDegradedCache: allowDegradedCache ? nil : false,
                providerID: coachDefaultProviderID,
                clientRequestID: clientRequestID
            ),
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            clientRequestID: clientRequestID,
            installID: snapshotEnvelope.installID,
            responseType: CoachProfileInsightsJobCreateResponse.self
        )
    }

    func getProfileInsightsJob(
        jobID: String,
        installID: String
    ) async throws -> CoachProfileInsightsJobStatusResponse {
        guard configuration.isFeatureEnabled else {
            throw CoachClientError.featureDisabled
        }
        guard let baseURL = configuration.backendBaseURL else {
            throw CoachClientError.missingBaseURL
        }
        var components = URLComponents(
            url: baseURL.appending(path: "v2/coach/profile-insights-jobs/\(jobID)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "installID", value: installID)
        ]

        guard let url = components?.url else {
            throw CoachClientError.invalidResponse
        }
        return try await sendGet(
            url: url,
            path: "v2/coach/profile-insights-jobs/\(jobID)",
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            installID: installID,
            responseType: CoachProfileInsightsJobStatusResponse.self
        )
    }

    func createChatJob(
        locale: String,
        question: String,
        clientRequestID: String,
        clientRecentTurns _: [CoachConversationMessage],
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
                provider: configuration.provider,
                localBackupHash: snapshotEnvelope.localBackupHash,
                snapshotHash: snapshotEnvelope.snapshotHash,
                snapshot: snapshotEnvelope.snapshot,
                snapshotUpdatedAt: snapshotEnvelope.snapshotUpdatedAt,
                runtimeContextDelta: runtimeContextDelta,
                capabilityScope: capabilityScope,
                clientRequestID: clientRequestID,
                providerID: coachDefaultProviderID
            ),
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            clientRequestID: clientRequestID,
            installID: snapshotEnvelope.installID,
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
        return try await sendGet(
            url: url,
            path: "v2/coach/chat-jobs/\(jobID)",
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            installID: installID,
            responseType: CoachChatJobStatusResponse.self
        )
    }

    func createWorkoutSummaryJob(
        _ request: WorkoutSummaryJobCreateRequest
    ) async throws -> WorkoutSummaryJobCreateResponse {
        try await send(
            path: "v2/coach/workout-summary-jobs",
            method: "POST",
            body: request,
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            clientRequestID: request.clientRequestID,
            installID: request.installID,
            responseType: WorkoutSummaryJobCreateResponse.self
        )
    }

    func getWorkoutSummaryJob(
        jobID: String,
        installID: String
    ) async throws -> WorkoutSummaryJobStatusResponse {
        guard configuration.isFeatureEnabled else {
            throw CoachClientError.featureDisabled
        }
        guard let baseURL = configuration.backendBaseURL else {
            throw CoachClientError.missingBaseURL
        }
        var components = URLComponents(
            url: baseURL.appending(path: "v2/coach/workout-summary-jobs/\(jobID)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "installID", value: installID)
        ]

        guard let url = components?.url else {
            throw CoachClientError.invalidResponse
        }
        return try await sendGet(
            url: url,
            path: "v2/coach/workout-summary-jobs/\(jobID)",
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            installID: installID,
            responseType: WorkoutSummaryJobStatusResponse.self
        )
    }

    func sendChat(
        locale: String,
        question: String,
        clientRecentTurns _: [CoachConversationMessage],
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
                provider: configuration.provider,
                localBackupHash: snapshotEnvelope.localBackupHash,
                snapshotHash: snapshotEnvelope.snapshotHash,
                snapshot: snapshotEnvelope.snapshot,
                snapshotUpdatedAt: snapshotEnvelope.snapshotUpdatedAt,
                runtimeContextDelta: runtimeContextDelta,
                capabilityScope: capabilityScope,
                providerID: coachDefaultProviderID
            ),
            session: chatSession,
            timeoutInterval: Self.chatRequestTimeoutInterval,
            clientRequestID: nil,
            installID: snapshotEnvelope.installID,
            responseType: CoachChatResponse.self
        )
    }

    func recordRestoreDecision(_ request: CloudBackupRestoreDecisionRequest) async throws {
        let _: EmptyCoachResponse = try await send(
            path: "v1/backup/restore-decision",
            method: "POST",
            body: request,
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            clientRequestID: nil,
            installID: request.installID,
            responseType: EmptyCoachResponse.self
        )
    }

    func clearRemoteChatMemory(_ request: CloudCoachMemoryClearRequest) async throws {
        let _: EmptyCoachResponse = try await send(
            path: "v1/coach/memory/clear",
            method: "POST",
            body: request,
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            clientRequestID: nil,
            installID: request.installID,
            responseType: EmptyCoachResponse.self
        )
    }

    func deleteRemoteBackup(installID: String) async throws {
        struct DeleteRequest: Encodable {
            let installID: String
        }

        let _: EmptyCoachResponse = try await send(
            path: "v1/backup",
            method: "DELETE",
            body: DeleteRequest(installID: installID),
            session: standardSession,
            timeoutInterval: Self.standardRequestTimeoutInterval,
            clientRequestID: nil,
            installID: installID,
            responseType: EmptyCoachResponse.self
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
            clientRequestID: nil,
            installID: installID,
            responseType: EmptyCoachResponse.self
        )
    }

    private func send<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        method: String,
        body: RequestBody,
        session: URLSession,
        timeoutInterval: TimeInterval,
        clientRequestID: String?,
        installID: String?,
        responseType: ResponseBody.Type
    ) async throws -> ResponseBody {
        _ = responseType
        guard configuration.isFeatureEnabled else {
            throw CoachClientError.featureDisabled
        }
        guard let baseURL = configuration.backendBaseURL else {
            throw CoachClientError.missingBaseURL
        }
        guard let internalBearerToken = configuration.internalBearerToken else {
            throw CoachClientError.missingAuthToken
        }

        let throttleContext = Self.makeThrottleContext(path: path, body: body)
        if let throttleContext {
            await Self.requestRateLimiter.awaitPermit(
                for: throttleContext,
                recorder: debugRecorder
            )
        }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(internalBearerToken)", forHTTPHeaderField: "Authorization")
        applyInstallProof(to: &request, installID: installID)
        request.httpBody = try Self.encoder.encode(body)

        let (data, response, startedAt) = try await tracedData(
            for: request,
            session: session,
            tracePath: path,
            clientRequestID: clientRequestID
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            recordNetworkTrace(
                method: request.httpMethod,
                path: path,
                statusCode: nil,
                startedAt: startedAt,
                requestID: nil,
                clientRequestID: clientRequestID,
                errorDescription: CoachClientError.invalidResponse.errorDescription
            )
            throw CoachClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let clientError = Self.parseAPIErrorResponse(
                data: data,
                statusCode: httpResponse.statusCode
            )
            if let throttleContext,
               case .api(let statusCode, _, _, _, _, _) = clientError,
               statusCode == 429 {
                await Self.requestRateLimiter.registerRateLimitHit(
                    for: throttleContext,
                    recorder: debugRecorder
                )
            }
            recordNetworkTrace(
                method: request.httpMethod,
                path: path,
                statusCode: httpResponse.statusCode,
                startedAt: startedAt,
                requestID: clientError.requestID,
                clientRequestID: clientRequestID,
                errorDescription: clientError.errorDescription
            )
            throw clientError
        }

        do {
            let decoded = try Self.decoder.decode(ResponseBody.self, from: data)
            recordNetworkTrace(
                method: request.httpMethod,
                path: path,
                statusCode: httpResponse.statusCode,
                startedAt: startedAt,
                requestID: nil,
                clientRequestID: clientRequestID,
                errorDescription: nil
            )
            return decoded
        } catch {
            recordNetworkTrace(
                method: request.httpMethod,
                path: path,
                statusCode: httpResponse.statusCode,
                startedAt: startedAt,
                requestID: nil,
                clientRequestID: clientRequestID,
                errorDescription: CoachClientError.invalidResponse.errorDescription
            )
            throw CoachClientError.invalidResponse
        }
    }

    private func sendGet<ResponseBody: Decodable>(
        url: URL,
        path: String,
        session: URLSession,
        timeoutInterval: TimeInterval,
        installID: String?,
        responseType: ResponseBody.Type
    ) async throws -> ResponseBody {
        _ = responseType
        guard configuration.isFeatureEnabled else {
            throw CoachClientError.featureDisabled
        }
        guard let internalBearerToken = configuration.internalBearerToken else {
            throw CoachClientError.missingAuthToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(internalBearerToken)", forHTTPHeaderField: "Authorization")
        applyInstallProof(to: &request, installID: installID)

        let (data, response, startedAt) = try await tracedData(
            for: request,
            session: session,
            tracePath: path,
            clientRequestID: nil
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            recordNetworkTrace(
                method: request.httpMethod,
                path: path,
                statusCode: nil,
                startedAt: startedAt,
                requestID: nil,
                clientRequestID: nil,
                errorDescription: CoachClientError.invalidResponse.errorDescription
            )
            throw CoachClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let clientError = Self.parseAPIErrorResponse(
                data: data,
                statusCode: httpResponse.statusCode
            )
            recordNetworkTrace(
                method: request.httpMethod,
                path: path,
                statusCode: httpResponse.statusCode,
                startedAt: startedAt,
                requestID: clientError.requestID,
                clientRequestID: nil,
                errorDescription: clientError.errorDescription
            )
            throw clientError
        }

        do {
            let decoded = try Self.decoder.decode(ResponseBody.self, from: data)
            recordNetworkTrace(
                method: request.httpMethod,
                path: path,
                statusCode: httpResponse.statusCode,
                startedAt: startedAt,
                requestID: nil,
                clientRequestID: nil,
                errorDescription: nil
            )
            return decoded
        } catch {
            recordNetworkTrace(
                method: request.httpMethod,
                path: path,
                statusCode: httpResponse.statusCode,
                startedAt: startedAt,
                requestID: nil,
                clientRequestID: nil,
                errorDescription: CoachClientError.invalidResponse.errorDescription
            )
            throw CoachClientError.invalidResponse
        }
    }

    private func tracedData(
        for request: URLRequest,
        session: URLSession,
        tracePath: String,
        clientRequestID: String?
    ) async throws -> (Data, URLResponse, Date) {
        let startedAt = Date()

        do {
            let (data, response) = try await session.data(for: request)
            return (data, response, startedAt)
        } catch {
            let requestID = (error as? CoachClientError)?.requestID
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            recordNetworkTrace(
                method: request.httpMethod,
                path: tracePath,
                statusCode: nil,
                startedAt: startedAt,
                requestID: requestID,
                clientRequestID: clientRequestID,
                errorDescription: description
            )
            throw error
        }
    }

    private func recordNetworkTrace(
        method: String?,
        path: String,
        statusCode: Int?,
        startedAt: Date,
        requestID: String?,
        clientRequestID: String?,
        errorDescription: String?
    ) {
        debugRecorder.traceNetwork(
            method: method ?? "GET",
            path: path,
            statusCode: statusCode,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
            startedAt: startedAt,
            requestID: requestID,
            clientRequestID: clientRequestID,
            errorDescription: errorDescription
        )
    }

    private func applyInstallProof(to request: inout URLRequest, installID: String?) {
        guard installID != nil,
              let installSecret = installSecretProvider()?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty else {
            return
        }

        request.setValue(installSecret, forHTTPHeaderField: "x-install-secret")
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
                requestID: payload.error.requestID,
                jobID: payload.jobID,
                provider: payload.provider
            )
        }

        return .httpStatus(statusCode)
    }

    private static func makeThrottleContext<RequestBody: Encodable>(
        path: String,
        body: RequestBody
    ) -> CoachAIRequestThrottleContext? {
        if let request = body as? CoachProfileInsightsRequest,
           request.provider == .gemini {
            return CoachAIRequestThrottleContext(
                provider: request.provider,
                operation: .profileInsights
            )
        }

        if let request = body as? CoachProfileInsightsJobCreateRequest,
           request.provider == .gemini {
            return CoachAIRequestThrottleContext(
                provider: request.provider,
                operation: .profileInsights
            )
        }

        if let request = body as? CoachChatJobCreateRequest,
           request.provider == .gemini {
            return CoachAIRequestThrottleContext(
                provider: request.provider,
                operation: .chatJobCreate
            )
        }

        if let request = body as? WorkoutSummaryJobCreateRequest,
           request.provider == .gemini {
            return CoachAIRequestThrottleContext(
                provider: request.provider,
                operation: .workoutSummaryJobCreate
            )
        }

        return nil
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

private struct CoachAIRequestThrottleContext: Sendable {
    enum Operation: String, Sendable {
        case profileInsights = "profile_insights"
        case chatJobCreate = "chat_job_create"
        case workoutSummaryJobCreate = "workout_summary_job_create"

        var minimumSpacing: Duration {
            switch self {
            case .profileInsights:
                return .seconds(2)
            case .chatJobCreate, .workoutSummaryJobCreate:
                return .seconds(1)
            }
        }

        var cooldownAfterRateLimit: Duration {
            switch self {
            case .profileInsights:
                return .seconds(5)
            case .chatJobCreate, .workoutSummaryJobCreate:
                return .seconds(3)
            }
        }
    }

    let provider: CoachAIProvider
    let operation: Operation

    var key: String {
        "\(provider.rawValue):\(operation.rawValue)"
    }
}

private actor CoachAIRequestRateLimiter {
    private let clock = ContinuousClock()
    private var nextPermittedTime: [String: ContinuousClock.Instant] = [:]

    func awaitPermit(
        for context: CoachAIRequestThrottleContext,
        recorder: any DebugEventRecording
    ) async {
        let now = clock.now
        let permittedAt = nextPermittedTime[context.key] ?? now
        if permittedAt > now {
            let delay = now.duration(to: permittedAt)
            let delayMs = max(0, Int(delay.components.seconds * 1_000) + Int(delay.components.attoseconds / 1_000_000_000_000_000))
            recorder.log(
                category: .coach,
                message: "ai_request_throttled",
                metadata: [
                    "provider": context.provider.rawValue,
                    "operation": context.operation.rawValue,
                    "delayMs": String(delayMs)
                ]
            )
            try? await Task.sleep(for: delay)
        }

        nextPermittedTime[context.key] = clock.now.advanced(by: context.operation.minimumSpacing)
    }

    func registerRateLimitHit(
        for context: CoachAIRequestThrottleContext,
        recorder: any DebugEventRecording
    ) {
        let cooldownUntil = clock.now.advanced(by: context.operation.cooldownAfterRateLimit)
        let existing = nextPermittedTime[context.key] ?? clock.now
        if cooldownUntil > existing {
            nextPermittedTime[context.key] = cooldownUntil
        }
        recorder.log(
            category: .coach,
            level: .error,
            message: "ai_request_rate_limited",
            metadata: [
                "provider": context.provider.rawValue,
                "operation": context.operation.rawValue,
                "cooldownMs": String(
                    Int(context.operation.cooldownAfterRateLimit.components.seconds * 1_000)
                )
            ]
        )
    }
}

struct CoachContextBuilder {
    private static let recentFinishedSessionsLimit = 12

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
        let preferredProgram = PreferredProgramResolver.resolve(
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
                            message: ProfileCompatibilityMessageFormatter.message(for: issue)
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
            generationStatus: .fallback,
            insightSource: .fallback
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

enum CloudRemoteDecisionMode: Hashable, Sendable {
    case restore
    case conflict
}

struct CloudPendingRemoteRestore: Identifiable, Sendable {
    let id: String
    var mode: CloudRemoteDecisionMode
    var response: CloudBackupDownloadResponse
    var localBackupHash: String?

    init(
        mode: CloudRemoteDecisionMode,
        response: CloudBackupDownloadResponse,
        localBackupHash: String?
    ) {
        self.id = "\(mode)-\(response.remote.backupVersion)-\(response.remote.backupHash)"
        self.mode = mode
        self.response = response
        self.localBackupHash = localBackupHash
    }
}

struct CloudSyncPreparationResult: Sendable {
    var localBackupHash: String?
    var status: CloudBackupStatusResponse?
    var canUseRemoteAIContextNow: Bool
    var shouldBuildInlineFallback: Bool

    static let empty = CloudSyncPreparationResult(
        localBackupHash: nil,
        status: nil,
        canUseRemoteAIContextNow: false,
        shouldBuildInlineFallback: false
    )

    var shouldUseRemoteContext: Bool {
        canUseRemoteAIContextNow
    }
}

@MainActor
@Observable
final class CloudSyncStore {
    var isSyncInProgress = false
    var lastSyncErrorDescription: String?
    var pendingRemoteRestore: CloudPendingRemoteRestore?
    var lastBackupStatus: CloudBackupStatusResponse?
    var lastStatusCheckedAt: Date?

    @ObservationIgnored private var client: any CoachAPIClient
    @ObservationIgnored private let localStateStore: CloudSyncLocalStateStore
    @ObservationIgnored private let installID: String
    @ObservationIgnored private let installSecretProvider: @Sendable () -> String?
    @ObservationIgnored private let debugRecorder: any DebugEventRecording
    private var configuration: CoachRuntimeConfiguration

    init(
        client: any CoachAPIClient,
        configuration: CoachRuntimeConfiguration,
        installID: String,
        installSecretProvider: @escaping @Sendable () -> String? = { nil },
        localStateStore: CloudSyncLocalStateStore = CloudSyncLocalStateStore(),
        debugRecorder: any DebugEventRecording = NoopDebugEventRecorder()
    ) {
        self.client = client
        self.configuration = configuration
        self.installID = installID
        self.installSecretProvider = installSecretProvider
        self.localStateStore = localStateStore
        self.debugRecorder = debugRecorder
    }

    func updateConfiguration(_ configuration: CoachRuntimeConfiguration) {
        self.configuration = configuration
        client = CoachAPIHTTPClient(
            configuration: configuration,
            installSecretProvider: installSecretProvider,
            debugRecorder: debugRecorder
        )
        pendingRemoteRestore = nil
        lastBackupStatus = nil
        lastStatusCheckedAt = nil
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
    ) async -> CloudSyncPreparationResult {
        guard configuration.canUseRemoteCoach else {
            return CloudSyncPreparationResult(
                localBackupHash: appStore.localBackupHash,
                status: nil,
                canUseRemoteAIContextNow: false,
                shouldBuildInlineFallback: appStore.localBackupHash != nil
            )
        }
        guard !isSyncInProgress else {
            debugRecorder.log(
                category: .cloudSync,
                message: "sync_skipped",
                metadata: ["reason": "already_in_progress"]
            )
            return currentPreparation(localBackupHash: appStore.localBackupHash)
        }

        debugRecorder.log(
            category: .cloudSync,
            message: "sync_started",
            metadata: [
                "allowUserPrompt": allowUserPrompt ? "true" : "false",
                "localStateKind": appStore.cloudLocalStateKind.rawValue
            ]
        )
        isSyncInProgress = true
        defer { isSyncInProgress = false }

        do {
            let snapshot = appStore.currentSnapshot()
            let localBackupHash: String
            if let hash = appStore.localBackupHash {
                localBackupHash = hash
            } else {
                localBackupHash = try CloudBackupHashing.hash(for: snapshot)
            }
            let statusRequest = CloudBackupStatusRequest(
                installID: installID,
                localBackupHash: localBackupHash,
                localSourceModifiedAt: appStore.localStateUpdatedAt,
                localStateKind: appStore.cloudLocalStateKind
            )
            let status = try await client.getBackupStatus(statusRequest)
            applyStatus(status, localBackupHash: localBackupHash)

            if status.actions.canUseRemoteAIContextNow {
                debugRecorder.log(
                    category: .cloudSync,
                    message: "status_context_ready",
                    metadata: [
                        "syncState": status.syncState.rawValue,
                        "contextState": status.contextState.rawValue
                    ]
                )
                return currentPreparation(localBackupHash: localBackupHash)
            }

            if status.actions.shouldUpload {
                debugRecorder.log(
                    category: .cloudSync,
                    message: "upload_started",
                    metadata: [
                        "hasRemoteVersion": status.remote?.backupVersion != nil ? "true" : "false",
                        "reasonCodes": status.reasonCodes.joined(separator: ",")
                    ]
                )
                let uploaded = try await client.uploadBackup(
                    CloudBackupUploadRequest(
                        installID: installID,
                        expectedRemoteVersion: status.remote?.backupVersion,
                        backupHash: localBackupHash,
                        clientSourceModifiedAt: appStore.localStateUpdatedAt,
                        appVersion: BackupConstants.appVersion,
                        buildNumber: BackupConstants.buildNumber,
                        snapshot: snapshot
                    )
                )
                appStore.adoptRemoteBackupHash(uploaded.backupHash)
                let resolvedLocalBackupHash = appStore.localBackupHash ?? uploaded.backupHash
                let readyStatus = CloudBackupStatusResponse(
                    syncState: .remoteReady,
                    contextState: .contextReady,
                    reasonCodes: ["upload_succeeded"],
                    actions: CloudBackupStatusActions(
                        canUseRemoteAIContextNow: true,
                        shouldUpload: false,
                        shouldOfferRestore: false,
                        shouldBuildInlineFallback: false,
                        shouldPromptUser: false
                    ),
                    authMode: status.authMode,
                    remote: uploaded
                )
                applyStatus(readyStatus, localBackupHash: resolvedLocalBackupHash)
                lastSyncErrorDescription = nil
                debugRecorder.log(
                    category: .cloudSync,
                    message: "upload_succeeded",
                    metadata: [
                        "remoteVersion": String(uploaded.backupVersion),
                        "adoptedRemoteHash": resolvedLocalBackupHash == uploaded.backupHash ? "true" : "false"
                    ]
                )
                return currentPreparation(localBackupHash: resolvedLocalBackupHash)
            }

            if status.actions.shouldOfferRestore,
               status.actions.shouldPromptUser,
               allowUserPrompt,
               status.remote != nil {
                let download = try await client.downloadBackup(installID: installID, version: nil)
                let mode: CloudRemoteDecisionMode = status.syncState == .conflict ? .conflict : .restore
                pendingRemoteRestore = CloudPendingRemoteRestore(
                    mode: mode,
                    response: download,
                    localBackupHash: localBackupHash
                )
                lastSyncErrorDescription = nil
                debugRecorder.log(
                    category: .cloudSync,
                    message: "download_prompted",
                    metadata: [
                        "mode": mode == .conflict ? "conflict" : "restore",
                        "remoteVersion": String(download.remote.backupVersion)
                    ]
                )
            }

            return currentPreparation(localBackupHash: localBackupHash)
        } catch {
            lastSyncErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            debugRecorder.log(
                category: .cloudSync,
                level: .error,
                message: "sync_failed",
                metadata: [
                    "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ]
            )
            return currentPreparation(localBackupHash: appStore.localBackupHash)
        }
    }

    func confirmPendingRemoteRestore(using appStore: AppStore) async {
        guard let pendingRemoteRestore else {
            return
        }

        appStore.applyRemoteRestore(
            snapshot: pendingRemoteRestore.response.backup.snapshot,
            remoteBackupHash: pendingRemoteRestore.response.remote.backupHash
        )
        let localBackupHash = appStore.localBackupHash ?? pendingRemoteRestore.response.remote.backupHash
        do {
            try await client.recordRestoreDecision(
                CloudBackupRestoreDecisionRequest(
                    installID: installID,
                    remoteVersion: pendingRemoteRestore.response.remote.backupVersion,
                    localBackupHash: pendingRemoteRestore.localBackupHash,
                    action: .apply
                )
            )
        } catch {
            debugRecorder.log(
                category: .cloudSync,
                level: .warning,
                message: "restore_decision_record_failed",
                metadata: [
                    "action": "apply",
                    "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ]
            )
        }

        let appliedStatus = CloudBackupStatusResponse(
            syncState: .remoteReady,
            contextState: .contextReady,
            reasonCodes: ["restore_applied"],
            actions: CloudBackupStatusActions(
                canUseRemoteAIContextNow: true,
                shouldUpload: false,
                shouldOfferRestore: false,
                shouldBuildInlineFallback: false,
                shouldPromptUser: false
            ),
            authMode: lastBackupStatus?.authMode ?? .legacyCompat,
            remote: pendingRemoteRestore.response.remote
        )
        applyStatus(appliedStatus, localBackupHash: localBackupHash)
        self.pendingRemoteRestore = nil
        lastSyncErrorDescription = nil
        debugRecorder.log(
            category: .cloudSync,
            message: "restore_confirmed",
            metadata: [
                "mode": pendingRemoteRestore.mode == .conflict ? "conflict" : "restore",
                "remoteVersion": String(pendingRemoteRestore.response.remote.backupVersion)
            ]
        )
    }

    func dismissPendingRemoteRestore() async {
        guard let pendingRemoteRestore else {
            return
        }

        do {
            try await client.recordRestoreDecision(
                CloudBackupRestoreDecisionRequest(
                    installID: installID,
                    remoteVersion: pendingRemoteRestore.response.remote.backupVersion,
                    localBackupHash: pendingRemoteRestore.localBackupHash,
                    action: .ignore
                )
            )
        } catch {
            debugRecorder.log(
                category: .cloudSync,
                level: .warning,
                message: "restore_decision_record_failed",
                metadata: [
                    "action": "ignore",
                    "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ]
            )
        }

        let ignoredStatus = CloudBackupStatusResponse(
            syncState: .remoteNewerThanLocal,
            contextState: .contextStale,
            reasonCodes: ["restore_previously_ignored"],
            actions: CloudBackupStatusActions(
                canUseRemoteAIContextNow: false,
                shouldUpload: false,
                shouldOfferRestore: true,
                shouldBuildInlineFallback: true,
                shouldPromptUser: false
            ),
            authMode: lastBackupStatus?.authMode ?? .legacyCompat,
            remote: pendingRemoteRestore.response.remote
        )
        applyStatus(ignoredStatus, localBackupHash: pendingRemoteRestore.localBackupHash)
        self.pendingRemoteRestore = nil
        debugRecorder.log(
            category: .cloudSync,
            message: "restore_dismissed",
            metadata: [
                "mode": pendingRemoteRestore.mode == .conflict ? "conflict" : "restore",
                "remoteVersion": String(pendingRemoteRestore.response.remote.backupVersion)
            ]
        )
    }

    func clearRemoteBackup(using appStore: AppStore) async {
        do {
            try await client.deleteRemoteBackup(installID: installID)
            let clearedStatus = CloudBackupStatusResponse(
                syncState: .noRemoteBackup,
                contextState: .reconcileRequired,
                reasonCodes: ["remote_backup_deleted"],
                actions: CloudBackupStatusActions(
                    canUseRemoteAIContextNow: false,
                    shouldUpload: appStore.cloudLocalStateKind == .userData && appStore.localBackupHash != nil,
                    shouldOfferRestore: false,
                    shouldBuildInlineFallback: appStore.localBackupHash != nil,
                    shouldPromptUser: false
                ),
                authMode: lastBackupStatus?.authMode ?? .legacyCompat,
                remote: nil
            )
            applyStatus(clearedStatus, localBackupHash: appStore.localBackupHash)
            pendingRemoteRestore = nil
            lastSyncErrorDescription = nil
        } catch {
            lastSyncErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func resetRemoteState(using appStore: AppStore) async {
        do {
            try await client.deleteRemoteState(installID: installID)
            let clearedStatus = CloudBackupStatusResponse(
                syncState: .noRemoteBackup,
                contextState: .reconcileRequired,
                reasonCodes: ["remote_state_reset"],
                actions: CloudBackupStatusActions(
                    canUseRemoteAIContextNow: false,
                    shouldUpload: appStore.cloudLocalStateKind == .userData && appStore.localBackupHash != nil,
                    shouldOfferRestore: false,
                    shouldBuildInlineFallback: appStore.localBackupHash != nil,
                    shouldPromptUser: false
                ),
                authMode: lastBackupStatus?.authMode ?? .legacyCompat,
                remote: nil
            )
            applyStatus(clearedStatus, localBackupHash: appStore.localBackupHash)
            pendingRemoteRestore = nil
            lastSyncErrorDescription = nil
        } catch {
            lastSyncErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func canUseServerSideContext(using appStore: AppStore) -> Bool {
        guard let localBackupHash = appStore.localBackupHash else {
            return false
        }

        return localStateStore.canUseServerSideContext(for: localBackupHash)
    }

    private func applyStatus(_ status: CloudBackupStatusResponse, localBackupHash: String?) {
        lastBackupStatus = status
        lastStatusCheckedAt = .now
        localStateStore.applyStatus(status, localBackupHash: localBackupHash)
        lastSyncErrorDescription = nil
    }

    private func currentPreparation(localBackupHash: String?) -> CloudSyncPreparationResult {
        CloudSyncPreparationResult(
            localBackupHash: localBackupHash,
            status: lastBackupStatus,
            canUseRemoteAIContextNow: localBackupHash.map { localStateStore.canUseServerSideContext(for: $0) } ?? false,
            shouldBuildInlineFallback: lastBackupStatus?.actions.shouldBuildInlineFallback
                ?? (localBackupHash != nil)
        )
    }
}

private struct PendingCoachChatJobState: Codable, Hashable, Sendable {
    var jobID: String
    var installID: String
    var pollStartedAt: Date?
    var nextPollAfterMs: Int
    var providerID: String
}

private struct PendingProfileInsightsJobState: Codable, Hashable, Sendable {
    var jobID: String
    var installID: String
    var providerID: String
}

@MainActor
@Observable
final class CoachStore {
    private static let initialChatPollAfterMs = 1_500
    private static let initialProfileInsightsPollAfterMs = 1_500
    private static let profileInsightsResumeCooldown: TimeInterval = 20

    var profileInsights: CoachProfileInsights?
    var profileInsightsOrigin: CoachInsightsOrigin = .fallback
    var messages: [CoachChatMessage] = []
    var visibleQuickPromptKeys: [String] = []
    var isLoadingProfileInsights = false
    var isSendingMessage = false
    var activeProfileInsightsJobID: String?
    var activeProfileInsightsInstallID: String?
    var activeProfileInsightsProvider: CoachAIProvider?
    var activeChatJobID: String?
    var activeChatInstallID: String?
    var activeChatProvider: CoachAIProvider?
    var activeChatAwaitingResume = false
    var analysisSettingsSaveState: CoachAnalysisSettingsSaveState = .idle
    var lastInsightsErrorDescription: String?
    var lastChatErrorDescription: String?
    var lastInsightsProvider: CoachAIProvider?
    var lastChatProvider: CoachAIProvider?
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
    @ObservationIgnored private var activeProfileInsightsRetryNotBefore: Date?
    @ObservationIgnored private var activeChatPollTask: Task<Void, Never>?
    @ObservationIgnored private var activeChatPollTaskJobID: String?
    @ObservationIgnored private var hasHydratedAnalysisSettingsDrafts = false
    @ObservationIgnored private let maxChatPollingDuration: TimeInterval
    @ObservationIgnored private let debugRecorder: any DebugEventRecording
    private var configuration: CoachRuntimeConfiguration
    @ObservationIgnored private let capabilityScope: CoachCapabilityScope

    init(
        client: any CoachAPIClient,
        configuration: CoachRuntimeConfiguration,
        localStateStore: CoachLocalStateStore = CoachLocalStateStore(),
        cloudSyncStore: CloudSyncStore? = nil,
        contextBuilder: CoachContextBuilder = CoachContextBuilder(),
        capabilityScope: CoachCapabilityScope = .draftChanges,
        maxChatPollingDuration: TimeInterval = coachStoreDefaultMaxChatPollingDuration,
        debugRecorder: any DebugEventRecording = NoopDebugEventRecorder()
    ) {
        self.client = client
        self.configuration = configuration
        self.localStateStore = localStateStore
        self.debugRecorder = debugRecorder
        self.cloudSyncStore = cloudSyncStore ?? CloudSyncStore(
            client: client,
            configuration: configuration,
            installID: localStateStore.installID,
            installSecretProvider: { localStateStore.installSecret },
            localStateStore: CloudSyncLocalStateStore(defaults: localStateStore.userDefaults),
            debugRecorder: debugRecorder
        )
        self.contextBuilder = contextBuilder
        self.capabilityScope = capabilityScope
        self.maxChatPollingDuration = maxChatPollingDuration
        self.allQuickPromptKeys = CoachStore.makeQuickPromptKeys()
        configureQuickPromptsIfNeeded()
        restorePersistedPendingProfileInsightsJobIfNeeded()
        restorePersistedPendingChatJobIfNeeded()
    }

    var canUseRemoteCoach: Bool {
        configuration.canUseRemoteCoach
    }

    var isSavingAnalysisSettings: Bool {
        analysisSettingsSaveState == .saving
    }

    var canResumePendingChatJob: Bool {
        activeChatJobID != nil && !isSendingMessage && activeChatPollTask == nil
    }

    func updateConfiguration(_ configuration: CoachRuntimeConfiguration) {
        let providerChanged = self.configuration.provider != configuration.provider
        self.configuration = configuration
        client = CoachAPIHTTPClient(
            configuration: configuration,
            installSecretProvider: { [localStateStore] in localStateStore.installSecret },
            debugRecorder: debugRecorder
        )
        cloudSyncStore.updateConfiguration(configuration)
        hasHydratedAnalysisSettingsDrafts = false
        clearActiveProfileInsightsJob()
        profileInsights = nil
        profileInsightsOrigin = .fallback
        lastInsightsErrorDescription = nil
        lastInsightsProvider = nil
        if providerChanged {
            lastChatErrorDescription = nil
        }
    }

    func syncAnalysisSettingsDrafts(using appStore: AppStore) {
        guard !hasHydratedAnalysisSettingsDrafts else {
            return
        }

        let savedSettings = appStore.coachAnalysisSettings
        let resolvedProgram = PreferredProgramResolver.resolve(
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
        _ = await cloudSyncStore.syncIfNeeded(using: appStore, allowUserPrompt: false)
    }

    func refreshProfileInsights(
        using appStore: AppStore,
        forceRefresh: Bool = false
    ) async {
        if isLoadingProfileInsights {
            debugRecorder.log(
                category: .coach,
                message: "insights_refresh_skipped_loading",
                metadata: [
                    "forceRefresh": forceRefresh ? "true" : "false",
                    "provider": configuration.provider.rawValue
                ]
            )
            return
        }

        if forceRefresh {
            clearActiveProfileInsightsJob()
        }

        let fallbackInsights = CoachFallbackInsightsFactory.make(from: appStore)
        let allowDegradedCache =
            !forceRefresh &&
            profileInsights != nil &&
            profileInsightsOrigin != .fallback

        if !forceRefresh,
           let jobID = activeProfileInsightsJobID,
           let installID = activeProfileInsightsInstallID {
            isLoadingProfileInsights = true
            defer { isLoadingProfileInsights = false }

            guard configuration.canUseRemoteCoach else {
                clearActiveProfileInsightsJob()
                profileInsights = fallbackInsights
                profileInsightsOrigin = .fallback
                lastInsightsErrorDescription = nil
                return
            }

            do {
                let remoteInsights = try await pollProfileInsightsJobUntilTerminal(
                    jobID: jobID,
                    installID: installID,
                    initialPollAfterMs: 0
                )
                applyProfileInsights(remoteInsights)
                lastInsightsErrorDescription = nil
                lastInsightsProvider = configuration.provider
                debugRecorder.log(
                    category: .coach,
                    message: "insights_job_resumed_and_completed",
                    metadata: [
                        "jobID": jobID,
                        "provider": configuration.provider.rawValue,
                        "source": remoteInsights.resolvedInsightSource.rawValue
                    ]
                )
            } catch is CancellationError {
                debugRecorder.log(
                    category: .coach,
                    message: "insights_job_resume_canceled",
                    metadata: ["jobID": jobID]
                )
                return
            } catch {
                profileInsights = fallbackInsights
                profileInsightsOrigin = .fallback
                lastInsightsErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                lastInsightsProvider = configuration.provider
                debugRecorder.log(
                    category: .coach,
                    level: .error,
                    message: "insights_job_resume_failed",
                    metadata: [
                        "jobID": jobID,
                        "provider": configuration.provider.rawValue,
                        "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    ]
                )
            }
            return
        }

        if !forceRefresh, let activeChatJobID {
            debugRecorder.log(
                category: .coach,
                message: "insights_refresh_skipped_active_chat_job",
                metadata: ["jobID": activeChatJobID]
            )
            return
        }

        isLoadingProfileInsights = true
        defer { isLoadingProfileInsights = false }
        debugRecorder.log(
            category: .coach,
            message: "insights_refresh_started",
            metadata: [
                "forceRefresh": forceRefresh ? "true" : "false",
                "allowDegradedCache": allowDegradedCache ? "true" : "false",
                "provider": configuration.provider.rawValue
            ]
        )

        guard configuration.canUseRemoteCoach else {
            profileInsights = fallbackInsights
            profileInsightsOrigin = .fallback
            lastInsightsErrorDescription = nil
            debugRecorder.log(
                category: .coach,
                message: "insights_refresh_fallback",
                metadata: ["reason": "remote_coach_unavailable"]
            )
            return
        }

        do {
            let preparation = await prepareCoachRequestState(
                using: appStore,
                allowUserPrompt: false
            )
            let preferredLocalBackupHash = preparation.localBackupHash ?? appStore.localBackupHash

            func performInsightsRequest(
                includeInlineSnapshot: Bool
            ) async throws -> (CoachProfileInsights, CoachSnapshotPackage, CoachProfileInsightsJobCreateResponse) {
                let snapshotPackage = try makeSnapshotPackage(
                    from: appStore,
                    localBackupHash: preferredLocalBackupHash,
                    includeInlineSnapshot: includeInlineSnapshot
                )
                let createResponse = try await client.createProfileInsightsJob(
                    locale: appStore.selectedLanguageCode,
                    clientRequestID: UUID().uuidString,
                    snapshotEnvelope: snapshotPackage.envelope,
                    capabilityScope: capabilityScope,
                    runtimeContextDelta: includeInlineSnapshot
                        ? nil
                        : (preparation.canUseRemoteAIContextNow
                            ? contextBuilder.runtimeContextDelta(from: appStore)
                            : nil),
                    forceRefresh: forceRefresh,
                    allowDegradedCache: allowDegradedCache
                )
                beginProfileInsightsJob(
                    jobID: createResponse.jobID,
                    installID: snapshotPackage.envelope.installID,
                    provider: createResponse.metadata?.provider ?? configuration.provider
                )
                let remoteInsights = try await pollProfileInsightsJobUntilTerminal(
                    jobID: createResponse.jobID,
                    installID: snapshotPackage.envelope.installID,
                    initialPollAfterMs: createResponse.pollAfterMs
                )
                return (remoteInsights, snapshotPackage, createResponse)
            }

            let initialIncludeInlineSnapshot =
                !preparation.canUseRemoteAIContextNow && preparation.shouldBuildInlineFallback
            var remoteInsights: CoachProfileInsights
            var snapshotPackage: CoachSnapshotPackage
            var createResponse: CoachProfileInsightsJobCreateResponse
            do {
                (remoteInsights, snapshotPackage, createResponse) = try await performInsightsRequest(
                    includeInlineSnapshot: initialIncludeInlineSnapshot
                )
            } catch let error as CoachClientError
            where error.isRemoteHeadChanged && !initialIncludeInlineSnapshot {
                debugRecorder.log(
                    category: .coach,
                    level: .warning,
                    message: "insights_remote_head_changed_retry",
                    metadata: ["provider": configuration.provider.rawValue]
                )
                (remoteInsights, snapshotPackage, createResponse) = try await performInsightsRequest(
                    includeInlineSnapshot: true
                )
            }
            applyProfileInsights(remoteInsights)
            lastInsightsErrorDescription = nil
            lastInsightsProvider = configuration.provider
            debugRecorder.log(
                category: .coach,
                message: "insights_refresh_succeeded",
                metadata: [
                    "jobID": createResponse.jobID,
                    "source": remoteInsights.resolvedInsightSource.rawValue,
                    "provider": configuration.provider.rawValue,
                    "selectedModel": remoteInsights.selectedModel ?? "",
                    "usedServerSideContext": snapshotPackage.includedInlineSnapshot ? "false" : "true",
                    "includedInlineSnapshot": snapshotPackage.includedInlineSnapshot ? "true" : "false"
                ]
            )
        } catch is CancellationError {
            debugRecorder.log(
                category: .coach,
                message: "insights_refresh_canceled",
                metadata: ["provider": configuration.provider.rawValue]
            )
            return
        } catch {
            profileInsights = fallbackInsights
            profileInsightsOrigin = .fallback
            lastInsightsErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastInsightsProvider = configuration.provider
            debugRecorder.log(
                category: .coach,
                level: .error,
                message: "insights_refresh_failed",
                metadata: [
                    "provider": configuration.provider.rawValue,
                    "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ]
            )
        }
    }

    private func applyProfileInsights(_ insights: CoachProfileInsights) {
        profileInsights = {
            var value = insights
            value.provider = configuration.provider
            return value
        }()
        profileInsightsOrigin = insights.resolvedInsightSource
    }

    private func beginProfileInsightsJob(
        jobID: String,
        installID: String,
        provider: CoachAIProvider
    ) {
        activeProfileInsightsJobID = jobID
        activeProfileInsightsInstallID = installID
        activeProfileInsightsProvider = provider
        activeProfileInsightsRetryNotBefore = nil
        persistPendingProfileInsightsJobState()
    }

    private func clearActiveProfileInsightsJob() {
        activeProfileInsightsJobID = nil
        activeProfileInsightsInstallID = nil
        activeProfileInsightsProvider = nil
        activeProfileInsightsRetryNotBefore = nil
        persistPendingProfileInsightsJobState()
    }

    private func pollProfileInsightsJobUntilTerminal(
        jobID: String,
        installID: String,
        initialPollAfterMs: Int
    ) async throws -> CoachProfileInsights {
        let startedAt = Date()
        var nextDelayMs = max(
            initialPollAfterMs,
            CoachStore.initialProfileInsightsPollAfterMs
        )
        var pollAttempt = 0

        while Date().timeIntervalSince(startedAt) < maxChatPollingDuration {
            if pollAttempt > 0 || initialPollAfterMs == 0 {
                let response = try await client.getProfileInsightsJob(
                    jobID: jobID,
                    installID: installID
                )
                if response.status.isCompletedForUserFlow {
                    clearActiveProfileInsightsJob()
                    guard let result = response.result else {
                        throw CoachClientError.invalidResponse
                    }
                    return CoachProfileInsights(
                        summary: result.summary,
                        keyObservations: result.keyObservations,
                        topConstraints: result.topConstraints,
                        recommendations: result.recommendations,
                        confidenceNotes: result.confidenceNotes,
                        executionContext: result.executionContext,
                        generationStatus: result.generationStatus,
                        insightSource: result.insightSource,
                        provider: response.metadata?.provider ?? activeProfileInsightsProvider,
                        selectedModel: result.selectedModel ?? response.metadata?.selectedModel
                    )
                }

                if response.status.isFailureForUserFlow {
                    clearActiveProfileInsightsJob()
                    throw CoachClientError.api(
                        statusCode: 500,
                        code: response.error?.code ?? "profile_insights_job_failed",
                        message: profileInsightsJobFailureDescription(from: response),
                        requestID: nil,
                        jobID: response.jobID,
                        provider: response.metadata?.provider ?? activeProfileInsightsProvider
                    )
                }
            }

            if nextDelayMs > 0 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: UInt64(nextDelayMs) * 1_000_000)
            }

            pollAttempt += 1
            nextDelayMs = profileInsightsPollIntervalMs(for: pollAttempt)
        }

        throw CoachClientError.api(
            statusCode: 202,
            code: "profile_insights_job_poll_timeout",
            message: coachLocalizedString("coach.loading.profile_insights"),
            requestID: nil,
            jobID: jobID,
            provider: activeProfileInsightsProvider
        )
    }

    private func profileInsightsPollIntervalMs(for attempt: Int) -> Int {
        switch attempt {
        case 0:
            return CoachStore.initialProfileInsightsPollAfterMs
        case 1:
            return 3_000
        default:
            return 5_000
        }
    }

    private func profileInsightsJobFailureDescription(
        from jobResponse: CoachProfileInsightsJobStatusResponse
    ) -> String {
        if let message = coachUserFacingJobFailureMessage(
            status: jobResponse.status,
            error: jobResponse.error
        ) {
            return message
        }

        return coachLocalizedString("coach.error.invalid_response")
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
        debugRecorder.log(
            category: .coach,
            message: "analysis_settings_saved",
            metadata: [
                "hasSelectedProgram": selectedProgramID != nil ? "true" : "false",
                "hasProgramComment": normalizedComment.isEmpty ? "false" : "true"
            ]
        )

        appStore.updateCoachAnalysisSettings { settings in
            settings.selectedProgramID = selectedProgramID
            settings.programComment = normalizedComment
        }
        syncAnalysisSettingsDrafts(using: appStore)

        _ = await cloudSyncStore.syncIfNeeded(
            using: appStore,
            allowUserPrompt: false
        )

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
            debugRecorder.log(
                category: .coach,
                level: .warning,
                message: "chat_job_failed",
                metadata: ["reason": "remote_coach_unavailable"]
            )
            return
        }

        do {
            let preparation = await prepareCoachRequestState(
                using: appStore,
                allowUserPrompt: false
            )
            let preferredLocalBackupHash = preparation.localBackupHash ?? appStore.localBackupHash
            func buildSnapshotPackage(includeInlineSnapshot: Bool) throws -> CoachSnapshotPackage {
                try makeSnapshotPackage(
                    from: appStore,
                    localBackupHash: preferredLocalBackupHash,
                    includeInlineSnapshot: includeInlineSnapshot
                )
            }
            let clientRequestID = UUID().uuidString.lowercased()
            let initialIncludeInlineSnapshot =
                !preparation.canUseRemoteAIContextNow && preparation.shouldBuildInlineFallback
            var snapshotPackage = try buildSnapshotPackage(
                includeInlineSnapshot: initialIncludeInlineSnapshot
            )

            do {
                let createResponse: CoachChatJobCreateResponse
                do {
                    createResponse = try await client.createChatJob(
                        locale: appStore.selectedLanguageCode,
                        question: trimmedQuestion,
                        clientRequestID: clientRequestID,
                        snapshotEnvelope: snapshotPackage.envelope,
                        capabilityScope: capabilityScope,
                        runtimeContextDelta: snapshotPackage.includedInlineSnapshot
                            ? nil
                            : (preparation.canUseRemoteAIContextNow
                                ? contextBuilder.runtimeContextDelta(from: appStore)
                                : nil)
                    )
                } catch let error as CoachClientError
                where error.isRemoteHeadChanged && !snapshotPackage.includedInlineSnapshot {
                    debugRecorder.log(
                        category: .coach,
                        level: .warning,
                        message: "chat_remote_head_changed_retry",
                        metadata: ["provider": configuration.provider.rawValue]
                    )
                    snapshotPackage = try buildSnapshotPackage(includeInlineSnapshot: true)
                    createResponse = try await client.createChatJob(
                        locale: appStore.selectedLanguageCode,
                        question: trimmedQuestion,
                        clientRequestID: clientRequestID,
                        snapshotEnvelope: snapshotPackage.envelope,
                        capabilityScope: capabilityScope,
                        runtimeContextDelta: nil
                    )
                }
                draftQuestion = ""
                setActiveChatJob(
                    jobID: createResponse.jobID,
                    installID: snapshotPackage.envelope.installID,
                    provider: createResponse.metadata?.provider ?? configuration.provider,
                    placeholderID: placeholderID,
                    initialPollAfterMs: createResponse.pollAfterMs,
                    resetPollingStart: true
                )
                debugRecorder.log(
                    category: .coach,
                    message: "chat_job_created",
                    metadata: [
                        "provider": createResponse.metadata?.provider?.rawValue ?? configuration.provider.rawValue,
                        "hasQuestion": "true",
                        "usedServerSideContext": snapshotPackage.includedInlineSnapshot ? "false" : "true",
                        "includedInlineSnapshot": snapshotPackage.includedInlineSnapshot ? "true" : "false"
                    ]
                )
            } catch let error as CoachClientError {
                if let existingJobID = error.activeChatJobID {
                    let existingJobProvider =
                        error.activeChatJobProvider ??
                        activeChatProvider ??
                        configuration.provider
                    removeMessage(id: userMessageID)
                    removeMessage(id: placeholderID)
                    let recoveredPlaceholderID = ensureRecoveredChatPlaceholder()
                    setActiveChatJob(
                        jobID: existingJobID,
                        installID: snapshotPackage.envelope.installID,
                        provider: existingJobProvider,
                        placeholderID: recoveredPlaceholderID,
                        initialPollAfterMs: CoachStore.initialChatPollAfterMs,
                        resetPollingStart: activeChatPollingStartedAt == nil
                    )
                    debugRecorder.log(
                        category: .coach,
                        message: "chat_job_resumed",
                        metadata: [
                            "reason": "existing_job_in_progress",
                            "provider": existingJobProvider.rawValue,
                        ]
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
            lastChatProvider = activeChatProvider ?? configuration.provider
            debugRecorder.log(
                category: .coach,
                level: .error,
                message: "chat_job_failed",
                metadata: ["error": description]
            )
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
        guard configuration.canUseRemoteCoach else {
            logChatResumeIgnored(reason: "remote_coach_unavailable")
            return
        }

        guard let activeChatContext = currentActiveChatContext() else {
            logChatResumeIgnored(reason: "no_active_job")
            return
        }

        guard activeChatPollTask == nil else {
            logChatResumeIgnored(
                reason: "polling_in_progress",
                metadata: ["jobID": activeChatContext.jobID]
            )
            return
        }

        guard !isSendingMessage else {
            logChatResumeIgnored(
                reason: "message_in_flight",
                metadata: ["jobID": activeChatContext.jobID]
            )
            return
        }

        let wasAwaitingResume = activeChatAwaitingResume
        activeChatAwaitingResume = false
        activeChatPollingStartedAt = Date()
        activeChatNextPollAfterMs = 0
        persistPendingChatJobState()
        lastChatErrorDescription = nil
        lastChatProvider = activeChatProvider ?? configuration.provider
        ensureActiveChatPlaceholder(
            id: activeChatContext.placeholderID,
            content: coachLocalizedString("coach.loading.response"),
            isLoading: true
        )
        debugRecorder.log(
            category: .coach,
            message: "chat_job_resumed",
            metadata: [
                "awaitingResume": wasAwaitingResume ? "true" : "false",
                "jobID": activeChatContext.jobID,
                "provider": (activeChatProvider ?? configuration.provider).rawValue
            ]
        )
        startActiveChatPolling(
            jobID: activeChatContext.jobID,
            installID: activeChatContext.installID,
            placeholderID: activeChatContext.placeholderID,
            initialPollAfterMs: 0,
            pollStartedAt: activeChatPollingStartedAt ?? Date()
        )
    }

    func resetConversation() {
        messages = []
        draftQuestion = ""
        lastChatErrorDescription = nil
        isSendingMessage = false
        activeChatJobID = nil
        activeChatInstallID = nil
        activeChatProvider = nil
        activeChatAwaitingResume = false
        activeChatPlaceholderID = nil
        activeChatPollingStartedAt = nil
        activeChatNextPollAfterMs = CoachStore.initialChatPollAfterMs
        cancelActiveChatPollTask()
        persistPendingChatJobState()
    }

    func clearRemoteConversation() async {
        resetConversation()
        guard configuration.canUseRemoteCoach else {
            return
        }

        do {
            try await client.clearRemoteChatMemory(
                CloudCoachMemoryClearRequest(
                    installID: localStateStore.installID,
                    providerID: coachDefaultProviderID,
                    clearInsightsCache: true
                )
            )
            debugRecorder.log(
                category: .coach,
                message: "remote_chat_memory_cleared",
                metadata: ["providerID": coachDefaultProviderID]
            )
        } catch {
            lastChatErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            debugRecorder.log(
                category: .coach,
                level: .warning,
                message: "remote_chat_memory_clear_failed",
                metadata: [
                    "error": (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ]
            )
        }
    }

    func handleTodayScreenDidBecomeVisible(using appStore: AppStore) async {
        syncAnalysisSettingsDrafts(using: appStore)

        if isLoadingProfileInsights {
            return
        }

        if activeProfileInsightsJobID != nil {
            if let retryNotBefore = activeProfileInsightsRetryNotBefore,
               retryNotBefore > Date() {
                return
            }

            await refreshProfileInsights(using: appStore)
            if activeProfileInsightsJobID != nil {
                activeProfileInsightsRetryNotBefore = Date()
                    .addingTimeInterval(Self.profileInsightsResumeCooldown)
            }
            return
        }

        guard profileInsights == nil, activeChatJobID == nil else {
            return
        }

        await refreshProfileInsights(using: appStore)
    }

    func handleCoachScreenDidBecomeVisible(using appStore: AppStore) async {
        configureQuickPromptsIfNeeded()
        syncAnalysisSettingsDrafts(using: appStore)

        if activeChatJobID != nil {
            await resumePendingChatJobIfNeeded(using: appStore)
        }
    }

    func configureQuickPromptsIfNeeded() {
        guard visibleQuickPromptKeys.isEmpty else {
            return
        }

        visibleQuickPromptKeys = Array(allQuickPromptKeys.shuffled().prefix(3))
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

        debugRecorder.log(
            category: .coach,
            message: "chat_job_poll_started",
            metadata: [
                "jobID": jobID,
                "initialPollAfterMs": String(nextDelayMs),
                "provider": (activeChatProvider ?? configuration.provider).rawValue
            ]
        )

        while true {
            if hasExceededChatPollingDuration(since: pollStartedAt) {
                suspendActiveChatJob(
                    placeholderID: placeholderID,
                    nextPollAfterMs: nextDelayMs,
                    expectedJobID: jobID
                )
                return nil
            }

            do {
                debugRecorder.log(
                    category: .coach,
                    message: "chat_job_poll_request_sent",
                    metadata: [
                        "jobID": jobID,
                        "attempt": String(pollAttempt),
                        "nextDelayMs": String(nextDelayMs),
                        "provider": (activeChatProvider ?? configuration.provider).rawValue
                    ]
                )
                let response = try await client.getChatJob(
                    jobID: jobID,
                    installID: installID
                )
                debugRecorder.log(
                    category: .coach,
                    message: "chat_job_poll_response_received",
                    metadata: [
                        "jobID": jobID,
                        "attempt": String(pollAttempt),
                        "status": response.status.rawValue,
                        "provider": response.metadata?.provider?.rawValue
                            ?? activeChatProvider?.rawValue
                            ?? configuration.provider.rawValue
                    ]
                )

                if response.status.isTerminalForUserFlow {
                    return response
                }

                if response.status.isPending {
                    ensureActiveChatPlaceholder(
                        id: placeholderID,
                        content: coachLocalizedString("coach.loading.response"),
                        isLoading: true
                    )
                }
            } catch is CancellationError {
                suspendActiveChatJob(
                    placeholderID: placeholderID,
                    nextPollAfterMs: nextDelayMs,
                    expectedJobID: jobID
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
                        nextPollAfterMs: nextDelayMs,
                        expectedJobID: jobID
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
        guard jobResponse.status.isCompletedForUserFlow,
              let result = jobResponse.result else {
            return nil
        }

        return CoachChatResponse(
            answerMarkdown: result.answerMarkdown,
            responseID: result.responseID,
            followUps: result.followUps,
            generationStatus: result.generationStatus,
            provider: result.provider ?? jobResponse.metadata?.provider,
            selectedModel: jobResponse.metadata?.selectedModel
        )
    }

    private func chatJobFailureDescription(
        from jobResponse: CoachChatJobStatusResponse
    ) -> String {
        if let message = coachUserFacingJobFailureMessage(
            status: jobResponse.status,
            error: jobResponse.error
        ) {
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
        provider: CoachAIProvider,
        placeholderID: String,
        initialPollAfterMs: Int,
        resetPollingStart: Bool
    ) {
        activeChatJobID = jobID
        activeChatInstallID = installID
        activeChatProvider = provider
        activeChatPlaceholderID = placeholderID
        activeChatNextPollAfterMs = max(initialPollAfterMs, 0)
        activeChatAwaitingResume = false
        if resetPollingStart || activeChatPollingStartedAt == nil {
            activeChatPollingStartedAt = Date()
        }
        persistPendingChatJobState()
    }

    private func clearActiveChatJob() {
        activeChatJobID = nil
        activeChatInstallID = nil
        activeChatProvider = nil
        activeChatAwaitingResume = false
        activeChatPlaceholderID = nil
        activeChatPollingStartedAt = nil
        activeChatNextPollAfterMs = CoachStore.initialChatPollAfterMs
        cancelActiveChatPollTask()
        persistPendingChatJobState()
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
            debugRecorder.log(
                category: .coach,
                level: .error,
                message: "chat_job_failed",
                metadata: [
                    "status": jobResponse.status.rawValue,
                    "errorCode": jobResponse.error?.code ?? "none",
                    "provider": jobResponse.metadata?.provider?.rawValue
                        ?? activeChatProvider?.rawValue
                        ?? configuration.provider.rawValue
                ]
            )
            replaceMessage(
                id: placeholderID,
                with: CoachChatMessage(
                    id: placeholderID,
                    role: .assistant,
                    content: description,
                    provider: jobResponse.metadata?.provider ?? activeChatProvider,
                    selectedModel: jobResponse.metadata?.selectedModel,
                    isStatus: true
                )
            )
            return
        }

        lastChatErrorDescription = nil
        lastChatProvider = response.provider ?? jobResponse.metadata?.provider ?? activeChatProvider
        debugRecorder.log(
            category: .coach,
            message: "chat_job_completed",
            metadata: [
                "followUpsCount": String(response.followUps.count),
                "generationStatus": response.generationStatus?.rawValue ?? "none",
                "provider": response.provider?.rawValue
                    ?? jobResponse.metadata?.provider?.rawValue
                    ?? activeChatProvider?.rawValue
                    ?? configuration.provider.rawValue
            ]
        )
        replaceMessage(
            id: placeholderID,
            with: CoachChatMessage(
                id: placeholderID,
                role: .assistant,
                content: response.answerMarkdown,
                followUps: response.followUps,
                generationStatus: response.generationStatus,
                provider: response.provider ?? jobResponse.metadata?.provider ?? activeChatProvider,
                selectedModel: response.selectedModel ?? jobResponse.metadata?.selectedModel
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
        let existingCreatedAt = messages.first(where: { $0.id == id })?.createdAt ?? Date()
        activeChatPlaceholderID = id
        replaceMessage(
            id: id,
            with: CoachChatMessage(
                id: id,
                role: .assistant,
                content: content,
                createdAt: existingCreatedAt,
                isLoading: isLoading,
                isStatus: true
            )
        )
    }

    private func suspendActiveChatJob(
        placeholderID: String,
        nextPollAfterMs: Int,
        expectedJobID: String? = nil
    ) {
        if let expectedJobID,
           activeChatJobID != expectedJobID {
            return
        }
        activeChatPlaceholderID = placeholderID
        activeChatAwaitingResume = true
        activeChatNextPollAfterMs = max(nextPollAfterMs, CoachStore.initialChatPollAfterMs)
        persistPendingChatJobState()
        debugRecorder.log(
            category: .coach,
            message: "chat_job_suspended",
            metadata: [
                "nextPollAfterMs": String(activeChatNextPollAfterMs),
                "provider": (activeChatProvider ?? configuration.provider).rawValue
            ]
        )
        ensureActiveChatPlaceholder(
            id: placeholderID,
            content: coachLocalizedString("coach.loading.response_delayed"),
            isLoading: false
        )
    }

    private func startActiveChatPolling(
        jobID: String,
        installID: String,
        placeholderID: String,
        initialPollAfterMs: Int,
        pollStartedAt: Date
    ) {
        guard activeChatPollTask == nil else {
            return
        }

        isSendingMessage = true
        activeChatPollTaskJobID = jobID
        activeChatPollTask = Task { [weak self, jobID, installID, placeholderID, initialPollAfterMs, pollStartedAt] in
            guard let self else {
                return
            }

            await self.runActiveChatPolling(
                jobID: jobID,
                installID: installID,
                placeholderID: placeholderID,
                initialPollAfterMs: initialPollAfterMs,
                pollStartedAt: pollStartedAt
            )
        }
    }

    private func runActiveChatPolling(
        jobID: String,
        installID: String,
        placeholderID: String,
        initialPollAfterMs: Int,
        pollStartedAt: Date
    ) async {
        defer {
            clearActiveChatPollTaskIfNeeded(jobID: jobID)
            isSendingMessage = false
        }

        do {
            if let jobResponse = try await awaitTerminalChatJob(
                jobID: jobID,
                installID: installID,
                initialPollAfterMs: initialPollAfterMs,
                placeholderID: placeholderID,
                pollStartedAt: pollStartedAt
            ) {
                finishActiveChatJob(
                    with: jobResponse,
                    placeholderID: placeholderID
                )
            }
        } catch {
            if isTransientPollingError(error) {
                suspendActiveChatJob(
                    placeholderID: placeholderID,
                    nextPollAfterMs: activeChatNextPollAfterMs,
                    expectedJobID: jobID
                )
                return
            }

            clearActiveChatJob()
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastChatErrorDescription = description
            debugRecorder.log(
                category: .coach,
                level: .error,
                message: "chat_job_failed",
                metadata: ["error": description]
            )
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

    private func cancelActiveChatPollTask() {
        let task = activeChatPollTask
        activeChatPollTask = nil
        activeChatPollTaskJobID = nil
        task?.cancel()
    }

    private func clearActiveChatPollTaskIfNeeded(jobID: String) {
        guard activeChatPollTaskJobID == jobID else {
            return
        }

        activeChatPollTask = nil
        activeChatPollTaskJobID = nil
    }

    private func logChatResumeIgnored(
        reason: String,
        metadata: [String: String] = [:]
    ) {
        debugRecorder.log(
            category: .coach,
            level: .warning,
            message: "chat_job_resume_ignored",
            metadata: ["reason": reason].merging(metadata) { current, _ in current }
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
    ) async -> CloudSyncPreparationResult {
        await cloudSyncStore.syncIfNeeded(
            using: appStore,
            allowUserPrompt: allowUserPrompt
        )
    }

    private func makeSnapshotPackage(
        from appStore: AppStore,
        localBackupHash: String?,
        includeInlineSnapshot: Bool
    ) throws -> CoachSnapshotPackage {
        let snapshot = includeInlineSnapshot ? contextBuilder.build(from: appStore) : nil
        let snapshotHash: String?
        if let snapshot {
            snapshotHash = try CoachSnapshotHashing.hash(for: snapshot)
        } else {
            snapshotHash = nil
        }

        return CoachSnapshotPackage(
            envelope: CoachSnapshotEnvelope(
                installID: localStateStore.installID,
                localBackupHash: localBackupHash,
                snapshotHash: includeInlineSnapshot ? snapshotHash : nil,
                snapshot: includeInlineSnapshot ? snapshot : nil,
                snapshotUpdatedAt: includeInlineSnapshot ? Date() : nil
            ),
            includedInlineSnapshot: includeInlineSnapshot
        )
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

    private func persistPendingChatJobState() {
        let defaults = localStateStore.userDefaults
        guard let jobID = activeChatJobID,
              let installID = activeChatInstallID else {
            defaults.removeObject(forKey: PreferenceKey.pendingChatJobState)
            return
        }

        let state = PendingCoachChatJobState(
            jobID: jobID,
            installID: installID,
            pollStartedAt: activeChatPollingStartedAt,
            nextPollAfterMs: activeChatNextPollAfterMs,
            providerID: coachDefaultProviderID
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            defaults.set(data, forKey: PreferenceKey.pendingChatJobState)
        }
    }

    private func persistPendingProfileInsightsJobState() {
        let defaults = localStateStore.userDefaults
        guard let jobID = activeProfileInsightsJobID,
              let installID = activeProfileInsightsInstallID else {
            defaults.removeObject(forKey: PreferenceKey.pendingProfileInsightsJobState)
            return
        }

        let state = PendingProfileInsightsJobState(
            jobID: jobID,
            installID: installID,
            providerID: coachDefaultProviderID
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            defaults.set(data, forKey: PreferenceKey.pendingProfileInsightsJobState)
        }
    }

    private func restorePersistedPendingChatJobIfNeeded() {
        let defaults = localStateStore.userDefaults
        guard let data = defaults.data(forKey: PreferenceKey.pendingChatJobState) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(PendingCoachChatJobState.self, from: data) else {
            defaults.removeObject(forKey: PreferenceKey.pendingChatJobState)
            return
        }

        guard state.installID == localStateStore.installID,
              state.providerID == coachDefaultProviderID else {
            defaults.removeObject(forKey: PreferenceKey.pendingChatJobState)
            debugRecorder.log(
                category: .coach,
                level: .warning,
                message: "chat_job_resume_ignored",
                metadata: ["reason": "install_or_provider_mismatch"]
            )
            return
        }

        activeChatJobID = state.jobID
        activeChatInstallID = state.installID
        activeChatAwaitingResume = true
        activeChatPollingStartedAt = state.pollStartedAt
        activeChatNextPollAfterMs = max(state.nextPollAfterMs, CoachStore.initialChatPollAfterMs)
    }

    private func restorePersistedPendingProfileInsightsJobIfNeeded() {
        let defaults = localStateStore.userDefaults
        guard let data = defaults.data(forKey: PreferenceKey.pendingProfileInsightsJobState) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(PendingProfileInsightsJobState.self, from: data) else {
            defaults.removeObject(forKey: PreferenceKey.pendingProfileInsightsJobState)
            return
        }

        guard state.installID == localStateStore.installID,
              state.providerID == coachDefaultProviderID else {
            defaults.removeObject(forKey: PreferenceKey.pendingProfileInsightsJobState)
            debugRecorder.log(
                category: .coach,
                level: .warning,
                message: "insights_job_resume_ignored",
                metadata: ["reason": "install_or_provider_mismatch"]
            )
            return
        }

        activeProfileInsightsJobID = state.jobID
        activeProfileInsightsInstallID = state.installID
        activeProfileInsightsProvider = configuration.provider
    }

    private enum PreferenceKey {
        static let pendingChatJobState = "coach.runtime.pending_chat_job_state"
        static let pendingProfileInsightsJobState = "coach.runtime.pending_profile_insights_job_state"
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

struct TodayCoachInsightItemState: Identifiable, Equatable {
    let id: String
    let message: String
    let systemImage: String
    let accent: TodayCardAccent
}

struct TodayCoachInsightsContentState: Equatable {
    let summary: String
    let explanation: String?
    let items: [TodayCoachInsightItemState]
    let sourceKey: String
    let sourceAccent: TodayCardAccent
    let modelLabel: String?
    let noteKey: String?
}

enum TodayCoachInsightsState: Equatable {
    case loading
    case ready(TodayCoachInsightsContentState)
    case unavailable(String)

    var isReady: Bool {
        if case .ready = self {
            return true
        }

        return false
    }
}

struct TodayCoachInsightsResolver {
    static func resolve(
        insights: CoachProfileInsights?,
        origin: CoachInsightsOrigin,
        isLoading: Bool,
        canUseRemoteCoach: Bool,
        lastErrorDescription: String?,
        languageCode: String
    ) -> TodayCoachInsightsState {
        if let insights {
            let hasError = !(lastErrorDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
            let filteredItems = focusItems(from: insights, languageCode: languageCode)
            let summary = normalizedText(insights.summary, languageCode: languageCode)
                ?? filteredItems.first?.message
            guard let summary else {
                return .unavailable(unavailableMessageKey(canUseRemoteCoach: canUseRemoteCoach))
            }

            return .ready(
                TodayCoachInsightsContentState(
                    summary: summary,
                    explanation: firstValidText(
                        [
                            insights.executionContext?.explanation,
                            insights.confidenceNotes.first
                        ],
                        languageCode: languageCode
                    ),
                    items: Array(filteredItems.filter { $0.message != summary }.prefix(2)),
                    sourceKey: sourceKey(for: origin),
                    sourceAccent: accent(for: origin),
                    modelLabel: coachVisibleModelLabel(insights.selectedModel),
                    noteKey: noteKey(for: origin, canUseRemoteCoach: canUseRemoteCoach, hasError: hasError)
                )
            )
        }

        if isLoading {
            return .loading
        }

        return .unavailable(unavailableMessageKey(canUseRemoteCoach: canUseRemoteCoach))
    }

    private static func unavailableMessageKey(canUseRemoteCoach: Bool) -> String {
        canUseRemoteCoach
            ? "today.insights.empty"
            : "today.insights.empty_local"
    }

    private static func firstValidText(
        _ values: [String?],
        languageCode: String
    ) -> String? {
        values
            .compactMap { normalizedText($0, languageCode: languageCode) }
            .first
    }

    private static func focusItems(
        from insights: CoachProfileInsights,
        languageCode: String
    ) -> [TodayCoachInsightItemState] {
        typealias Source = (
            prefix: String,
            systemImage: String,
            accent: TodayCardAccent,
            values: [String]
        )

        let sources: [Source] = [
            (
                prefix: "recommendation",
                systemImage: "bolt.fill",
                accent: .accent,
                values: insights.recommendations
            ),
            (
                prefix: "constraint",
                systemImage: "shield.lefthalf.filled",
                accent: .warning,
                values: insights.topConstraints
            ),
            (
                prefix: "observation",
                systemImage: "waveform.path.ecg",
                accent: .indigo,
                values: insights.keyObservations
            )
        ]

        var selectedItems: [TodayCoachInsightItemState] = []
        var usedMessages = Set<String>()

        func appendFirst(from source: Source) {
            guard let item = source.values
                .compactMap({ normalizedText($0, languageCode: languageCode) })
                .first(where: { usedMessages.insert($0).inserted }) else {
                return
            }

            selectedItems.append(
                TodayCoachInsightItemState(
                    id: "\(source.prefix)-primary",
                    message: item,
                    systemImage: source.systemImage,
                    accent: source.accent
                )
            )
        }

        sources.forEach(appendFirst)

        if selectedItems.count < 2 {
            for source in sources {
                for item in source.values.compactMap({ normalizedText($0, languageCode: languageCode) }) {
                    guard usedMessages.insert(item).inserted else {
                        continue
                    }

                    selectedItems.append(
                        TodayCoachInsightItemState(
                            id: "\(source.prefix)-\(selectedItems.count)",
                            message: item,
                            systemImage: source.systemImage,
                            accent: source.accent
                        )
                    )

                    if selectedItems.count == 2 {
                        break
                    }
                }

                if selectedItems.count == 2 {
                    break
                }
            }
        }

        return Array(selectedItems.prefix(2))
    }

    private static func normalizedText(
        _ text: String?,
        languageCode: String
    ) -> String? {
        guard let text else {
            return nil
        }

        let normalized = coachNormalizedReadableText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        guard matchesPreferredLanguage(normalized, languageCode: languageCode) else {
            return nil
        }

        return normalized
    }

    private static func matchesPreferredLanguage(
        _ text: String,
        languageCode: String
    ) -> Bool {
        let counts = scriptCounts(in: text)
        if counts.cyrillic == 0 && counts.latin == 0 {
            return true
        }

        if languageCode.lowercased().hasPrefix("ru") {
            return counts.cyrillic >= counts.latin
        }

        return counts.latin >= counts.cyrillic
    }

    private static func scriptCounts(in text: String) -> (cyrillic: Int, latin: Int) {
        var cyrillic = 0
        var latin = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0410...0x044F, 0x0401, 0x0451:
                cyrillic += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latin += 1
            default:
                continue
            }
        }

        return (cyrillic, latin)
    }

    private static func sourceKey(for origin: CoachInsightsOrigin) -> String {
        switch origin {
        case .freshModel:
            return "coach.insights.source.fresh_model"
        case .cachedModel:
            return "coach.insights.source.cached_model"
        case .fallback:
            return "coach.insights.source.fallback"
        }
    }

    private static func accent(for origin: CoachInsightsOrigin) -> TodayCardAccent {
        switch origin {
        case .freshModel:
            return .success
        case .cachedModel:
            return .warning
        case .fallback:
            return .indigo
        }
    }

    private static func noteKey(
        for origin: CoachInsightsOrigin,
        canUseRemoteCoach: Bool,
        hasError: Bool
    ) -> String? {
        switch origin {
        case .freshModel:
            return nil
        case .cachedModel:
            return "today.insights.note.cached"
        case .fallback:
            return (canUseRemoteCoach || hasError)
                ? "today.insights.note.local_fallback"
                : "today.insights.note.local_first"
        }
    }
}

@MainActor
struct TodayCoachInsightsCard: View {
    let state: TodayCoachInsightsState

    var body: some View {
        AppCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("today.insights.title")
                    .font(AppTypography.heading(size: 20))
                    .foregroundStyle(AppTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                switch state {
                case .loading:
                    HStack(spacing: 12) {
                        ProgressView()
                            .tint(AppTheme.accent)

                        Text("today.insights.loading")
                            .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case let .unavailable(messageKey):
                    Text(LocalizedStringKey(messageKey))
                        .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                case let .ready(content):
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .center, spacing: 10) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(content.sourceAccent.tint)
                                    .frame(width: 8, height: 8)

                                Text(LocalizedStringKey(content.sourceKey))
                                    .font(AppTypography.caption(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.secondaryText)
                            }

                            Spacer(minLength: 12)

                            if let modelLabel = content.modelLabel {
                                HStack(spacing: 6) {
                                    CoachStatusDot(color: content.sourceAccent.tint, size: 7)

                                    Text(modelLabel)
                                        .font(AppTypography.caption(size: 12, weight: .semibold))
                                        .foregroundStyle(AppTheme.primaryText)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.82)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(AppTheme.surface)
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(AppTheme.border, lineWidth: 1)
                                )
                            }
                        }

                        Text(content.summary)
                            .font(AppTypography.body(size: 18, weight: .semibold, relativeTo: .title3))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if let explanation = content.explanation {
                            Text(explanation)
                                .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !content.items.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(content.items) { item in
                                    TodayCoachInsightRow(item: item)
                                }
                            }
                        }

                        if let noteKey = content.noteKey {
                            Text(LocalizedStringKey(noteKey))
                                .font(AppTypography.caption(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

private struct TodayCoachInsightRow: View {
    let item: TodayCoachInsightItemState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.systemImage)
                .font(AppTypography.icon(size: 14, weight: .semibold))
                .foregroundStyle(item.accent.tint)
                .frame(width: 32, height: 32)
                .background(item.accent.subtleFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            Text(item.message)
                .font(AppTypography.body(size: 14, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
struct CoachView: View {
    @Environment(AppStore.self) private var store
    @Environment(CoachStore.self) private var coachStore
    @Environment(\.appBottomRailInset) private var bottomRailInset
    @FocusState private var focusedField: CoachFocusField?

    private var shouldShowQuickPrompts: Bool {
        coachStore.messages.isEmpty &&
        coachStore.canUseRemoteCoach &&
        !coachStore.canResumePendingChatJob
    }

    var body: some View {
        VStack(spacing: 0) {
            AppPageHeaderModule(titleKey: "header.coach.title")
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 10)

            CoachConversationPanel(
                messages: coachStore.messages,
                canUseRemoteCoach: coachStore.canUseRemoteCoach,
                canResumePendingChatJob: coachStore.canResumePendingChatJob,
                visibleQuickPromptKeys: shouldShowQuickPrompts ? coachStore.visibleQuickPromptKeys : [],
                isSendingMessage: coachStore.isSendingMessage
            ) { prompt in
                focusedField = nil
                sendQuestion(prompt)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CoachChatComposerBar(
                draftQuestion: Binding(
                    get: { coachStore.draftQuestion },
                    set: { coachStore.draftQuestion = $0 }
                ),
                canUseRemoteCoach: coachStore.canUseRemoteCoach,
                canResumePendingChatJob: coachStore.canResumePendingChatJob,
                isSendingMessage: coachStore.isSendingMessage,
                lastErrorDescription: coachStore.lastChatErrorDescription,
                focusedField: $focusedField,
                bottomInset: bottomRailInset
            ) {
                focusedField = nil
                if coachStore.canResumePendingChatJob &&
                    coachStore.draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task {
                        await coachStore.resumePendingChatJobIfNeeded(using: store)
                    }
                } else {
                    sendQuestion(coachStore.draftQuestion)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField = nil
        }
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
}

private struct CoachConversationPanel: View {
    let messages: [CoachChatMessage]
    let canUseRemoteCoach: Bool
    let canResumePendingChatJob: Bool
    let visibleQuickPromptKeys: [String]
    let isSendingMessage: Bool
    let onFollowUpTap: (String) -> Void

    private var lastAssistantMessageWithFollowUpsID: String? {
        messages.last { message in
            message.role == .assistant &&
            !message.isLoading &&
            !message.isStatus &&
            !message.followUps.isEmpty
        }?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty {
                        CoachConversationEmptyState(
                            canUseRemoteCoach: canUseRemoteCoach,
                            canResumePendingChatJob: canResumePendingChatJob,
                            visibleQuickPromptKeys: visibleQuickPromptKeys,
                            isSendingMessage: isSendingMessage,
                            onPromptTap: onFollowUpTap
                        )
                    } else {
                        ForEach(messages) { message in
                            CoachChatMessageCard(
                                message: message,
                                showsFollowUps: message.id == lastAssistantMessageWithFollowUpsID,
                                onFollowUpTap: onFollowUpTap
                            )
                            .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
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

private struct CoachConversationEmptyState: View {
    let canUseRemoteCoach: Bool
    let canResumePendingChatJob: Bool
    let visibleQuickPromptKeys: [String]
    let isSendingMessage: Bool
    let onPromptTap: (String) -> Void

    private var titleKey: String {
        if canResumePendingChatJob {
            return "coach.chat.resume.title"
        }

        return canUseRemoteCoach ? "coach.ask.title" : "coach.status.fallback"
    }

    private var bodyKey: String {
        if canResumePendingChatJob {
            return "coach.chat.resume.body"
        }

        return canUseRemoteCoach ? "coach.chat.empty.body" : "coach.error.chat_unavailable"
    }

    private var iconName: String {
        if canResumePendingChatJob {
            return "hourglass.circle.fill"
        }

        return canUseRemoteCoach ? "sparkles.rectangle.stack.fill" : "bolt.slash.circle.fill"
    }

    private var iconColor: Color {
        if canResumePendingChatJob {
            return AppTheme.accent
        }

        return canUseRemoteCoach ? AppTheme.accent : AppTheme.warning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(AppTypography.icon(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)

                Text(LocalizedStringKey(titleKey))
                    .font(AppTypography.heading(size: 24))
                    .foregroundStyle(AppTheme.primaryText)
            }

            Text(LocalizedStringKey(bodyKey))
                .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !canUseRemoteCoach {
                Text("coach.chat.settings_hint")
                    .font(AppTypography.caption(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if canUseRemoteCoach && !canResumePendingChatJob && !visibleQuickPromptKeys.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("coach.quick_prompt.title")
                        .font(AppTypography.caption(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.secondaryText)

                    FlowLayout(spacing: 10) {
                        ForEach(visibleQuickPromptKeys, id: \.self) { promptKey in
                            let prompt = coachLocalizedString(promptKey)
                            Button {
                                onPromptTap(prompt)
                            } label: {
                                Text(prompt)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(CoachPromptButtonStyle())
                            .disabled(isSendingMessage)
                            .opacity(isSendingMessage ? 0.55 : 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
        .padding(.top, 18)
    }
}

private struct CoachChatComposerBar: View {
    @Binding var draftQuestion: String

    let canUseRemoteCoach: Bool
    let canResumePendingChatJob: Bool
    let isSendingMessage: Bool
    let lastErrorDescription: String?
    let focusedField: FocusState<CoachFocusField?>.Binding
    let bottomInset: CGFloat
    let onSend: () -> Void

    private var trimmedDraft: String {
        draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsResumeButton: Bool {
        canResumePendingChatJob && trimmedDraft.isEmpty
    }

    private var sendButtonDisabled: Bool {
        trimmedDraft.isEmpty || isSendingMessage || !canUseRemoteCoach
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let lastErrorDescription, !lastErrorDescription.isEmpty {
                Text(lastErrorDescription)
                    .font(AppTypography.caption(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !canUseRemoteCoach {
                Text("coach.chat.settings_hint")
                    .font(AppTypography.caption(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField("coach.ask.placeholder", text: $draftQuestion, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AppTypography.body(size: 16))
                    .foregroundStyle(AppTheme.primaryText)
                    .focused(focusedField, equals: .question)
                    .disabled(isSendingMessage)
                    .lineLimit(1...5)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(AppTheme.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )

                if !showsResumeButton {
                    Button(action: onSend) {
                        Group {
                            if isSendingMessage {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(AppTypography.icon(size: 16, weight: .bold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(
                            Circle()
                                .fill(sendButtonDisabled ? AppTheme.accent.opacity(0.5) : AppTheme.accent)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(sendButtonDisabled)
                }
            }

            if showsResumeButton {
                Button("coach.action.resume_waiting", action: onSend)
                    .buttonStyle(AppPrimaryButtonStyle())
                    .disabled(isSendingMessage || !canUseRemoteCoach)
                    .opacity((isSendingMessage || !canUseRemoteCoach) ? 0.55 : 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12 + bottomInset)
        .background(
            Rectangle()
                .fill(AppTheme.backgroundRaised.opacity(0.98))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(AppTheme.border)
                        .frame(height: 1)
                }
                .ignoresSafeArea()
        )
    }
}

struct CoachContextPreferencesCard: View {
    @Binding var selectedProgramID: UUID?
    @Binding var programComment: String

    let programs: [WorkoutProgram]
    let saveState: CoachAnalysisSettingsSaveState
    let isExpanded: Bool
    let savedSelectedProgramID: UUID?
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

    private var hasSavedContext: Bool {
        savedSelectedProgramID != nil ||
        !savedProgramComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var collapsedStatusKey: LocalizedStringKey {
        hasSavedContext ? "coach.context.status.ready" : "coach.context.status.missing"
    }

    private var collapsedStatusColor: Color {
        hasSavedContext ? AppTheme.success : AppTheme.destructive
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

private struct CoachChatMessageCard: View {
    let message: CoachChatMessage
    let showsFollowUps: Bool
    let onFollowUpTap: (String) -> Void

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var isAssistant: Bool {
        message.role == .assistant
    }

    private var allowsCopy: Bool {
        isAssistant && !message.isLoading && !message.isStatus
    }

    private var timestampText: String {
        Self.timestampFormatter.string(from: message.createdAt)
    }

    private var rowAlignment: Alignment {
        if isStatusRow {
            return .center
        }

        return isAssistant ? .leading : .trailing
    }

    private var isStatusRow: Bool {
        message.isStatus || message.isLoading
    }

    @ViewBuilder
    var body: some View {
        let content = Group {
            if isStatusRow {
                statusRow
            } else {
                bubbleRow
            }
        }
        .frame(maxWidth: .infinity, alignment: rowAlignment)

        if allowsCopy {
            content.contextMenu {
                Button {
                    UIPasteboard.general.string = CoachMarkdownText.normalizedContent(from: message.content)
                } label: {
                    Label("action.copy", systemImage: "doc.on.doc")
                }
            }
        } else {
            content
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if message.isLoading {
                ProgressView()
                    .tint(AppTheme.accent)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(AppTypography.icon(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.warning)
            }

            Text(message.content)
                .font(AppTypography.caption(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(AppTheme.surfaceElevated)
        )
        .overlay(
            Capsule()
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }

    private var bubbleRow: some View {
        HStack(spacing: 0) {
            if isAssistant {
                bubble(isLeading: true)
                Spacer(minLength: 52)
            } else {
                Spacer(minLength: 52)
                bubble(isLeading: false)
            }
        }
    }

    private func bubble(isLeading: Bool) -> some View {
        let bubbleAlignment: HorizontalAlignment = isLeading ? .leading : .trailing
        let frameAlignment: Alignment = isLeading ? .leading : .trailing

        return VStack(alignment: bubbleAlignment, spacing: 8) {
            CoachMarkdownText(
                content: message.content,
                isAssistant: isAssistant,
                isStatus: false
            )

            bubbleMetadata

            if showsFollowUps {
                FlowLayout(spacing: 8) {
                    ForEach(message.followUps, id: \.self) { followUp in
                        Button {
                            onFollowUpTap(followUp)
                        } label: {
                            Text(followUp)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(CoachPromptButtonStyle())
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 340, alignment: frameAlignment)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isAssistant ? AppTheme.surfaceElevated : AppTheme.accent)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isAssistant ? AppTheme.border : AppTheme.accent.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var bubbleMetadata: some View {
        if isAssistant {
            HStack(spacing: 8) {
                Text(timestampText)
                    .font(AppTypography.caption(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)

                Spacer(minLength: 8)

                if let modelLabel = coachChatModelLabel(
                    selectedModel: message.selectedModel,
                    provider: message.provider
                ) {
                    HStack(spacing: 6) {
                        CoachStatusDot(
                            color: coachChatModelTint(
                                provider: message.provider,
                                selectedModel: message.selectedModel
                            ),
                            size: 6
                        )

                        Text(modelLabel)
                            .font(AppTypography.caption(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(timestampText)
                .font(AppTypography.caption(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.74))
        }
    }
}

private func coachVisibleModelLabel(_ selectedModel: String?) -> String? {
    guard let selectedModel = selectedModel?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !selectedModel.isEmpty else {
        return nil
    }

    if selectedModel.hasPrefix("@cf/") {
        return String(selectedModel.dropFirst(4))
    }

    return selectedModel
}

private func coachChatModelLabel(
    selectedModel: String?,
    provider: CoachAIProvider?
) -> String? {
    if let selectedModel = coachVisibleModelLabel(selectedModel) {
        return selectedModel
    }

    return provider?.debugName
}

private func coachChatModelTint(
    provider: CoachAIProvider?,
    selectedModel: String?
) -> Color {
    if coachVisibleModelLabel(selectedModel) != nil {
        switch provider {
        case .gemini:
            return AppTheme.warning
        case .workersAI:
            return AppTheme.success
        case nil:
            return AppTheme.accent
        }
    }

    switch provider {
    case .gemini:
        return AppTheme.warning
    case .workersAI:
        return AppTheme.success
    case nil:
        return AppTheme.secondaryText
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

private struct CoachInsightsSourceDot: View {
    let origin: CoachInsightsOrigin

    var body: some View {
        CoachStatusDot(color: origin.sourceColor, size: 8)
    }
}

private struct CoachMarkdownText: View {
    let content: String
    let isAssistant: Bool
    let isStatus: Bool

    var body: some View {
        Text(verbatim: normalizedContent)
            .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
            .foregroundStyle(foregroundColor)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var normalizedContent: String {
        Self.normalizedContent(from: content)
    }

    static func normalizedContent(from content: String) -> String {
        let normalizedLineBreaks = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(
                of: #"<br\s*/?>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )

        let normalizedLines = normalizedLineBreaks
            .components(separatedBy: "\n")
            .map(Self.normalizedLine(from:))

        return Self.cleanedInlineMarkdown(in: normalizedLines.joined(separator: "\n"))
            .replacingOccurrences(
                of: #"\n{3,}"#,
                with: "\n\n",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([.!?])(\p{Lu})"#,
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([:;])(\p{Lu})"#,
                with: "$1 $2",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLine(from line: String) -> String {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard !trimmedLine.isEmpty else {
            return ""
        }

        let headingNormalized = trimmedLine.replacingOccurrences(
            of: #"^#{1,6}\s*"#,
            with: "",
            options: .regularExpression
        )
        if headingNormalized != trimmedLine {
            return headingNormalized.trimmingCharacters(in: .whitespaces)
        }

        let bulletNormalized = trimmedLine.replacingOccurrences(
            of: #"^[-*+]\s+"#,
            with: "• ",
            options: .regularExpression
        )
        if bulletNormalized != trimmedLine {
            return bulletNormalized
        }

        let numberedListNormalized = trimmedLine.replacingOccurrences(
            of: #"^(\d+)[.)]\s+"#,
            with: "$1. ",
            options: .regularExpression
        )
        return numberedListNormalized
    }

    private static func cleanedInlineMarkdown(in text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\*\*(.+?)\*\*"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"__(.+?)__"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<!\*)\*(?!\s)(.+?)(?<!\s)\*(?!\*)"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<!_)_(?!\s)(.+?)(?<!\s)_(?!_)"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"`([^`]+)`"#,
                with: "$1",
                options: .regularExpression
            )
    }

    private var foregroundColor: Color {
        if isStatus {
            return AppTheme.secondaryText
        }

        return isAssistant ? AppTheme.primaryText : .white
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
        let subviewProposal = ProposedViewSize(
            width: proposal.width.map { max($0, 1) },
            height: nil
        )
        var currentLineWidth: CGFloat = 0
        var currentLineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(subviewProposal)
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
        let subviewProposal = ProposedViewSize(
            width: max(bounds.width, 1),
            height: nil
        )

        for subview in subviews {
            let size = subview.sizeThatFits(subviewProposal)
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

private func coachUserFacingJobFailureMessage(
    status: CoachChatJobStatus,
    error: CoachChatJobError?
) -> String? {
    if status == .canceled || error?.code == "workflow_canceled" {
        return nil
    }

    let message = error?.message.trimmingCharacters(in: .whitespacesAndNewlines)
    return message?.isEmpty == false ? message : nil
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
