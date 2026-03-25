import SwiftUI

@main
struct WorkoutAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore
    @State private var coachStore: CoachStore
    @State private var cloudSyncStore: CloudSyncStore

    init() {
        AppTypography.configureGlobalAppearance()
        _store = State(initialValue: AppStore())
        let configurationStore = CoachRuntimeConfigurationStore(bundle: .main)
        let configuration = configurationStore.runtimeConfiguration
        let client = CoachAPIHTTPClient(configuration: configuration)
        let localStateStore = CoachLocalStateStore()
        let cloudSyncStore = CloudSyncStore(
            client: client,
            configuration: configuration,
            installID: localStateStore.installID
        )
        _cloudSyncStore = State(initialValue: cloudSyncStore)
        _coachStore = State(
            initialValue: CoachStore(
                client: client,
                configuration: configuration,
                localStateStore: localStateStore,
                cloudSyncStore: cloudSyncStore
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(coachStore)
                .environment(cloudSyncStore)
                .preferredColorScheme(.dark)
                .task {
                    await store.handleAppLaunch()
                    await cloudSyncStore.handleAppLaunch(using: store)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background else {
                return
            }

            Task {
                await cloudSyncStore.handleSceneDidEnterBackground(using: store)
                await store.handleSceneDidEnterBackground()
            }
        }
    }
}
