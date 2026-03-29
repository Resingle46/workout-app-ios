import SwiftUI

struct PreferredProgramResolver {
    @MainActor
    static func resolve(
        from store: AppStore,
        preferredProgramID: UUID? = nil
    ) -> WorkoutProgram? {
        resolve(
            programs: store.programs,
            preferredProgramID: preferredProgramID,
            activeWorkoutTemplateID: store.activeSession?.workoutTemplateID,
            lastFinishedWorkoutTemplateID: store.lastFinishedSession?.workoutTemplateID,
            history: store.history
        )
    }

    static func resolve(
        programs: [WorkoutProgram],
        preferredProgramID: UUID? = nil,
        activeWorkoutTemplateID: UUID? = nil,
        lastFinishedWorkoutTemplateID: UUID? = nil,
        history: [WorkoutSession] = []
    ) -> WorkoutProgram? {
        if let preferredProgramID,
           let preferredProgram = programs.first(where: { $0.id == preferredProgramID }),
           !preferredProgram.workouts.isEmpty {
            return preferredProgram
        }

        if let activeWorkoutTemplateID,
           let program = program(containing: activeWorkoutTemplateID, in: programs) {
            return program
        }

        if let lastFinishedWorkoutTemplateID,
           let program = program(containing: lastFinishedWorkoutTemplateID, in: programs) {
            return program
        }

        if let workoutTemplateID = history.first(where: \.isFinished)?.workoutTemplateID,
           let program = program(containing: workoutTemplateID, in: programs) {
            return program
        }

        return programs.first(where: { !$0.workouts.isEmpty })
    }

    private static func program(
        containing workoutTemplateID: UUID,
        in programs: [WorkoutProgram]
    ) -> WorkoutProgram? {
        programs.first { program in
            program.workouts.contains { $0.id == workoutTemplateID }
        }
    }
}

struct ProfileCompatibilityMessageFormatter {
    static func message(for issue: ProfileGoalCompatibilityIssue) -> String {
        switch issue.kind {
        case .missingGoal:
            return todayLocalizedString("profile.card.compatibility.issue_missing_goal")
        case .goalTargetMismatch:
            return todayLocalizedString("profile.card.compatibility.issue_goal_target")
        case .frequencyTooLow:
            return String(
                format: todayLocalizedString("profile.card.compatibility.issue_frequency_low"),
                issue.recommendedWeeklyTargetLowerBound ?? 0,
                issue.currentWeeklyTarget ?? 0
            )
        case .frequencyTooHighForBeginner:
            return String(
                format: todayLocalizedString("profile.card.compatibility.issue_frequency_high_beginner"),
                issue.currentWeeklyTarget ?? 0
            )
        case .programFrequencyMismatch:
            return String(
                format: todayLocalizedString("profile.card.compatibility.issue_program_frequency_mismatch"),
                issue.programWorkoutCount ?? 0,
                issue.currentWeeklyTarget ?? 0
            )
        case .adherenceGap:
            return String(
                format: todayLocalizedString("profile.card.compatibility.issue_adherence_gap"),
                issue.observedWorkoutsPerWeek?.appNumberText ?? todayLocalizedString("common.no_data"),
                issue.currentWeeklyTarget ?? 0
            )
        case .longGoalTimeline:
            return String(
                format: todayLocalizedString("profile.card.compatibility.issue_long_eta"),
                issue.etaWeeksUpperBound ?? 0
            )
        }
    }
}

struct TodayWorkoutRecommendation {
    let program: WorkoutProgram
    let workout: WorkoutTemplate
}

enum TodayHeroState {
    case active(TodayActiveHeroState)
    case recommended(TodayWorkoutHeroState)
    case backOnTrack(TodayWorkoutHeroState)
    case recovery(TodayRecoveryHeroState)
    case firstWorkout(TodayWorkoutHeroState)
    case empty(TodayEmptyHeroState)

    var startableWorkout: WorkoutTemplate? {
        switch self {
        case .active:
            return nil
        case let .recommended(state),
             let .backOnTrack(state),
             let .firstWorkout(state):
            return state.recommendation.workout
        case let .recovery(state):
            return state.optionalRecommendation?.workout
        case .empty:
            return nil
        }
    }

    var kind: TodayHeroKind {
        switch self {
        case .active:
            return .active
        case .recommended:
            return .recommended
        case .backOnTrack:
            return .backOnTrack
        case .recovery:
            return .recovery
        case .firstWorkout:
            return .firstWorkout
        case .empty:
            return .empty
        }
    }
}

