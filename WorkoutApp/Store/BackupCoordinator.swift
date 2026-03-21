import CloudKit
import CryptoKit
import Foundation

enum BackupTriggerReason: String, Codable, Sendable {
    case launch
    case sceneBackground
    case backgroundTask
    case manual
}

struct BackupEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let createdAt: Date
    let snapshotHash: String
    let appVersion: String
    let buildNumber: String
    let snapshot: AppSnapshot

    static func make(
        snapshot: AppSnapshot,
        createdAt: Date = .now,
        appVersion: String = BackupConstants.appVersion,
        buildNumber: String = BackupConstants.buildNumber
    ) throws -> BackupEnvelope {
        BackupEnvelope(
            schemaVersion: BackupConstants.schemaVersion,
            createdAt: createdAt,
            snapshotHash: try BackupHashing.hash(for: snapshot),
            appVersion: appVersion,
            buildNumber: buildNumber,
            snapshot: snapshot
        )
    }
}

struct BackupMetadata: Equatable, Codable, Sendable {
    let createdAt: Date
    let snapshotHash: String
    let schemaVersion: Int
    let appVersion: String
    let buildNumber: String
}

struct BackupStatus: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case checking
        case available
        case iCloudAccountMissing
        case restricted
        case temporarilyUnavailable
    }

    var availability: Availability = .checking
    var latestCloudBackup: BackupMetadata?
    var lastSuccessfulBackupAt: Date?
    var isBackupInProgress = false
    var isRestoreInProgress = false
    var lastErrorDescription: String?

    var canBackupNow: Bool {
        availability == .available && !isBackupInProgress && !isRestoreInProgress
    }

    var canRestore: Bool {
        availability == .available && !isBackupInProgress && !isRestoreInProgress
    }
}

struct BackupRestorePrompt: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case emptyLocal
        case cloudNewerThanLocal
        case manualRestore
    }

    let kind: Kind
    let metadata: BackupMetadata

    var id: String {
        "\(kind.rawValue)-\(metadata.snapshotHash)"
    }
}

struct BackupSyncResult: Sendable {
    var status: BackupStatus
    var restorePrompt: BackupRestorePrompt?
}

enum BackupHashing {
    static func hash(for snapshot: AppSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum BackupPolicy {
    static let automaticUploadInterval: TimeInterval = 24 * 60 * 60

    static func shouldUploadAutomatically(
        localSnapshotExists: Bool,
        snapshotHash: String,
        latestCloudBackup: BackupMetadata?,
        now: Date,
        minimumInterval: TimeInterval = automaticUploadInterval
    ) -> Bool {
        guard localSnapshotExists else {
            return false
        }

        if latestCloudBackup?.snapshotHash == snapshotHash {
            return false
        }

        guard let latestCloudBackup else {
            return true
        }

        return now.timeIntervalSince(latestCloudBackup.createdAt) >= minimumInterval
    }

    static func restorePrompt(
        localSnapshotExists: Bool,
        localSnapshotModifiedAt: Date?,
        cloudBackup: BackupMetadata?,
        dismissedSnapshotHash: String?
    ) -> BackupRestorePrompt? {
        guard let cloudBackup else {
            return nil
        }

        guard dismissedSnapshotHash != cloudBackup.snapshotHash else {
            return nil
        }

        if !localSnapshotExists {
            return BackupRestorePrompt(kind: .emptyLocal, metadata: cloudBackup)
        }

        guard let localSnapshotModifiedAt, cloudBackup.createdAt > localSnapshotModifiedAt else {
            return nil
        }

        return BackupRestorePrompt(kind: .cloudNewerThanLocal, metadata: cloudBackup)
    }
}

enum BackupConstants {
    static let schemaVersion = 1
    static let recordType = "WorkoutBackup"
    static let recordName = "latestBackup"
    static let payloadField = "payload"
    static let createdAtField = "createdAt"
    static let snapshotHashField = "snapshotHash"
    static let schemaVersionField = "schemaVersion"
    static let appVersionField = "appVersion"
    static let buildNumberField = "buildNumber"
    static var backgroundTaskIdentifier: String {
        "\(Bundle.main.bundleIdentifier ?? "com.example.WorkoutApp").daily-backup"
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

}

actor BackupCoordinator {
    static var isRuntimeAvailable: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "CloudBackupFeatureEnabled") as? Bool) == true
    }

