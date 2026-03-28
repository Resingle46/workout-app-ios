import SwiftUI
import UIKit

enum AppTheme {
    static let background = Color(red: 0.02, green: 0.02, blue: 0.03)
    static let backgroundRaised = Color(red: 0.035, green: 0.035, blue: 0.045)
    static let surface = Color(red: 0.08, green: 0.08, blue: 0.1)
    static let surfaceElevated = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let surfacePressed = Color(red: 0.13, green: 0.13, blue: 0.16)
    static let border = Color.white.opacity(0.08)
    static let stroke = border
    static let accent = Color(red: 0.29, green: 0.58, blue: 0.98)
    static let accentMuted = Color(red: 0.16, green: 0.21, blue: 0.32)
    static let success = Color(red: 0.36, green: 0.8, blue: 0.56)
    static let warning = Color(red: 0.98, green: 0.57, blue: 0.29)
    static let destructive = Color(red: 0.89, green: 0.3, blue: 0.28)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.68)
    static let tertiaryText = Color.white.opacity(0.42)
    static let shadowSubtle = Color.black.opacity(0.3)
    static let screenGlow = Color(red: 0.22, green: 0.43, blue: 0.76).opacity(0.18)
    static let cardCornerRadius: CGFloat = 26
    static let railCornerRadius: CGFloat = 30

    // Compatibility aliases for screens outside the first refactor wave.
    static let neonBlue = accent
    static let neonViolet = Color(red: 0.37, green: 0.46, blue: 0.86)
    static let neonCyan = Color(red: 0.41, green: 0.68, blue: 0.98)
    static let neonLime = success
    static let neonOrange = warning
}

enum AppTypography {
    private static let onestPostScriptName = "Onest-Regular"

    static func pageHeaderTitle(size: CGFloat = 30) -> Font {
        onest(size: size, weight: .heavy, relativeTo: .largeTitle)
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
        let normalFont = UIFont(name: onestPostScriptName, size: 13) ?? .systemFont(ofSize: 13, weight: .medium)
        let selectedFont = UIFont(name: onestPostScriptName, size: 13) ?? .systemFont(ofSize: 13, weight: .semibold)
        segmented.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        segmented.selectedSegmentTintColor = UIColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1)
        segmented.apportionsSegmentWidthsByContent = true
        segmented.setTitleTextAttributes(
            [
                .font: normalFont,
                .foregroundColor: UIColor(white: 1, alpha: 0.68)
            ],
            for: .normal
        )
        segmented.setTitleTextAttributes(
            [
                .font: selectedFont,
                .foregroundColor: UIColor.white
            ],
            for: .selected
        )
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

enum TabBarPresentationMode: Equatable {
    case expanded
    case collapsedWorkout
    case expandedFromWorkout
}

struct RootTabBarPresentationResolver {
    static func resolve(
        selectedTab: RootTab,
        hasActiveWorkout: Bool,
        workoutTabsExpanded: Bool
    ) -> TabBarPresentationMode {
        guard hasActiveWorkout, selectedTab == .workout else {
            return .expanded
        }

        return workoutTabsExpanded ? .expandedFromWorkout : .collapsedWorkout
    }
}

@MainActor
struct RootTabView: View {
    @Environment(AppStore.self) private var store
    @Environment(CloudSyncStore.self) private var cloudSyncStore
    @State private var workoutTabsExpanded = false

