import SwiftUI

@main
struct WorkoutAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore
    @State private var coachStore: CoachStore
    @State private var workoutSummaryStore: WorkoutSummaryStore
    @State private var cloudSyncStore: CloudSyncStore
    @State private var debugDiagnosticsController: DebugDiagnosticsController
    @State private var workoutLiveActivityDiagnostics: WorkoutLiveActivityDiagnostics
    @State private var activeWorkoutDraftCoordinator = ActiveWorkoutDraftCoordinator()
    @State private var workoutLiveActivityManager: WorkoutLiveActivityManager

    private let debugRecorder: DebugEventRecorder

    init() {
        AppTypography.configureGlobalAppearance()
        let debugEventStore = DebugEventStore()
        let debugRecorder = DebugEventRecorder(store: debugEventStore)
        self.debugRecorder = debugRecorder
        let workoutLiveActivityDiagnostics = WorkoutLiveActivityDiagnostics()
        _workoutLiveActivityDiagnostics = State(initialValue: workoutLiveActivityDiagnostics)
        _workoutLiveActivityManager = State(
            initialValue: WorkoutLiveActivityManager(
                diagnostics: workoutLiveActivityDiagnostics,
                debugRecorder: debugRecorder
            )
        )

        let store = AppStore(debugRecorder: debugRecorder)
        _store = State(initialValue: store)

        let configurationStore = CoachRuntimeConfigurationStore(bundle: .main)
        let configuration = configurationStore.runtimeConfiguration
        let localStateStore = CoachLocalStateStore(debugRecorder: debugRecorder)
        let cloudSyncLocalStateStore = CloudSyncLocalStateStore(defaults: localStateStore.userDefaults)
        let client = CoachAPIHTTPClient(
            configuration: configuration,
            installSecretProvider: { localStateStore.installSecret },
            debugRecorder: debugRecorder
        )
        let cloudSyncStore = CloudSyncStore(
            client: client,
            configuration: configuration,
            installID: localStateStore.installID,
            installSecretProvider: { localStateStore.installSecret },
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
        let workoutSummaryStore = WorkoutSummaryStore(
            client: client,
            configuration: configuration,
            localStateStore: localStateStore,
            cloudSyncStore: cloudSyncStore,
            debugRecorder: debugRecorder
        )
        _workoutSummaryStore = State(initialValue: workoutSummaryStore)

        let runtimeConfigurationProvider: @Sendable () -> CoachRuntimeConfiguration = {
            CoachRuntimeConfigurationStore(bundle: .main).runtimeConfiguration
        }
        let reportBuilder = DebugDiagnosticsReportBuilder(
            eventStore: debugEventStore,
            appStoreProvider: { store },
            coachStoreProvider: { coachStore },
            workoutSummaryStoreProvider: { workoutSummaryStore },
            cloudSyncStoreProvider: { cloudSyncStore },
            coachLocalStateStoreProvider: { localStateStore },
            liveActivityDiagnosticsProvider: { workoutLiveActivityDiagnostics },
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
                .environment(activeWorkoutDraftCoordinator)
                .preferredColorScheme(.dark)
                .task {
                    await store.handleAppLaunch()
                    await workoutLiveActivityManager.reconcile(activeSession: store.activeSession, using: store)
                    await cloudSyncStore.handleAppLaunch(using: store)
                    await workoutSummaryStore.resumePendingJobsIfNeeded()
                    await coachStore.resumePendingChatJobIfNeeded(using: store)
                    debugDiagnosticsController.refreshReport()
                }
                .task(id: store.activeSession) {
                    await workoutLiveActivityManager.sync(activeSession: store.activeSession, using: store)
                    await MainActor.run {
                        debugDiagnosticsController.refreshReport()
                    }
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
                    await workoutLiveActivityManager.reconcile(activeSession: store.activeSession, using: store)
                    if store.selectedTab == .coach {
                        await coachStore.resumePendingChatJobIfNeeded(using: store)
                    }
                    await workoutSummaryStore.resumePendingJobsIfNeeded()
                case .inactive:
                    await MainActor.run {
                        activeWorkoutDraftCoordinator.flushAll()
                    }
                    await store.handleSceneWillResignActive()
                    await workoutLiveActivityManager.sync(activeSession: store.activeSession, using: store)
                case .background:
                    await MainActor.run {
                        activeWorkoutDraftCoordinator.flushAll()
                    }
                    await store.handleSceneDidEnterBackground()
                    await workoutLiveActivityManager.sync(activeSession: store.activeSession, using: store)
                    await cloudSyncStore.handleSceneDidEnterBackground(using: store)
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