    private let container: CKContainer
    private let database: CKDatabase
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let fileManager: FileManager

    init(
        container: CKContainer? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        if let container {
            self.container = container
        } else {
            // Personal-team and sideload installs can rewrite the runtime bundle identifier.
            // Using the default container avoids CloudKit init crashes from mismatched identifiers.
            self.container = CKContainer.default()
        }

        self.database = self.container.privateCloudDatabase
        self.defaults = defaults
        self.now = now
        self.fileManager = fileManager
    }

    func refreshStatus(
        localSnapshotExists: Bool,
        localSnapshotModifiedAt: Date?
    ) async -> BackupSyncResult {
        let availability = await availabilityStatus()
        var status = baseStatus(availability: availability)
        guard availability == .available else {
            return BackupSyncResult(status: status, restorePrompt: nil)
        }

        do {
            let cloudMetadata = try await fetchLatestBackupMetadata()
            status.latestCloudBackup = cloudMetadata
            status.lastSuccessfulBackupAt = cloudMetadata?.createdAt ?? cachedLastSuccessfulBackupAt
            let prompt = BackupPolicy.restorePrompt(
                localSnapshotExists: localSnapshotExists,
                localSnapshotModifiedAt: localSnapshotModifiedAt,
                cloudBackup: cloudMetadata,
                dismissedSnapshotHash: dismissedRestoreSnapshotHash
            )
            return BackupSyncResult(status: status, restorePrompt: prompt)
        } catch {
            status.lastErrorDescription = userFacingError(error)
            return BackupSyncResult(status: status, restorePrompt: nil)
        }
    }

    func syncIfNeeded(
        snapshot: AppSnapshot,
        localSnapshotExists: Bool,
        localSnapshotModifiedAt: Date?,
        reason: BackupTriggerReason
    ) async -> BackupSyncResult {
        let availability = await availabilityStatus()
        var status = baseStatus(availability: availability)
        guard availability == .available else {
            return BackupSyncResult(status: status, restorePrompt: nil)
        }

        do {
            let cloudMetadata = try await fetchLatestBackupMetadata()
            status.latestCloudBackup = cloudMetadata
            status.lastSuccessfulBackupAt = cloudMetadata?.createdAt ?? cachedLastSuccessfulBackupAt

            let prompt = BackupPolicy.restorePrompt(
                localSnapshotExists: localSnapshotExists,
                localSnapshotModifiedAt: localSnapshotModifiedAt,
                cloudBackup: cloudMetadata,
                dismissedSnapshotHash: dismissedRestoreSnapshotHash
            )

            guard prompt == nil, reason != .manual else {
                return BackupSyncResult(status: status, restorePrompt: prompt)
            }

            let snapshotHash = try BackupHashing.hash(for: snapshot)
            let shouldUpload = BackupPolicy.shouldUploadAutomatically(
                localSnapshotExists: localSnapshotExists,
                snapshotHash: snapshotHash,
                latestCloudBackup: cloudMetadata,
                now: now()
            )

            guard shouldUpload else {
                return BackupSyncResult(status: status, restorePrompt: nil)
            }

            let metadata = try await uploadSnapshot(snapshot)
            status.latestCloudBackup = metadata
            status.lastSuccessfulBackupAt = metadata.createdAt
            status.lastErrorDescription = nil
            return BackupSyncResult(status: status, restorePrompt: nil)
        } catch {
            status.lastErrorDescription = userFacingError(error)
            return BackupSyncResult(status: status, restorePrompt: nil)
        }
    }

    func backupNow(snapshot: AppSnapshot) async -> BackupStatus {
        let availability = await availabilityStatus()
        var status = baseStatus(availability: availability)
        guard availability == .available else {
            return status
        }

        do {
            let metadata = try await uploadSnapshot(snapshot)
            status.latestCloudBackup = metadata
            status.lastSuccessfulBackupAt = metadata.createdAt
            status.lastErrorDescription = nil
            return status
        } catch {
            status.latestCloudBackup = try? await fetchLatestBackupMetadata()
            status.lastSuccessfulBackupAt = status.latestCloudBackup?.createdAt ?? cachedLastSuccessfulBackupAt
            status.lastErrorDescription = userFacingError(error)
            return status
        }
    }