enum TodayHeroKind {
    case active
    case recommended
    case backOnTrack
    case recovery
    case firstWorkout
    case empty
}

struct TodayActiveHeroState {
    let session: WorkoutSession
    let progress: WorkoutExerciseProgress
    let lastCompletedSetDate: Date?
    let programTitle: String?
}

struct TodayWorkoutHeroState {
    let recommendation: TodayWorkoutRecommendation
    let daysSinceLastWorkout: Int?
    let workoutsThisWeek: Int
    let weeklyTarget: Int
}

struct TodayRecoveryHeroState {
    let optionalRecommendation: TodayWorkoutRecommendation?
    let workoutsThisWeek: Int
    let weeklyTarget: Int
    let lastWorkoutDate: Date?
    let recentExercises: [RecentWorkoutExerciseSummary]
    let referenceDate: Date
}

struct TodayEmptyHeroState {
    let hasPrograms: Bool
}

enum TodayAttentionKind {
    case compatibility
    case recentPR
    case streak
    case weeklyStrength
}

enum TodayCardAccent {
    case accent
    case success
    case warning
    case rose
    case indigo

    var tint: Color {
        switch self {
        case .accent:
            return AppTheme.accent
        case .success:
            return AppTheme.success
        case .warning:
            return AppTheme.warning
        case .rose:
            return AppTheme.destructive
        case .indigo:
            return Color(red: 0.44, green: 0.52, blue: 0.94)
        }
    }

    var subtleFill: Color {
        tint.opacity(0.14)
    }
}

struct TodayAttentionCardState {
    let kind: TodayAttentionKind
    let title: String
    let message: String
    let systemImage: String
    let accent: TodayCardAccent
}

struct TodayMetricState: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let accent: TodayCardAccent
}

struct TodayDashboardState {
    let hero: TodayHeroState
    let attention: TodayAttentionCardState?
    let metrics: [TodayMetricState]
}

struct TodayWorkoutRecommendationResolver {
    @MainActor
    static func resolve(
        from store: AppStore,
        preferredProgram: WorkoutProgram?
    ) -> TodayWorkoutRecommendation? {
        guard let preferredProgram, !preferredProgram.workouts.isEmpty else {
            return nil
        }

        let workout = resolveNextWorkout(
            in: preferredProgram,
            lastFinishedWorkoutTemplateID: store.lastFinishedSession?.workoutTemplateID,
            history: store.history
        )

        return TodayWorkoutRecommendation(program: preferredProgram, workout: workout)
    }

    static func resolveNextWorkout(
        in program: WorkoutProgram,
        lastFinishedWorkoutTemplateID: UUID?,
        history: [WorkoutSession]
    ) -> WorkoutTemplate {
        guard !program.workouts.isEmpty else {
            fatalError("Program must contain at least one workout")
        }

        if let lastFinishedWorkoutTemplateID,
           let lastWorkoutIndex = program.workouts.firstIndex(where: { $0.id == lastFinishedWorkoutTemplateID }) {
            let nextIndex = program.workouts.index(after: lastWorkoutIndex)
            return program.workouts[nextIndex == program.workouts.endIndex ? program.workouts.startIndex : nextIndex]
        }

        if let recentProgramWorkoutID = history
            .filter(\.isFinished)
            .compactMap(\.workoutTemplateID)
            .first(where: { workoutID in
                program.workouts.contains(where: { $0.id == workoutID })
            }),
           let recentWorkoutIndex = program.workouts.firstIndex(where: { $0.id == recentProgramWorkoutID }) {
            let nextIndex = program.workouts.index(after: recentWorkoutIndex)
            return program.workouts[nextIndex == program.workouts.endIndex ? program.workouts.startIndex : nextIndex]
        }

        return program.workouts[0]
    }
}

