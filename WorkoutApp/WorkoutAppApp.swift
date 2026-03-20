import SwiftUI

@main
struct WorkoutAppApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}
