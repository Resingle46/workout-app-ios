import SwiftUI
import UIKit

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
    private static let onestPostScriptName = "Onest-Regular"

    static func pageHeaderTitle(size: CGFloat = 25) -> Font {
        .custom("PlayfairDisplaySC-Regular", size: size, relativeTo: .title2)
    }

    static func body(size: CGFloat = 17, weight: AppFontWeight = .regular, relativeTo textStyle: Font.TextStyle = .body) -> Font {
        onest(size: size, weight: weight, relativeTo: textStyle)
    }

    static func title(size: CGFloat = 30) -> Font {
        onest(size: size, weight: .black, relativeTo: .title2)
    }

    static func heading(size: CGFloat = 24) -> Font {
        onest(size: size, weight: .heavy, relativeTo: .title3)
    }

    static func metric(size: CGFloat = 28) -> Font {
        onest(size: size, weight: .black, relativeTo: .title3)
    }

    static func button(size: CGFloat = 17) -> Font {
        onest(size: size, weight: .semibold, relativeTo: .headline)
    }

    static func label(size: CGFloat = 12, weight: AppFontWeight = .semibold) -> Font {
        onest(size: size, weight: weight, relativeTo: .caption)
    }

    static func caption(size: CGFloat = 13, weight: AppFontWeight = .medium) -> Font {
        onest(size: size, weight: weight, relativeTo: .caption)
    }

    static func value(size: CGFloat = 18, weight: AppFontWeight = .semibold) -> Font {
        onest(size: size, weight: weight, relativeTo: .body)
    }

    static func icon(size: CGFloat = 18, weight: AppFontWeight = .semibold) -> Font {
        onest(size: size, weight: weight, relativeTo: .body)
    }

    static func configureGlobalAppearance() {
        let segmented = UISegmentedControl.appearance()
        let normalFont = UIFont(name: onestPostScriptName, size: 14) ?? .systemFont(ofSize: 14, weight: .medium)
        let selectedFont = UIFont(name: onestPostScriptName, size: 14) ?? .systemFont(ofSize: 14, weight: .semibold)
        segmented.setTitleTextAttributes([.font: normalFont], for: .normal)
        segmented.setTitleTextAttributes([.font: selectedFont], for: .selected)
    }

    private static func onest(size: CGFloat, weight: AppFontWeight, relativeTo textStyle: Font.TextStyle) -> Font {
        .custom(onestPostScriptName, size: size, relativeTo: textStyle).weight(weight.fontWeight)
    }
}

enum AppFontWeight {
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black

    fileprivate var fontWeight: Font.Weight {
        switch self {
        case .regular:
            .regular
        case .medium:
            .medium
        case .semibold:
            .semibold
        case .bold:
            .bold
        case .heavy:
            .heavy
        case .black:
            .black
        }
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
            .font(AppTypography.body())
            .appLiquidGlassCard(glowStyle: glowStyle)
    }
}

