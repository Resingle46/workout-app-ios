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

enum AppTypography {
    static func pageHeaderTitle(size: CGFloat = 25) -> Font {
        .custom("PlayfairDisplaySC-Regular", size: size, relativeTo: .title2)
    }
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

struct AppPageHeaderModule: View {
    let titleKey: LocalizedStringKey
    let subtitleKey: LocalizedStringKey?

    init(titleKey: LocalizedStringKey, subtitleKey: LocalizedStringKey? = nil) {
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.black
                .frame(height: subtitleKey == nil ? 70 : 78)
                .overlay(alignment: .top) {
                    VStack(spacing: subtitleKey == nil ? 0 : 5) {
                        Text(titleKey)
                            .font(AppTypography.pageHeaderTitle(size: subtitleKey == nil ? 23 : 25))
                            .foregroundStyle(AppTheme.primaryText)
                            .multilineTextAlignment(.center)
                            .tracking(subtitleKey == nil ? 1.8 : 1.6)

                        if let subtitleKey {
                            Text(subtitleKey)
                                .font(.system(size: 10.5, weight: .light, design: .rounded))
                                .foregroundStyle(AppTheme.secondaryText)
                                .multilineTextAlignment(.center)
                                .tracking(4.6)

                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            AppTheme.neonViolet.opacity(0),
                                            AppTheme.neonViolet.opacity(0.32),
                                            AppTheme.neonBlue.opacity(0.28),
                                            AppTheme.neonCyan.opacity(0.24),
                                            AppTheme.neonLime.opacity(0)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: 162, height: 1.8)
                                .clipShape(Capsule())
                                .opacity(0.8)
                                .padding(.top, 1)
                        }
                    }
                    .padding(.top, subtitleKey == nil ? 18 : 14)
                }

            LinearGradient(
                colors: [
                    Color.black,
                    Color.black.opacity(0.72),
                    AppTheme.background.opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: subtitleKey == nil ? 46 : 58)
        }
        .padding(.horizontal, -20)
        .frame(maxWidth: .infinity, alignment: .top)
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
        ZStack {
            AppAmbientBackground()
            content
        }
        .foregroundStyle(AppTheme.primaryText)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private struct AppAmbientBackground: View {
    @State private var driftForward = false

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
                        AppTheme.neonOrange.opacity(0.4),
                        AppTheme.neonViolet.opacity(0.26),
                        Color.clear
                    ],
                    size: CGSize(width: width * 1.55, height: height * 0.68),
                    startOffset: CGSize(width: -width * 0.92, height: -height * 0.34),
                    endOffset: CGSize(width: width * 0.42, height: -height * 0.24),
                    blur: 138,
                    driftForward: driftForward
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonBlue.opacity(0.34),
                        AppTheme.neonCyan.opacity(0.24),
                        Color.clear
                    ],
                    size: CGSize(width: width * 1.26, height: height * 0.58),
                    startOffset: CGSize(width: width * 0.88, height: -height * 0.24),
                    endOffset: CGSize(width: -width * 0.38, height: height * 0.02),
                    blur: 126,
                    driftForward: driftForward
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonViolet.opacity(0.32),
                        AppTheme.neonBlue.opacity(0.22),
                        Color.clear
                    ],
                    size: CGSize(width: width * 1.48, height: height * 0.66),
                    startOffset: CGSize(width: -width * 0.4, height: height * 0.66),
                    endOffset: CGSize(width: width * 0.52, height: height * 0.2),
                    blur: 144,
                    driftForward: driftForward
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonLime.opacity(0.2),
                        AppTheme.neonCyan.opacity(0.18),
                        Color.clear
                    ],
                    size: CGSize(width: width * 1.02, height: height * 0.44),
                    startOffset: CGSize(width: width * 0.7, height: height * 0.1),
                    endOffset: CGSize(width: -width * 0.16, height: height * 0.38),
                    blur: 110,
                    driftForward: driftForward
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonCyan.opacity(0.2),
                        AppTheme.neonBlue.opacity(0.18),
                        Color.clear
                    ],
                    size: CGSize(width: width * 1.36, height: height * 0.5),
                    startOffset: CGSize(width: -width * 0.82, height: height * 0.14),
                    endOffset: CGSize(width: width * 0.32, height: -height * 0.08),
                    blur: 122,
                    driftForward: driftForward
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonViolet.opacity(0.16),
                        AppTheme.neonOrange.opacity(0.14),
                        Color.clear
                    ],
                    size: CGSize(width: width * 1.18, height: height * 0.4),
                    startOffset: CGSize(width: width * 0.5, height: -height * 0.02),
                    endOffset: CGSize(width: -width * 0.28, height: -height * 0.18),
                    blur: 112,
                    driftForward: driftForward
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.04),
                        AppTheme.background.opacity(0.18),
                        Color.black.opacity(0.1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Color.black.opacity(0.02)
            }
            .ignoresSafeArea()
            .onAppear {
                guard !driftForward else { return }
                withAnimation(.easeInOut(duration: 42).repeatForever(autoreverses: true)) {
                    driftForward = true
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func ambientBlob(
        colors: [Color],
        size: CGSize,
        startOffset: CGSize,
        endOffset: CGSize,
        blur: CGFloat,
        driftForward: Bool
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
            .offset(driftForward ? endOffset : startOffset)
            .blur(radius: blur)
            .blendMode(.screen)
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
