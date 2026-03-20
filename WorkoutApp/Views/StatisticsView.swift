import Charts
import SwiftUI

struct StatisticsView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedExerciseID: UUID?

    var body: some View {
        List {
            Section(NSLocalizedString("stats.exercise_picker", comment: "")) {
                Picker(NSLocalizedString("stats.exercise", comment: ""), selection: $selectedExerciseID) {
                    Text("common.select").tag(UUID?.none)
                    ForEach(store.exercises) { exercise in
                        Text(exercise.name).tag(UUID?.some(exercise.id))
                    }
                }
            }

            if let selectedExerciseID,
               let exercise = store.exercise(for: selectedExerciseID) {
                let points = store.chartPoints(for: selectedExerciseID)
                Section(exercise.name) {
                    if points.isEmpty {
                        Text("stats.empty")
                            .foregroundStyle(.secondary)
                    } else {
                        Chart(points, id: \.0) { point in
                            LineMark(
                                x: .value(NSLocalizedString("stats.chart.date", comment: ""), point.0),
                                y: .value(NSLocalizedString("stats.chart.weight", comment: ""), point.1)
                            )
                            PointMark(
                                x: .value(NSLocalizedString("stats.chart.date", comment: ""), point.0),
                                y: .value(NSLocalizedString("stats.chart.weight", comment: ""), point.1)
                            )
                        }
                        .frame(height: 220)

                        ForEach(points, id: \.0) { point in
                            HStack {
                                Text(point.0, style: .date)
                                Spacer()
                                Text(String(format: NSLocalizedString("stats.weight_value", comment: ""), point.1))
                            }
                        }
                    }
                }
            }

            Section(NSLocalizedString("stats.history", comment: "")) {
                if store.history.isEmpty {
                    Text("stats.no_workouts")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.history) { session in
                        NavigationLink(destination: WorkoutSummaryView(session: session)) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.title)
                                    .font(.headline)
                                Text(session.startedAt, style: .date)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("tab.statistics")
    }
}

struct WorkoutSummaryView: View {
    @Environment(AppStore.self) private var store
    let session: WorkoutSession

    var body: some View {
        List {
            Section(NSLocalizedString("stats.summary", comment: "")) {
                row(title: NSLocalizedString("workout.duration", comment: ""), value: duration)
                row(title: NSLocalizedString("stats.avg_set_rest", comment: ""), value: averageSetRest)
                row(title: NSLocalizedString("stats.avg_exercise_rest", comment: ""), value: averageExerciseRest)
            }

            ForEach(session.exercises) { exercise in
                if let item = store.exercise(for: exercise.exerciseID) {
                    Section(item.name) {
                        ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                            VStack(alignment: .leading) {
                                Text(String(format: NSLocalizedString("workout.set_number", comment: ""), index + 1))
                                Text(String(format: NSLocalizedString("stats.set_value", comment: ""), set.weight, set.reps))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(session.title)
    }

    private var duration: String {
        guard let endedAt = session.endedAt else { return NSLocalizedString("common.no_data", comment: "") }
        return DateComponentsFormatter.workout.string(from: session.startedAt, to: endedAt) ?? "00:00"
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

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
