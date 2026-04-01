import AppIntents
import Foundation
import OSLog

private let completeCurrentSetIntentLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "WorkoutApp",
    category: "live_activity_intent"
)

struct CompleteCurrentSetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Complete current set"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Session ID")
    var sessionID: String

    @Parameter(title: "Current Set ID")
    var currentSetID: String

    init() {}

    init(sessionID: String, currentSetID: String) {
        self.sessionID = sessionID
        self.currentSetID = currentSetID
    }

    func perform() async throws -> some IntentResult {
        guard let sessionUUID = UUID(uuidString: sessionID),
              let currentSetUUID = UUID(uuidString: currentSetID) else {
            completeCurrentSetIntentLogger.error(
                "intent_invalid_payload sessionID=\(sessionID, privacy: .public) currentSetID=\(currentSetID, privacy: .public)"
            )
            return .result()
        }

        let command = WorkoutExternalCommand(
            kind: .completeCurrentSet,
            sessionID: sessionUUID,
            currentSetID: currentSetUUID
        )

        do {
            let commandStore = try WorkoutExternalCommandStore.shared()
            _ = try commandStore.enqueue(command)
            WorkoutLiveActivityCommandSignal.postCommandAvailableNotification()
        } catch {
            completeCurrentSetIntentLogger.error(
                "intent_enqueue_failed sessionID=\(sessionUUID.uuidString, privacy: .public) setID=\(currentSetUUID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }

        return .result()
    }
}
