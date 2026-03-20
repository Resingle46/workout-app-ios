import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.03, green: 0.03, blue: 0.05)
    static let surface = Color(red: 0.1, green: 0.1, blue: 0.12)
    static let surfaceElevated = Color(red: 0.14, green: 0.14, blue: 0.17)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.16, green: 0.85, blue: 0.67)
    static let accentMuted = Color(red: 0.24, green: 0.39, blue: 0.36)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.65)
}

struct RootTabView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        TabView(selection: $store.selectedTab) {
            NavigationStack { ProgramsView() }
                .tag(RootTab.programs)
                .tabItem { Label("tab.programs", systemImage: "list.clipboard") }

            NavigationStack { ActiveWorkoutView() }
                .tag(RootTab.workout)
                .tabItem { Label("tab.workout", systemImage: "timer") }

            NavigationStack { StatisticsView() }
                .tag(RootTab.statistics)
                .tabItem { Label("tab.statistics", systemImage: "chart.line.uptrend.xyaxis") }

            NavigationStack { ProfileView() }
                .tag(RootTab.profile)
                .tabItem { Label("tab.profile", systemImage: "person.crop.circle") }
        }
        .tint(.white)
        .toolbarColorScheme(.dark, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(AppTheme.surface, for: .tabBar)
    }
}

struct AppCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(AppTheme.stroke, lineWidth: 1)
            )
    }
}

struct AppSectionTitle: View {
    let titleKey: LocalizedStringKey
    var body: some View {
        Text(titleKey)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.secondaryText)
            .textCase(.uppercase)
            .tracking(1.2)
    }
}

struct AppPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.white.opacity(configuration.isPressed ? 0.82 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct AppSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(AppTheme.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(AppTheme.surfaceElevated.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct AppOutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(AppTheme.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(AppTheme.surface.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.28), lineWidth: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

extension View {
    func appScreenBackground() -> some View {
        modifier(AppScreenBackgroundModifier())
    }
}

private struct AppScreenBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                LinearGradient(
                    colors: [Color.black, AppTheme.background],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .foregroundStyle(AppTheme.primaryText)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
}

extension Double {
    var appNumberText: String {
        if truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(self))
        }
        return String(format: "%.1f", self)
    }
}
