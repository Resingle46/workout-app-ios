import BackgroundTasks
import SwiftUI

@main
struct WorkoutAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore

    init() {
        let store = AppStore()
        _store = State(initialValue: store)
        BackgroundBackupScheduler.shared.attach(store: store)
        BackgroundBackupScheduler.shared.registerIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .preferredColorScheme(.dark)
                .task {
                    BackgroundBackupScheduler.shared.schedule()
                    await store.handleAppLaunch()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background else {
                return
            }

            BackgroundBackupScheduler.shared.schedule()
            Task {
                await store.handleSceneDidEnterBackground()
            }
        }
    }
}

private final class BackgroundBackupScheduler {
    static let shared = BackgroundBackupScheduler()
    private static let minimumSchedulingDelay: TimeInterval = 60 * 60

    private weak var store: AppStore?
    private var isRegistered = false

    private init() {}

    func attach(store: AppStore) {
        self.store = store
    }

    func registerIfNeeded() {
        guard !isRegistered else {
            return
        }

        isRegistered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackupConstants.backgroundTaskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            self.handle(processingTask)
        }
    }

    func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackupConstants.backgroundTaskIdentifier)

        let request = BGProcessingTaskRequest(identifier: BackupConstants.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.minimumSchedulingDelay)

        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(_ task: BGProcessingTask) {
        schedule()

        let operation = Task { @MainActor [weak self] in
            guard let store = self?.store else {
                return false
            }

            return await store.handleBackgroundBackupTask()
        }

        task.expirationHandler = {
            operation.cancel()
        }

        Task {
            let success = await operation.value
            task.setTaskCompleted(success: success && !operation.isCancelled)
        }
    }
}