    private var tabBarPresentationMode: TabBarPresentationMode {
        RootTabBarPresentationResolver.resolve(
            selectedTab: store.selectedTab,
            hasActiveWorkout: store.activeSession != nil,
            workoutTabsExpanded: workoutTabsExpanded
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let bottomRailInset = reservedBottomInset(safeAreaBottom: proxy.safeAreaInsets.bottom)

            ZStack {
                rootNavigationStack(for: .programs, bottomRailInset: bottomRailInset)
                rootNavigationStack(for: .workout, bottomRailInset: bottomRailInset)
                rootNavigationStack(for: .statistics, bottomRailInset: bottomRailInset)
                rootNavigationStack(for: .coach, bottomRailInset: bottomRailInset)
                rootNavigationStack(for: .profile, bottomRailInset: bottomRailInset)
            }
            .onChange(of: store.selectedTab, initial: false) { _, newValue in
                if newValue != .workout {
                    workoutTabsExpanded = false
                }
            }
            .onChange(of: store.activeSession?.id) { _, newValue in
                if newValue == nil {
                    workoutTabsExpanded = false
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomRail
            }
            .environment(\.locale, store.locale)
            .environment(\.appBottomRailInset, bottomRailInset)
            .alert(
                cloudRestoreAlertTitle,
                isPresented: Binding(
                    get: { cloudSyncStore.pendingRemoteRestore != nil },
                    set: { isPresented in
                        if !isPresented, cloudSyncStore.pendingRemoteRestore != nil {
                            Task {
                                await cloudSyncStore.dismissPendingRemoteRestore()
                            }
                        }
                    }
                ),
                presenting: cloudSyncStore.pendingRemoteRestore
            ) { _ in
                Button("Restore Remote") {
                    Task {
                        await cloudSyncStore.confirmPendingRemoteRestore(using: store)
                    }
                }
                Button("Keep Local", role: .cancel) {
                    Task {
                        await cloudSyncStore.dismissPendingRemoteRestore()
                    }
                }
            } message: { pending in
                Text(cloudRestoreAlertMessage(for: pending))
            }
        }
    }

    @ViewBuilder
    private func rootNavigationStack(for tab: RootTab, bottomRailInset: CGFloat) -> some View {
        let isSelected = store.selectedTab == tab

        NavigationStack {
            switch tab {
            case .programs:
                ProgramsView()
            case .workout:
                ActiveWorkoutView()
            case .statistics:
                StatisticsView()
            case .coach:
                CoachView()
            case .profile:
                ProfileView()
            }
        }
        .environment(\.appBottomRailInset, bottomRailInset)
        .opacity(isSelected ? 1 : 0)
        .allowsHitTesting(isSelected)
        .accessibilityHidden(!isSelected)
        .zIndex(isSelected ? 1 : 0)
    }

    private func reservedBottomInset(safeAreaBottom: CGFloat) -> CGFloat {
        let baseInset: CGFloat

        switch tabBarPresentationMode {
        case .collapsedWorkout:
            baseInset = 84
        case .expanded, .expandedFromWorkout:
            baseInset = 92
        }

        return baseInset + max(0, safeAreaBottom - 10)
    }

    @ViewBuilder
    private var bottomRail: some View {
        switch tabBarPresentationMode {
        case .collapsedWorkout:
            AppCollapsedWorkoutTabBar(
                sessionTitle: store.activeSession?.title ?? NSLocalizedString("header.workout.subtitle", comment: "")
            ) {
                workoutTabsExpanded = true
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

        case .expanded, .expandedFromWorkout:
            AppExpandedTabBar(
                selectedTab: store.selectedTab,
                presentationMode: tabBarPresentationMode,
                onSelect: { tab in
                    if tab != .workout {
                        workoutTabsExpanded = false
                    }
                    store.selectedTab = tab
                },
                onToggleWorkoutTabs: {
                    workoutTabsExpanded.toggle()
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
    }

    private var cloudRestoreAlertTitle: String {
        guard let pending = cloudSyncStore.pendingRemoteRestore else {
            return "Cloud Backup"
        }

        switch pending.mode {
        case .restore:
            return "Cloud Backup Found"
        case .conflict:
            return "Remote Backup Conflict"
        }
    }

    private func cloudRestoreAlertMessage(for pending: CloudPendingRemoteRestore) -> String {
        let uploadedAt = pending.response.remote.uploadedAt.formatted(
            .dateTime
                .year()
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
                .locale(store.locale)
        )

        switch pending.mode {
        case .restore:
            return "A cloud backup from \(uploadedAt) is available for this install. Restore it now?"
        case .conflict:
            return "The cloud backup from \(uploadedAt) differs from the local data on this device. Restore the remote backup now?"
        }
    }
}

struct AppCard<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .font(AppTypography.body())
            .appSurfaceCard(padding: padding)
    }
}

struct AppSectionTitle: View {
    let titleKey: LocalizedStringKey

    var body: some View {
        Text(titleKey)
            .font(AppTypography.label(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.secondaryText)
            .textCase(.uppercase)
            .tracking(1.2)
    }
}

struct AppPageHeaderModule: View {
    let titleKey: LocalizedStringKey
    let subtitleKey: LocalizedStringKey?
    private let trailingAction: AnyView?

    init(titleKey: LocalizedStringKey, subtitleKey: LocalizedStringKey? = nil) {
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
        self.trailingAction = nil
    }

    init<Trailing: View>(
        titleKey: LocalizedStringKey,
        subtitleKey: LocalizedStringKey? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.titleKey = titleKey
        self.subtitleKey = subtitleKey
        self.trailingAction = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(titleKey)
                    .font(AppTypography.pageHeaderTitle())
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                if let subtitleKey {
                    Text(subtitleKey)
                        .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            if let trailingAction {
                trailingAction
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}

struct AppPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.button())
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                configuration.isPressed ? AppTheme.accent.opacity(0.86) : AppTheme.accent,
                in: Capsule()
            )
    }
}

struct AppSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.button())
            .foregroundStyle(AppTheme.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                configuration.isPressed ? AppTheme.surfacePressed : AppTheme.surfaceElevated,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(AppTheme.border, lineWidth: 1)
            )
    }
}

struct AppOutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.button())
            .foregroundStyle(AppTheme.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                configuration.isPressed ? AppTheme.surfacePressed : AppTheme.surface,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
    }
}

