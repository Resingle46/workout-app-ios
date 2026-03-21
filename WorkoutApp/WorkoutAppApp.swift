import SwiftUI

@main
struct WorkoutAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: AppStore

    init() {
        _store = State(initialValue: AppStore())
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
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