    func restoreLatestBackup() async throws -> BackupEnvelope {
        guard await availabilityStatus() == .available else {
            throw BackupCoordinatorError.iCloudUnavailable
        }

        guard let record = try await fetchLatestRecord() else {
            throw BackupCoordinatorError.missingBackup
        }

        guard
            let asset = record[BackupConstants.payloadField] as? CKAsset,
            let fileURL = asset.fileURL
        else {
            throw BackupCoordinatorError.corruptedBackup
        }

        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(BackupEnvelope.self, from: data)
        clearDismissedRestoreSnapshotHash()
        return envelope
    }

    func dismissRestorePrompt(for metadata: BackupMetadata) {
        defaults.set(metadata.snapshotHash, forKey: PreferenceKey.dismissedRestoreSnapshotHash)
    }

    func clearDismissedRestorePrompt() {
        clearDismissedRestoreSnapshotHash()
    }

    func manualRestorePrompt() async -> BackupSyncResult {
        let availability = await availabilityStatus()
        var status = baseStatus(availability: availability)
        guard availability == .available else {
            return BackupSyncResult(status: status, restorePrompt: nil)
        }

        do {
            let cloudMetadata = try await fetchLatestBackupMetadata()
            status.latestCloudBackup = cloudMetadata
            status.lastSuccessfulBackupAt = cloudMetadata?.createdAt ?? cachedLastSuccessfulBackupAt
            guard let cloudMetadata else {
                status.lastErrorDescription = BackupCoordinatorError.missingBackup.localizedDescription
                return BackupSyncResult(status: status, restorePrompt: nil)
            }

            return BackupSyncResult(
                status: status,
                restorePrompt: BackupRestorePrompt(kind: .manualRestore, metadata: cloudMetadata)
            )
        } catch {
            status.lastErrorDescription = userFacingError(error)
            return BackupSyncResult(status: status, restorePrompt: nil)
        }
    }

    private func uploadSnapshot(_ snapshot: AppSnapshot) async throws -> BackupMetadata {
        let envelope = try BackupEnvelope.make(snapshot: snapshot, createdAt: now())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        let tempURL = try temporaryAssetURL()
        try data.write(to: tempURL, options: .atomic)

        defer {
            try? fileManager.removeItem(at: tempURL)
        }

        let recordID = CKRecord.ID(recordName: BackupConstants.recordName)
        let record = (try await fetchLatestRecord()) ?? CKRecord(recordType: BackupConstants.recordType, recordID: recordID)
        record[BackupConstants.payloadField] = CKAsset(fileURL: tempURL)
        record[BackupConstants.createdAtField] = envelope.createdAt as NSDate
        record[BackupConstants.snapshotHashField] = envelope.snapshotHash as NSString
        record[BackupConstants.schemaVersionField] = NSNumber(value: envelope.schemaVersion)
        record[BackupConstants.appVersionField] = envelope.appVersion as NSString
        record[BackupConstants.buildNumberField] = envelope.buildNumber as NSString

        _ = try await save(record: record)
        cacheSuccessfulBackup(metadata: BackupMetadata(envelope: envelope))
        clearDismissedRestoreSnapshotHash()
        return BackupMetadata(envelope: envelope)
    }

