import AppIntents
import Foundation

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
            return .result()
        }

        let command = WorkoutExternalCommand(
            kind: .completeCurrentSet,
            sessionID: sessionUUID,
            currentSetID: currentSetUUID
        )
        let commandStore = WorkoutExternalCommandStore()
        _ = try commandStore.enqueue(command)

        #if APP_EXTENSION
        if let runtimeProcessor = await MainActor.run(
            body: { WorkoutLiveActivityCommandRuntime.shared.processPendingCommands }
        ) {
            await runtimeProcessor()
        }
        #else
        await WorkoutLiveActivityIntentAppExecutor.shared.processPendingCommands()
        #endif

        return .result()
    }
}