extension View {
    func appSurfaceCard(
        padding: CGFloat = 20,
        cornerRadius: CGFloat = AppTheme.cardCornerRadius
    ) -> some View {
        modifier(
            AppSurfaceCardModifier(
                padding: padding,
                cornerRadius: cornerRadius
            )
        )
    }

    func appScreenBackground() -> some View {
        modifier(AppScreenBackgroundModifier())
    }
}

private struct AppSurfaceCardModifier: ViewModifier {
    let padding: CGFloat
    let cornerRadius: CGFloat

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
                                AppTheme.surfaceElevated,
                                AppTheme.surface
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
                                        Color.white.opacity(0.03),
                                        Color.clear,
                                        Color.black.opacity(0.12)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .overlay {
                shape
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .shadow(color: AppTheme.shadowSubtle, radius: 14, y: 8)
    }
}

private struct AppBottomRailInsetEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var appBottomRailInset: CGFloat {
        get { self[AppBottomRailInsetEnvironmentKey.self] }
        set { self[AppBottomRailInsetEnvironmentKey.self] = newValue }
    }
}

struct AppInteractiveCardButtonStyle: ButtonStyle {
    var pressedOpacity: Double = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .overlay {
                RoundedRectangle(
                    cornerRadius: AppTheme.cardCornerRadius + 2,
                    style: .continuous
                )
                .fill(Color.white.opacity(configuration.isPressed ? 0.02 : 0))
            }
    }
}

