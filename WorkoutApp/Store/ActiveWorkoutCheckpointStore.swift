import Foundation

struct ActiveWorkoutCheckpoint: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var savedAt: Date
    var session: WorkoutSession

    init(
        schemaVersion: Int = ActiveWorkoutCheckpoint.currentSchemaVersion,
        savedAt: Date = .now,
        session: WorkoutSession
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.session = session
    }
}

struct ActiveWorkoutCheckpointStore: Sendable {
    let fileURL: URL

    init(baseDirectoryURL: URL? = nil) {
        self.fileURL = Self.makeFileURL(baseDirectoryURL: baseDirectoryURL)
    }

    func load() throws -> ActiveWorkoutCheckpoint? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ActiveWorkoutCheckpoint.self, from: data)
    }

    @discardableResult
    func save(_ checkpoint: ActiveWorkoutCheckpoint) throws -> URL {
        let fileManager = FileManager.default
        try ensureDirectoryExists(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(checkpoint)
        try data.write(to: fileURL, options: .atomic)
        try excludeFromBackup(fileURL)
        return fileURL
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: fileURL)
    }

    func exists() -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    private func ensureDirectoryExists(fileManager: FileManager) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
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

    private static func makeFileURL(baseDirectoryURL: URL?) -> URL {
        let baseDirectory: URL
        if let baseDirectoryURL {
            baseDirectory = baseDirectoryURL
        } else {
            let fileManager = FileManager.default
            let applicationSupportURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let appDirectoryName = Bundle.main.bundleIdentifier ?? "WorkoutApp"
            baseDirectory = applicationSupportURL.appendingPathComponent(
                appDirectoryName,
                isDirectory: true
            )
        }

        return baseDirectory.appendingPathComponent("workout-active-checkpoint.json")
    }
}
