import Foundation

@MainActor
final class WorkoutLiveActivityIntentAppExecutor {
    static let shared = WorkoutLiveActivityIntentAppExecutor()

    private init() {}

    func processPendingCommands() async {
        if let runtimeProcessor = WorkoutLiveActivityCommandRuntime.shared.processPendingCommands {
            await runtimeProcessor()
            return
        }

        let store = AppStore()
        let diagnostics = WorkoutLiveActivityDiagnostics()
        let liveActivityManager = WorkoutLiveActivityManager(diagnostics: diagnostics)
        let commandProcessor = WorkoutLiveActivityCommandProcessor()

        await store.handleAppLaunch()
        _ = await commandProcessor.processPendingCommands(
            using: store,
            liveActivitySynchronizer: liveActivityManager
        )
    }
}
