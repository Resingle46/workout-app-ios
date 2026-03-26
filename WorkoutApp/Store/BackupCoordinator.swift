import CryptoKit
import Foundation

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
    let fileName: String
}

struct BackupStatus: Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case notConfigured
        case ready
        case accessLost
    }

    var availability: Availability = .notConfigured
    var selectedFolderName: String?
    var selectedFolderPath: String?
    var latestBackup: BackupMetadata?
    var lastSuccessfulBackupAt: Date?
    var isBackupInProgress = false
    var isRestoreInProgress = false
    var lastErrorDescription: String?

    var hasSelectedFolder: Bool {
        selectedFolderName != nil || selectedFolderPath != nil
    }

    var canBackupNow: Bool {
        availability == .ready && !isBackupInProgress && !isRestoreInProgress
    }

    var canRestoreLatest: Bool {
        availability == .ready && latestBackup != nil && !isBackupInProgress && !isRestoreInProgress
    }
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

enum BackupConstants {
    static let schemaVersion = 1
    static let filePrefix = "WorkoutApp-backup-"
    static let fileExtension = "json"
    static let maxBackupFiles = 3

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

actor BackupCoordinator {
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let debugRecorder: any DebugEventRecording

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default,
        debugRecorder: any DebugEventRecording = NoopDebugEventRecorder()
    ) {
        self.defaults = defaults
        self.now = now
        self.fileManager = fileManager
        self.debugRecorder = debugRecorder

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    static func initialStatus(defaults: UserDefaults = .standard) -> BackupStatus {
        let hasBookmark = defaults.data(forKey: PreferenceKey.folderBookmarkData) != nil
        let accessLost = defaults.bool(forKey: PreferenceKey.folderAccessLost)

        return BackupStatus(
            availability: hasBookmark ? (accessLost ? .accessLost : .ready) : .notConfigured,
            selectedFolderName: defaults.string(forKey: PreferenceKey.folderDisplayName),
            selectedFolderPath: defaults.string(forKey: PreferenceKey.folderPath),
            latestBackup: nil,
            lastSuccessfulBackupAt: defaults.object(forKey: PreferenceKey.lastSuccessfulBackupAt) as? Date,
            isBackupInProgress: false,
            isRestoreInProgress: false,
            lastErrorDescription: accessLost ? backupLocalizedString("backup.error.access_lost") : nil
        )
    }

    func refreshStatus() async -> BackupStatus {
        var status = Self.initialStatus(defaults: defaults)
        guard status.hasSelectedFolder else {
            status.lastErrorDescription = nil
            return status
        }

        do {
            let folderURL = try resolveFolderURL()
            let latestBackup = try latestBackupMetadata(in: folderURL)
            status.availability = .ready
            status.latestBackup = latestBackup
            status.lastSuccessfulBackupAt = latestBackup?.createdAt ?? cachedLastSuccessfulBackupAt
            status.lastErrorDescription = nil
            cacheFolderInfo(for: folderURL)
            defaults.set(false, forKey: PreferenceKey.folderAccessLost)
            return status
        } catch {
            markFolderAccessLost()
            status.availability = .accessLost
            status.latestBackup = nil
            status.lastErrorDescription = userFacingError(error)
            return status
        }
    }

    func selectBackupFolder(_ url: URL) async throws -> BackupStatus {
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
        guard values.isDirectory == true else {
            throw BackupCoordinatorError.invalidFolder
        }

        let bookmarkData = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmarkData, forKey: PreferenceKey.folderBookmarkData)
        defaults.set(false, forKey: PreferenceKey.folderAccessLost)
        defaults.removeObject(forKey: PreferenceKey.lastSuccessfulBackupAt)
        defaults.removeObject(forKey: PreferenceKey.lastSuccessfulSnapshotHash)
        cacheFolderInfo(for: url)
        return await refreshStatus()
    }

