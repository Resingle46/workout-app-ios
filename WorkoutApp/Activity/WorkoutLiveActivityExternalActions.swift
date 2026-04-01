import CoreFoundation
import Foundation
import OSLog

private let workoutExternalActionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "WorkoutApp",
    category: "live_activity_external_action"
)

enum WorkoutLiveActivitySharedContainerError: Error, Equatable, LocalizedError {
    case missingAppGroupContainer(String)

    var errorDescription: String? {
        switch self {
        case .missingAppGroupContainer(let identifier):
            return "Missing app group container: \(identifier)"
        }
    }
}

enum WorkoutLiveActivitySharedContainer {
    static let appGroupIdentifier = "group.io.resingle.workoutapp"

    static func sharedBaseDirectoryURL(
        containerURLProvider: () -> URL? = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: WorkoutLiveActivitySharedContainer.appGroupIdentifier
            )
        }
    ) throws -> URL {
        guard let containerURL = containerURLProvider() else {
            workoutExternalActionLogger.error(
                "shared_container_missing appGroup=\(appGroupIdentifier, privacy: .public)"
            )
            throw WorkoutLiveActivitySharedContainerError.missingAppGroupContainer(
                appGroupIdentifier
            )
        }

        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("WorkoutLiveActivity", isDirectory: true)
    }
}

enum WorkoutLiveActivityCommandSignal {
    static let notificationName = "io.resingle.workoutapp.live-activity.command-available"

    static var cfNotificationName: CFNotificationName {
        CFNotificationName(notificationName as CFString)
    }

    static func postCommandAvailableNotification() {
        workoutExternalActionLogger.log(
            "command_signal_posted name=\(notificationName, privacy: .public)"
        )
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            cfNotificationName,
            nil,
            nil,
            true
        )
    }
}

final class WorkoutLiveActivityCommandObserver {
    private let handler: @MainActor () async -> Void
    private var observerPointer: UnsafeMutableRawPointer?

    init(handler: @escaping @MainActor () async -> Void) {
        self.handler = handler
        let observerPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        self.observerPointer = observerPointer

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observerPointer,
            { _, observer, name, _, _ in
                guard let observer else { return }
                let instance = Unmanaged<WorkoutLiveActivityCommandObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                instance.handleNotification(name)
            },
            WorkoutLiveActivityCommandSignal.notificationName as CFString,
            nil,
            .deliverImmediately
        )

        workoutExternalActionLogger.log(
            "command_observer_registered name=\(WorkoutLiveActivityCommandSignal.notificationName, privacy: .public)"
        )
    }

    deinit {
        guard let observerPointer else {
            return
        }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observerPointer,
            WorkoutLiveActivityCommandSignal.cfNotificationName,
            nil
        )
        workoutExternalActionLogger.log(
            "command_observer_removed name=\(WorkoutLiveActivityCommandSignal.notificationName, privacy: .public)"
        )
    }

    private func handleNotification(_ name: CFNotificationName?) {
        let notificationName = name.map { $0.rawValue as String }
            ?? WorkoutLiveActivityCommandSignal.notificationName
        workoutExternalActionLogger.log(
            "command_signal_received name=\(notificationName, privacy: .public)"
        )
        Task { @MainActor in
            await handler()
        }
    }
}

struct WorkoutExternalCommand: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case completeCurrentSet
    }

    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var kind: Kind
    var sessionID: UUID
    var currentSetID: UUID
    var createdAt: Date

    init(
        schemaVersion: Int = WorkoutExternalCommand.currentSchemaVersion,
        kind: Kind,
        sessionID: UUID,
        currentSetID: UUID,
        createdAt: Date = .now
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.sessionID = sessionID
        self.currentSetID = currentSetID
        self.createdAt = createdAt
    }

    var fileName: String {
        "\(kind.rawValue)-\(sessionID.uuidString.lowercased())-\(currentSetID.uuidString.lowercased()).json"
    }
}

struct WorkoutExternalCommandStore: Sendable {
    let directoryURL: URL

    init(baseDirectoryURL: URL) {
        self.directoryURL = baseDirectoryURL.appendingPathComponent(
            "external-commands",
            isDirectory: true
        )
    }

    static func shared(
        containerURLProvider: () -> URL? = {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: WorkoutLiveActivitySharedContainer.appGroupIdentifier
            )
        }
    ) throws -> WorkoutExternalCommandStore {
        WorkoutExternalCommandStore(
            baseDirectoryURL: try WorkoutLiveActivitySharedContainer.sharedBaseDirectoryURL(
                containerURLProvider: containerURLProvider
            )
        )
    }

    @discardableResult
    func enqueue(_ command: WorkoutExternalCommand) throws -> Bool {
        let fileManager = FileManager.default
        try ensureDirectoryExists(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(command)
        let fileURL = self.fileURL(for: command)

        do {
            try data.write(to: fileURL, options: [.atomic, .withoutOverwriting])
            try excludeFromBackup(fileURL)
            workoutExternalActionLogger.log(
                "command_enqueued kind=\(command.kind.rawValue, privacy: .public) sessionID=\(command.sessionID.uuidString, privacy: .public) setID=\(command.currentSetID.uuidString, privacy: .public)"
            )
            return true
        } catch CocoaError.fileWriteFileExists {
            workoutExternalActionLogger.log(
                "command_enqueue_duplicate kind=\(command.kind.rawValue, privacy: .public) sessionID=\(command.sessionID.uuidString, privacy: .public) setID=\(command.currentSetID.uuidString, privacy: .public)"
            )
            return false
        }
    }

    func pendingCommands() throws -> [WorkoutExternalCommand] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let commands = fileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap { (url: URL) -> WorkoutExternalCommand? in
                do {
                    let data = try Data(contentsOf: url)
                    let command = try decoder.decode(WorkoutExternalCommand.self, from: data)
                    guard command.schemaVersion == WorkoutExternalCommand.currentSchemaVersion else {
                        workoutExternalActionLogger.warning(
                            "command_load_ignored_schema_mismatch file=\(url.lastPathComponent, privacy: .public) schemaVersion=\(command.schemaVersion, privacy: .public)"
                        )
                        try? FileManager.default.removeItem(at: url)
                        return nil
                    }
                    return command
                } catch {
                    workoutExternalActionLogger.error(
                        "command_load_failed file=\(url.lastPathComponent, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
            }
            .sorted { (lhs: WorkoutExternalCommand, rhs: WorkoutExternalCommand) in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.fileName < rhs.fileName
                }
                return lhs.createdAt < rhs.createdAt
            }

        workoutExternalActionLogger.log(
            "command_load_succeeded count=\(commands.count, privacy: .public)"
        )
        return commands
    }

    func acknowledge(_ command: WorkoutExternalCommand) throws {
        let fileURL = self.fileURL(for: command)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: fileURL)
        workoutExternalActionLogger.log(
            "command_acknowledged kind=\(command.kind.rawValue, privacy: .public) sessionID=\(command.sessionID.uuidString, privacy: .public) setID=\(command.currentSetID.uuidString, privacy: .public)"
        )
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }

        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            try FileManager.default.removeItem(at: fileURL)
        }
        workoutExternalActionLogger.log("command_store_cleared")
    }

    private func fileURL(for command: WorkoutExternalCommand) -> URL {
        directoryURL.appendingPathComponent(command.fileName, isDirectory: false)
    }

    private func ensureDirectoryExists(fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
        try excludeFromBackup(directoryURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }
}