struct TodayAttentionResolver {
    static func resolve(
        compatibilitySummary: ProfileGoalCompatibilitySummary,
        recentPersonalRecords: [ProfilePRItem],
        consistencySummary: ProfileConsistencySummary,
        weeklyStrengthSummary: WeeklyStrengthSummary
    ) -> TodayAttentionCardState? {
        if let issue = compatibilitySummary.issues.first {
            return TodayAttentionCardState(
                kind: .compatibility,
                title: todayLocalizedString("today.attention.compatibility.title"),
                message: ProfileCompatibilityMessageFormatter.message(for: issue),
                systemImage: issue.systemImage,
                accent: .rose
            )
        }

        if let record = recentPersonalRecords.first {
            return TodayAttentionCardState(
                kind: .recentPR,
                title: todayLocalizedString("today.attention.pr.title"),
                message: String(
                    format: todayLocalizedString("today.attention.pr.body"),
                    record.exerciseName,
                    record.delta.appNumberText
                ),
                systemImage: "sparkles.rectangle.stack.fill",
                accent: .warning
            )
        }

        if consistencySummary.streakWeeks > 0 {
            return TodayAttentionCardState(
                kind: .streak,
                title: todayLocalizedString("today.attention.streak.title"),
                message: String(
                    format: todayLocalizedString("today.attention.streak.body"),
                    consistencySummary.streakWeeks
                ),
                systemImage: "flame.fill",
                accent: .success
            )
        }

        if weeklyStrengthSummary.percentChange != 0 {
            let change = weeklyStrengthSummary.percentChange
            let value = change > 0 ? "+\(change)%" : "\(change)%"
            return TodayAttentionCardState(
                kind: .weeklyStrength,
                title: todayLocalizedString("today.attention.strength.title"),
                message: String(
                    format: todayLocalizedString("today.attention.strength.body"),
                    value
                ),
                systemImage: change > 0 ? "chart.line.uptrend.xyaxis.circle.fill" : "waveform.path.ecg.rectangle",
                accent: change > 0 ? .success : .warning
            )
        }

        return nil
    }
}

struct TodayRecommendationBuilder {
    @MainActor
    static func build(
        from store: AppStore,
        now: Date = .now,
        calendar: Calendar? = nil
    ) -> TodayDashboardState {
        let calendar = calendar ?? AppStore.statisticsCalendar(locale: store.locale)
        let progressSummary = store.profileProgressSummary(referenceDate: now, calendar: calendar)
        let consistencySummary = store.profileConsistencySummary(referenceDate: now, calendar: calendar)
        let weeklyStrengthSummary = store.weeklyStrengthSummary(referenceDate: now, calendar: calendar)
        let compatibilitySummary = store.profileGoalCompatibilitySummary(referenceDate: now, calendar: calendar)
        let recentPersonalRecords = store.recentPersonalRecords(limit: 1)
        let recentExercises = store.recentExercisesFromLastWorkout()
        let preferredProgram = PreferredProgramResolver.resolve(
            from: store,
            preferredProgramID: store.coachAnalysisSettings.selectedProgramID
        )
        let recommendation = TodayWorkoutRecommendationResolver.resolve(
            from: store,
            preferredProgram: preferredProgram
        )
        let hero = resolveHeroState(
            store: store,
            recommendation: recommendation,
            progressSummary: progressSummary,
            consistencySummary: consistencySummary,
            recentExercises: recentExercises,
            referenceDate: now,
            calendar: calendar
        )
        let hasFinishedHistory = progressSummary.totalFinishedWorkouts > 0
        let isSparseEmptyState = store.programs.isEmpty && !hasFinishedHistory
        let attention = isSparseEmptyState
            ? nil
            : TodayAttentionResolver.resolve(
                compatibilitySummary: compatibilitySummary,
                recentPersonalRecords: recentPersonalRecords,
                consistencySummary: consistencySummary,
                weeklyStrengthSummary: weeklyStrengthSummary
            )

        return TodayDashboardState(
            hero: hero,
            attention: attention,
            metrics: resolveMetrics(
                store: store,
                recommendation: recommendation,
                progressSummary: progressSummary,
                consistencySummary: consistencySummary,
                recentPersonalRecords: recentPersonalRecords,
                referenceDate: now,
                calendar: calendar
            )
        )
    }