    private func availabilityStatus() async -> BackupStatus.Availability {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BackupStatus.Availability, Error>) in
                container.accountStatus { accountStatus, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    let availability: BackupStatus.Availability
                    switch accountStatus {
                    case .available:
                        availability = .available
                    case .noAccount:
                        availability = .iCloudAccountMissing
                    case .restricted:
                        availability = .restricted
                    case .couldNotDetermine, .temporarilyUnavailable:
                        availability = .temporarilyUnavailable
                    @unknown default:
                        availability = .temporarilyUnavailable
                    }
                    continuation.resume(returning: availability)
                }
            }
        } catch {
            return .temporarilyUnavailable
        }
    }

    private func fetchLatestBackupMetadata() async throws -> BackupMetadata? {
        guard let record = try await fetchLatestRecord() else {
            return nil
        }

        return BackupMetadata(record: record)
    }

    private func fetchLatestRecord() async throws -> CKRecord? {
        let recordID = CKRecord.ID(recordName: BackupConstants.recordName)
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord?, Error>) in
                database.fetch(withRecordID: recordID) { record, error in
                    if let ckError = error as? CKError, ckError.code == .unknownItem {
                        continuation.resume(returning: nil)
                        return
                    }

                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    continuation.resume(returning: record)
                }
            }
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func save(record: CKRecord) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, Error>) in
            database.save(record) { savedRecord, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let savedRecord else {
                    continuation.resume(throwing: BackupCoordinatorError.corruptedBackup)
                    return
                }

                continuation.resume(returning: savedRecord)
            }
        }
    }

    private func temporaryAssetURL() throws -> URL {
        let directory = fileManager.temporaryDirectory.appendingPathComponent("WorkoutAppBackup", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }

        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    }

    private func baseStatus(availability: BackupStatus.Availability) -> BackupStatus {
        BackupStatus(
            availability: availability,
            latestCloudBackup: nil,
            lastSuccessfulBackupAt: cachedLastSuccessfulBackupAt,
            isBackupInProgress: false,
            isRestoreInProgress: false,
            lastErrorDescription: nil
        )
    }

    private func cacheSuccessfulBackup(metadata: BackupMetadata) {
        defaults.set(metadata.createdAt, forKey: PreferenceKey.lastSuccessfulBackupAt)
        defaults.set(metadata.snapshotHash, forKey: PreferenceKey.lastSuccessfulSnapshotHash)
    }

    private func clearDismissedRestoreSnapshotHash() {
        defaults.removeObject(forKey: PreferenceKey.dismissedRestoreSnapshotHash)
    }

    private var cachedLastSuccessfulBackupAt: Date? {
        defaults.object(forKey: PreferenceKey.lastSuccessfulBackupAt) as? Date
    }

    private var dismissedRestoreSnapshotHash: String? {
        defaults.string(forKey: PreferenceKey.dismissedRestoreSnapshotHash)
    }

    private func userFacingError(_ error: Error) -> String {
        if let backupError = error as? BackupCoordinatorError {
            return backupError.localizedDescription
        }

        let nsError = error as NSError
        if nsError.domain == CKError.errorDomain {
            switch CKError.Code(rawValue: nsError.code) {
            case .networkUnavailable, .networkFailure:
                return backupLocalizedString("backup.error.network")
            case .notAuthenticated:
                return backupLocalizedString("backup.error.sign_in")
            case .quotaExceeded:
                return backupLocalizedString("backup.error.quota")
            case .serviceUnavailable, .requestRateLimited, .zoneBusy:
                return backupLocalizedString("backup.error.temporary")
            default:
                break
            }
        }

        return nsError.localizedDescription
    }

    private enum PreferenceKey {
        static let lastSuccessfulBackupAt = "backup.lastSuccessfulBackupAt"
        static let lastSuccessfulSnapshotHash = "backup.lastSuccessfulSnapshotHash"
        static let dismissedRestoreSnapshotHash = "backup.dismissedRestoreSnapshotHash"
    }
}

enum BackupCoordinatorError: LocalizedError {
    case iCloudUnavailable
    case missingBackup
    case corruptedBackup

    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return backupLocalizedString("backup.error.unavailable")
        case .missingBackup:
            return backupLocalizedString("backup.error.missing")
        case .corruptedBackup:
            return backupLocalizedString("backup.error.corrupted")
        }
    }
}

private func backupLocalizedString(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

private extension BackupMetadata {
    init(envelope: BackupEnvelope) {
        self.init(
            createdAt: envelope.createdAt,
            snapshotHash: envelope.snapshotHash,
            schemaVersion: envelope.schemaVersion,
            appVersion: envelope.appVersion,
            buildNumber: envelope.buildNumber
        )
    }

    init?(record: CKRecord) {
        guard
            let createdAt = record[BackupConstants.createdAtField] as? Date ?? record.modificationDate,
            let snapshotHash = record[BackupConstants.snapshotHashField] as? String,
            let schemaVersionNumber = record[BackupConstants.schemaVersionField] as? NSNumber
        else {
            return nil
        }

        self.init(
            createdAt: createdAt,
            snapshotHash: snapshotHash,
            schemaVersion: schemaVersionNumber.intValue,
            appVersion: record[BackupConstants.appVersionField] as? String ?? BackupConstants.appVersion,
            buildNumber: record[BackupConstants.buildNumberField] as? String ?? BackupConstants.buildNumber
        )
    }
}
