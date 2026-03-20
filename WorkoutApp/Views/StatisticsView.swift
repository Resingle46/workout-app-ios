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

                AppCard {
                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionTitle(titleKey: "stats.exercise_picker")
                        Picker(NSLocalizedString("stats.exercise", comment: ""), selection: $selectedExerciseID) {
                            Text("common.select").tag(UUID?.none)
                            ForEach(store.exercises) { exercise in
                                Text(exercise.name).tag(UUID?.some(exercise.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                if !recentExercises.isEmpty {
                    AppCard {
                        VStack(alignment: .leading, spacing: 14) {
                            AppSectionTitle(titleKey: "stats.recent_exercises")

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

                if let selectedExerciseID,
                   let exercise = store.exercise(for: selectedExerciseID) {
                    exerciseAnalyticsCard(for: exercise)
                } else {
                    AppCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("stats.pick_exercise_title")
                                .font(.title3.weight(.heavy))
                            Text("stats.pick_exercise_description")
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }

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

    private func exerciseAnalyticsCard(for exercise: Exercise) -> some View {
        let points = store.chartPoints(for: exercise.id)

        return AppCard {
            VStack(alignment: .leading, spacing: 16) {
                Text(exercise.name)
                    .font(.title3.weight(.heavy))

                if points.isEmpty {
                    Text("stats.empty")
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    Chart(points, id: \.0) { point in
                        AreaMark(
                            x: .value(NSLocalizedString("stats.chart.date", comment: ""), point.0),
                            y: .value(NSLocalizedString("stats.chart.weight", comment: ""), point.1)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AppTheme.accent.opacity(0.35), AppTheme.accent.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value(NSLocalizedString("stats.chart.date", comment: ""), point.0),
                            y: .value(NSLocalizedString("stats.chart.weight", comment: ""), point.1)
                        )
                        .foregroundStyle(AppTheme.accent)
                        .interpolationMethod(.catmullRom)

                        PointMark(
                            x: .value(NSLocalizedString("stats.chart.date", comment: ""), point.0),
                            y: .value(NSLocalizedString("stats.chart.weight", comment: ""), point.1)
                        )
                        .foregroundStyle(.white)
                    }
                    .frame(height: 220)

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

    private func sessionSubtitle(for session: WorkoutSession) -> String {
        let exerciseCount = session.exercises.count
        let duration = session.endedAt.map { formattedDuration(startedAt: session.startedAt, endedAt: $0) } ?? NSLocalizedString("common.no_data", comment: "")
        return String(format: NSLocalizedString("stats.history_meta", comment: ""), exerciseCount, duration)
    }

    private func setSummary(for sets: [WorkoutSetLog]) -> String {
        sets.map { String(format: NSLocalizedString("stats.set_value", comment: ""), $0.weight, $0.reps) }
            .joined(separator: "  •  ")
    }
}

struct WorkoutSummaryView: View {
    @Environment(AppStore.self) private var store

    let session: WorkoutSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AppCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(session.title)
                            .font(.system(size: 28, weight: .black, design: .rounded))
                        summaryRow(title: NSLocalizedString("workout.duration", comment: ""), value: duration)
                        summaryRow(title: NSLocalizedString("stats.avg_set_rest", comment: ""), value: averageSetRest)
                        summaryRow(title: NSLocalizedString("stats.avg_exercise_rest", comment: ""), value: averageExerciseRest)
                    }
                }

                ForEach(session.exercises) { exercise in
                    if let item = store.exercise(for: exercise.exerciseID) {
                        AppCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(item.name)
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
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .appScreenBackground()
    }

    private var duration: String {
        guard let endedAt = session.endedAt else { return NSLocalizedString("common.no_data", comment: "") }
        return formattedDuration(startedAt: session.startedAt, endedAt: endedAt)
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

    private func formattedDuration(startedAt: Date, endedAt: Date) -> String {
        let interval = endedAt.timeIntervalSince(startedAt)
        if interval >= 3600 {
            return DateComponentsFormatter.workoutDurationLong.string(from: startedAt, to: endedAt) ?? "00:00"
        }
        return DateComponentsFormatter.workoutDurationShort.string(from: startedAt, to: endedAt) ?? "00:00"
    }
}