    @MainActor
    private static func resolveHeroState(
        store: AppStore,
        recommendation: TodayWorkoutRecommendation?,
        progressSummary: ProfileProgressSummary,
        consistencySummary: ProfileConsistencySummary,
        recentExercises: [RecentWorkoutExerciseSummary],
        referenceDate: Date,
        calendar: Calendar
    ) -> TodayHeroState {
        if let activeSession = store.activeSession {
            let derivedState = ActiveWorkoutDerivedState.build(session: activeSession, store: store)
            let programTitle = store.programs.first { program in
                program.workouts.contains { $0.id == activeSession.workoutTemplateID }
            }?.title

            return .active(
                TodayActiveHeroState(
                    session: activeSession,
                    progress: derivedState.progress,
                    lastCompletedSetDate: derivedState.lastCompletedSetDate,
                    programTitle: programTitle
                )
            )
        }

        let hasFinishedHistory = progressSummary.totalFinishedWorkouts > 0
        let daysSinceLastWorkout = progressSummary.lastWorkoutDate.map {
            todayDayDistance(from: $0, to: referenceDate, calendar: calendar)
        }
        let weeklyGap = max(consistencySummary.weeklyTarget - consistencySummary.workoutsThisWeek, 0)
        let cadenceThreshold = recommendedWorkoutCadenceThreshold(for: consistencySummary.weeklyTarget)
        let backOnTrackThreshold = max(cadenceThreshold + 3, 7)
        let isBackOnTrack = hasFinishedHistory &&
            weeklyGap > 0 &&
            (daysSinceLastWorkout ?? 0) >= backOnTrackThreshold
        let shouldRecommendWorkout = hasFinishedHistory &&
            weeklyGap > 0 &&
            !isBackOnTrack &&
            (daysSinceLastWorkout ?? 0) >= cadenceThreshold

        if let recommendation, shouldRecommendWorkout {
            return .recommended(
                TodayWorkoutHeroState(
                    recommendation: recommendation,
                    daysSinceLastWorkout: daysSinceLastWorkout,
                    workoutsThisWeek: consistencySummary.workoutsThisWeek,
                    weeklyTarget: consistencySummary.weeklyTarget
                )
            )
        }

        if let recommendation, hasFinishedHistory, isBackOnTrack {
            return .backOnTrack(
                TodayWorkoutHeroState(
                    recommendation: recommendation,
                    daysSinceLastWorkout: daysSinceLastWorkout,
                    workoutsThisWeek: consistencySummary.workoutsThisWeek,
                    weeklyTarget: consistencySummary.weeklyTarget
                )
            )
        }

        if hasFinishedHistory {
            return .recovery(
                TodayRecoveryHeroState(
                    optionalRecommendation: recommendation,
                    workoutsThisWeek: consistencySummary.workoutsThisWeek,
                    weeklyTarget: consistencySummary.weeklyTarget,
                    lastWorkoutDate: progressSummary.lastWorkoutDate,
                    recentExercises: recentExercises,
                    referenceDate: referenceDate
                )
            )
        }

        if let recommendation {
            return .firstWorkout(
                TodayWorkoutHeroState(
                    recommendation: recommendation,
                    daysSinceLastWorkout: nil,
                    workoutsThisWeek: consistencySummary.workoutsThisWeek,
                    weeklyTarget: consistencySummary.weeklyTarget
                )
            )
        }

        return .empty(TodayEmptyHeroState(hasPrograms: !store.programs.isEmpty))
    }

    @MainActor
    private static func resolveMetrics(
        store: AppStore,
        recommendation: TodayWorkoutRecommendation?,
        progressSummary: ProfileProgressSummary,
        consistencySummary: ProfileConsistencySummary,
        recentPersonalRecords: [ProfilePRItem],
        referenceDate: Date,
        calendar: Calendar
    ) -> [TodayMetricState] {
        let hasFinishedHistory = progressSummary.totalFinishedWorkouts > 0

        if !hasFinishedHistory {
            return onboardingMetrics(
                store: store,
                recommendation: recommendation
            )
        }

        var metrics: [TodayMetricState] = [
            TodayMetricState(
                id: "this_week",
                title: todayLocalizedString("today.metric.this_week"),
                value: "\(consistencySummary.workoutsThisWeek)/\(consistencySummary.weeklyTarget)",
                detail: todayLocalizedString("today.metric.this_week_detail"),
                accent: .accent
            )
        ]

        if consistencySummary.streakWeeks > 0 {
            metrics.append(
                TodayMetricState(
                    id: "streak",
                    title: todayLocalizedString("today.metric.streak"),
                    value: String(
                        format: todayLocalizedString("profile.card.consistency.weeks_value"),
                        consistencySummary.streakWeeks
                    ),
                    detail: todayLocalizedString("today.metric.streak_detail"),
                    accent: .success
                )
            )
        } else if let weekday = consistencySummary.mostFrequentWeekday {
            metrics.append(
                TodayMetricState(
                    id: "favorite_day",
                    title: todayLocalizedString("today.metric.favorite_day"),
                    value: todayWeekdayName(for: weekday, calendar: calendar),
                    detail: todayLocalizedString("today.metric.favorite_day_detail"),
                    accent: .indigo
                )
            )
        }

        if let recentPR = recentPersonalRecords.first {
            metrics.append(
                TodayMetricState(
                    id: "recent_pr",
                    title: todayLocalizedString("today.metric.recent_pr"),
                    value: "+\(recentPR.delta.appNumberText) kg",
                    detail: recentPR.exerciseName,
                    accent: .warning
                )
            )
        } else {
            metrics.append(
                TodayMetricState(
                    id: "last_workout",
                    title: todayLocalizedString("today.metric.last_workout"),
                    value: todayRelativeDateText(
                        for: progressSummary.lastWorkoutDate,
                        referenceDate: referenceDate,
                        locale: store.locale
                    ),
                    detail: store.lastFinishedSession?.title ?? todayLocalizedString("common.no_data"),
                    accent: .indigo
                )
            )
        }

        return Array(metrics.prefix(3))
    }

