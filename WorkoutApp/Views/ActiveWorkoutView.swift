import SwiftUI

struct ActiveWorkoutView: View {
    @Environment(AppStore.self) private var store

    @State private var now = Date()
    @State private var scrollOffset: CGFloat = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let session = store.activeSession {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        scrollOffsetReader
                        expandedHeader(for: session)

                        LazyVStack(spacing: 16) {
                            ForEach(Array(session.exercises.enumerated()), id: \.element.id) { exerciseIndex, item in
                                if let exercise = store.exercise(for: item.exerciseID) {
                                    AppCard {
                                        VStack(alignment: .leading, spacing: 16) {
                                            HStack(alignment: .top, spacing: 12) {
                                                VStack(alignment: .leading, spacing: 8) {
                                                    Text(exercise.name)
                                                        .font(.title3.weight(.heavy))
                                                    if item.groupKind == .superset {
                                                        Label("label.superset", systemImage: "bolt.fill")
                                                            .font(.caption.weight(.semibold))
                                                            .padding(.horizontal, 10)
                                                            .padding(.vertical, 6)
                                                            .background(AppTheme.accentMuted, in: Capsule())
                                                    }
                                                }
                                                Spacer()
                                            }

                                            ForEach(Array(item.sets.enumerated()), id: \.element.id) { setIndex, set in
                                                WorkoutSetRow(
                                                    exerciseIndex: exerciseIndex,
                                                    setIndex: setIndex,
                                                    set: set
                                                )
                                            }

                                            Button {
                                                store.updateActiveSession { current in
                                                    current.exercises[exerciseIndex].sets.append(WorkoutSetLog(reps: 10, weight: 0))
                                                }
                                            } label: {
                                                Label("action.add_set", systemImage: "plus")
                                            }
                                            .buttonStyle(AppSecondaryButtonStyle())

                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(restSummary(for: item))
                                                if let previousSetRest = previousSetRest(for: item) {
                                                    Text(String(format: NSLocalizedString("workout.previous_rest", comment: ""), previousSetRest))
                                                }
                                            }
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.secondaryText)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .coordinateSpace(name: "workout-scroll")
                .overlay(alignment: .top) {
                    if scrollOffset < -70 {
                        collapsedHeader(for: session)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    finishWorkoutCTA
                }
                .navigationTitle(session.title)
                .navigationBarTitleDisplayMode(.inline)
                .onPreferenceChange(WorkoutScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
                .onReceive(timer) { now = $0 }
                .sheet(item: Binding(get: { store.lastFinishedSession }, set: { _ in store.dismissLastFinishedSession() })) { session in
                    NavigationStack { WorkoutSummaryView(session: session) }
                }
                .appScreenBackground()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("tab.workout")
                            .font(.system(size: 38, weight: .black, design: .rounded))

                        AppCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("workout.empty_title")
                                    .font(.title2.weight(.heavy))
                                Text("workout.empty_description")
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                    }
                    .padding(20)
                }
                .navigationTitle("tab.workout")
                .navigationBarTitleDisplayMode(.inline)
                .appScreenBackground()
            }
        }
    }

    private var finishWorkoutCTA: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(AppTheme.stroke)
            Button(role: .destructive) {
                store.finishActiveWorkout()
            } label: {
                Label("action.finish_workout", systemImage: "stop.fill")
            }
            .buttonStyle(AppOutlinedButtonStyle())
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial.opacity(0.2))
        }
    }

    private var scrollOffsetReader: some View {
        GeometryReader { geometry in
            Color.clear
                .preference(key: WorkoutScrollOffsetPreferenceKey.self, value: geometry.frame(in: .named("workout-scroll")).minY)
        }
        .frame(height: 0)
    }

    private func expandedHeader(for session: WorkoutSession) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 18) {
                Text(session.title)
                    .font(.system(size: 30, weight: .black, design: .rounded))

                HStack(spacing: 12) {
                    WorkoutMetricPanel(
                        title: NSLocalizedString("workout.duration", comment: ""),
                        value: durationValue(for: session)
                    )

                    WorkoutMetricPanel(
                        title: NSLocalizedString("workout.rest_live", comment: ""),
                        value: liveRestValue(for: session)
                    )
                }
            }
        }
    }

    private func collapsedHeader(for session: WorkoutSession) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("workout.rest_live")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                Text(liveRestValue(for: session))
                    .font(.headline.weight(.heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("workout.duration")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                Text(durationValue(for: session))
                    .font(.headline.weight(.heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func liveRestValue(for session: WorkoutSession) -> String {
        let lastDate = session.exercises.flatMap(\.sets).compactMap(\.completedAt).max()
        guard let lastDate else { return NSLocalizedString("common.no_data", comment: "") }
        return DateComponentsFormatter.workoutRest.string(from: lastDate, to: now) ?? "00:00"
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
        return DateComponentsFormatter.workoutRest.string(from: previous, to: last)
    }

    private func durationValue(for session: WorkoutSession) -> String {
        let interval = now.timeIntervalSince(session.startedAt)
        if interval >= 3600 {
            return DateComponentsFormatter.workoutDurationLong.string(from: session.startedAt, to: now) ?? "00:00"
        }
        return DateComponentsFormatter.workoutDurationShort.string(from: session.startedAt, to: now) ?? "00:00"
    }
}

struct WorkoutSetRow: View {
    @Environment(AppStore.self) private var store
    @FocusState private var isWeightFieldFocused: Bool

    let exerciseIndex: Int
    let setIndex: Int
    let set: WorkoutSetLog

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(format: NSLocalizedString("workout.set_number", comment: ""), setIndex + 1))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if set.completedAt != nil {
                    Label("workout.done_badge", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppTheme.accent)
                }
            }

            Stepper(value: Binding(
                get: { Int(set.reps) },
                set: { newValue in updateSet { $0.reps = newValue } }
            ), in: 1...50) {
                Text(String(format: NSLocalizedString("workout.reps", comment: ""), set.reps))
                    .foregroundStyle(AppTheme.primaryText)
            }
            .tint(AppTheme.accent)

            HStack(spacing: 12) {
                Text("workout.weight")
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                TextField("0", value: Binding(
                    get: { set.weight },
                    set: { newValue in updateSet { $0.weight = newValue } }
                ), format: .number)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .focused($isWeightFieldFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: 110)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.stroke, lineWidth: 1)
                )
            }

            HStack(spacing: 12) {
                Button {
                    updateSet { current in
                        current.completedAt = current.completedAt == nil ? .now : nil
                    }
                } label: {
                    Label(set.completedAt == nil ? "action.mark_done" : "action.unmark_done", systemImage: set.completedAt == nil ? "checkmark.circle" : "checkmark.circle.fill")
                }
                .buttonStyle(AppSecondaryButtonStyle())

                Button(role: .destructive) {
                    store.removeSetFromActiveWorkout(exerciseIndex: exerciseIndex, setIndex: setIndex)
                } label: {
                    Label("common.delete", systemImage: "trash")
                }
                .buttonStyle(AppSecondaryButtonStyle())
            }
        }
        .padding(16)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.stroke, lineWidth: 1)
        )
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("action.done") {
                    isWeightFieldFocused = false
                }
            }
        }
    }

    private func updateSet(_ change: (inout WorkoutSetLog) -> Void) {
        store.updateActiveSession { session in
            change(&session.exercises[exerciseIndex].sets[setIndex])
        }
    }
}

private struct WorkoutMetricPanel: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.stroke, lineWidth: 1)
        )
    }
}

private struct WorkoutScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension DateComponentsFormatter {
    static let workoutDurationShort: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    static let workoutDurationLong: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    static let workoutRest: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}
