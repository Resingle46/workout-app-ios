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

enum AppCardGlowStyle {
    case neutral
    case programs
    case workout
    case statistics
    case profile
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
    let glowStyle: AppCardGlowStyle
    let content: Content

    init(glowStyle: AppCardGlowStyle = .neutral, @ViewBuilder content: () -> Content) {
        self.glowStyle = glowStyle
        self.content = content()
    }

    var body: some View {
        content
            .appLiquidGlassCard(glowStyle: glowStyle)
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
    @Environment(\.locale) private var locale

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

    private var usesRussianHeaderMetrics: Bool {
        locale.identifier.lowercased().hasPrefix("ru")
    }

    private var titleTracking: CGFloat {
        usesRussianHeaderMetrics ? 1.6 : 2.8
    }

    private var subtitleTracking: CGFloat {
        usesRussianHeaderMetrics ? 2.2 : 3.8
    }

    private var subtitleFontSize: CGFloat {
        usesRussianHeaderMetrics ? 10 : 10.5
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
                            .tracking(titleTracking)
                            .textCase(.uppercase)
                            .lineLimit(1)
                            .minimumScaleFactor(0.84)
                            .allowsTightening(true)

                        if let subtitleKey {
                            Text(subtitleKey)
                                .font(.system(size: subtitleFontSize, weight: .medium, design: .rounded))
                                .foregroundStyle(AppTheme.secondaryText)
                                .multilineTextAlignment(.center)
                                .tracking(subtitleTracking)
                                .textCase(.uppercase)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .allowsTightening(true)

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
    func appLiquidGlassCard(
        glowStyle: AppCardGlowStyle = .neutral,
        padding: CGFloat = 18,
        cornerRadius: CGFloat = AppTheme.cardCornerRadius,
        shadowColor: Color = Color.black.opacity(0.26)
    ) -> some View {
        modifier(
            AppLiquidGlassCardModifier(
                glowStyle: glowStyle,
                padding: padding,
                cornerRadius: cornerRadius,
                shadowColor: shadowColor
            )
        )
    }

    func appScreenBackground() -> some View {
        modifier(AppScreenBackgroundModifier())
    }
}

private struct AppLiquidGlassCardModifier: ViewModifier {
    let glowStyle: AppCardGlowStyle
    let padding: CGFloat
    let cornerRadius: CGFloat
    let shadowColor: Color

    private var borderPalette: AppLiquidGlassBorderPalette {
        switch glowStyle {
        case .neutral:
            AppLiquidGlassBorderPalette(
                rimColors: [
                    Color.white.opacity(0.72),
                    AppTheme.neonBlue.opacity(0.42),
                    Color.white.opacity(0.22),
                    AppTheme.neonViolet.opacity(0.34),
                    Color.white.opacity(0.68)
                ],
                edgeGlowColors: [
                    Color.white.opacity(0.14),
                    AppTheme.neonBlue.opacity(0.16),
                    Color.clear,
                    AppTheme.neonViolet.opacity(0.14),
                    Color.white.opacity(0.12)
                ],
                highlightColors: [
                    Color.white.opacity(0.46),
                    Color.white.opacity(0.08),
                    Color.clear
                ],
                highlightStart: UnitPoint(x: 0.12, y: 0.04),
                highlightEnd: UnitPoint(x: 0.9, y: 0.94)
            )
        case .programs:
            AppLiquidGlassBorderPalette(
                rimColors: [
                    Color.white.opacity(0.84),
                    AppTheme.neonCyan.opacity(0.54),
                    AppTheme.neonLime.opacity(0.22),
                    Color.white.opacity(0.2),
                    AppTheme.neonBlue.opacity(0.3),
                    Color.white.opacity(0.78)
                ],
                edgeGlowColors: [
                    Color.white.opacity(0.18),
                    AppTheme.neonCyan.opacity(0.22),
                    AppTheme.neonLime.opacity(0.12),
                    Color.clear,
                    Color.white.opacity(0.12)
                ],
                highlightColors: [
                    Color.white.opacity(0.52),
                    AppTheme.neonCyan.opacity(0.12),
                    Color.clear
                ],
                highlightStart: UnitPoint(x: 0.05, y: 0.08),
                highlightEnd: UnitPoint(x: 0.86, y: 0.94)
            )
        case .workout:
            AppLiquidGlassBorderPalette(
                rimColors: [
                    Color.white.opacity(0.72),
                    AppTheme.neonBlue.opacity(0.4),
                    AppTheme.neonCyan.opacity(0.34),
                    Color.white.opacity(0.18),
                    AppTheme.neonViolet.opacity(0.46),
                    Color.white.opacity(0.76)
                ],
                edgeGlowColors: [
                    Color.white.opacity(0.1),
                    AppTheme.neonBlue.opacity(0.2),
                    AppTheme.neonCyan.opacity(0.14),
                    Color.clear,
                    AppTheme.neonViolet.opacity(0.14)
                ],
                highlightColors: [
                    Color.clear,
                    Color.white.opacity(0.18),
                    AppTheme.neonBlue.opacity(0.32),
                    Color.white.opacity(0.18),
                    Color.clear
                ],
                highlightStart: UnitPoint(x: 0.42, y: 0.02),
                highlightEnd: UnitPoint(x: 1.0, y: 0.92)
            )
        case .statistics:
            AppLiquidGlassBorderPalette(
                rimColors: [
                    Color.white.opacity(0.7),
                    AppTheme.neonViolet.opacity(0.48),
                    AppTheme.neonBlue.opacity(0.32),
                    Color.white.opacity(0.16),
                    AppTheme.neonCyan.opacity(0.3),
                    Color.white.opacity(0.74)
                ],
                edgeGlowColors: [
                    Color.white.opacity(0.12),
                    AppTheme.neonViolet.opacity(0.22),
                    AppTheme.neonBlue.opacity(0.16),
                    Color.clear,
                    AppTheme.neonCyan.opacity(0.12)
                ],
                highlightColors: [
                    Color.white.opacity(0.38),
                    AppTheme.neonViolet.opacity(0.16),
                    Color.clear
                ],
                highlightStart: UnitPoint(x: 0.18, y: 0.02),
                highlightEnd: UnitPoint(x: 0.96, y: 0.92)
            )
        case .profile:
            AppLiquidGlassBorderPalette(
                rimColors: [
                    Color.white.opacity(0.8),
                    Color.white.opacity(0.22),
                    AppTheme.neonCyan.opacity(0.32),
                    AppTheme.neonBlue.opacity(0.16),
                    Color.white.opacity(0.72)
                ],
                edgeGlowColors: [
                    Color.white.opacity(0.16),
                    AppTheme.neonCyan.opacity(0.18),
                    Color.clear,
                    AppTheme.neonBlue.opacity(0.1),
                    Color.white.opacity(0.12)
                ],
                highlightColors: [
                    Color.white.opacity(0.5),
                    Color.white.opacity(0.12),
                    Color.clear
                ],
                highlightStart: UnitPoint(x: 0.1, y: 0.04),
                highlightEnd: UnitPoint(x: 0.84, y: 0.96)
            )
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(AppTheme.surface.opacity(0.96))
                    .overlay {
                        GeometryReader { proxy in
                            AppLiquidGlassGlowLayer(glowStyle: glowStyle, size: proxy.size)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                    .overlay {
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.022),
                                        Color.clear,
                                        Color.black.opacity(0.1)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .overlay {
                shape
                    .strokeBorder(
                        AngularGradient(
                            colors: borderPalette.rimColors,
                            center: .center
                        ),
                        lineWidth: 1.3
                    )
                    .overlay {
                        shape
                            .strokeBorder(
                                LinearGradient(
                                    colors: borderPalette.highlightColors,
                                    startPoint: borderPalette.highlightStart,
                                    endPoint: borderPalette.highlightEnd
                                ),
                                lineWidth: 1.05
                            )
                            .blendMode(.screen)
                    }
                    .overlay {
                        shape
                            .strokeBorder(
                                AngularGradient(
                                    colors: borderPalette.edgeGlowColors,
                                    center: .center
                                ),
                                lineWidth: 2.4
                            )
                            .blur(radius: 2.4)
                            .opacity(0.82)
                    }
            }
            .shadow(color: shadowColor, radius: 24, y: 10)
    }
}

private struct AppLiquidGlassGlowLayer: View {
    let glowStyle: AppCardGlowStyle
    let size: CGSize

    var body: some View {
        ZStack {
            sheenBand
            glowPattern
            RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.012),
                            Color.clear,
                            Color.black.opacity(0.075)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var sheenBand: some View {
        switch glowStyle {
        case .neutral:
            glassBand(x: -0.06, y: -0.06, width: 0.26, rotation: -6, opacity: 0.08)
        case .programs:
            glassBand(x: 0.02, y: -0.04, width: 0.22, rotation: -4, opacity: 0.08)
        case .workout:
            glassBand(x: 0.28, y: -0.02, width: 0.24, rotation: 18, opacity: 0.07)
        case .statistics:
            glassBand(x: 0.14, y: 0.06, width: 0.2, rotation: -16, opacity: 0.06)
        case .profile:
            glassBand(x: 0.08, y: -0.02, width: 0.18, rotation: 2, opacity: 0.055)
        }
    }

    @ViewBuilder
    private var glowPattern: some View {
        switch glowStyle {
        case .neutral:
            glowEllipse(
                colors: [AppTheme.neonBlue.opacity(0.08), AppTheme.neonViolet.opacity(0.05), .clear],
                width: 0.76,
                height: 0.4,
                x: 0.08,
                y: 0.36,
                blur: 40
            )
        case .programs:
            ZStack {
                glowEllipse(
                    colors: [AppTheme.neonCyan.opacity(0.15), AppTheme.neonBlue.opacity(0.06), .clear],
                    width: 0.92,
                    height: 0.34,
                    x: -0.06,
                    y: 0.4,
                    blur: 42
                )
                glowEllipse(
                    colors: [AppTheme.neonLime.opacity(0.08), AppTheme.neonCyan.opacity(0.03), .clear],
                    width: 0.62,
                    height: 0.24,
                    x: 0.12,
                    y: 0.42,
                    blur: 34
                )
            }
        case .workout:
            ZStack {
                glowCapsule(
                    colors: [AppTheme.neonBlue.opacity(0.14), AppTheme.neonViolet.opacity(0.08), .clear],
                    width: 0.92,
                    height: 0.2,
                    x: 0.18,
                    y: 0.18,
                    blur: 38,
                    rotation: 24
                )
                glowEllipse(
                    colors: [AppTheme.neonCyan.opacity(0.13), AppTheme.neonBlue.opacity(0.04), .clear],
                    width: 0.56,
                    height: 0.32,
                    x: 0.28,
                    y: 0.36,
                    blur: 34
                )
                glowEllipse(
                    colors: [AppTheme.neonLime.opacity(0.07), .clear],
                    width: 0.42,
                    height: 0.22,
                    x: 0.22,
                    y: 0.48,
                    blur: 28
                )
            }
        case .statistics:
            ZStack {
                glowCapsule(
                    colors: [AppTheme.neonViolet.opacity(0.12), AppTheme.neonBlue.opacity(0.06), .clear],
                    width: 0.32,
                    height: 0.11,
                    x: -0.18,
                    y: 0.38,
                    blur: 28,
                    rotation: -18
                )
                glowCapsule(
                    colors: [AppTheme.neonViolet.opacity(0.13), AppTheme.neonCyan.opacity(0.05), .clear],
                    width: 0.34,
                    height: 0.11,
                    x: 0.02,
                    y: 0.28,
                    blur: 30,
                    rotation: -18
                )
                glowCapsule(
                    colors: [AppTheme.neonBlue.opacity(0.14), AppTheme.neonCyan.opacity(0.06), .clear],
                    width: 0.34,
                    height: 0.11,
                    x: 0.22,
                    y: 0.18,
                    blur: 30,
                    rotation: -18
                )
                glowEllipse(
                    colors: [AppTheme.neonBlue.opacity(0.08), .clear],
                    width: 0.6,
                    height: 0.24,
                    x: 0.16,
                    y: 0.42,
                    blur: 34
                )
            }
        case .profile:
            ZStack {
                glowEllipse(
                    colors: [Color.white.opacity(0.06), AppTheme.neonCyan.opacity(0.055), .clear],
                    width: 0.66,
                    height: 0.42,
                    x: 0.02,
                    y: 0.12,
                    blur: 44
                )
                glowEllipse(
                    colors: [AppTheme.neonCyan.opacity(0.075), AppTheme.neonBlue.opacity(0.025), .clear],
                    width: 0.82,
                    height: 0.28,
                    x: 0.02,
                    y: 0.4,
                    blur: 38
                )
            }
        }
    }

    private func glassBand(x: CGFloat, y: CGFloat, width: CGFloat, rotation: Double, opacity: Double) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(opacity * 0.08),
                        Color.white.opacity(opacity),
                        Color.white.opacity(opacity * 0.16),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: size.width * width, height: size.height * 1.22)
            .rotationEffect(.degrees(rotation))
            .offset(x: size.width * x, y: size.height * y)
            .blur(radius: 34)
    }

    private func glowEllipse(
        colors: [Color],
        width: CGFloat,
        height: CGFloat,
        x: CGFloat,
        y: CGFloat,
        blur: CGFloat,
        rotation: Double = 0
    ) -> some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: colors,
                    center: .center,
                    startRadius: 8,
                    endRadius: max(size.width, size.height) * 0.46
                )
            )
            .frame(width: size.width * width, height: size.height * height)
            .rotationEffect(.degrees(rotation))
            .offset(x: size.width * x, y: size.height * y)
            .blur(radius: blur)
    }

    private func glowCapsule(
        colors: [Color],
        width: CGFloat,
        height: CGFloat,
        x: CGFloat,
        y: CGFloat,
        blur: CGFloat,
        rotation: Double
    ) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: colors,
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: size.width * width, height: size.height * height)
            .rotationEffect(.degrees(rotation))
            .offset(x: size.width * x, y: size.height * y)
            .blur(radius: blur)
    }
}

private struct AppLiquidGlassBorderPalette {
    let rimColors: [Color]
    let edgeGlowColors: [Color]
    let highlightColors: [Color]
    let highlightStart: UnitPoint
    let highlightEnd: UnitPoint
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
