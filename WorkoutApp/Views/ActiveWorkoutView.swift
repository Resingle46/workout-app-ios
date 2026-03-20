import SwiftUI

struct ActiveWorkoutView: View {
    @Environment(AppStore.self) private var store
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let session = store.activeSession {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            MetricCard(title: NSLocalizedString("workout.duration", comment: ""), value: DateComponentsFormatter.workout.string(from: session.startedAt, to: now) ?? "00:00")
                            MetricCard(title: NSLocalizedString("workout.rest_live", comment: ""), value: liveRestValue(for: session))
                        }
                        .padding(.vertical, 4)

                        Button(role: .destructive) {
                            store.finishActiveWorkout()
                        } label: {
                            Label("action.finish_workout", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }

                    ForEach(Array(session.exercises.enumerated()), id: \.element.id) { exerciseIndex, item in
                        if let exercise = store.exercise(for: item.exerciseID) {
                            Section {
                                ForEach(Array(item.sets.enumerated()), id: \.element.id) { setIndex, set in
                                    WorkoutSetRow(
                                        exerciseIndex: exerciseIndex,
                                        setIndex: setIndex,
                                        set: set
                                    )
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            store.removeSetFromActiveWorkout(exerciseIndex: exerciseIndex, setIndex: setIndex)
                                        } label: {
                                            Label(NSLocalizedString("common.delete", comment: ""), systemImage: "trash")
                                        }
                                    }
                                }

                                Button {
                                    store.updateActiveSession { current in
                                        current.exercises[exerciseIndex].sets.append(WorkoutSetLog(reps: 10, weight: 0))
                                    }
                                } label: {
                                    Label("action.add_set", systemImage: "plus")
                                }
                            } header: {
                                HStack {
                                    Text(exercise.name)
                                    if item.groupKind == .superset {
                                        Text("label.superset")
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.15), in: Capsule())
                                    }
                                }
                            } footer: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(restSummary(for: item))
                                    if let previousSetRest = previousSetRest(for: item) {
                                        Text(String(format: NSLocalizedString("workout.previous_rest", comment: ""), previousSetRest))
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle(session.title)
                .onReceive(timer) { now = $0 }
            } else {
                ContentUnavailableView(
                    NSLocalizedString("workout.empty_title", comment: ""),
                    systemImage: "figure.strengthtraining.functional",
                    description: Text("workout.empty_description")
                )
            }
        }
        .navigationTitle("tab.workout")
        .sheet(item: Binding(get: { store.lastFinishedSession }, set: { store.lastFinishedSession = $0 })) { session in
            NavigationStack { WorkoutSummaryView(session: session) }
        }
    }

    private func liveRestValue(for session: WorkoutSession) -> String {
        let lastDate = session.exercises.flatMap(\.sets).compactMap(\.completedAt).max()
        guard let lastDate else { return NSLocalizedString("common.no_data", comment: "") }
        return DateComponentsFormatter.workout.string(from: lastDate, to: now) ?? "00:00"
    }

    private func restSummary(for exercise: WorkoutExerciseLog) -> String {
        let completed = exercise.sets.compactMap(\.completedAt).sorted()
        guard completed.count > 1 else { return NSLocalizedString("workout.no_rest_data", comment: "") }
        let diffs = zip(completed.dropFirst(), completed).map { $0.timeIntervalSince($1) }
        let avg = diffs.reduce(0, +) / Double(diffs.count)
        return String(format: NSLocalizedString("workout.avg_rest", comment: ""), Int(avg))
    }

    private func previousSetRest(for exercise: WorkoutExerciseLog) -> String? {
        let completed = exercise.sets.compactMap(\.completedAt).sorted()
        guard completed.count > 1,
              let last = completed.last,
              let previous = completed.dropLast().last else { return nil }
        return DateComponentsFormatter.workout.string(from: previous, to: last) ?? nil
    }
}

struct WorkoutSetRow: View {
    @Environment(AppStore.self) private var store
    let exerciseIndex: Int
    let setIndex: Int
    let set: WorkoutSetLog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: NSLocalizedString("workout.set_number", comment: ""), setIndex + 1))
                .font(.subheadline.weight(.semibold))

            HStack {
                Stepper(value: Binding(
                    get: { Int(set.reps) },
                    set: { newValue in updateSet { $0.reps = newValue } }
                ), in: 1...50) {
                    Text(String(format: NSLocalizedString("workout.reps", comment: ""), set.reps))
                }
            }

            HStack {
                Text(NSLocalizedString("workout.weight", comment: ""))
                Spacer()
                TextField("0", value: Binding(
                    get: { set.weight },
                    set: { newValue in updateSet { $0.weight = newValue } }
                ), format: .number)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .frame(width: 80)
            }

            Button {
                updateSet { current in
                    current.completedAt = current.completedAt == nil ? .now : nil
                }
            } label: {
                Label(set.completedAt == nil ? "action.mark_done" : "action.unmark_done", systemImage: set.completedAt == nil ? "checkmark.circle" : "checkmark.circle.fill")
            }
            .buttonStyle(.bordered)
            .tint(set.completedAt == nil ? .blue : .green)
        }
        .padding(.vertical, 4)
    }

    private func updateSet(_ change: (inout WorkoutSetLog) -> Void) {
        store.updateActiveSession { session in
            change(&session.exercises[exerciseIndex].sets[setIndex])
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension DateComponentsFormatter {
    static let workout: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}
