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
    static let neonBlue = Color(red: 0.21, green: 0.36, blue: 1.0)
    static let neonViolet = Color(red: 0.55, green: 0.2, blue: 1.0)
    static let neonCyan = Color(red: 0.22, green: 0.88, blue: 0.96)
    static let neonLime = Color(red: 0.73, green: 1.0, blue: 0.25)
    static let neonOrange = Color(red: 0.98, green: 0.48, blue: 0.26)
}

@MainActor
struct RootTabView: View {
    @Environment(AppStore.self) private var store
    @State private var showBackupSetupPrompt = false
    @State private var launchBackupPickerMode: BackupDocumentPickerMode?
    @State private var launchRestoreRequest: BackupRestoreRequest?

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
        .environment(\.locale, store.locale)
        .toolbarColorScheme(.dark, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(AppTheme.surface, for: .tabBar)
        .onChange(of: store.shouldPromptForBackupSetup, initial: true) { _, newValue in
            showBackupSetupPrompt = newValue
        }
        .confirmationDialog("backup.setup.title", isPresented: $showBackupSetupPrompt, titleVisibility: .visible) {
            Button("backup.setup.choose_folder") {
                store.dismissBackupSetupPrompt()
                launchBackupPickerMode = .folder
            }
            Button("backup.setup.later", role: .cancel) {
                store.dismissBackupSetupPrompt()
            }
        } message: {
            Text("backup.setup.message")
        }
        .sheet(item: $launchBackupPickerMode) { mode in
            BackupDocumentPicker(mode: mode, onPick: { url in
                launchBackupPickerMode = nil
                Task {
                    let hadExistingBackups = await store.chooseBackupFolder(url)
                    if hadExistingBackups {
                        launchRestoreRequest = .latest
                    }
                }
            }, onCancel: {
                launchBackupPickerMode = nil
            })
        }
        .alert(item: $launchRestoreRequest) { request in
            Alert(
                title: Text("backup.setup.restore_found_title"),
                message: Text(request.message(store: store)),
                primaryButton: .default(Text("backup.action.restore")) {
                    Task {
                        await store.restoreLatestBackup()
                    }
                },
                secondaryButton: .cancel(Text("backup.setup.restore_later"))
            )
        }
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
            .font(.system(size: 17, weight: .medium, design: .rounded))
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
            .font(.system(size: 17, weight: .medium, design: .rounded))
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
            .font(.system(size: 17, weight: .medium, design: .rounded))
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
            .background(AppAmbientBackground())
            .foregroundStyle(AppTheme.primaryText)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private struct AppAmbientBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                LinearGradient(
                    colors: [
                        Color.black,
                        AppTheme.background,
                        Color(red: 0.02, green: 0.02, blue: 0.04)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonOrange.opacity(0.2),
                        AppTheme.neonViolet.opacity(0.12),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.92, height: height * 0.42),
                    offset: CGSize(width: -width * 0.28, height: -height * 0.2),
                    blur: 120
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonBlue.opacity(0.18),
                        AppTheme.neonCyan.opacity(0.12),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.78, height: height * 0.34),
                    offset: CGSize(width: width * 0.34, height: -height * 0.1),
                    blur: 112
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonViolet.opacity(0.16),
                        AppTheme.neonBlue.opacity(0.1),
                        Color.clear
                    ],
                    size: CGSize(width: width * 1.05, height: height * 0.38),
                    offset: CGSize(width: -width * 0.08, height: height * 0.36),
                    blur: 132
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonLime.opacity(0.08),
                        AppTheme.neonCyan.opacity(0.06),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.62, height: height * 0.24),
                    offset: CGSize(width: width * 0.2, height: height * 0.24),
                    blur: 96
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.18),
                        AppTheme.background.opacity(0.56),
                        Color.black.opacity(0.34)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Color.black.opacity(0.14)
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }

    private func ambientBlob(
        colors: [Color],
        size: CGSize,
        offset: CGSize,
        blur: CGFloat
    ) -> some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: colors,
                    center: .center,
                    startRadius: 12,
                    endRadius: max(size.width, size.height) * 0.52
                )
            )
            .frame(width: size.width, height: size.height)
            .offset(offset)
            .blur(radius: blur)
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
