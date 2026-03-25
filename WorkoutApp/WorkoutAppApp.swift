import SwiftUI

@main
struct WorkoutAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore
    @State private var coachStore: CoachStore

    init() {
        AppTypography.configureGlobalAppearance()
        _store = State(initialValue: AppStore())
        let configurationStore = CoachRuntimeConfigurationStore(bundle: .main)
        let configuration = configurationStore.runtimeConfiguration
        _coachStore = State(
            initialValue: CoachStore(
                client: CoachAPIHTTPClient(configuration: configuration),
                configuration: configuration
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(coachStore)
                .preferredColorScheme(.dark)
                .task {
                    await store.handleAppLaunch()
                    await coachStore.syncSnapshotIfNeeded(using: store)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background else {
                return
            }

            Task {
                await coachStore.syncSnapshotIfNeeded(using: store)
                await store.handleSceneDidEnterBackground()
            }
        }
    }
}
