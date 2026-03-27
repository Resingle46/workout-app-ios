import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(CoachStore.self) private var coachStore
    @Environment(\.appBottomRailInset) private var bottomRailInset
    @State private var showingProfileEditor = false

    private var progressSummary: ProfileProgressSummary {
        store.profileProgressSummary()
    }

    private var recentPersonalRecords: [ProfilePRItem] {
        store.recentPersonalRecords()
    }

    private var consistencySummary: ProfileConsistencySummary {
        store.profileConsistencySummary()
    }

    private var goalSummary: ProfileGoalSummary {
        store.profileGoalSummary()
    }

    private var metabolismSummary: ProfileMetabolismSummary {
        store.profileMetabolismSummary()
    }

    private var profileRefreshSeed: String {
        [
            store.selectedLanguageCode,
            store.localStateUpdatedAt?.timeIntervalSince1970.appNumberText ?? "none",
            store.activeSession?.id.uuidString ?? "no-active-session"
        ].joined(separator: "|")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                AppPageHeaderModule(
                    titleKey: "header.profile.title",
                    subtitleKey: "header.profile.subtitle"
                ) {
                    NavigationLink(destination: ProfileSettingsView()) {
                        Image(systemName: "gearshape.fill")
                            .font(AppTypography.icon(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .frame(width: 44, height: 44)
                            .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(AppTheme.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showingProfileEditor = true
                } label: {
                    ProfileHeroCard(profile: store.profile)
                }
                .buttonStyle(AppInteractiveCardButtonStyle(pressedOpacity: 0.97))

                Button {
                    showingProfileEditor = true
                } label: {
                    ProfileGoalProgressCard(summary: goalSummary)
                }
                .buttonStyle(AppInteractiveCardButtonStyle(pressedOpacity: 0.97))

                ProfileMetabolismCard(summary: metabolismSummary)

                ProfileCoachInsightsCard(
                    insights: coachStore.profileInsights,
                    origin: coachStore.profileInsightsOrigin,
                    isLoading: coachStore.isLoadingProfileInsights,
                    onOpenCoach: {
                        store.selectedTab = .coach
                    }
                )

                Button {
                    store.selectedTab = .statistics
                } label: {
                    ProfileProgressSnapshotCard(summary: progressSummary, locale: store.locale)
                }
                .buttonStyle(AppInteractiveCardButtonStyle(pressedOpacity: 0.97))

                Button {
                    store.selectedTab = .statistics
                } label: {
                    ProfileRecentPRsCard(records: recentPersonalRecords, locale: store.locale)
                }
                .buttonStyle(AppInteractiveCardButtonStyle(pressedOpacity: 0.97))

                ProfileConsistencyCard(
                    summary: consistencySummary,
                    calendar: AppStore.statisticsCalendar(locale: store.locale)
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 24 + bottomRailInset)
        }
        .sheet(isPresented: $showingProfileEditor) {
            NavigationStack {
                ProfileEditorView(profile: store.profile) { updatedProfile in
                    store.updateProfile { profile in
                        profile = updatedProfile
                    }
                }
            }
            .presentationDetents([.large])
            .presentationBackground(AppTheme.background)
        }
        .task(id: profileRefreshSeed) {
            if store.selectedTab == .profile {
                await coachStore.refreshProfileInsights(using: store)
            }
        }
        .onChange(of: store.selectedTab, initial: true) { _, newValue in
            guard newValue == .profile else {
                return
            }

            Task {
                await coachStore.refreshProfileInsights(using: store)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .appScreenBackground()
    }
}

private struct ProfileSettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appBottomRailInset) private var bottomRailInset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AppCard {
                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionTitle(titleKey: "profile.settings.preferences")

                        Picker("", selection: Binding(
                            get: { store.selectedLanguageCode },
                            set: { store.updateLanguage($0) }
                        )) {
                            Text("profile.language.english").tag("en")
                            Text("profile.language.russian").tag("ru")
                        }
                        .pickerStyle(.segmented)
                        .tint(AppTheme.accent)
                    }
                }

                CoachBackendSettingsCard()

                BackupControlsCard()

                DeveloperMenuSettingsCard()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .padding(.bottom, bottomRailInset)
        }
        .navigationTitle("profile.settings.title")
        .navigationBarTitleDisplayMode(.inline)
        .appScreenBackground()
    }
}

@MainActor
private struct CoachBackendSettingsCard: View {
    @Environment(AppStore.self) private var store
    @Environment(CoachStore.self) private var coachStore
    @Environment(WorkoutSummaryStore.self) private var workoutSummaryStore
    private let coachConfigurationStore = CoachRuntimeConfigurationStore(bundle: .main)

    @State private var isFeatureEnabled = false
    @State private var backendBaseURLText = ""
    @State private var internalBearerToken = ""
    @State private var didLoadDraft = false
    @State private var statusMessage: String?
    @State private var validationMessage: String?

