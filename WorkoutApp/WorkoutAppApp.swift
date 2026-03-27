import SwiftUI

@main
struct WorkoutAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore
    @State private var coachStore: CoachStore
    @State private var workoutSummaryStore: WorkoutSummaryStore
    @State private var cloudSyncStore: CloudSyncStore
    @State private var debugDiagnosticsController: DebugDiagnosticsController

    private let debugRecorder: DebugEventRecorder

    init() {
        AppTypography.configureGlobalAppearance()
        let debugEventStore = DebugEventStore()
        let debugRecorder = DebugEventRecorder(store: debugEventStore)
        self.debugRecorder = debugRecorder

        let store = AppStore(debugRecorder: debugRecorder)
        _store = State(initialValue: store)

        let configurationStore = CoachRuntimeConfigurationStore(bundle: .main)
        let configuration = configurationStore.runtimeConfiguration
        let localStateStore = CoachLocalStateStore()
        let cloudSyncLocalStateStore = CloudSyncLocalStateStore(defaults: localStateStore.userDefaults)
        let client = CoachAPIHTTPClient(
            configuration: configuration,
            debugRecorder: debugRecorder
        )
        let cloudSyncStore = CloudSyncStore(
            client: client,
            configuration: configuration,
            installID: localStateStore.installID,
            localStateStore: cloudSyncLocalStateStore,
            debugRecorder: debugRecorder
        )
        _cloudSyncStore = State(initialValue: cloudSyncStore)
        let coachStore = CoachStore(
            client: client,
            configuration: configuration,
            localStateStore: localStateStore,
            cloudSyncStore: cloudSyncStore,
            debugRecorder: debugRecorder
        )
        _coachStore = State(initialValue: coachStore)
        _workoutSummaryStore = State(
            initialValue: WorkoutSummaryStore(
                client: client,
                configuration: configuration,
                localStateStore: localStateStore,
                debugRecorder: debugRecorder
            )
        )

        let runtimeConfigurationProvider = {
            CoachRuntimeConfigurationStore(bundle: .main).runtimeConfiguration
        }
        let reportBuilder = DebugDiagnosticsReportBuilder(
            eventStore: debugEventStore,
            appStoreProvider: { store },
            coachStoreProvider: { coachStore },
            workoutSummaryStoreProvider: { workoutSummaryStore },
            cloudSyncStoreProvider: { cloudSyncStore },
            coachLocalStateStoreProvider: { localStateStore },
            cloudSyncLocalStateStoreProvider: { cloudSyncLocalStateStore },
            runtimeConfigurationProvider: runtimeConfigurationProvider
        )
        let healthCheckService = DebugHealthCheckService(
            runtimeConfigurationProvider: runtimeConfigurationProvider,
            debugRecorder: debugRecorder
        )
        _debugDiagnosticsController = State(
            initialValue: DebugDiagnosticsController(
                reportBuilder: reportBuilder,
                eventStore: debugEventStore,
                healthCheckService: healthCheckService
            )
        )

        debugRecorder.log(
            category: .appLifecycle,
            message: "app_bootstrapped",
            metadata: [
                "remoteCoachAvailable": configuration.canUseRemoteCoach ? "true" : "false"
            ]
        )
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(coachStore)
                .environment(workoutSummaryStore)
                .environment(cloudSyncStore)
                .environment(debugDiagnosticsController)
                .preferredColorScheme(.dark)
                .task {
                    await store.handleAppLaunch()
                    await cloudSyncStore.handleAppLaunch(using: store)
                    debugDiagnosticsController.refreshReport()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            debugRecorder.log(
                category: .appLifecycle,
                message: "scene_phase_changed",
                metadata: ["phase": scenePhaseName(newPhase)]
            )
            Task {
                switch newPhase {
                case .active:
                    if store.selectedTab == .coach {
                        await coachStore.resumePendingChatJobIfNeeded(using: store)
                    }
                case .background:
                    await cloudSyncStore.handleSceneDidEnterBackground(using: store)
                    await store.handleSceneDidEnterBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }

                await MainActor.run {
                    debugDiagnosticsController.refreshReport()
                }
            }
        }
    }

    private func scenePhaseName(_ phase: ScenePhase) -> String {
        switch phase {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
}