struct AppSectionTitle: View {
    let titleKey: LocalizedStringKey
    var body: some View {
        Text(titleKey)
            .font(AppTypography.label())
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
            .font(AppTypography.button())
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
            .font(AppTypography.button())
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
            .font(AppTypography.button())
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
                    Color.white.opacity(0.42),
                    AppTheme.neonBlue.opacity(0.22),
                    Color.white.opacity(0.1),
                    AppTheme.neonViolet.opacity(0.18),
                    Color.white.opacity(0.38)
                ],
                edgeGlowColors: [
                    Color.white.opacity(0.06),
                    AppTheme.neonBlue.opacity(0.08),
                    Color.clear,
                    AppTheme.neonViolet.opacity(0.08),
                    Color.white.opacity(0.05)
                ],
                highlightColors: [
                    Color.white.opacity(0.22),
                    Color.white.opacity(0.03),
                    Color.clear
                ],
                highlightStart: UnitPoint(x: 0.12, y: 0.04),
                highlightEnd: UnitPoint(x: 0.9, y: 0.94)
            )
        case .programs:
            AppLiquidGlassBorderPalette(
                rimColors: [
                    Color.white.opacity(0.5),
                    AppTheme.neonCyan.opacity(0.28),
                    AppTheme.neonLime.opacity(0.1),
                    Color.white.opacity(0.08),
                    AppTheme.neonBlue.opacity(0.16),
                    Color.white.opacity(0.44)
                ],
                edgeGlowColors: [
                    Color.white.opacity(0.08),
                    AppTheme.neonCyan.opacity(0.1),
                    AppTheme.neonLime.opacity(0.04),
                    Color.clear,
                    Color.white.opacity(0.05)
                ],
                highlightColors: [
                    Color.white.opacity(0.26),
                    AppTheme.neonCyan.opacity(0.05),
                    Color.clear
                ],
                highlightStart: UnitPoint(x: 0.05, y: 0.08),
                highlightEnd: UnitPoint(x: 0.86, y: 0.94)
            )
        case .workout:
            AppLiquidGlassBorderPalette(
                rimColors: [
                    Color.white.opacity(0.42),
                    AppTheme.neonBlue.opacity(0.22),
                    AppTheme.neonCyan.opacity(0.16),
                    Color.white.opacity(0.08),
                    AppTheme.neonViolet.opacity(0.24),
                    Color.white.opacity(0.44)
                ],
                edgeGlowColors: [
                    Color.white.opacity(0.05),
                    AppTheme.neonBlue.opacity(0.1),
                    AppTheme.neonCyan.opacity(0.06),
                    Color.clear,
                    AppTheme.neonViolet.opacity(0.07)
                ],
                highlightColors: [
                    Color.clear,
                    Color.white.opacity(0.08),
                    AppTheme.neonBlue.opacity(0.14),
                    Color.white.opacity(0.08),
                    Color.clear
                ],
                highlightStart: UnitPoint(x: 0.42, y: 0.02),
                highlightEnd: UnitPoint(x: 1.0, y: 0.92)
            )
        case .statistics:
            AppLiquidGlassBorderPalette(
                rimColors: [
                    Color.white.opacity(0.42),
                    AppTheme.neonViolet.opacity(0.24),
                    AppTheme.neonBlue.opacity(0.16),
                    Color.white.opacity(0.08),
                    AppTheme.neonCyan.opacity(0.14),
                    Color.white.opacity(0.42)
                ],
                edgeGlowColors: [
                    Color.white.opacity(0.05),
                    AppTheme.neonViolet.opacity(0.1),
                    AppTheme.neonBlue.opacity(0.07),
                    Color.clear,
                    AppTheme.neonCyan.opacity(0.05)
                ],
                highlightColors: [
                    Color.white.opacity(0.18),
                    AppTheme.neonViolet.opacity(0.06),
                    Color.clear
                ],
                highlightStart: UnitPoint(x: 0.18, y: 0.02),
                highlightEnd: UnitPoint(x: 0.96, y: 0.92)
            )
        case .profile:
            AppLiquidGlassBorderPalette(
                rimColors: [
                    Color.white.opacity(0.46),
                    Color.white.opacity(0.1),
                    AppTheme.neonCyan.opacity(0.16),
                    AppTheme.neonBlue.opacity(0.08),
                    Color.white.opacity(0.42)
                ],
                edgeGlowColors: [
                    Color.white.opacity(0.06),
                    AppTheme.neonCyan.opacity(0.08),
                    Color.clear,
                    AppTheme.neonBlue.opacity(0.04),
                    Color.white.opacity(0.05)
                ],
                highlightColors: [
                    Color.white.opacity(0.24),
                    Color.white.opacity(0.04),
                    Color.clear
                ],
                highlightStart: UnitPoint(x: 0.1, y: 0.04),
                highlightEnd: UnitPoint(x: 0.84, y: 0.96)
            )
        }
    }

    private var primaryGlowColors: [Color] {
        switch glowStyle {
        case .neutral:
            [Color.white.opacity(0.05), AppTheme.neonBlue.opacity(0.05), .clear]
        case .programs:
            [AppTheme.neonCyan.opacity(0.08), AppTheme.neonLime.opacity(0.04), .clear]
        case .workout:
            [AppTheme.neonBlue.opacity(0.08), AppTheme.neonCyan.opacity(0.05), .clear]
        case .statistics:
            [AppTheme.neonViolet.opacity(0.08), AppTheme.neonBlue.opacity(0.04), .clear]
        case .profile:
            [Color.white.opacity(0.05), AppTheme.neonCyan.opacity(0.035), .clear]
        }
    }

    private var secondaryGlowColors: [Color] {
        switch glowStyle {
        case .neutral:
            [Color.clear, Color.white.opacity(0.03), Color.black.opacity(0.12)]
        case .programs:
            [Color.clear, AppTheme.neonBlue.opacity(0.025), Color.black.opacity(0.12)]
        case .workout:
            [Color.clear, AppTheme.neonViolet.opacity(0.03), Color.black.opacity(0.14)]
        case .statistics:
            [Color.clear, AppTheme.neonCyan.opacity(0.02), Color.black.opacity(0.12)]
        case .profile:
            [Color.clear, Color.white.opacity(0.025), Color.black.opacity(0.12)]
        }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                AppTheme.surfaceElevated.opacity(0.7),
                                AppTheme.surface.opacity(0.92),
                                Color.black.opacity(0.86)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.012),
                                        Color.clear,
                                        Color.black.opacity(0.18)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        shape
                            .fill(
                                RadialGradient(
                                    colors: primaryGlowColors,
                                    center: .topLeading,
                                    startRadius: 4,
                                    endRadius: 220
                                )
                            )
                            .blendMode(.screen)
                    }
                    .overlay {
                        shape
                            .fill(
                                LinearGradient(
                                    colors: secondaryGlowColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .blendMode(.screen)
                    }
            }
            .overlay {
                shape
                    .strokeBorder(
                        AngularGradient(
                            colors: borderPalette.rimColors,
                            center: .center
                        ),
                        lineWidth: 0.95
                    )
                    .overlay {
                        shape
                            .strokeBorder(
                                LinearGradient(
                                    colors: borderPalette.highlightColors,
                                    startPoint: borderPalette.highlightStart,
                                    endPoint: borderPalette.highlightEnd
                                ),
                                lineWidth: 0.75
                            )
                            .blendMode(.screen)
                            .opacity(0.78)
                    }
                    .overlay {
                        shape
                            .strokeBorder(
                                AngularGradient(
                                    colors: borderPalette.edgeGlowColors,
                                    center: .center
                                ),
                                lineWidth: 1.45
                            )
                            .blur(radius: 1.6)
                            .opacity(0.55)
                    }
            }
            .shadow(color: shadowColor, radius: 16, y: 8)
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
                    offset: settledOffset(
                        from: CGSize(width: -width * 0.34, height: -height * 0.08),
                        to: CGSize(width: -width * 0.12, height: height * 0.06)
                    ),
                    blur: 84
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonBlue.opacity(0.16),
                        AppTheme.neonCyan.opacity(0.12),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.52, height: height * 0.18),
                    offset: settledOffset(
                        from: CGSize(width: width * 0.34, height: -height * 0.06),
                        to: CGSize(width: width * 0.16, height: height * 0.1)
                    ),
                    blur: 78
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonViolet.opacity(0.16),
                        AppTheme.neonBlue.opacity(0.1),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.44, height: height * 0.2),
                    offset: settledOffset(
                        from: CGSize(width: -width * 0.2, height: height * 0.38),
                        to: CGSize(width: -width * 0.06, height: height * 0.24)
                    ),
                    blur: 82
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonLime.opacity(0.14),
                        AppTheme.neonCyan.opacity(0.08),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.46, height: height * 0.19),
                    offset: settledOffset(
                        from: CGSize(width: width * 0.28, height: height * 0.34),
                        to: CGSize(width: width * 0.12, height: height * 0.18)
                    ),
                    blur: 76
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonCyan.opacity(0.14),
                        AppTheme.neonBlue.opacity(0.1),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.44, height: height * 0.18),
                    offset: settledOffset(
                        from: CGSize(width: -width * 0.28, height: height * 0.14),
                        to: CGSize(width: -width * 0.08, height: height * 0.02)
                    ),
                    blur: 72
                )

                ambientBlob(
                    colors: [
                        AppTheme.neonViolet.opacity(0.1),
                        AppTheme.neonOrange.opacity(0.08),
                        Color.clear
                    ],
                    size: CGSize(width: width * 0.4, height: height * 0.16),
                    offset: settledOffset(
                        from: CGSize(width: width * 0.08, height: height * 0.58),
                        to: CGSize(width: width * 0.18, height: height * 0.42)
                    ),
                    blur: 70
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
        }
        .allowsHitTesting(false)
    }

    private func settledOffset(from start: CGSize, to end: CGSize) -> CGSize {
        CGSize(
            width: (start.width + end.width) / 2,
            height: (start.height + end.height) / 2
        )
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
