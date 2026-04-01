import Foundation

enum WorkoutLiveActivitySharedContainer {
    static let appGroupIdentifier = "group.io.resingle.workoutapp"

    static func makeBaseDirectoryURL(
        baseDirectoryURL: URL?,
        fileManager: FileManager = .default
    ) -> URL {
        if let baseDirectoryURL {
            return baseDirectoryURL
        }

        if let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("WorkoutLiveActivity", isDirectory: true)
        }

        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let appDirectoryName = Bundle.main.bundleIdentifier ?? "WorkoutApp"
        return applicationSupportURL
            .appendingPathComponent(appDirectoryName, isDirectory: true)
            .appendingPathComponent("WorkoutLiveActivity", isDirectory: true)
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

    init(baseDirectoryURL: URL? = nil) {
        self.directoryURL = WorkoutLiveActivitySharedContainer.makeBaseDirectoryURL(
            baseDirectoryURL: baseDirectoryURL
        ).appendingPathComponent("external-commands", isDirectory: true)
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
            return true
        } catch CocoaError.fileWriteFileExists {
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

        return try fileURLs
            .filter { $0.pathExtension == "json" }
            .map { url in
                let data = try Data(contentsOf: url)
                return try decoder.decode(WorkoutExternalCommand.self, from: data)
            }
            .filter { $0.schemaVersion == WorkoutExternalCommand.currentSchemaVersion }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.fileName < $1.fileName
                }
                return $0.createdAt < $1.createdAt
            }
    }

    func acknowledge(_ command: WorkoutExternalCommand) throws {
        let fileURL = self.fileURL(for: command)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: fileURL)
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

@MainActor
final class WorkoutLiveActivityCommandRuntime {
    static let shared = WorkoutLiveActivityCommandRuntime()

    var processPendingCommands: (@MainActor () async -> Void)?

    private init() {}
}
