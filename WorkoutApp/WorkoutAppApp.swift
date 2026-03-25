import SwiftUI

@main
struct WorkoutAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore
    @State private var coachConfigurationStore: CoachRuntimeConfigurationStore
    @State private var coachStore: CoachStore

    init() {
        AppTypography.configureGlobalAppearance()
        _store = State(initialValue: AppStore())
        let configurationStore = CoachRuntimeConfigurationStore(bundle: .main)
        let configuration = configurationStore.runtimeConfiguration
        _coachConfigurationStore = State(initialValue: configurationStore)
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
                .environment(coachConfigurationStore)
                .environment(coachStore)
                .preferredColorScheme(.dark)
                .task {
                    await store.handleAppLaunch()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background else {
                return
            }

            Task {
                await store.handleSceneDidEnterBackground()
            }
        }
    }
}