    func backupNow(snapshot: AppSnapshot) async -> BackupStatus {
        var status = await refreshStatus()
        guard status.availability == .ready else {
            if status.lastErrorDescription == nil {
                status.lastErrorDescription = backupLocalizedString("backup.error.folder_not_selected")
            }
            return status
        }

        do {
            let envelope = try BackupEnvelope.make(snapshot: snapshot, createdAt: now())
            if envelope.snapshotHash == cachedLastSuccessfulSnapshotHash {
                status.lastErrorDescription = nil
                debugRecorder.log(
                    category: .backup,
                    message: "backup_skipped_unchanged",
                    metadata: [:]
                )
                return status
            }

            let folderURL = try resolveFolderURL()
            let fileURL = try writeBackup(envelope: envelope, to: folderURL)
            try pruneOldBackups(in: folderURL, keepingNewest: BackupConstants.maxBackupFiles)

            let metadata = BackupMetadata(envelope: envelope, fileName: fileURL.lastPathComponent)
            cacheSuccessfulBackup(metadata: metadata)
            defaults.set(false, forKey: PreferenceKey.folderAccessLost)

            status.availability = .ready
            status.latestBackup = metadata
            status.lastSuccessfulBackupAt = metadata.createdAt
            status.lastErrorDescription = nil
            debugRecorder.log(
                category: .backup,
                message: "backup_succeeded",
                metadata: [
                    "schemaVersion": String(metadata.schemaVersion),
                    "fileName": metadata.fileName
                ]
            )
            return status
        } catch {
            markFolderAccessLostIfNeeded(error)
            status = await refreshStatus()
            status.lastErrorDescription = userFacingError(error)
            debugRecorder.log(
                category: .backup,
                level: .error,
                message: "backup_failed",
                metadata: ["error": userFacingError(error)]
            )
            return status
        }
    }

    func restoreLatestBackup() async throws -> BackupEnvelope {
        let folderURL = try resolveFolderURL()
        let fileURL = try latestBackupFileURL(in: folderURL)
        let envelope = try readEnvelope(from: fileURL)
        defaults.set(false, forKey: PreferenceKey.folderAccessLost)
        return envelope
    }

    func importBackup(from url: URL) async throws -> BackupEnvelope {
        try readEnvelope(from: url)
    }

    private func resolveFolderURL() throws -> URL {
        guard let bookmarkData = defaults.data(forKey: PreferenceKey.folderBookmarkData) else {
            throw BackupCoordinatorError.folderNotSelected
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            defaults.set(try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: PreferenceKey.folderBookmarkData)
        }

        let accessStarted = url.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
        guard values.isDirectory == true, fileManager.fileExists(atPath: url.path) else {
            throw BackupCoordinatorError.folderAccessLost
        }

        return url
    }

    private func latestBackupMetadata(in folderURL: URL) throws -> BackupMetadata? {
        guard let latestFileURL = try latestBackupFileURLIfPresent(in: folderURL) else {
            return nil
        }
        let envelope = try readEnvelope(from: latestFileURL)
        return BackupMetadata(envelope: envelope, fileName: latestFileURL.lastPathComponent)
    }

    private func latestBackupFileURL(in folderURL: URL) throws -> URL {
        guard let latest = try latestBackupFileURLIfPresent(in: folderURL) else {
            throw BackupCoordinatorError.missingBackup
        }
        return latest
    }

    private func latestBackupFileURLIfPresent(in folderURL: URL) throws -> URL? {
        let candidates = try backupFileURLs(in: folderURL)
        for fileURL in candidates {
            if (try? readEnvelope(from: fileURL)) != nil {
                return fileURL
            }
        }
        return nil
    }

