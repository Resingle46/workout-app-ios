import Charts
import SwiftUI

struct StatisticsView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedExerciseID: UUID?

    private var recentExercises: [RecentWorkoutExerciseSummary] {
        store.recentExercisesFromLastWorkout()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("tab.statistics")
                    .font(.system(size: 38, weight: .black, design: .rounded))

                if !recentExercises.isEmpty {
                    AppCard {
                        VStack(alignment: .leading, spacing: 14) {
                            AppSectionTitle(titleKey: "stats.last_workout")

                            ForEach(recentExercises) { exercise in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(exercise.exerciseName)
                                            .font(.headline.weight(.heavy))
                                        Spacer()
                                        Text(exercise.performedAt, format: .dateTime.day().month().year())
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }

                                    Text(setSummary(for: exercise.sets))
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }

                                if exercise.id != (recentExercises.last?.id ?? exercise.id) {
                                    Divider()
                                        .overlay(AppTheme.stroke)
                                }
                            }
                        }
                    }
                }

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
                    }
                }

                exerciseChartSection

                AppCard {
                    VStack(alignment: .leading, spacing: 14) {
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
                                                .font(.headline.weight(.heavy))
                                                .foregroundStyle(AppTheme.primaryText)
                                            Spacer()
                                            Text(session.startedAt, format: .dateTime.day().month().year())
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(AppTheme.secondaryText)
                                        }

                                        Text(sessionSubtitle(for: session))
                                            .font(.subheadline)
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
            .padding(20)
        }
        .onAppear {
            if selectedExerciseID == nil {
                selectedExerciseID = recentExercises.first?.exerciseID
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .appScreenBackground()
    }

    @ViewBuilder
    private var exerciseChartSection: some View {
        if let selectedExerciseID,
           let exercise = store.exercise(for: selectedExerciseID) {
            exerciseChartCard(for: exercise)
        } else {
            AppCard {
                VStack(alignment: .leading, spacing: 10) {
                    AppSectionTitle(titleKey: "stats.exercise_chart")
                    Text("stats.pick_exercise_title")
                        .font(.title3.weight(.heavy))
                    Text("stats.pick_exercise_description")
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        }
    }

    private func exerciseChartCard(for exercise: Exercise) -> some View {
        let points = store.chartPoints(for: exercise.id)
        let latestPoint = points.last

        return AppCard {
            VStack(alignment: .leading, spacing: 16) {
                AppSectionTitle(titleKey: "stats.exercise_chart")
                Text(exercise.localizedName)
                    .font(.title3.weight(.heavy))

                if points.isEmpty {
                    Text("stats.empty")
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    Chart {
                        ForEach(points, id: \.0) { point in
                            AreaMark(
                                x: .value(NSLocalizedString("stats.chart.date", comment: ""), point.0),
                                yStart: .value(NSLocalizedString("stats.chart.weight", comment: ""), 0),
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
                            .symbolSize(70)
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
                            .background(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.03), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(points, id: \.0) { point in
                            HStack {
                                Text(point.0, format: .dateTime.day().month().year())
                                Spacer()
                                Text(String(format: NSLocalizedString("stats.weight_value", comment: ""), point.1))
                            }
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private var chartAreaGradient: LinearGradient {
        LinearGradient(
            colors: [
                AppTheme.neonViolet.opacity(0.34),
                AppTheme.neonBlue.opacity(0.24),
                AppTheme.neonCyan.opacity(0.06)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var chartLineGradient: LinearGradient {
        LinearGradient(
            colors: [AppTheme.neonViolet, AppTheme.neonBlue, AppTheme.neonCyan],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func sessionSubtitle(for session: WorkoutSession) -> String {
        let exerciseCount = session.exercises.count
        let duration = session.endedAt.map { formattedDuration(startedAt: session.startedAt, endedAt: $0) } ?? NSLocalizedString("common.no_data", comment: "")
        return String(format: NSLocalizedString("stats.history_meta", comment: ""), exerciseCount, duration)
    }

    private func setSummary(for sets: [WorkoutSetLog]) -> String {
        sets.map { String(format: NSLocalizedString("stats.set_value", comment: ""), $0.weight, $0.reps) }
            .joined(separator: "  |  ")
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
                        .font(.system(size: 38, weight: .black, design: .rounded))
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Text(session.title)
                                .font(.system(size: 28, weight: .black, design: .rounded))
                            Spacer(minLength: 8)
                            Text(completedAtText)
                                .font(.caption.weight(.medium))
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
                                    .font(.title3.weight(.heavy))

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
            .padding(.bottom, mode == .completion ? 96 : 0)
        }
        .safeAreaInset(edge: .bottom) {
            if mode == .completion {
                continueCTA
            }
        }
        .navigationTitle(mode == .history ? session.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode == .previousWorkout {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("action.done") {
                        onDone?()
                    }
                }
            }
        }
        .appScreenBackground()
    }

    private var continueCTA: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(AppTheme.stroke)
            Button("action.continue") {
                onContinue?()
            }
            .buttonStyle(AppPrimaryButtonStyle())
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial.opacity(0.2))
        }
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.system(size: 26, weight: .black, design: .rounded))
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