    @MainActor
    private static func onboardingMetrics(
        store: AppStore,
        recommendation: TodayWorkoutRecommendation?
    ) -> [TodayMetricState] {
        let goalTitle = todayGoalTitle(store.profile.primaryGoal)
        let programDays = recommendation?.program.workouts.count ?? 0
        return [
            TodayMetricState(
                id: "weekly_target",
                title: todayLocalizedString("today.metric.weekly_target"),
                value: "\(max(store.profile.weeklyWorkoutTarget, 1))",
                detail: todayLocalizedString("today.metric.weekly_target_detail"),
                accent: .accent
            ),
            TodayMetricState(
                id: "program_days",
                title: todayLocalizedString("today.metric.program_days"),
                value: "\(programDays)",
                detail: recommendation?.program.title ?? todayLocalizedString("today.metric.program_days_empty"),
                accent: .indigo
            ),
            TodayMetricState(
                id: "goal",
                title: todayLocalizedString("today.metric.goal"),
                value: goalTitle,
                detail: todayLocalizedString("today.metric.goal_detail"),
                accent: .warning
            )
        ]
    }

    private static func recommendedWorkoutCadenceThreshold(for weeklyTarget: Int) -> Int {
        let normalizedTarget = max(weeklyTarget, 1)
        let spacing = Int(ceil(7.0 / Double(normalizedTarget)))
        return max(spacing - 1, 1)
    }
}

