import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            NavigationStack { ProgramsView() }
                .tabItem { Label("tab.programs", systemImage: "list.clipboard") }

            NavigationStack { ActiveWorkoutView() }
                .tabItem { Label("tab.workout", systemImage: "timer") }

            NavigationStack { StatisticsView() }
                .tabItem { Label("tab.statistics", systemImage: "chart.line.uptrend.xyaxis") }

            NavigationStack { ProfileView() }
                .tabItem { Label("tab.profile", systemImage: "person.crop.circle") }
        }
    }
}
