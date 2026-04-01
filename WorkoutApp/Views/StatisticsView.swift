import Charts
import SwiftUI

struct StatisticsView: View {
    @Environment(AppStore.self) private var store
    @Environment(CoachStore.self) private var coachStore
    @Environment(CloudSyncStore.self) private var cloudSyncStore
    @Environment(WorkoutSummaryStore.self) private var workoutSummaryStore
    @Environment(\.appBottomRailInset) private var bottomRailInset
    @State private var selectedExerciseID: UUID?
    @State private var pendingDeleteSession: WorkoutSession?
    @State private var revealedHistoryDeleteSessionID: UUID?
    @State private var historySyncNotice: StatisticsHistorySyncNotice?
    @State private var isRetryingHistorySync = false

    private var selectedExercise: Exercise? {
        guard let selectedExerciseID else { return nil }
        return store.exercise(for: selectedExerciseID)
    }

    private var weeklyStrengthSummary: WeeklyStrengthSummary {
        store.weeklyStrengthSummary()
    }

    private var defaultExerciseID: UUID? {
        if let selectedExerciseID, store.exercise(for: selectedExerciseID) != nil {
            return selectedExerciseID
        }

        if let recentExerciseID = store.lastFinishedSession?.exercises.first?.exerciseID,
           store.exercise(for: recentExerciseID) != nil {
            return recentExerciseID
        }

        return store.exercises.first?.id
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                AppPageHeaderModule(titleKey: "header.statistics.title", subtitleKey: "header.statistics.subtitle")
                weeklyStrengthSummaryText
                exerciseAnalyticsCard
                recentExerciseSessionsCard

                AppCard {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        AppSectionTitle(titleKey: "stats.history")

                        if let historySyncNotice {
                            historySyncNoticeView(historySyncNotice)
                        }

                        if store.history.isEmpty {
                            Text("stats.no_workouts")
                                .foregroundStyle(AppTheme.secondaryText)
                        } else {
                            ForEach(store.history) { session in
                                StatisticsHistoryRow(
                                    session: session,
                                    isDeleteRevealed: revealedHistoryDeleteSessionID == session.id,
                                    onRevealDelete: {
                                        revealedHistoryDeleteSessionID = session.id
                                    },
                                    onHideDelete: {
                                        guard revealedHistoryDeleteSessionID == session.id else {
                                            return
                                        }
                                        revealedHistoryDeleteSessionID = nil
                                    },
                                    onDelete: {
                                        revealedHistoryDeleteSessionID = nil
                                        pendingDeleteSession = session
                                    },
                                    destination: WorkoutSummaryView(
                                        session: session,
                                        onDeleteFromHistory: {
                                            confirmDelete(for: session)
                                        }
                                    )
                                )

                                if session.id != (store.history.last?.id ?? session.id) {
                                    Divider()
                                        .overlay(AppTheme.stroke)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 24 + bottomRailInset)
        }
        .onAppear(perform: syncSelectedExercise)
        .onChange(of: store.exercises.map(\.id)) { _, _ in
            syncSelectedExercise()
        }
        .alert(
            "stats.history_delete_confirm_title",
            isPresented: Binding(
                get: { pendingDeleteSession != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeleteSession = nil
                    }
                }
            ),
            presenting: pendingDeleteSession
        ) { session in
            Button("common.delete", role: .destructive) {
                confirmDelete(for: session)
            }
            Button("action.cancel", role: .cancel) {
                pendingDeleteSession = nil
            }
        } message: { _ in
            Text("stats.history_delete_confirm_message")
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .appScreenBackground()
    }

    @ViewBuilder
    private var weeklyStrengthSummaryText: some View {
        if weeklyStrengthSummary.percentChange != 0 {
            Text(
                String(
                    format: NSLocalizedString("stats.weekly_strength_summary", comment: ""),
                    formattedWeeklyStrengthChange
                )
            )
            .font(AppTypography.body(size: 18, weight: .semibold, relativeTo: .headline))
            .foregroundStyle(weeklyStrengthSummary.isPositive ? AppTheme.success : AppTheme.destructive)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var exerciseAnalyticsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                AppSectionTitle(titleKey: "stats.exercise_picker")
                Picker(NSLocalizedString("stats.exercise", comment: ""), selection: $selectedExerciseID) {
                    Text("common.select").tag(UUID?.none)
                    ForEach(store.exercises) { exercise in
                        Text(exercise.localizedName).tag(UUID?.some(exercise.id))
                    }
                }
                .pickerStyle(.menu)

                if let selectedExercise {
                    exerciseChartContent(for: selectedExercise)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("stats.pick_exercise_title")
                            .font(AppTypography.heading(size: 21))
                        Text("stats.pick_exercise_description")
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentExerciseSessionsCard: some View {
        if let selectedExercise {
            let recentSessions = store.recentSessionAverages(for: selectedExercise.id)

            AppCard {
                VStack(alignment: .leading, spacing: 16) {
                    AppSectionTitle(titleKey: "stats.exercise_recent_sessions")
                    Text(selectedExercise.localizedName)
                        .font(AppTypography.heading(size: 21))

                    if recentSessions.isEmpty {
                        Text("stats.exercise_recent_sessions_empty")
                            .foregroundStyle(AppTheme.secondaryText)
                    } else {
                        recentSessionAveragesTable(recentSessions)
                    }
                }
            }
        }
    }

    private func exerciseChartContent(for exercise: Exercise) -> some View {
        let points = store.chartPoints(for: exercise.id)
        let latestPoint = points.last

        return VStack(alignment: .leading, spacing: 16) {
            Text(exercise.localizedName)
                .font(AppTypography.heading(size: 21))

            if points.isEmpty {
                Text("stats.empty")
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                Chart {
                    ForEach(points, id: \.0) { point in
                        AreaMark(
                            x: .value(NSLocalizedString("stats.chart.date", comment: ""), point.0),
                            yStart: .value(NSLocalizedString("stats.chart.weight", comment: ""), 0.0),
                            yEnd: .value(NSLocalizedString("stats.chart.weight", comment: ""), point.1)
                        )
                        .foregroundStyle(chartAreaGradient)

                        LineMark(
                            x: .value(NSLocalizedString("stats.chart.date", comment: ""), point.0),
                            y: .value(NSLocalizedString("stats.chart.weight", comment: ""), point.1)
                        )
                        .foregroundStyle(chartLineGradient)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                        PointMark(
                            x: .value(NSLocalizedString("stats.chart.date", comment: ""), point.0),
                            y: .value(NSLocalizedString("stats.chart.weight", comment: ""), point.1)
                        )
                        .symbolSize(56)
                        .foregroundStyle(Color.white)
                    }

                    if let latestPoint {
                        RuleMark(x: .value(NSLocalizedString("stats.chart.date", comment: ""), latestPoint.0))
                            .foregroundStyle(Color.white.opacity(0.18))
                    }
                }
                .frame(height: 220)
                .chartYAxis {
                    AxisMarks(position: .trailing)
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(AppTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                recentChartPointsList(points)
            }
        }
    }

    private func recentChartPointsList(_ points: [(Date, Double)]) -> some View {
        let displayedPoints = Array(points.suffix(4).reversed())

        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(displayedPoints.enumerated()), id: \.offset) { _, point in
                HStack {
                    Text(point.0, format: .dateTime.day().month().year())
                    Spacer()
                    Text(String(format: NSLocalizedString("stats.weight_value", comment: ""), point.1))
                }
                .font(AppTypography.body(size: 16, relativeTo: .subheadline))
                .foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private func recentSessionAveragesTable(_ averages: [ExerciseSessionAverage]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                sessionTableHeaderCell("stats.table_date", alignment: .leading)
                sessionTableHeaderCell("stats.table_avg_weight", alignment: .center)
                sessionTableHeaderCell("stats.table_avg_reps", alignment: .center)
                sessionTableHeaderCell("stats.table_sets", alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            ForEach(Array(averages.enumerated()), id: \.element.id) { index, average in
                HStack(spacing: 12) {
                    sessionTableValueCell(
                        average.date.formatted(date: .abbreviated, time: .omitted),
                        alignment: .leading
                    )
                    sessionTableValueCell(
                        String(format: NSLocalizedString("stats.weight_value", comment: ""), average.averageWeight),
                        alignment: .center,
                        foregroundStyle: AppTheme.primaryText
                    )
                    sessionTableValueCell(
                        average.averageReps.appNumberText,
                        alignment: .center
                    )
                    sessionTableValueCell(
                        "\(average.setsCount)",
                        alignment: .trailing
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(index.isMultiple(of: 2) ? AppTheme.surface.opacity(0.35) : AppTheme.surfaceElevated.opacity(0.82))

                if index < averages.count - 1 {
                    Divider()
                        .overlay(AppTheme.stroke)
                }
            }
        }
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.stroke, lineWidth: 1)
        )
    }

    private func sessionTableHeaderCell(_ titleKey: LocalizedStringKey, alignment: Alignment) -> some View {
        Text(titleKey)
            .font(AppTypography.caption(size: 12, weight: .semibold))
            .foregroundStyle(AppTheme.secondaryText)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func sessionTableValueCell(
        _ value: String,
        alignment: Alignment,
        foregroundStyle: Color = AppTheme.secondaryText
    ) -> some View {
        Text(value)
            .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
            .foregroundStyle(foregroundStyle)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var formattedWeeklyStrengthChange: String {
        let percent = weeklyStrengthSummary.percentChange
        if percent > 0 {
            return "+\(percent)%"
        }

        return "\(percent)%"
    }

    private func syncSelectedExercise() {
        selectedExerciseID = defaultExerciseID
    }

    @ViewBuilder
    private func historySyncNoticeView(_ notice: StatisticsHistorySyncNotice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("stats.history_delete_remote_notice")
                .font(AppTypography.caption(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.warning)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = notice.detail, !detail.isEmpty {
                Text(detail)
                    .font(AppTypography.caption(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                retryHistoryRemoteSync()
            } label: {
                Text(
                    LocalizedStringKey(
                        isRetryingHistorySync
                            ? "stats.history_delete_remote_syncing"
                            : "backup.action.sync_remote"
                    )
                )
            }
            .buttonStyle(.plain)
            .font(AppTypography.caption(size: 12, weight: .semibold))
            .foregroundStyle(isRetryingHistorySync ? AppTheme.secondaryText : AppTheme.accent)
            .disabled(isRetryingHistorySync)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(AppTheme.surfaceElevated.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.warning.opacity(0.35), lineWidth: 1)
        )
    }

    private var chartAreaGradient: LinearGradient {
        LinearGradient(
            colors: [
                AppTheme.accent.opacity(0.22),
                AppTheme.accent.opacity(0.08),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var chartLineGradient: LinearGradient {
        LinearGradient(
            colors: [AppTheme.accent, AppTheme.accent.opacity(0.72)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func sessionSubtitle(for session: WorkoutSession) -> String {
        let exerciseCount = session.exercises.count
        let duration = session.endedAt.map { formattedDuration(startedAt: session.startedAt, endedAt: $0) } ?? NSLocalizedString("common.no_data", comment: "")
        return String(format: NSLocalizedString("stats.history_meta", comment: ""), exerciseCount, duration)
    }

    @MainActor
    private func confirmDelete(for session: WorkoutSession) {
        revealedHistoryDeleteSessionID = nil
        pendingDeleteSession = nil

        guard store.deleteHistorySession(id: session.id) else {
            return
        }

        workoutSummaryStore.discardSummary(for: session.id)
        coachStore.rebuildProfileInsightsFromLocalHistory(using: store)
        historySyncNotice = nil

        Task { @MainActor in
            let syncResult = await cloudSyncStore.syncSnapshotAfterLocalMutation(using: store)
            applyHistorySyncResult(syncResult)
        }
    }

    @MainActor
    private func retryHistoryRemoteSync() {
        guard !isRetryingHistorySync else {
            return
        }

        isRetryingHistorySync = true
        Task { @MainActor in
            let syncResult = await cloudSyncStore.syncSnapshotAfterLocalMutation(using: store)
            isRetryingHistorySync = false
            applyHistorySyncResult(syncResult)
        }
    }

    @MainActor
    private func applyHistorySyncResult(_ result: CloudSnapshotMutationSyncResult) {
        guard result.attemptedRemoteSync else {
            historySyncNotice = nil
            return
        }

        historySyncNotice = result.remoteUpdated
            ? nil
            : StatisticsHistorySyncNotice(detail: result.errorDescription)
    }
}

private struct StatisticsHistorySyncNotice: Equatable {
    var detail: String?
}

private struct StatisticsHistoryRow<Destination: View>: View {
    private let deleteRevealWidth: CGFloat = 88

    let session: WorkoutSession
    let isDeleteRevealed: Bool
    let onRevealDelete: () -> Void
    let onHideDelete: () -> Void
    let onDelete: () -> Void
    let destination: Destination

    @State private var settledOffset: CGFloat = 0
    @GestureState private var dragTranslationX: CGFloat = 0

    private var contentOffset: CGFloat {
        max(-deleteRevealWidth, min(0, settledOffset + dragTranslationX))
    }

    private var visibleDeleteWidth: CGFloat {
        max(0, -contentOffset)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            deleteButton

            NavigationLink(destination: destination) {
                rowContent
            }
            .buttonStyle(.plain)
            .disabled(visibleDeleteWidth > 0.5)
            .offset(x: contentOffset)
        }
        .contentShape(Rectangle())
        .clipped()
        .simultaneousGesture(historySwipeGesture)
        .onAppear {
            settledOffset = isDeleteRevealed ? -deleteRevealWidth : 0
        }
        .onChange(of: isDeleteRevealed) { _, newValue in
            let targetOffset = newValue ? -deleteRevealWidth : 0
            guard abs(settledOffset - targetOffset) > 0.5 else {
                return
            }

            withAnimation(.easeOut(duration: 0.18)) {
                settledOffset = targetOffset
            }
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.title)
                    .font(AppTypography.heading(size: 18))
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Text(session.startedAt, format: .dateTime.day().month().year())
                    .font(AppTypography.caption())
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Text(sessionSubtitle)
                .font(AppTypography.body(size: 16, relativeTo: .subheadline))
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            VStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(AppTypography.icon(size: 16, weight: .semibold))

                Text("common.delete")
                    .font(AppTypography.caption(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(width: deleteRevealWidth)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.destructive)
            )
        }
        .buttonStyle(.plain)
        .frame(width: visibleDeleteWidth, alignment: .trailing)
        .clipped()
        .opacity(visibleDeleteWidth > 0 ? 1 : 0)
        .allowsHitTesting(visibleDeleteWidth > 0)
    }

    private var historySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($dragTranslationX) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                let translation = value.translation.width
                let minimumTranslation = -deleteRevealWidth - settledOffset
                let maximumTranslation = -settledOffset
                state = min(max(translation, minimumTranslation), maximumTranslation)
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                let finalOffset = max(-deleteRevealWidth, min(0, settledOffset + value.translation.width))
                let shouldRevealDelete = finalOffset < (-deleteRevealWidth * 0.5)
                let targetOffset = shouldRevealDelete ? -deleteRevealWidth : 0

                withAnimation(.easeOut(duration: 0.18)) {
                    settledOffset = targetOffset
                }

                if shouldRevealDelete {
                    onRevealDelete()
                } else {
                    onHideDelete()
                }
            }
    }

    private var sessionSubtitle: String {
        let exerciseCount = session.exercises.count
        let duration = session.endedAt.map { formattedDuration(startedAt: session.startedAt, endedAt: $0) }
            ?? NSLocalizedString("common.no_data", comment: "")
        return String(format: NSLocalizedString("stats.history_meta", comment: ""), exerciseCount, duration)
    }
}

enum WorkoutSummaryMode {
    case history
    case completion
    case previousWorkout
}

struct WorkoutSummaryView: View {
    @Environment(AppStore.self) private var store
    @Environment(WorkoutSummaryStore.self) private var workoutSummaryStore
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingDeleteConfirmation = false

    let session: WorkoutSession
    var mode: WorkoutSummaryMode = .history
    var onContinue: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onDeleteFromHistory: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if mode == .completion {
                    Text("stats.summary")
                        .font(AppTypography.metric(size: 38))
                } else if mode == .previousWorkout {
                    Text("stats.previous_workout_preview")
                        .font(AppTypography.title(size: 30))
                }

                if mode == .completion {
                    workoutSummaryAICard
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Text(session.title)
                                .font(AppTypography.metric(size: 28))
                            Spacer(minLength: 8)
                            Text(completedAtText)
                                .font(AppTypography.caption())
                                .foregroundStyle(AppTheme.secondaryText)
                                .multilineTextAlignment(.trailing)
                        }
                        summaryRow(title: NSLocalizedString("workout.duration", comment: ""), value: duration)
                        summaryRow(title: NSLocalizedString("stats.avg_set_rest", comment: ""), value: averageSetRest)
                        summaryRow(title: NSLocalizedString("stats.avg_exercise_rest", comment: ""), value: averageExerciseRest)
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    WorkoutSummaryMetricCard(titleKey: "summary.exercises", value: "\(exerciseCount)")
                    WorkoutSummaryMetricCard(titleKey: "summary.total_sets", value: "\(totalSetsCount)")
                    WorkoutSummaryMetricCard(titleKey: "summary.completed_sets", value: "\(completedSetsCount)")
                    WorkoutSummaryMetricCard(titleKey: "summary.total_reps", value: "\(totalRepsCount)")
                }

                if mode == .completion {
                    progressionCard
                }

                ForEach(session.exercises) { exercise in
                    if let item = store.exercise(for: exercise.exerciseID) {
                        AppCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(item.localizedName)
                                    .font(AppTypography.heading(size: 21))

                                ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                                    HStack {
                                        Text(String(format: NSLocalizedString("workout.set_number", comment: ""), index + 1))
                                        Spacer()
                                        Text(String(format: NSLocalizedString("stats.set_value", comment: ""), set.weight, set.reps))
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }

                                    if index < exercise.sets.count - 1 {
                                        Divider()
                                            .overlay(AppTheme.stroke)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .padding(.bottom, mode == .completion || mode == .previousWorkout ? 96 : 0)
        }
        .task(id: session) {
            guard mode == .completion else {
                return
            }

            await workoutSummaryStore.finalizeOrResumeSummary(
                for: session,
                using: store
            )
        }
        .safeAreaInset(edge: .bottom) {
            if mode == .completion {
                continueCTA
            } else if mode == .previousWorkout {
                previousWorkoutCTAs
            }
        }
        .toolbar {
            if mode == .history, onDeleteFromHistory != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .alert("stats.history_delete_confirm_title", isPresented: $isShowingDeleteConfirmation) {
            Button("common.delete", role: .destructive) {
                onDeleteFromHistory?()
                dismiss()
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("stats.history_delete_confirm_message")
        }
        .navigationTitle(mode == .history ? session.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .appScreenBackground()
    }

    @ViewBuilder
    private var workoutSummaryAICard: some View {
        switch workoutSummaryCardState(
            mode: mode,
            sessionID: session.id,
            store: workoutSummaryStore
        ) {
        case .hidden:
            EmptyView()
        case .loading:
            WorkoutSummaryAILoadingCard()
        case .unavailable:
            WorkoutSummaryAIUnavailableCard {
                Task {
                    await workoutSummaryStore.retryFinalSummary(
                        for: session,
                        using: store
                    )
                }
            }
        case .ready(let result):
            WorkoutSummaryAIResultCard(result: result)
        }
    }

    private var continueCTA: some View {
        summaryCTA("action.continue") {
            onContinue?()
        }
    }

    private var startWorkoutCTAButton: some View {
        Button("action.start_workout") {
            onDone?()
        }
        .buttonStyle(AppPrimaryButtonStyle())
    }

    private var previousWorkoutCTAs: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(AppTheme.stroke)

            HStack(spacing: 12) {
                Button("action.cancel") {
                    onCancel?()
                }
                .buttonStyle(AppSecondaryButtonStyle())

                startWorkoutCTAButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
        .background(AppTheme.background)
    }

    private func summaryCTA(_ titleKey: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(AppTheme.stroke)
            Button(titleKey, action: action)
            .buttonStyle(AppPrimaryButtonStyle())
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
        }
        .background(AppTheme.background)
    }

    private var duration: String {
        guard let endedAt = session.endedAt else { return NSLocalizedString("common.no_data", comment: "") }
        return formattedDuration(startedAt: session.startedAt, endedAt: endedAt)
    }

    private var completedAtText: String {
        let date = session.endedAt ?? session.startedAt
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var exerciseCount: Int {
        session.exercises.count
    }

    private var progressionItems: [WorkoutProgressionDisplayItem] {
        let engine = ProgressionEngine()
        return store.progressionInputs(for: session).compactMap { input in
            guard let exercise = store.exercise(for: input.exerciseID) else {
                return nil
            }

            return WorkoutProgressionDisplayItem(
                exerciseID: input.exerciseID,
                exerciseName: exercise.localizedName,
                decision: engine.evaluate(input)
            )
        }
    }

    private var totalSetsCount: Int {
        session.exercises.reduce(0) { $0 + $1.sets.count }
    }

    private var completedSetsCount: Int {
        session.exercises.flatMap(\.sets).filter { $0.completedAt != nil }.count
    }

    private var totalRepsCount: Int {
        session.exercises.flatMap(\.sets).reduce(0) { $0 + $1.reps }
    }

    private var averageSetRest: String {
        let allIntervals = session.exercises.flatMap { exercise in
            let dates = exercise.sets.compactMap(\.completedAt).sorted()
            return zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) }
        }
        guard !allIntervals.isEmpty else { return NSLocalizedString("common.no_data", comment: "") }
        return String(format: NSLocalizedString("common.seconds_value", comment: ""), Int(allIntervals.reduce(0, +) / Double(allIntervals.count)))
    }

    private var averageExerciseRest: String {
        let exerciseEnds = session.exercises.compactMap { $0.sets.compactMap(\.completedAt).max() }.sorted()
        guard exerciseEnds.count > 1 else { return NSLocalizedString("common.no_data", comment: "") }
        let intervals = zip(exerciseEnds.dropFirst(), exerciseEnds).map { $0.timeIntervalSince($1) }
        return String(format: NSLocalizedString("common.seconds_value", comment: ""), Int(intervals.reduce(0, +) / Double(intervals.count)))
    }

    private func summaryRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    @ViewBuilder
    private var progressionCard: some View {
        if !progressionItems.isEmpty {
            AppCard {
                VStack(alignment: .leading, spacing: 14) {
                    AppSectionTitle(titleKey: "progression.card_title")

                    ForEach(Array(progressionItems.enumerated()), id: \.element.id) { index, item in
                        WorkoutProgressionRow(item: item)

                        if index < progressionItems.count - 1 {
                            Divider()
                                .overlay(AppTheme.stroke)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
func workoutSummaryCardState(
    mode: WorkoutSummaryMode,
    sessionID: UUID,
    store: WorkoutSummaryStore
) -> WorkoutSummaryCardState {
    guard mode == .completion else {
        return .hidden
    }

    return store.cardState(for: sessionID)
}

private struct WorkoutSummaryMetricCard: View {
    let titleKey: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titleKey)
                .font(AppTypography.caption(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(AppTypography.metric(size: 26))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.stroke, lineWidth: 1)
        )
    }
}

private struct WorkoutProgressionDisplayItem: Identifiable {
    var id: UUID { exerciseID }
    var exerciseID: UUID
    var exerciseName: String
    var decision: ProgressionDecision
}

private struct WorkoutProgressionRow: View {
    let item: WorkoutProgressionDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(item.exerciseName)
                    .font(AppTypography.body(size: 16, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(2)

                Spacer(minLength: 8)

                WorkoutProgressionActionBadge(action: item.decision.action)
            }

            Text(message)
                .font(AppTypography.body(size: 14, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var message: String {
        switch item.decision.action {
        case .insufficientData:
            return NSLocalizedString("progression.message.insufficient_data", comment: "")
        case .hold:
            if let referenceWeight = item.decision.referenceWeight,
               item.decision.confidence.allowsNumericReference {
                return String(
                    format: NSLocalizedString("progression.message.hold_with_weight", comment: ""),
                    formattedWeight(referenceWeight)
                )
            }
            return NSLocalizedString("progression.message.hold", comment: "")
        case .increaseWeight:
            if let recommendedWeight = item.decision.recommendedWeight {
                return String(
                    format: NSLocalizedString("progression.message.increase_weight", comment: ""),
                    formattedWeight(recommendedWeight)
                )
            }
            return NSLocalizedString("progression.message.hold", comment: "")
        case .deload:
            if let recommendedWeight = item.decision.recommendedWeight {
                return String(
                    format: NSLocalizedString("progression.message.deload", comment: ""),
                    formattedWeight(recommendedWeight)
                )
            }
            return NSLocalizedString("progression.message.hold", comment: "")
        }
    }

    private func formattedWeight(_ weight: Double) -> String {
        String(format: NSLocalizedString("stats.weight_value", comment: ""), weight)
    }
}

private struct WorkoutProgressionActionBadge: View {
    let action: ProgressionAction

    var body: some View {
        Text(label)
            .font(AppTypography.caption(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(backgroundColor, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            )
    }

    private var label: LocalizedStringKey {
        switch action {
        case .insufficientData:
            return "progression.action.insufficient_data"
        case .hold:
            return "progression.action.hold"
        case .increaseWeight:
            return "progression.action.increase_weight"
        case .deload:
            return "progression.action.deload"
        }
    }

    private var backgroundColor: Color {
        switch action {
        case .insufficientData:
            return AppTheme.surface
        case .hold:
            return AppTheme.surfaceElevated
        case .increaseWeight:
            return AppTheme.success.opacity(0.18)
        case .deload:
            return AppTheme.warning.opacity(0.18)
        }
    }

    private var borderColor: Color {
        switch action {
        case .insufficientData:
            return AppTheme.border
        case .hold:
            return AppTheme.stroke
        case .increaseWeight:
            return AppTheme.success.opacity(0.55)
        case .deload:
            return AppTheme.warning.opacity(0.55)
        }
    }
}

private struct WorkoutSummaryAILoadingCard: View {
    var body: some View {
        AppCard {
            HStack(alignment: .center, spacing: 14) {
                ProgressView()
                    .tint(AppTheme.accent)

                VStack(alignment: .leading, spacing: 6) {
                    Label("workout_summary.ai_title", systemImage: "sparkles")
                        .font(AppTypography.caption(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.secondaryText)

                    Text("workout_summary.loading")
                        .font(AppTypography.body(size: 16, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(AppTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

private struct WorkoutSummaryAIResultCard: View {
    let result: WorkoutSummaryJobResult

    private var visibleModelLabel: String? {
        workoutSummaryVisibleModelLabel(result.selectedModel)
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("workout_summary.ai_title", systemImage: "sparkles")
                        .font(AppTypography.caption(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.secondaryText)

                    if let visibleModelLabel {
                        Text(visibleModelLabel)
                            .font(AppTypography.caption(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText.opacity(0.85))
                    }
                }

                Text(result.headline)
                    .font(AppTypography.heading(size: 23))
                    .foregroundStyle(AppTheme.primaryText)

                Text(result.summary)
                    .font(AppTypography.body(size: 16, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(AppTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if !result.highlights.isEmpty {
                    workoutSummarySection(
                        titleKey: "workout_summary.highlights_title",
                        items: result.highlights
                    )
                }

                if !result.nextWorkoutFocus.isEmpty {
                    workoutSummarySection(
                        titleKey: "workout_summary.next_focus_title",
                        items: result.nextWorkoutFocus
                    )
                }
            }
        }
    }

    private func workoutSummarySection(
        titleKey: LocalizedStringKey,
        items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titleKey)
                .font(AppTypography.caption(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(AppTheme.accent)
                            .frame(width: 6, height: 6)
                            .padding(.top, 7)

                        Text(item)
                            .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                            .foregroundStyle(AppTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private func workoutSummaryVisibleModelLabel(_ selectedModel: String?) -> String? {
    guard let selectedModel = selectedModel?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !selectedModel.isEmpty else {
        return nil
    }

    if selectedModel.hasPrefix("@cf/") {
        return String(selectedModel.dropFirst(4))
    }

    return selectedModel
}

private struct WorkoutSummaryAIUnavailableCard: View {
    let retryAction: () -> Void

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("workout_summary.ai_title", systemImage: "sparkles")
                    .font(AppTypography.caption(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)

                Text("workout_summary.unavailable_title")
                    .font(AppTypography.heading(size: 23))
                    .foregroundStyle(AppTheme.primaryText)

                Text("workout_summary.unavailable_message")
                    .font(AppTypography.body(size: 16, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button("workout_summary.retry", action: retryAction)
                    .buttonStyle(AppSecondaryButtonStyle())
            }
        }
    }
}

private func formattedDuration(startedAt: Date, endedAt: Date) -> String {
    let interval = endedAt.timeIntervalSince(startedAt)
    if interval >= 3600 {
        return DateComponentsFormatter.workoutDurationLong.string(from: startedAt, to: endedAt) ?? "00:00"
    }
    return DateComponentsFormatter.workoutDurationShort.string(from: startedAt, to: endedAt) ?? "00:00"
}