struct TodayDashboardView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appBottomRailInset) private var bottomRailInset
    @State private var showingCreateProgram = false

    private var state: TodayDashboardState {
        TodayRecommendationBuilder.build(from: store)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header
                TodayHeroCard(
                    state: state.hero,
                    locale: store.locale,
                    onCreateProgram: { showingCreateProgram = true },
                    onPrimaryStartWorkout: { template in
                        store.startWorkout(template: template)
                    },
                    onContinueWorkout: {
                        store.selectedTab = .workout
                    },
                    onOpenStatistics: {
                        store.selectedTab = .statistics
                    }
                )

                if let attention = state.attention {
                    TodayAttentionCard(attention: attention)
                }

                if !state.metrics.isEmpty {
                    TodayMetricsStrip(metrics: state.metrics)
                }

                TodayQuickActionsCard(
                    hero: state.hero,
                    onCreateProgram: { showingCreateProgram = true },
                    onStartWorkout: { template in
                        store.startWorkout(template: template)
                    },
                    onContinueWorkout: {
                        store.selectedTab = .workout
                    },
                    onOpenCoach: {
                        store.selectedTab = .coach
                    },
                    onOpenStatistics: {
                        store.selectedTab = .statistics
                    }
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 28 + bottomRailInset)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingCreateProgram) {
            CreateProgramView()
        }
        .appScreenBackground()
    }

    private var header: some View {
        AppPageHeaderModule(titleKey: "header.today.title", subtitleKey: "header.today.subtitle") {
            HStack(spacing: 10) {
                NavigationLink(destination: ProgramsLibraryView()) {
                    Image(systemName: "list.clipboard")
                        .font(AppTypography.icon(size: 18, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 42, height: 42)
                        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(AppTheme.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                if case .empty = state.hero {
                    Button {
                        showingCreateProgram = true
                    } label: {
                        Image(systemName: "plus")
                            .font(AppTypography.icon(size: 18, weight: .medium))
                            .foregroundStyle(AppTheme.primaryText)
                            .frame(width: 42, height: 42)
                            .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(AppTheme.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct TodayHeroCard: View {
    let state: TodayHeroState
    let locale: Locale
    let onCreateProgram: () -> Void
    let onPrimaryStartWorkout: (WorkoutTemplate) -> Void
    let onContinueWorkout: () -> Void
    let onOpenStatistics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            title
            description
            badges
            actions
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroBackground)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .shadow(color: AppTheme.shadowSubtle, radius: 16, y: 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(eyebrowText)
                .font(AppTypography.label(size: 12, weight: .semibold))
                .foregroundStyle(eyebrowColor)
                .textCase(.uppercase)
                .tracking(1.1)

            Spacer(minLength: 12)

            Image(systemName: heroIcon)
                .font(AppTypography.icon(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
                .padding(10)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var title: some View {
        Text(heroTitle)
            .font(AppTypography.title(size: 32))
            .foregroundStyle(AppTheme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var description: some View {
        Text(heroDescription)
            .font(AppTypography.body(size: 16, weight: .medium, relativeTo: .subheadline))
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var badges: some View {
        let badgeItems = heroBadges
        if !badgeItems.isEmpty {
            FlexibleBadgeRow(items: badgeItems)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .active:
            HStack(spacing: 12) {
                Button("today.action.continue_workout", action: onContinueWorkout)
                    .buttonStyle(AppPrimaryButtonStyle())

                Button("today.action.open_statistics", action: onOpenStatistics)
                    .buttonStyle(AppSecondaryButtonStyle())
            }
        case let .recommended(heroState),
             let .backOnTrack(heroState),
             let .firstWorkout(heroState):
            Button {
                onPrimaryStartWorkout(heroState.recommendation.workout)
            } label: {
                Text("action.start_workout")
            }
            .buttonStyle(AppPrimaryButtonStyle())
        case .recovery:
            Button("today.action.open_statistics", action: onOpenStatistics)
                .buttonStyle(AppSecondaryButtonStyle())
        case .empty:
            Button("action.create_program", action: onCreateProgram)
                .buttonStyle(AppPrimaryButtonStyle())
        }
    }

    private var eyebrowText: String {
        switch state {
        case .active:
            return todayLocalizedString("today.hero.eyebrow.active")
        case .recommended:
            return todayLocalizedString("today.hero.eyebrow.recommended")
        case .backOnTrack:
            return todayLocalizedString("today.hero.eyebrow.back_on_track")
        case .recovery:
            return todayLocalizedString("today.hero.eyebrow.recovery")
        case .firstWorkout:
            return todayLocalizedString("today.hero.eyebrow.first_workout")
        case .empty:
            return todayLocalizedString("today.hero.eyebrow.empty")
        }
    }

    private var heroTitle: String {
        switch state {
        case let .active(heroState):
            return heroState.session.title
        case let .recommended(heroState),
             let .backOnTrack(heroState),
             let .firstWorkout(heroState):
            return heroState.recommendation.workout.title
        case let .recovery(heroState):
            if heroState.workoutsThisWeek >= heroState.weeklyTarget {
                return todayLocalizedString("today.hero.recovery.title_met_target")
            }
            return todayLocalizedString("today.hero.recovery.title_recent")
        case .empty:
            return todayLocalizedString("today.hero.empty.title")
        }
    }

    private var heroDescription: String {
        switch state {
        case let .active(heroState):
            let progressText = String(
                format: todayLocalizedString("workout.progress_value"),
                heroState.progress.completed,
                heroState.progress.remaining
            )
            return String(
                format: todayLocalizedString("today.hero.active.body"),
                progressText
            )
        case let .recommended(heroState):
            return String(
                format: todayLocalizedString("today.hero.recommended.body"),
                heroState.recommendation.program.title
            )
        case let .backOnTrack(heroState):
            let relativeText = todayRelativeDateText(
                daysSinceLastWorkout: heroState.daysSinceLastWorkout,
                locale: locale
            )
            return String(
                format: todayLocalizedString("today.hero.back_on_track.body"),
                relativeText,
                heroState.recommendation.program.title
            )
        case let .recovery(heroState):
            if heroState.workoutsThisWeek >= heroState.weeklyTarget {
                return String(
                    format: todayLocalizedString("today.hero.recovery.met_target"),
                    heroState.workoutsThisWeek,
                    heroState.weeklyTarget
                )
            }

            if let lastWorkoutDate = heroState.lastWorkoutDate,
               let recommendation = heroState.optionalRecommendation {
                return String(
                    format: todayLocalizedString("today.hero.recovery.recent"),
                    todayRelativeDateText(
                        for: lastWorkoutDate,
                        referenceDate: heroState.referenceDate,
                        locale: locale
                    ),
                    recommendation.workout.title
                )
            }

            return todayLocalizedString("today.hero.recovery.generic")
        case let .firstWorkout(heroState):
            return String(
                format: todayLocalizedString("today.hero.first_workout.body"),
                heroState.recommendation.program.title
            )
        case .empty:
            return todayLocalizedString("today.hero.empty.body")
        }
    }

    private var heroBadges: [String] {
        switch state {
        case let .active(heroState):
            var items: [String] = []
            items.append(todayDurationText(since: heroState.session.startedAt))
            items.append("\(heroState.progress.completed)/\(heroState.progress.total)")
            if let programTitle = heroState.programTitle {
                items.append(programTitle)
            }
            return items
        case let .recommended(heroState),
             let .backOnTrack(heroState),
             let .firstWorkout(heroState):
            var items = [
                heroState.recommendation.program.title,
                todayWeeklyTargetText(
                    workoutsThisWeek: heroState.workoutsThisWeek,
                    weeklyTarget: heroState.weeklyTarget
                )
            ]

            if !heroState.recommendation.workout.focus.isEmpty {
                items.append(heroState.recommendation.workout.focus)
            }

            return items
        case let .recovery(heroState):
            var items = [todayWeeklyTargetText(
                workoutsThisWeek: heroState.workoutsThisWeek,
                weeklyTarget: heroState.weeklyTarget
            )]
            if !heroState.recentExercises.isEmpty {
                items.append(heroState.recentExercises.prefix(2).map(\.exerciseName).joined(separator: " • "))
            }
            return items
        case .empty:
            return []
        }
    }

    private var heroIcon: String {
        switch state {
        case .active:
            return "figure.run.circle.fill"
        case .recommended:
            return "sun.max.fill"
        case .backOnTrack:
            return "bolt.heart.fill"
        case .recovery:
            return "figure.cooldown"
        case .firstWorkout:
            return "play.circle.fill"
        case .empty:
            return "tray.fill"
        }
    }

    private var eyebrowColor: Color {
        switch state.kind {
        case .active:
            return AppTheme.accent
        case .recommended:
            return AppTheme.success
        case .backOnTrack:
            return AppTheme.warning
        case .recovery:
            return AppTheme.secondaryText
        case .firstWorkout:
            return AppTheme.accent
        case .empty:
            return AppTheme.warning
        }
    }

    private var heroBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: backgroundColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.08), Color.clear],
                            center: .topTrailing,
                            startRadius: 8,
                            endRadius: 220
                        )
                    )
            )
    }

    private var backgroundColors: [Color] {
        switch state.kind {
        case .active:
            return [AppTheme.accent.opacity(0.38), AppTheme.surfaceElevated, AppTheme.surface]
        case .recommended:
            return [AppTheme.success.opacity(0.3), AppTheme.surfaceElevated, AppTheme.surface]
        case .backOnTrack:
            return [AppTheme.warning.opacity(0.28), AppTheme.surfaceElevated, AppTheme.surface]
        case .recovery:
            return [AppTheme.accentMuted.opacity(0.88), AppTheme.surfaceElevated, AppTheme.surface]
        case .firstWorkout:
            return [AppTheme.accent.opacity(0.28), AppTheme.surfaceElevated, AppTheme.surface]
        case .empty:
            return [AppTheme.warning.opacity(0.22), AppTheme.surfaceElevated, AppTheme.surface]
        }
    }
}

private struct TodayAttentionCard: View {
    let attention: TodayAttentionCardState

    var body: some View {
        AppCard(padding: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: attention.systemImage)
                    .font(AppTypography.icon(size: 18, weight: .bold))
                    .foregroundStyle(attention.accent.tint)
                    .frame(width: 42, height: 42)
                    .background(attention.accent.subtleFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(attention.title)
                        .font(AppTypography.heading(size: 19))
                        .foregroundStyle(AppTheme.primaryText)

                    Text(attention.message)
                        .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct TodayMetricsStrip: View {
    let metrics: [TodayMetricState]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(metrics) { metric in
                    TodayMetricCard(metric: metric)
                }
            }
            .padding(.horizontal, 1)
        }
    }
}

private struct TodayMetricCard: View {
    let metric: TodayMetricState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(metric.title)
                .font(AppTypography.caption(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .textCase(.uppercase)
                .tracking(1.0)

            Text(metric.value)
                .font(AppTypography.heading(size: 22))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(metric.detail)
                .font(AppTypography.caption(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(18)
        .frame(width: 164, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AppTheme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(metric.accent.subtleFill)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

private struct TodayQuickActionsCard: View {
    let hero: TodayHeroState
    let onCreateProgram: () -> Void
    let onStartWorkout: (WorkoutTemplate) -> Void
    let onContinueWorkout: () -> Void
    let onOpenCoach: () -> Void
    let onOpenStatistics: () -> Void

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                AppSectionTitle(titleKey: "today.quick_actions.title")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    if case .active = hero {
                        TodayQuickActionButton(
                            title: todayLocalizedString("today.action.continue_workout"),
                            systemImage: "play.fill"
                        ) {
                            onContinueWorkout()
                        }
                    } else if let template = hero.startableWorkout {
                        TodayQuickActionButton(
                            title: todayLocalizedString("action.start_workout"),
                            systemImage: "play.fill"
                        ) {
                            onStartWorkout(template)
                        }
                    } else {
                        TodayQuickActionButton(
                            title: todayLocalizedString("action.create_program"),
                            systemImage: "plus"
                        ) {
                            onCreateProgram()
                        }
                    }

                    TodayQuickActionButton(
                        title: todayLocalizedString("today.action.open_coach"),
                        systemImage: "sparkles"
                    ) {
                        onOpenCoach()
                    }

                    TodayQuickActionButton(
                        title: todayLocalizedString("today.action.open_statistics"),
                        systemImage: "chart.line.uptrend.xyaxis"
                    ) {
                        onOpenStatistics()
                    }

                    NavigationLink(destination: ProgramsLibraryView()) {
                        TodayQuickActionLabel(
                            title: todayLocalizedString("today.action.programs"),
                            systemImage: "list.clipboard"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct TodayQuickActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TodayQuickActionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

private struct TodayQuickActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(AppTypography.icon(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 36, height: 36)
                .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            Text(title)
                .font(AppTypography.body(size: 15, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AppTheme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
        }
    }
}

private struct FlexibleBadgeRow: View {
    let items: [String]

    var body: some View {
        ViewThatFits(in: .vertical) {
            HStack(spacing: 10) {
                ForEach(items, id: \.self) { item in
                    badge(item)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(items, id: \.self) { item in
                    badge(item)
                }
            }
        }
    }

    private func badge(_ value: String) -> some View {
        Text(value)
            .font(AppTypography.caption(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private func todayLocalizedString(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

private func todayDayDistance(
    from startDate: Date,
    to endDate: Date,
    calendar: Calendar
) -> Int {
    max(
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: startDate),
            to: calendar.startOfDay(for: endDate)
        ).day ?? 0,
        0
    )
}

private func todayRelativeDateText(
    for date: Date?,
    referenceDate: Date,
    locale: Locale
) -> String {
    guard let date else {
        return todayLocalizedString("common.no_data")
    }

    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: referenceDate)
}

private func todayRelativeDateText(
    daysSinceLastWorkout: Int?,
    locale: Locale
) -> String {
    guard let daysSinceLastWorkout else {
        return todayLocalizedString("common.no_data")
    }

    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .full
    return formatter.localizedString(fromTimeInterval: -Double(daysSinceLastWorkout * 24 * 60 * 60))
}

private func todayDurationText(since startDate: Date) -> String {
    let duration = max(Date().timeIntervalSince(startDate), 0)
    if duration >= 3600 {
        return DateComponentsFormatter.workoutDurationLong.string(from: duration) ?? "00:00"
    }

    return DateComponentsFormatter.workoutDurationShort.string(from: duration) ?? "00:00"
}

private func todayWeeklyTargetText(
    workoutsThisWeek: Int,
    weeklyTarget: Int
) -> String {
    String(
        format: todayLocalizedString("profile.card.consistency.goal_progress"),
        workoutsThisWeek,
        weeklyTarget
    )
}

private func todayWeekdayName(
    for weekday: Int,
    calendar: Calendar
) -> String {
    let weekdaySymbols = calendar.weekdaySymbols
    guard weekdaySymbols.indices.contains(weekday - 1) else {
        return todayLocalizedString("common.no_data")
    }

    return weekdaySymbols[weekday - 1]
}

private func todayGoalTitle(_ goal: TrainingGoal) -> String {
    switch goal {
    case .notSet:
        return todayLocalizedString("profile.goal.not_set")
    case .strength:
        return todayLocalizedString("profile.goal.strength")
    case .hypertrophy:
        return todayLocalizedString("profile.goal.hypertrophy")
    case .fatLoss:
        return todayLocalizedString("profile.goal.fat_loss")
    case .generalFitness:
        return todayLocalizedString("profile.goal.general_fitness")
    }
}