    private func backupFileURLs(in folderURL: URL) throws -> [URL] {
        let accessStarted = folderURL.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let urls = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return urls
            .filter { url in
                url.lastPathComponent.hasPrefix(BackupConstants.filePrefix) &&
                url.pathExtension.lowercased() == BackupConstants.fileExtension
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func writeBackup(envelope: BackupEnvelope, to folderURL: URL) throws -> URL {
        let fileURL = folderURL.appendingPathComponent(fileName(for: envelope.createdAt))
        let data = try encoder.encode(envelope)

        let accessStarted = folderURL.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func pruneOldBackups(in folderURL: URL, keepingNewest count: Int) throws {
        let files = try backupFileURLs(in: folderURL)
        guard files.count > count else {
            return
        }

        for fileURL in files.dropFirst(count) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func readEnvelope(from url: URL) throws -> BackupEnvelope {
        let accessStarted = url.startAccessingSecurityScopedResource()
        defer {
            if accessStarted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BackupCoordinatorError.corruptedBackup
        }

        do {
            return try decoder.decode(BackupEnvelope.self, from: data)
        } catch {
            throw BackupCoordinatorError.corruptedBackup
        }
    }

    private func fileName(for date: Date) -> String {
        "\(BackupConstants.filePrefix)\(timestampFormatter.string(from: date)).\(BackupConstants.fileExtension)"
    }

    private var timestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter
    }

    private func cacheFolderInfo(for url: URL) {
        defaults.set(url.lastPathComponent, forKey: PreferenceKey.folderDisplayName)
        defaults.set(url.path, forKey: PreferenceKey.folderPath)
    }

    private func cacheSuccessfulBackup(metadata: BackupMetadata) {
        defaults.set(metadata.createdAt, forKey: PreferenceKey.lastSuccessfulBackupAt)
        defaults.set(metadata.snapshotHash, forKey: PreferenceKey.lastSuccessfulSnapshotHash)
    }

    private var cachedLastSuccessfulBackupAt: Date? {
        defaults.object(forKey: PreferenceKey.lastSuccessfulBackupAt) as? Date
    }

    private var cachedLastSuccessfulSnapshotHash: String? {
        defaults.string(forKey: PreferenceKey.lastSuccessfulSnapshotHash)
    }

    private func markFolderAccessLost() {
        defaults.set(true, forKey: PreferenceKey.folderAccessLost)
    }

    private func markFolderAccessLostIfNeeded(_ error: Error) {
        if let backupError = error as? BackupCoordinatorError,
           backupError == .folderAccessLost || backupError == .invalidFolder {
            markFolderAccessLost()
        }
    }

    private func userFacingError(_ error: Error) -> String {
        if let backupError = error as? BackupCoordinatorError {
            return backupError.localizedDescription
        }

        return (error as NSError).localizedDescription
    }

    private enum PreferenceKey {
        static let folderBookmarkData = "backup.folderBookmarkData"
        static let folderDisplayName = "backup.folderDisplayName"
        static let folderPath = "backup.folderPath"
        static let folderAccessLost = "backup.folderAccessLost"
        static let lastSuccessfulBackupAt = "backup.lastSuccessfulBackupAt"
        static let lastSuccessfulSnapshotHash = "backup.lastSuccessfulSnapshotHash"
    }
}

enum BackupCoordinatorError: LocalizedError, Equatable {
    case folderNotSelected
    case invalidFolder
    case folderAccessLost
    case missingBackup
    case corruptedBackup

    var errorDescription: String? {
        switch self {
        case .folderNotSelected:
            return backupLocalizedString("backup.error.folder_not_selected")
        case .invalidFolder:
            return backupLocalizedString("backup.error.invalid_folder")
        case .folderAccessLost:
            return backupLocalizedString("backup.error.access_lost")
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
    init(envelope: BackupEnvelope, fileName: String) {
        self.init(
            createdAt: envelope.createdAt,
            snapshotHash: envelope.snapshotHash,
            schemaVersion: envelope.schemaVersion,
            appVersion: envelope.appVersion,
            buildNumber: envelope.buildNumber,
            fileName: fileName
        )
    }
}
