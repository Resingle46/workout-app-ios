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
    static let cardCornerRadius: CGFloat = 24
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
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
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

    private var headerBarHeight: CGFloat {
        subtitleKey == nil ? 46 : 54
    }

    private var headerFadeHeight: CGFloat {
        subtitleKey == nil ? 26 : 38
    }

    private var titleFontSize: CGFloat {
        subtitleKey == nil ? 21 : 22
    }

    private var titleTopPadding: CGFloat {
        subtitleKey == nil ? 7 : 1
    }

    private var contentSpacing: CGFloat {
        subtitleKey == nil ? 0 : 4
    }

    private var bottomOverlap: CGFloat {
        subtitleKey == nil ? -6 : -12
    }

    init(titleKey: LocalizedStringKey, subtitleKey: LocalizedStringKey? = nil) {
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.black
                .frame(height: headerBarHeight)
                .overlay(alignment: .top) {
                    VStack(spacing: contentSpacing) {
                        Text(titleKey)
                            .font(AppTypography.pageHeaderTitle(size: titleFontSize))
                            .foregroundStyle(AppTheme.primaryText)
                            .multilineTextAlignment(.center)
                            .tracking(2.8)
                            .textCase(.uppercase)

                        if let subtitleKey {
                            Text(subtitleKey)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(AppTheme.secondaryText)
                                .multilineTextAlignment(.center)
                                .tracking(3.8)
                                .textCase(.uppercase)

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
                                .frame(width: 132, height: 1.4)
                                .clipShape(Capsule())
                                .opacity(0.62)
                                .padding(.top, 1)
                        }
                    }
                    .padding(.top, titleTopPadding)
                }

            LinearGradient(
                colors: [
                    Color.black,
                    Color.black.opacity(0.86),
                    Color.black.opacity(0.62),
                    AppTheme.background.opacity(0.28),
                    AppTheme.background.opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: headerFadeHeight)
        }
        .padding(.horizontal, -20)
        .padding(.bottom, bottomOverlap)
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
                        AppTheme.neonOrange.opacity(0.2),
                        AppTheme.neonViolet.opacity(0.1),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.58, height: height * 0.2),
                    startOffset: CGSize(width: -width * 0.34, height: -height * 0.08),
                    endOffset: CGSize(width: -width * 0.12, height: height * 0.06),
                    blur: 84,
                    driftForward: driftForward
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonBlue.opacity(0.16),
                        AppTheme.neonCyan.opacity(0.12),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.52, height: height * 0.18),
                    startOffset: CGSize(width: width * 0.34, height: -height * 0.06),
                    endOffset: CGSize(width: width * 0.16, height: height * 0.1),
                    blur: 78,
                    driftForward: driftForward
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonViolet.opacity(0.16),
                        AppTheme.neonBlue.opacity(0.1),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.44, height: height * 0.2),
                    startOffset: CGSize(width: -width * 0.2, height: height * 0.38),
                    endOffset: CGSize(width: -width * 0.06, height: height * 0.24),
                    blur: 82,
                    driftForward: driftForward
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonLime.opacity(0.14),
                        AppTheme.neonCyan.opacity(0.08),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.46, height: height * 0.19),
                    startOffset: CGSize(width: width * 0.28, height: height * 0.34),
                    endOffset: CGSize(width: width * 0.12, height: height * 0.18),
                    blur: 76,
                    driftForward: driftForward
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonCyan.opacity(0.14),
                        AppTheme.neonBlue.opacity(0.1),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.44, height: height * 0.18),
                    startOffset: CGSize(width: -width * 0.28, height: height * 0.14),
                    endOffset: CGSize(width: -width * 0.08, height: height * 0.02),
                    blur: 72,
                    driftForward: driftForward
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonViolet.opacity(0.1),
                        AppTheme.neonOrange.opacity(0.08),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.4, height: height * 0.16),
                    startOffset: CGSize(width: width * 0.08, height: height * 0.58),
                    endOffset: CGSize(width: width * 0.18, height: height * 0.42),
                    blur: 70,
                    driftForward: driftForward
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.04),
                        AppTheme.background.opacity(0.12),
                        Color.black.opacity(0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [
                            Color.black,
                            Color.black,
                            Color.black.opacity(0.94),
                            AppTheme.background.opacity(0.55),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: min(height * 0.28, 220))

                    Spacer()
                }

                Color.black.opacity(0.015)
            }
            .ignoresSafeArea()
            .onAppear {
                guard !driftForward else { return }
                withAnimation(.easeInOut(duration: 60).repeatForever(autoreverses: true)) {
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