    private var hasDraftChanges: Bool {
        isFeatureEnabled != coachConfigurationStore.isFeatureEnabled ||
        backendBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines) != coachConfigurationStore.backendBaseURLText ||
        internalBearerToken.trimmingCharacters(in: .whitespacesAndNewlines) != coachConfigurationStore.internalBearerToken
    }

    private var statusKey: LocalizedStringKey {
        coachStore.canUseRemoteCoach ? "coach.status.remote" : "coach.status.fallback"
    }

    private var statusDescriptionKey: LocalizedStringKey {
        coachStore.canUseRemoteCoach ? "coach.status.remote_description" : "coach.status.fallback_description"
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                AppSectionTitle(titleKey: "profile.settings.coach")

                HStack(spacing: 10) {
                    Circle()
                        .fill(coachStore.canUseRemoteCoach ? AppTheme.success : AppTheme.warning)
                        .frame(width: 10, height: 10)

                    Text(statusKey)
                        .font(AppTypography.body(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                }

                Text(statusDescriptionKey)
                    .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $isFeatureEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("profile.settings.coach.enable")
                            .font(AppTypography.body(size: 16, weight: .semibold))
                            .foregroundStyle(AppTheme.primaryText)

                        Text("profile.settings.coach.note")
                            .font(AppTypography.caption(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(AppTheme.accent)

                CoachSettingsTextField(
                    titleKey: "profile.settings.coach.url",
                    placeholderKey: "profile.settings.coach.url.placeholder",
                    text: $backendBaseURLText,
                    isSecure: false
                )

                CoachSettingsTextField(
                    titleKey: "profile.settings.coach.token",
                    placeholderKey: "profile.settings.coach.token.placeholder",
                    text: $internalBearerToken,
                    isSecure: true
                )

                if let validationMessage, !validationMessage.isEmpty {
                    Text(validationMessage)
                        .font(AppTypography.caption(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(AppTypography.caption(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.success)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    Button("action.save") {
                        saveConfiguration()
                    }
                    .buttonStyle(AppPrimaryButtonStyle())
                    .disabled(!hasDraftChanges)
                    .opacity(hasDraftChanges ? 1 : 0.55)

                    Button("profile.settings.coach.reset") {
                        resetConfiguration()
                    }
                    .buttonStyle(AppSecondaryButtonStyle())
                }
            }
        }
        .task {
            loadDraftFromStoreIfNeeded()
        }
    }

    private func loadDraftFromStoreIfNeeded() {
        guard !didLoadDraft else {
            return
        }

        didLoadDraft = true
        isFeatureEnabled = coachConfigurationStore.isFeatureEnabled
        backendBaseURLText = coachConfigurationStore.backendBaseURLText
        internalBearerToken = coachConfigurationStore.internalBearerToken
    }

    private func saveConfiguration() {
        validationMessage = nil
        statusMessage = nil

        let trimmedBaseURLText = backendBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = internalBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)

        if isFeatureEnabled {
            guard !trimmedBaseURLText.isEmpty else {
                validationMessage = localizedString("coach.error.missing_base_url")
                return
            }
            guard CoachRuntimeConfiguration.parseBackendBaseURL(trimmedBaseURLText) != nil else {
                validationMessage = localizedString("profile.settings.coach.invalid_url")
                return
            }
            guard !trimmedToken.isEmpty else {
                validationMessage = localizedString("coach.error.missing_auth_token")
                return
            }
        }

        coachConfigurationStore.isFeatureEnabled = isFeatureEnabled
        coachConfigurationStore.backendBaseURLText = trimmedBaseURLText
        coachConfigurationStore.internalBearerToken = trimmedToken
        let configuration = coachConfigurationStore.save()

        backendBaseURLText = coachConfigurationStore.backendBaseURLText
        internalBearerToken = coachConfigurationStore.internalBearerToken

        coachStore.updateConfiguration(configuration)
        workoutSummaryStore.updateConfiguration(configuration)
        statusMessage = localizedString("profile.settings.coach.saved")

        Task {
            await coachStore.refreshProfileInsights(using: store)
        }
    }

    private func resetConfiguration() {
        validationMessage = nil
        statusMessage = localizedString("profile.settings.coach.reset_done")

        let configuration = coachConfigurationStore.resetToDefaults()
        isFeatureEnabled = coachConfigurationStore.isFeatureEnabled
        backendBaseURLText = coachConfigurationStore.backendBaseURLText
        internalBearerToken = coachConfigurationStore.internalBearerToken

        coachStore.updateConfiguration(configuration)
        workoutSummaryStore.updateConfiguration(configuration)

        Task {
            await coachStore.refreshProfileInsights(using: store)
        }
    }

}

private struct CoachSettingsTextField: View {
    let titleKey: LocalizedStringKey
    let placeholderKey: LocalizedStringKey
    @Binding var text: String
    let isSecure: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titleKey)
                .font(AppTypography.body(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)

            Group {
                if isSecure {
                    SecureField(placeholderKey, text: $text)
                } else {
                    TextField(placeholderKey, text: $text)
                        .keyboardType(.URL)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(AppTypography.body(size: 15))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
        }
    }
}

private struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (UserProfile) -> Void

    @State private var draftProfile: UserProfile
    @State private var activePicker: ProfilePickerField?

    init(profile: UserProfile, onSave: @escaping (UserProfile) -> Void) {
        self.onSave = onSave
        _draftProfile = State(initialValue: profile)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AppCard {
                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionTitle(titleKey: "profile.personal")

                        ProfileSelectionRow(titleKey: "profile.sex", value: draftProfile.localizedSexValue) {
                            activePicker = .sex
                        }

                        ProfileSelectionRow(titleKey: "profile.age", value: "\(draftProfile.age)") {
                            activePicker = .age
                        }

                        ProfileSelectionRow(titleKey: "profile.weight", value: "\(draftProfile.weight.appNumberText) kg") {
                            activePicker = .weight
                        }

                        ProfileSelectionRow(titleKey: "profile.height", value: "\(Int(draftProfile.height)) cm") {
                            activePicker = .height
                        }
                    }
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionTitle(titleKey: "profile.training_preferences")

                        ProfileSelectionRow(titleKey: "profile.goal", value: draftProfile.primaryGoal.localizedTitle) {
                            activePicker = .primaryGoal
                        }

                        ProfileSelectionRow(titleKey: "profile.experience", value: draftProfile.experienceLevel.localizedTitle) {
                            activePicker = .experienceLevel
                        }

                        ProfileSelectionRow(titleKey: "profile.weekly_target", value: draftProfile.weeklyTargetValue) {
                            activePicker = .weeklyWorkoutTarget
                        }

                        ProfileSelectionRow(titleKey: "profile.target_weight", value: draftProfile.targetWeightValue) {
                            activePicker = .targetBodyWeight
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("profile.editor.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("action.save") {
                    onSave(draftProfile)
                    dismiss()
                }
            }
        }
        .sheet(item: $activePicker) { picker in
            ProfilePickerSheet(
                picker: picker,
                profile: draftProfile,
                onSave: { updatedProfile in
                    draftProfile = updatedProfile
                }
            )
            .presentationDetents([.height(332)])
            .presentationDragIndicator(.hidden)
            .presentationBackground(AppTheme.surfaceElevated)
        }
        .appScreenBackground()
    }
}

private struct ProfileSelectionRow: View {
    let titleKey: LocalizedStringKey
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(titleKey)
                    .font(AppTypography.body(size: 18))
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Text(value)
                    .font(AppTypography.value(size: 18, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

private struct ProfileHeroCard: View {
    let profile: UserProfile

    var body: some View {
        ProfileGraphiteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    ProfileCardBadge(systemImage: "person.crop.circle.fill")

                    Text("header.profile.title")
                        .font(AppTypography.heading(size: 22))
                        .foregroundStyle(AppTheme.primaryText)

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(AppTypography.icon(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ProfileMetricTile(titleKey: "profile.sex", value: profile.localizedSexValue, compact: true)
                    ProfileMetricTile(titleKey: "profile.age", value: "\(profile.age)", compact: true)
                    ProfileMetricTile(titleKey: "profile.weight", value: "\(profile.weight.appNumberText) kg", compact: true)
                    ProfileMetricTile(titleKey: "profile.height", value: "\(Int(profile.height)) cm", compact: true)
                    ProfileMetricTile(titleKey: "profile.goal", value: profile.primaryGoal.localizedTitle, compact: true)
                    ProfileMetricTile(titleKey: "profile.weekly_target", value: profile.weeklyTargetValue, compact: true)
                }
            }
        }
    }
}

private struct ProfileProgressSnapshotCard: View {
    let summary: ProfileProgressSummary
    let locale: Locale

    var body: some View {
        ProfileAccentCard(accent: .cyan) {
            VStack(alignment: .leading, spacing: 18) {
                ProfileCardHeader(
                    eyebrowKey: "profile.card.progress.eyebrow",
                    titleKey: "profile.card.progress.title",
                    systemImage: "chart.xyaxis.line"
                )

                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text("\(summary.totalFinishedWorkouts)")
                        .font(AppTypography.metric(size: 46))
                        .foregroundStyle(AppTheme.primaryText)

                    Text("profile.card.progress.total_workouts_inline")
                        .font(AppTypography.body(size: 20, weight: .semibold, relativeTo: .headline))
                        .foregroundStyle(AppTheme.primaryText.opacity(0.92))
                }

                Text("profile.card.progress.subtitle")
                    .font(AppTypography.body(size: 16, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(DashboardCardAccent.cyan.secondaryText)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ProfileMetricTile(
                        titleKey: "profile.card.progress.exercises",
                        value: "\(summary.recentExercisesCount)",
                        accent: .cyan
                    )
                    ProfileMetricTile(
                        titleKey: "profile.card.progress.volume_30d",
                        value: summary.recentVolume.volumeValueText,
                        accent: .cyan
                    )
                    ProfileMetricTile(
                        titleKey: "profile.card.progress.avg_duration_30d",
                        value: formattedProfileDuration(summary.averageDuration),
                        accent: .cyan
                    )
                    ProfileMetricTile(
                        titleKey: "profile.card.progress.last_workout",
                        value: formattedProfileDate(summary.lastWorkoutDate, locale: locale),
                        accent: .cyan
                    )
                }
            }
        }
    }
}

private struct ProfileRecentPRsCard: View {
    let records: [ProfilePRItem]
    let locale: Locale

    var body: some View {
        ProfileAccentCard(accent: .orange) {
            VStack(alignment: .leading, spacing: 18) {
                ProfileCardHeader(
                    eyebrowKey: "profile.card.prs.eyebrow",
                    titleKey: "profile.card.prs.title",
                    systemImage: "flame.fill"
                )

                if records.isEmpty {
                    Text("profile.card.prs.empty")
                        .font(AppTypography.body(size: 16, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(DashboardCardAccent.orange.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 12) {
                        ForEach(records) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(item.exerciseName)
                                        .font(AppTypography.heading(size: 21))
                                        .foregroundStyle(AppTheme.primaryText)
                                        .lineLimit(2)

                                    Spacer(minLength: 12)

                                    Text("\(item.weight.appNumberText) kg")
                                        .font(AppTypography.value(size: 20, weight: .bold))
                                        .foregroundStyle(AppTheme.primaryText)
                                }

                                HStack(spacing: 8) {
                                    Text(String(format: localizedString("profile.card.prs.delta_format"), item.delta.appNumberText))
                                        .font(AppTypography.caption(size: 13, weight: .semibold))
                                        .foregroundStyle(AppTheme.primaryText)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.white.opacity(0.12), in: Capsule())

                                    Text(item.achievedAt.formatted(
                                        .dateTime
                                            .day()
                                            .month(.abbreviated)
                                            .locale(locale)
                                    ))
                                    .font(AppTypography.caption(size: 13, weight: .medium))
                                    .foregroundStyle(DashboardCardAccent.orange.secondaryText)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct ProfileConsistencyCard: View {
    let summary: ProfileConsistencySummary
    let calendar: Calendar

    private var mostFrequentDayLabel: String {
        guard let weekday = summary.mostFrequentWeekday else {
            return localizedString("common.no_data")
        }

        let symbols = calendar.weekdaySymbols
        guard symbols.indices.contains(weekday - 1) else {
            return localizedString("common.no_data")
        }

        return symbols[weekday - 1]
    }

    var body: some View {
        ProfileAccentCard(accent: .mint) {
            VStack(alignment: .leading, spacing: 18) {
                ProfileCardHeader(
                    eyebrowKey: "profile.card.consistency.eyebrow",
                    titleKey: "profile.card.consistency.title",
                    systemImage: "calendar.badge.clock",
                    showsChevron: false
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.weeklyStatusTitle)
                        .font(AppTypography.heading(size: 25))
                        .foregroundStyle(AppTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(summary.weeklyStatusProgress)
                        .font(AppTypography.metric(size: 36))
                        .foregroundStyle(AppTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    ProfileMetricTile(
                        titleKey: "profile.card.consistency.streak",
                        value: String(format: localizedString("profile.card.consistency.weeks_value"), summary.streakWeeks),
                        accent: .mint
                    )
                    ProfileMetricTile(
                        titleKey: "profile.card.consistency.favorite_day",
                        value: mostFrequentDayLabel,
                        accent: .mint
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("profile.card.consistency.last_weeks")
                        .font(AppTypography.caption(size: 12, weight: .semibold))
                        .foregroundStyle(DashboardCardAccent.mint.secondaryText)

                    ProfileWeeklyActivityStrip(weeks: summary.recentWeeklyActivity, accent: .mint)
                }
            }
        }
    }
}

private struct ProfileGoalProgressCard: View {
    let summary: ProfileGoalSummary

    private let accent = DashboardCardAccent.indigo

    private var deltaText: String {
        guard let delta = summary.remainingWeightDelta else {
            return localizedString("profile.card.goal.no_target")
        }

        if delta == 0 {
            return localizedString("profile.card.goal.target_reached")
        }

        return String(format: localizedString("profile.card.goal.delta_format"), abs(delta).appNumberText)
    }

    private var safePaceText: String? {
        guard let lowerBound = summary.safeWeeklyChangeLowerBound,
              let upperBound = summary.safeWeeklyChangeUpperBound else {
            return nil
        }

        return String(
            format: localizedString("profile.card.goal.safe_pace_format"),
            lowerBound.appNumberText,
            upperBound.appNumberText
        )
    }

    private var etaText: String? {
        formattedProfileETA(
            lowerWeeks: summary.etaWeeksLowerBound,
            upperWeeks: summary.etaWeeksUpperBound
        )
    }

    var body: some View {
        ProfileAccentCard(accent: accent) {
            VStack(alignment: .leading, spacing: 18) {
                ProfileCardHeader(
                    eyebrowKey: "profile.card.goal.eyebrow",
                    titleKey: "profile.card.goal.title",
                    systemImage: "scope"
                )

                Text(summary.primaryGoal.localizedTitle)
                    .font(AppTypography.metric(size: 34))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(2)

                Text(deltaText)
                    .font(AppTypography.body(size: 16, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(accent.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if summary.usesCurrentWeightOnly, summary.targetBodyWeight != nil, !summary.hasReachedTarget {
                    Text("profile.card.goal.from_current_only")
                        .font(AppTypography.caption(size: 13, weight: .medium))
                        .foregroundStyle(accent.secondaryText.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ProfileMetricTile(
                        titleKey: "profile.card.goal.current_weight",
                        value: "\(summary.currentWeight.appNumberText) kg",
                        accent: accent
                    )
                    ProfileMetricTile(
                        titleKey: "profile.card.goal.target_weight",
                        value: summary.targetBodyWeight.map { "\($0.appNumberText) kg" } ?? localizedString("profile.value.not_set"),
                        accent: accent
                    )

                    if let safePaceText {
                        ProfileMetricTile(
                            titleKey: "profile.card.goal.safe_pace",
                            value: safePaceText,
                            accent: accent
                        )
                    }

                    if let etaText {
                        ProfileMetricTile(
                            titleKey: "profile.card.goal.eta",
                            value: etaText,
                            accent: accent
                        )
                    }
                }
            }
        }
    }
}

private struct ProfileMetabolismCard: View {
    let summary: ProfileMetabolismSummary

    private var maintenanceText: String {
        "\(summary.maintenanceCaloriesLowerBound)-\(summary.maintenanceCaloriesUpperBound) kcal"
    }

    private var activityFactorText: String {
        "\(summary.activityFactorLowerBound.appNumberText)-\(summary.activityFactorUpperBound.appNumberText)"
    }

    private var sourceText: String {
        localizedString(summary.estimateSource.sourceKey)
    }

    var body: some View {
        ProfileAccentCard(accent: .ember) {
            VStack(alignment: .leading, spacing: 18) {
                ProfileCardHeader(
                    eyebrowKey: "profile.card.metabolism.eyebrow",
                    titleKey: "profile.card.metabolism.title",
                    systemImage: "flame.circle.fill",
                    showsChevron: false
                )

                Text(maintenanceText)
                    .font(AppTypography.metric(size: 34))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(2)

                Text("\(sourceText) \(localizedString("profile.card.metabolism.note"))")
                    .font(AppTypography.body(size: 16, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(DashboardCardAccent.ember.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    ProfileMetricTile(
                        titleKey: "profile.card.metabolism.bmr",
                        value: "\(summary.bmr) kcal",
                        accent: .ember
                    )
                    ProfileMetricTile(
                        titleKey: "profile.card.metabolism.activity_factor",
                        value: activityFactorText,
                        accent: .ember
                    )
                }
            }
        }
    }
}

private struct ProfileCoachInsightsCard: View {
    let insights: CoachProfileInsights?
    let origin: CoachInsightsOrigin
    let isLoading: Bool
    let onOpenCoach: () -> Void

    private var sourceKey: LocalizedStringKey {
        origin.profileSourceKey
    }

    var body: some View {
        ProfileAccentCard(accent: .aqua) {
            VStack(alignment: .leading, spacing: 18) {
                ProfileCardHeader(
                    eyebrowKey: "profile.card.ai.eyebrow",
                    titleKey: "profile.card.ai.title",
                    systemImage: "sparkles",
                    showsChevron: false
                )

                if isLoading && insights == nil {
                    HStack(spacing: 12) {
                        ProgressView()
                            .tint(AppTheme.primaryText)
                        Text("profile.card.ai.loading")
                            .font(AppTypography.body(size: 16, weight: .medium))
                            .foregroundStyle(DashboardCardAccent.aqua.secondaryText)
                    }
                } else {
                    Text(insights?.summary ?? localizedString("profile.card.ai.empty"))
                        .font(AppTypography.heading(size: 24))
                        .foregroundStyle(AppTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Circle()
                            .fill(origin.sourceColor)
                            .frame(width: 8, height: 8)

                        Text(sourceKey)
                            .font(AppTypography.caption(size: 13, weight: .medium))
                            .foregroundStyle(DashboardCardAccent.aqua.secondaryText)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array((insights?.recommendations ?? []).prefix(4).enumerated()), id: \.offset) { _, recommendation in
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill(Color.white.opacity(0.82))
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 8)

                                Text(recommendation)
                                    .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                                    .foregroundStyle(AppTheme.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Button("profile.card.ai.open_coach") {
                    onOpenCoach()
                }
                .buttonStyle(AppSecondaryButtonStyle())
            }
        }
    }
}

private struct ProfileTrainingRecommendationsCard: View {
    let summary: ProfileTrainingRecommendationSummary

    private var frequencyText: String {
        if summary.recommendedWeeklyTargetLowerBound == summary.recommendedWeeklyTargetUpperBound {
            return String(
                format: localizedString("profile.card.recommendations.frequency_single_format"),
                summary.recommendedWeeklyTargetLowerBound
            )
        }

        return String(
            format: localizedString("profile.card.recommendations.frequency_format"),
            summary.recommendedWeeklyTargetLowerBound,
            summary.recommendedWeeklyTargetUpperBound
        )
    }

    private var repRangeText: String {
        String(
            format: localizedString("profile.card.recommendations.rep_range_format"),
            summary.mainRepLowerBound,
            summary.mainRepUpperBound,
            summary.accessoryRepLowerBound,
            summary.accessoryRepUpperBound
        )
    }

    private var volumeText: String {
        String(
            format: localizedString("profile.card.recommendations.volume_format"),
            summary.weeklySetsLowerBound,
            summary.weeklySetsUpperBound
        )
    }

    private var splitText: String {
        if let splitWorkoutDays = summary.splitWorkoutDays {
            return String(
                format: localizedString("profile.card.recommendations.split_days_format"),
                splitWorkoutDays
            )
        }

        return summary.split.localizedTitle
    }

    private var splitSourceText: String? {
        guard let splitProgramTitle = summary.splitProgramTitle,
              summary.splitWorkoutDays != nil else {
            return nil
        }

        return String(
            format: localizedString("profile.card.recommendations.split_program_note"),
            splitProgramTitle
        )
    }

    var body: some View {
        ProfileAccentCard(accent: .gold) {
            VStack(alignment: .leading, spacing: 18) {
                ProfileCardHeader(
                    eyebrowKey: "profile.card.recommendations.eyebrow",
                    titleKey: "profile.card.recommendations.title",
                    systemImage: "figure.strengthtraining.traditional"
                )

                Text(summary.isGenericFallback ? localizedString("profile.card.recommendations.generic") : summary.primaryGoal.localizedTitle)
                    .font(AppTypography.metric(size: 32))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(2)

                if summary.isGenericFallback {
                    Text("profile.card.recommendations.complete_profile")
                        .font(AppTypography.body(size: 16, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(DashboardCardAccent.gold.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ProfileMetricTile(
                        titleKey: "profile.card.recommendations.frequency",
                        value: frequencyText,
                        accent: .gold
                    )
                    ProfileMetricTile(
                        titleKey: "profile.card.recommendations.rep_range",
                        value: repRangeText,
                        accent: .gold
                    )
                    ProfileMetricTile(
                        titleKey: "profile.card.recommendations.volume",
                        value: volumeText,
                        accent: .gold
                    )
                    ProfileMetricTile(
                        titleKey: "profile.card.recommendations.split",
                        value: splitText,
                        accent: .gold
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    if let splitSourceText {
                        Text(splitSourceText)
                            .font(AppTypography.caption(size: 13, weight: .medium))
                            .foregroundStyle(DashboardCardAccent.gold.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("profile.card.recommendations.rep_range_note")
                        .font(AppTypography.caption(size: 13, weight: .medium))
                        .foregroundStyle(DashboardCardAccent.gold.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ProfileGoalCompatibilityCard: View {
    let summary: ProfileGoalCompatibilitySummary

    private var accent: DashboardCardAccent {
        summary.isAligned ? .emerald : .rose
    }

    var body: some View {
        ProfileAccentCard(accent: accent) {
            VStack(alignment: .leading, spacing: 18) {
                ProfileCardHeader(
                    eyebrowKey: "profile.card.compatibility.eyebrow",
                    titleKey: "profile.card.compatibility.title",
                    systemImage: summary.isAligned ? "checkmark.seal.fill" : "exclamationmark.bubble.fill"
                )

                Text("profile.card.compatibility.note")
                    .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(accent.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if summary.isAligned {
                    Text("profile.card.compatibility.aligned")
                        .font(AppTypography.heading(size: 25))
                        .foregroundStyle(AppTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 12) {
                        ForEach(summary.issues) { issue in
                            ProfileCompatibilityIssueRow(issue: issue)
                        }
                    }
                }
            }
        }
    }
}

private struct ProfileCompatibilityIssueRow: View {
    let issue: ProfileGoalCompatibilityIssue

    private var message: String {
        switch issue.kind {
        case .missingGoal:
            return localizedString("profile.card.compatibility.issue_missing_goal")
        case .goalTargetMismatch:
            return localizedString("profile.card.compatibility.issue_goal_target")
        case .frequencyTooLow:
            return String(
                format: localizedString("profile.card.compatibility.issue_frequency_low"),
                issue.recommendedWeeklyTargetLowerBound ?? 0,
                issue.currentWeeklyTarget ?? 0
            )
        case .frequencyTooHighForBeginner:
            return String(
                format: localizedString("profile.card.compatibility.issue_frequency_high_beginner"),
                issue.currentWeeklyTarget ?? 0
            )
        case .programFrequencyMismatch:
            return String(
                format: localizedString("profile.card.compatibility.issue_program_frequency_mismatch"),
                issue.programWorkoutCount ?? 0,
                issue.currentWeeklyTarget ?? 0
            )
        case .adherenceGap:
            return String(
                format: localizedString("profile.card.compatibility.issue_adherence_gap"),
                issue.observedWorkoutsPerWeek?.appNumberText ?? localizedString("common.no_data"),
                issue.currentWeeklyTarget ?? 0
            )
        case .longGoalTimeline:
            return String(
                format: localizedString("profile.card.compatibility.issue_long_eta"),
                issue.etaWeeksUpperBound ?? 0
            )
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: issue.systemImage)
                .font(AppTypography.icon(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.08), in: Circle())

            Text(message)
                .font(AppTypography.body(size: 16, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ProfileCardHeader: View {
    let eyebrowKey: LocalizedStringKey
    let titleKey: LocalizedStringKey
    let systemImage: String
    var showsChevron = true

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ProfileCardBadge(systemImage: systemImage)

            VStack(alignment: .leading, spacing: 8) {
                Text(eyebrowKey)
                    .font(AppTypography.label(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.68))
                    .textCase(.uppercase)
                    .tracking(1.2)

                Text(titleKey)
                    .font(AppTypography.heading(size: 26))
                    .foregroundStyle(AppTheme.primaryText)
            }

            Spacer(minLength: 12)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(AppTypography.icon(size: 14, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.65))
            }
        }
    }
}

private struct ProfileWeeklyActivityStrip: View {
    let weeks: [ProfileWeeklyActivity]
    let accent: DashboardCardAccent

    private var maxCount: Int {
        max(weeks.map(\.workoutsCount).max() ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 8) {
                    GeometryReader { proxy in
                        let height = max(14, (CGFloat(item.workoutsCount) / CGFloat(maxCount)) * proxy.size.height)

                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))

                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            item.meetsTarget ? accent.glowPrimary.opacity(0.94) : accent.glowSecondary.opacity(0.74),
                                            accent.glowSecondary.opacity(0.38)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(height: height)
                        }
                    }
                    .frame(height: 56)

                    Text("\(item.workoutsCount)")
                        .font(AppTypography.caption(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct ProfileMetricTile: View {
    let titleKey: LocalizedStringKey
    let value: String
    var accent: DashboardCardAccent? = nil
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Text(titleKey)
                .font(AppTypography.caption(size: compact ? 10 : 12, weight: .semibold))
                .foregroundStyle((accent?.secondaryText ?? AppTheme.secondaryText).opacity(0.95))
                .textCase(.uppercase)
                .tracking(compact ? 0.5 : 0.8)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Text(value)
                .font(AppTypography.value(size: compact ? 15 : 20, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(compact ? 2 : 2)
                .minimumScaleFactor(0.82)
        }
        .padding(compact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: compact ? 112 : 100, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(accent == nil ? 0.04 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct ProfilePill: View {
    let value: String

    var body: some View {
        Text(value)
            .font(AppTypography.caption(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct ProfileCardBadge: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(AppTypography.icon(size: 18, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .frame(width: 52, height: 52)
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.12),
                                Color.white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}

private struct ProfileGraphiteCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)

        content
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.07, green: 0.07, blue: 0.09),
                                Color(red: 0.03, green: 0.03, blue: 0.04),
                                Color.black
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
                                        Color.white.opacity(0.05),
                                        Color.clear,
                                        Color.black.opacity(0.22)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        RadialGradient(
                            colors: [
                                Color(red: 0.78, green: 1.0, blue: 0.28).opacity(0.42),
                                Color(red: 0.46, green: 0.88, blue: 0.22).opacity(0.18),
                                Color.clear
                            ],
                            center: UnitPoint(x: 0.9, y: 0.16),
                            startRadius: 0,
                            endRadius: 260
                        )
                        .blendMode(.screen)
                    }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(0.38), radius: 18, y: 12)
    }
}

private struct ProfileAccentCard<Content: View>: View {
    let accent: DashboardCardAccent
    let content: Content

    init(accent: DashboardCardAccent, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)

        content
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    let maxSide = max(proxy.size.width, proxy.size.height)

                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.05, green: 0.05, blue: 0.06),
                                    Color(red: 0.02, green: 0.02, blue: 0.03),
                                    Color.black
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            shape
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.05),
                                            Color.clear,
                                            Color.black.opacity(0.22)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                        .overlay {
                            RadialGradient(
                                colors: [
                                    accent.glowPrimary.opacity(0.92),
                                    accent.glowSecondary.opacity(0.42),
                                    Color.clear
                                ],
                                center: accent.primaryGlowCenter,
                                startRadius: 0,
                                endRadius: maxSide * 0.85
                            )
                            .blendMode(.screen)
                        }
                        .overlay {
                            RadialGradient(
                                colors: [
                                    accent.glowSecondary.opacity(0.28),
                                    Color.clear
                                ],
                                center: accent.secondaryGlowCenter,
                                startRadius: 0,
                                endRadius: maxSide * 0.5
                            )
                            .blendMode(.screen)
                        }
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.34),
                                Color.white.opacity(0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(0.4), radius: 18, y: 12)
    }
}

private struct DashboardCardAccent {
    let glowPrimary: Color
    let glowSecondary: Color
    let secondaryText: Color
    let primaryGlowCenter: UnitPoint
    let secondaryGlowCenter: UnitPoint

    static let cyan = DashboardCardAccent(
        glowPrimary: Color(red: 0.17, green: 0.92, blue: 0.98),
        glowSecondary: Color(red: 0.16, green: 0.56, blue: 0.98),
        secondaryText: Color(red: 0.86, green: 0.98, blue: 1.0),
        primaryGlowCenter: .bottomTrailing,
        secondaryGlowCenter: UnitPoint(x: 0.78, y: 0.82)
    )

    static let orange = DashboardCardAccent(
        glowPrimary: Color(red: 1.0, green: 0.58, blue: 0.12),
        glowSecondary: Color(red: 1.0, green: 0.8, blue: 0.28),
        secondaryText: Color(red: 1.0, green: 0.93, blue: 0.82),
        primaryGlowCenter: .bottomTrailing,
        secondaryGlowCenter: UnitPoint(x: 0.82, y: 0.86)
    )

    static let mint = DashboardCardAccent(
        glowPrimary: Color(red: 0.38, green: 0.95, blue: 0.79),
        glowSecondary: Color(red: 0.09, green: 0.7, blue: 0.64),
        secondaryText: Color(red: 0.86, green: 1.0, blue: 0.95),
        primaryGlowCenter: .bottomLeading,
        secondaryGlowCenter: UnitPoint(x: 0.22, y: 0.84)
    )

    static let aqua = DashboardCardAccent(
        glowPrimary: Color(red: 0.54, green: 0.97, blue: 0.79),
        glowSecondary: Color(red: 0.22, green: 0.82, blue: 0.86),
        secondaryText: Color(red: 0.9, green: 1.0, blue: 0.95),
        primaryGlowCenter: .bottomTrailing,
        secondaryGlowCenter: UnitPoint(x: 0.7, y: 0.82)
    )

    static let indigo = DashboardCardAccent(
        glowPrimary: Color(red: 0.51, green: 0.62, blue: 1.0),
        glowSecondary: Color(red: 0.29, green: 0.38, blue: 0.95),
        secondaryText: Color(red: 0.89, green: 0.92, blue: 1.0),
        primaryGlowCenter: UnitPoint(x: 0.86, y: 0.22),
        secondaryGlowCenter: UnitPoint(x: 0.2, y: 0.88)
    )

    static let ember = DashboardCardAccent(
        glowPrimary: Color(red: 0.99, green: 0.4, blue: 0.28),
        glowSecondary: Color(red: 1.0, green: 0.66, blue: 0.24),
        secondaryText: Color(red: 1.0, green: 0.9, blue: 0.84),
        primaryGlowCenter: UnitPoint(x: 0.86, y: 0.2),
        secondaryGlowCenter: UnitPoint(x: 0.24, y: 0.88)
    )

    static let gold = DashboardCardAccent(
        glowPrimary: Color(red: 1.0, green: 0.88, blue: 0.3),
        glowSecondary: Color(red: 0.93, green: 0.68, blue: 0.16),
        secondaryText: Color(red: 1.0, green: 0.97, blue: 0.82),
        primaryGlowCenter: UnitPoint(x: 0.82, y: 0.16),
        secondaryGlowCenter: UnitPoint(x: 0.26, y: 0.84)
    )

    static let emerald = DashboardCardAccent(
        glowPrimary: Color(red: 0.28, green: 0.95, blue: 0.58),
        glowSecondary: Color(red: 0.08, green: 0.72, blue: 0.44),
        secondaryText: Color(red: 0.88, green: 1.0, blue: 0.92),
        primaryGlowCenter: UnitPoint(x: 0.82, y: 0.18),
        secondaryGlowCenter: UnitPoint(x: 0.22, y: 0.86)
    )

    static let rose = DashboardCardAccent(
        glowPrimary: Color(red: 1.0, green: 0.44, blue: 0.62),
        glowSecondary: Color(red: 0.98, green: 0.24, blue: 0.48),
        secondaryText: Color(red: 1.0, green: 0.88, blue: 0.93),
        primaryGlowCenter: UnitPoint(x: 0.84, y: 0.18),
        secondaryGlowCenter: UnitPoint(x: 0.24, y: 0.86)
    )
}

@MainActor
private struct BackupControlsCard: View {
    private enum RemoteMaintenanceAction: String, Identifiable {
        case clearChatMemory
        case deleteBackup
        case resetRemoteState

        var id: String { rawValue }
    }

    @Environment(AppStore.self) private var store
    @Environment(CloudSyncStore.self) private var cloudSyncStore
    @Environment(CoachStore.self) private var coachStore
    @State private var pendingAction: RemoteMaintenanceAction?

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                AppSectionTitle(titleKey: "backup.section")

                backupRow(
                    title: localized("backup.row.remote_status"),
                    value: remoteStatusText
                )
                backupRow(
                    title: localized("backup.row.remote_backup"),
                    value: formattedDate(
                        cloudSyncStore.lastBackupStatus?.remote?.uploadedAt,
                        emptyKey: "backup.value.remote_none"
                    )
                )
                backupRow(
                    title: localized("backup.row.local_cache"),
                    value: formattedDate(
                        store.localStateUpdatedAt,
                        emptyKey: "backup.value.local_none"
                    )
                )
                backupRow(
                    title: localized("backup.row.remote_context"),
                    value: remoteContextStatusText
                )
                backupRow(
                    title: localized("backup.row.install_auth"),
                    value: installAuthText
                )

                if let errorDescription = cloudSyncStore.lastSyncErrorDescription, !errorDescription.isEmpty {
                    Text(errorDescription)
                        .font(AppTypography.caption(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    Button(localized("backup.action.sync_remote")) {
                        Task {
                            _ = await cloudSyncStore.syncIfNeeded(using: store, allowUserPrompt: true)
                        }
                    }
                    .buttonStyle(AppPrimaryButtonStyle())

                    Button(localized("backup.action.clear_remote_chat")) {
                        pendingAction = .clearChatMemory
                    }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(!coachStore.canUseRemoteCoach)
                    .opacity(coachStore.canUseRemoteCoach ? 1 : 0.55)

                    Button(localized("backup.action.delete_remote_backup")) {
                        pendingAction = .deleteBackup
                    }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(!coachStore.canUseRemoteCoach)
                    .opacity(coachStore.canUseRemoteCoach ? 1 : 0.55)

                    Button(localized("backup.action.reset_remote_state")) {
                        pendingAction = .resetRemoteState
                    }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(!coachStore.canUseRemoteCoach)
                    .opacity(coachStore.canUseRemoteCoach ? 1 : 0.55)
                }
            }
        }
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingAction = nil
                    }
                }
            )
        ) {
            Button(localized("backup.action.confirm"), role: pendingAction == .clearChatMemory ? nil : .destructive) {
                Task {
                    await performPendingAction()
                }
            }
            Button(localized("backup.action.cancel"), role: .cancel) {
                pendingAction = nil
            }
        } message: {
            Text(alertMessage)
        }
    }

    private var remoteStatusText: String {
        guard let status = cloudSyncStore.lastBackupStatus else {
            return localized("backup.sync_state.not_checked")
        }

        return localized("backup.sync_state.\(status.syncState.rawValue)")
    }

    private var remoteContextStatusText: String {
        guard let status = cloudSyncStore.lastBackupStatus else {
            return localized("backup.context_state.not_checked")
        }

        return localized("backup.context_state.\(status.contextState.rawValue)")
    }

    private var installAuthText: String {
        guard let authMode = cloudSyncStore.lastBackupStatus?.authMode else {
            return localized("backup.value.remote_none")
        }

        return localized("backup.auth_mode.\(authMode.rawValue)")
    }

    private var alertTitle: String {
        switch pendingAction {
        case .clearChatMemory:
            return localized("backup.confirm.clear_remote_chat.title")
        case .deleteBackup:
            return localized("backup.confirm.delete_remote_backup.title")
        case .resetRemoteState:
            return localized("backup.confirm.reset_remote_state.title")
        case .none:
            return localized("backup.section")
        }
    }

    private var alertMessage: String {
        switch pendingAction {
        case .clearChatMemory:
            return localized("backup.confirm.clear_remote_chat.message")
        case .deleteBackup:
            return localized("backup.confirm.delete_remote_backup.message")
        case .resetRemoteState:
            return localized("backup.confirm.reset_remote_state.message")
        case .none:
            return ""
        }
    }

    private func performPendingAction() async {
        let action = pendingAction
        pendingAction = nil

        switch action {
        case .clearChatMemory:
            await coachStore.clearRemoteConversation()
        case .deleteBackup:
            await cloudSyncStore.clearRemoteBackup(using: store)
        case .resetRemoteState:
            await cloudSyncStore.resetRemoteState(using: store)
            coachStore.resetConversation()
        case .none:
            break
        }
    }

    private func backupRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(AppTypography.body(size: 17))
                .foregroundStyle(AppTheme.primaryText)
            Spacer(minLength: 20)
            Text(value)
                .font(AppTypography.body(size: 17, weight: .medium))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private func formattedDate(_ date: Date?, emptyKey: String) -> String {
        guard let date else {
            return localized(emptyKey)
        }

        return date.formatted(
            .dateTime
                .year()
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
                .locale(store.locale)
        )
    }

    private func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}

enum ProfilePickerField: String, Identifiable {
    case sex
    case age
    case weight
    case height
    case primaryGoal
    case experienceLevel
    case weeklyWorkoutTarget
    case targetBodyWeight

    var id: String { rawValue }
}

private struct ProfilePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let picker: ProfilePickerField
    let profile: UserProfile
    let onSave: (UserProfile) -> Void

    @State private var sex: String
    @State private var age: Int
    @State private var weightStep: Int
    @State private var height: Int
    @State private var primaryGoal: TrainingGoal
    @State private var experienceLevel: ExperienceLevel
    @State private var weeklyWorkoutTarget: Int
    @State private var targetBodyWeightStep: Int

    init(picker: ProfilePickerField, profile: UserProfile, onSave: @escaping (UserProfile) -> Void) {
        self.picker = picker
        self.profile = profile
        self.onSave = onSave
        _sex = State(initialValue: profile.sex == "F" ? "F" : "M")
        _age = State(initialValue: min(max(profile.age, 10), 100))
        _weightStep = State(initialValue: min(max(Int((profile.weight * 2).rounded()), 60), 500))
        _height = State(initialValue: min(max(Int(profile.height.rounded()), 120), 230))
        _primaryGoal = State(initialValue: profile.primaryGoal)
        _experienceLevel = State(initialValue: profile.experienceLevel)
        _weeklyWorkoutTarget = State(initialValue: min(max(profile.weeklyWorkoutTarget, 1), 14))
        _targetBodyWeightStep = State(initialValue: profile.targetBodyWeight.map { min(max(Int(($0 * 2).rounded()), 60), 500) } ?? 0)
    }

    private var targetWeightOptions: [Int] {
        [0] + Array(60...500)
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 44, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 14)

            HStack {
                Text(title(for: picker))
                    .font(AppTypography.heading(size: 21))
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Button("action.done") {
                    onSave(
                        UserProfile(
                            sex: sex,
                            age: age,
                            weight: Double(weightStep) / 2,
                            height: Double(height),
                            appLanguageCode: profile.appLanguageCode,
                            primaryGoal: primaryGoal,
                            experienceLevel: experienceLevel,
                            weeklyWorkoutTarget: weeklyWorkoutTarget,
                            targetBodyWeight: targetBodyWeightStep == 0 ? nil : Double(targetBodyWeightStep) / 2
                        )
                    )
                    dismiss()
                }
                .font(AppTypography.button(size: 16))
                .foregroundStyle(AppTheme.primaryText)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 2)

            pickerContent
                .frame(maxWidth: .infinity)
                .frame(height: 188)
                .clipped()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.surface.ignoresSafeArea())
    }

    @ViewBuilder
    private var pickerContent: some View {
        switch picker {
        case .sex:
            Picker("", selection: $sex) {
                Text("profile.sex.male").tag("M")
                Text("profile.sex.female").tag("F")
            }
            .pickerStyle(.wheel)

        case .age:
            Picker("", selection: $age) {
                ForEach(10...100, id: \.self) { value in
                    Text("\(value)")
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)

        case .weight:
            Picker("", selection: $weightStep) {
                ForEach(60...500, id: \.self) { value in
                    Text("\(Double(value) / 2, specifier: "%.1f") kg")
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)

        case .height:
            Picker("", selection: $height) {
                ForEach(120...230, id: \.self) { value in
                    Text("\(value) cm")
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)

        case .primaryGoal:
            Picker("", selection: $primaryGoal) {
                ForEach(TrainingGoal.allCases, id: \.self) { value in
                    Text(value.localizedTitle)
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)

        case .experienceLevel:
            Picker("", selection: $experienceLevel) {
                ForEach(ExperienceLevel.allCases, id: \.self) { value in
                    Text(value.localizedTitle)
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)

        case .weeklyWorkoutTarget:
            Picker("", selection: $weeklyWorkoutTarget) {
                ForEach(1...14, id: \.self) { value in
                    Text(String(format: localizedString("profile.weekly_target_value"), value))
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)

        case .targetBodyWeight:
            Picker("", selection: $targetBodyWeightStep) {
                ForEach(targetWeightOptions, id: \.self) { value in
                    if value == 0 {
                        Text("profile.value.not_set")
                            .tag(value)
                    } else {
                        Text("\(Double(value) / 2, specifier: "%.1f") kg")
                            .tag(value)
                    }
                }
            }
            .pickerStyle(.wheel)
        }
    }

    private func title(for picker: ProfilePickerField) -> LocalizedStringKey {
        switch picker {
        case .sex:
            return "profile.sex"
        case .age:
            return "profile.age"
        case .weight:
            return "profile.weight"
        case .height:
            return "profile.height"
        case .primaryGoal:
            return "profile.goal"
        case .experienceLevel:
            return "profile.experience"
        case .weeklyWorkoutTarget:
            return "profile.weekly_target"
        case .targetBodyWeight:
            return "profile.target_weight"
        }
    }
}

private extension UserProfile {
    var localizedSexValue: String {
        sex.uppercased() == "F" ? localizedString("profile.sex.female") : localizedString("profile.sex.male")
    }

    var weeklyTargetValue: String {
        String(format: localizedString("profile.weekly_target_value"), weeklyWorkoutTarget)
    }

    var targetWeightValue: String {
        targetBodyWeight.map { "\($0.appNumberText) kg" } ?? localizedString("profile.value.not_set")
    }
}

private extension TrainingGoal {
    var localizationKey: String {
        switch self {
        case .notSet:
            return "profile.goal.not_set"
        case .strength:
            return "profile.goal.strength"
        case .hypertrophy:
            return "profile.goal.hypertrophy"
        case .fatLoss:
            return "profile.goal.fat_loss"
        case .generalFitness:
            return "profile.goal.general_fitness"
        }
    }

    var localizedTitle: String {
        localizedString(localizationKey)
    }
}

private extension ExperienceLevel {
    var localizationKey: String {
        switch self {
        case .notSet:
            return "profile.experience.not_set"
        case .beginner:
            return "profile.experience.beginner"
        case .intermediate:
            return "profile.experience.intermediate"
        case .advanced:
            return "profile.experience.advanced"
        }
    }

    var localizedTitle: String {
        localizedString(localizationKey)
    }
}

private extension MetabolismEstimateSource {
    var sourceKey: String {
        switch self {
        case .history:
            return "profile.card.metabolism.source_history"
        case .target:
            return "profile.card.metabolism.source_target"
        }
    }
}

private extension ProfileTrainingSplitRecommendation {
    var titleKey: String {
        switch self {
        case .fullBody:
            return "profile.card.recommendations.split.full_body"
        case .upperLowerHybrid:
            return "profile.card.recommendations.split.upper_lower_hybrid"
        case .upperLower:
            return "profile.card.recommendations.split.upper_lower"
        case .upperLowerPlusSpecialization:
            return "profile.card.recommendations.split.upper_lower_plus"
        case .highFrequencySplit:
            return "profile.card.recommendations.split.high_frequency"
        }
    }

    var localizedTitle: String {
        localizedString(titleKey)
    }
}

private extension Double {
    var volumeValueText: String {
        if self >= 1000 {
            return "\(Int(self.rounded())) kg"
        }
        return "\(self.appNumberText) kg"
    }
}

private extension ProfileConsistencySummary {
    var weeklyStatusTitle: String {
        localizedString(workoutsThisWeek >= weeklyTarget
            ? "profile.card.consistency.goal_met_short"
            : "profile.card.consistency.goal_not_met_short")
    }

    var weeklyStatusProgress: String {
        String(format: localizedString("profile.card.consistency.goal_progress"), workoutsThisWeek, weeklyTarget)
    }
}

private func formattedProfileDate(_ date: Date?, locale: Locale) -> String {
    guard let date else {
        return localizedString("common.no_data")
    }

    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.dateFormat = "dd.MM.yyyy"
    return formatter.string(from: date)
}

private func formattedProfileDuration(_ duration: TimeInterval?) -> String {
    guard let duration else {
        return localizedString("common.no_data")
    }

    if duration >= 3600 {
        return DateComponentsFormatter.workoutDurationLong.string(from: duration) ?? "00:00"
    }

    return DateComponentsFormatter.workoutDurationShort.string(from: duration) ?? "00:00"
}

private func formattedProfileETA(lowerWeeks: Int?, upperWeeks: Int?) -> String? {
    guard let lowerWeeks, let upperWeeks else {
        return nil
    }

    if upperWeeks >= 8 {
        let lowerMonths = max(Int(ceil(Double(lowerWeeks) / 4.345)), 1)
        let upperMonths = max(Int(ceil(Double(upperWeeks) / 4.345)), lowerMonths)
        return String(format: localizedString("profile.card.goal.eta_months"), lowerMonths, upperMonths)
    }

    return String(format: localizedString("profile.card.goal.eta_weeks"), lowerWeeks, upperWeeks)
}

private func localizedString(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}