private struct AppScreenBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            AppStaticScreenBackground()
            content
        }
        .foregroundStyle(AppTheme.primaryText)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private struct AppStaticScreenBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack {
                LinearGradient(
                    colors: [
                        Color.black,
                        AppTheme.background,
                        AppTheme.backgroundRaised
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    colors: [
                        AppTheme.screenGlow,
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.5, y: 0.34),
                    startRadius: 0,
                    endRadius: max(width, height) * 0.62
                )
                .scaleEffect(x: 1.25, y: 0.78)

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.2),
                        Color.clear,
                        Color.black.opacity(0.26)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

private struct AppExpandedTabBar: View {
    let selectedTab: RootTab
    let presentationMode: TabBarPresentationMode
    let onSelect: (RootTab) -> Void
    let onToggleWorkoutTabs: () -> Void

    private struct Metrics {
        let railSpacing: CGFloat
        let innerSpacing: CGFloat
        let railPadding: CGFloat
        let iconSize: CGFloat
        let labelSize: CGFloat
        let labelMinScale: CGFloat
        let minHeight: CGFloat
    }

    var body: some View {
        let usesCompactLayout = presentationMode == .expandedFromWorkout
        let metrics = metrics(for: usesCompactLayout)

        return HStack(spacing: metrics.railSpacing) {
            HStack(spacing: metrics.innerSpacing) {
                ForEach(RootTab.allCases, id: \.self) { tab in
                    Button {
                        onSelect(tab)
                    } label: {
                        tabCell(for: tab, metrics: metrics, compact: usesCompactLayout)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(metrics.railPadding)
            .frame(maxWidth: .infinity)
            .background(tabBarBackground)

            if presentationMode == .expandedFromWorkout {
                Button(action: onToggleWorkoutTabs) {
                    Text("tabbar.tabs")
                        .font(AppTypography.label(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .background(tabBarBackground)
            }
        }
    }

    private func metrics(for compact: Bool) -> Metrics {
        if compact {
            return Metrics(
                railSpacing: 8,
                innerSpacing: 6,
                railPadding: 6,
                iconSize: 16,
                labelSize: 10,
                labelMinScale: 0.72,
                minHeight: 54
            )
        }

        return Metrics(
            railSpacing: 6,
            innerSpacing: 2,
            railPadding: 6,
            iconSize: 17,
            labelSize: 9.5,
            labelMinScale: 0.68,
            minHeight: 62
        )
    }

    private var tabBarBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.railCornerRadius, style: .continuous)
            .fill(AppTheme.backgroundRaised.opacity(0.98))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.railCornerRadius, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
            .shadow(color: AppTheme.shadowSubtle, radius: 16, y: 10)
    }

    private func tabCell(for tab: RootTab, metrics: Metrics, compact: Bool) -> some View {
        let isSelected = selectedTab == tab

        return VStack(spacing: compact ? 5 : 4) {
            Image(systemName: tab.systemImage)
                .font(AppTypography.icon(size: metrics.iconSize, weight: .semibold))
            if !compact {
                Text(tab.titleKey)
                    .font(AppTypography.label(size: metrics.labelSize, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(metrics.labelMinScale)
                    .allowsTightening(true)
            }
        }
        .foregroundStyle(isSelected ? AppTheme.primaryText : AppTheme.secondaryText)
        .frame(maxWidth: .infinity)
        .frame(minHeight: metrics.minHeight)
        .padding(.horizontal, compact ? 1 : 0)
        .padding(.vertical, compact ? 10 : 9)
        .accessibilityLabel(Text(tab.titleKey))
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(AppTheme.accent.opacity(0.26))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(AppTheme.accent.opacity(0.55), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.clear)
                }
            }
        )
    }
}

private struct AppCollapsedWorkoutTabBar: View {
    let sessionTitle: String
    let onShowTabs: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: RootTab.workout.systemImage)
                    .font(AppTypography.icon(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(RootTab.workout.titleKey)
                        .font(AppTypography.body(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(sessionTitle)
                        .font(AppTypography.caption(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            Button(action: onShowTabs) {
                Text("tabbar.tabs")
                    .font(AppTypography.label(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(AppTheme.surfaceElevated, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.railCornerRadius, style: .continuous)
                .fill(AppTheme.backgroundRaised.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.railCornerRadius, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
                .shadow(color: AppTheme.shadowSubtle, radius: 16, y: 10)
        )
    }
}

private extension RootTab {
    var systemImage: String {
        switch self {
        case .programs:
            return "list.clipboard"
        case .workout:
            return "timer"
        case .statistics:
            return "chart.line.uptrend.xyaxis"
        case .coach:
            return "sparkles"
        case .profile:
            return "person.crop.circle"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .programs:
            return "tab.programs"
        case .workout:
            return "tab.workout"
        case .statistics:
            return "tab.statistics"
        case .coach:
            return "tab.coach"
        case .profile:
            return "tab.profile"
        }
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
