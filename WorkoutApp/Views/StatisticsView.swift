import Charts
import SwiftUI

struct StatisticsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appBottomRailInset) private var bottomRailInset
    @State private var selectedExerciseID: UUID?

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

                        if store.history.isEmpty {
                            Text("stats.no_workouts")
                                .foregroundStyle(AppTheme.secondaryText)
                        } else {
                            ForEach(store.history) { session in
                                NavigationLink(destination: WorkoutSummaryView(session: session)) {
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

                                        Text(sessionSubtitle(for: session))
                                            .font(AppTypography.body(size: 16, relativeTo: .subheadline))
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)

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
}

enum WorkoutSummaryMode {
    case history
    case completion
    case previousWorkout
}

struct WorkoutSummaryView: View {
    @Environment(AppStore.self) private var store

    let session: WorkoutSession
    var mode: WorkoutSummaryMode = .history
    var onContinue: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil

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
        .safeAreaInset(edge: .bottom) {
            if mode == .completion {
                continueCTA
            } else if mode == .previousWorkout {
                startWorkoutCTA
            }
        }
        .navigationTitle(mode == .history ? session.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .appScreenBackground()
    }

    private var continueCTA: some View {
        summaryCTA("action.continue") {
            onContinue?()
        }
    }

    private var startWorkoutCTA: some View {
        summaryCTA("action.start_workout") {
            onDone?()
        }
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

private func formattedDuration(startedAt: Date, endedAt: Date) -> String {
    let interval = endedAt.timeIntervalSince(startedAt)
    if interval >= 3600 {
        return DateComponentsFormatter.workoutDurationLong.string(from: startedAt, to: endedAt) ?? "00:00"
    }
    return DateComponentsFormatter.workoutDurationShort.string(from: startedAt, to: endedAt) ?? "00:00"
}
