import SwiftUI

struct ActiveWorkoutView: View {
    @Environment(AppStore.self) private var store

    @State private var presentedSummary: PresentedWorkoutSummary?
    @FocusState private var focusedField: WorkoutSetField?

    var body: some View {
        Group {
            if let session = store.activeSession {
                activeSessionContent(for: session)
            } else {
                emptyStateContent
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("action.done") {
                    focusedField = nil
                }
            }
        }
        .onAppear {
            if store.activeSession == nil {
                presentedSummary = nil
            }
        }
        .onChange(of: store.activeSession?.id) { _ in
            guard store.activeSession != nil, let session = store.lastFinishedSession else { return }
            presentedSummary = PresentedWorkoutSummary(session: session, mode: .previousWorkout)
        }
        .onChange(of: store.lastFinishedSession?.id) { _ in
            guard store.activeSession == nil, let session = store.lastFinishedSession else { return }
            presentedSummary = PresentedWorkoutSummary(session: session, mode: .completion)
        }
        .fullScreenCover(item: $presentedSummary) { presented in
            NavigationStack {
                WorkoutSummaryView(
                    session: presented.session,
                    mode: presented.mode,
                    onContinue: {
                        presentedSummary = nil
                        store.selectedTab = .statistics
                    },
                    onDone: {
                        presentedSummary = nil
                    }
                )
            }
            .interactiveDismissDisabled()
        }
    }

    private var emptyStateContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AppPageHeaderModule(titleKey: "header.workout.title", subtitleKey: "header.workout.subtitle")

                AppCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("workout.empty_title")
                            .font(AppTypography.heading(size: 24))
                        Text("workout.empty_description")
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 24)
        }
        .appScreenBackground()
    }

    private func activeSessionContent(for session: WorkoutSession) -> some View {
        let currentSetPosition = currentSetPosition(in: session)

        return ScrollViewReader { proxy in
            ScrollView {
                activeSessionScrollContent(
                    for: session,
                    currentSetPosition: currentSetPosition,
                    onMarkedDone: { scrollToCurrentSet(using: proxy) }
                )
            }
            .appScreenBackground()
        }
    }

    private func activeSessionScrollContent(
        for session: WorkoutSession,
        currentSetPosition: CurrentWorkoutSetPosition?,
        onMarkedDone: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            AppPageHeaderModule(titleKey: "header.workout.title", subtitleKey: "header.workout.subtitle")
            expandedHeader(for: session)
            exerciseList(for: session, currentSetPosition: currentSetPosition, onMarkedDone: onMarkedDone)
            finishWorkoutCTA
        }
        .padding(.horizontal, 20)
        .padding(.top, 0)
        .padding(.bottom, 32)
    }

    private func exerciseList(
        for session: WorkoutSession,
        currentSetPosition: CurrentWorkoutSetPosition?,
        onMarkedDone: @escaping () -> Void
    ) -> some View {
        LazyVStack(spacing: 16) {
            ForEach(Array(session.exercises.enumerated()), id: \.element.id) { exerciseIndex, item in
                if let exercise = store.exercise(for: item.exerciseID) {
                    exerciseCard(
                        for: exercise,
                        item: item,
                        session: session,
                        exerciseIndex: exerciseIndex,
                        currentSetPosition: currentSetPosition,
                        onMarkedDone: onMarkedDone
                    )
                }
            }
        }
    }

    private func exerciseCard(
        for exercise: Exercise,
        item: WorkoutExerciseLog,
        session: WorkoutSession,
        exerciseIndex: Int,
        currentSetPosition: CurrentWorkoutSetPosition?,
        onMarkedDone: @escaping () -> Void
    ) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(exercise.localizedName)
                            .font(AppTypography.heading(size: 21))

                        WorkoutExerciseInfoRow(
                            targetWeightText: targetWeightText(for: item, session: session),
                            previousWeightText: previousWeightText(for: item)
                        )

                        if item.groupKind == .superset {
                            Label("label.superset", systemImage: "bolt.fill")
                                .font(AppTypography.caption(size: 13, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(AppTheme.accentMuted, in: Capsule())
                        }
                    }

                    Spacer()
                }

                setRows(
                    for: item,
                    exerciseIndex: exerciseIndex,
                    currentSetPosition: currentSetPosition,
                    onMarkedDone: onMarkedDone
                )

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
                .font(AppTypography.caption(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private func setRows(
        for item: WorkoutExerciseLog,
        exerciseIndex: Int,
        currentSetPosition: CurrentWorkoutSetPosition?,
        onMarkedDone: @escaping () -> Void
    ) -> some View {
        ForEach(Array(item.sets.enumerated()), id: \.element.id) { setIndex, set in
            WorkoutSetRow(
                exerciseIndex: exerciseIndex,
                setIndex: setIndex,
                set: set,
                isCurrent: isCurrentSet(
                    currentSetPosition,
                    exerciseIndex: exerciseIndex,
                    setIndex: setIndex
                ),
                focusedField: $focusedField,
                onMarkedDone: onMarkedDone
            )
            .id(CurrentWorkoutSetPosition(exerciseIndex: exerciseIndex, setIndex: setIndex))
        }
    }

    private var finishWorkoutCTA: some View {
        Button(role: .destructive) {
            store.finishActiveWorkout()
        } label: {
            Label("action.finish_workout", systemImage: "stop.fill")
        }
        .buttonStyle(WorkoutFinishButtonStyle())
        .padding(.top, 8)
    }

    private func expandedHeader(for session: WorkoutSession) -> some View {
        let lastCompletedSetDate = lastCompletedSetDate(in: session)

        return WorkoutHeroCard {
            VStack(alignment: .leading, spacing: 18) {
                Text(session.title)
                    .font(AppTypography.title(size: 30))

                WorkoutExerciseProgressCard(progress: workoutProgress(for: session))

                HStack(spacing: 12) {
                    WorkoutMetricPanel(
                        title: NSLocalizedString("workout.duration", comment: "")
                    ) {
                        WorkoutDurationText(startedAt: session.startedAt)
                    }

                    WorkoutMetricPanel(
                        title: NSLocalizedString("workout.rest_live", comment: "")
                    ) {
                        WorkoutLiveRestText(lastCompletedSetDate: lastCompletedSetDate)
                    }
                }
            }
        }
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

    private func lastCompletedSetDate(in session: WorkoutSession) -> Date? {
        session.exercises
            .flatMap(\.sets)
            .compactMap(\.completedAt)
            .max()
    }

    private func workoutProgress(for session: WorkoutSession) -> WorkoutExerciseProgress {
        let totalExercises = max(session.exercises.count, 1)
        let completedExercises = session.exercises.filter { exercise in
            !exercise.sets.isEmpty && exercise.sets.allSatisfy { $0.completedAt != nil }
        }.count
        let remainingExercises = max(session.exercises.count - completedExercises, 0)
        let currentStep = session.exercises.isEmpty ? 0 : min(completedExercises + (remainingExercises > 0 ? 1 : 0), totalExercises)

        return WorkoutExerciseProgress(
            total: totalExercises,
            completed: completedExercises,
            remaining: remainingExercises,
            currentStep: currentStep
        )
    }

    private func targetWeightText(for item: WorkoutExerciseLog, session: WorkoutSession) -> String {
        guard let weight = store.targetWeight(workoutTemplateID: session.workoutTemplateID, templateExerciseID: item.templateExerciseID) else {
            return NSLocalizedString("common.no_data", comment: "")
        }
        return String(format: NSLocalizedString("stats.weight_value", comment: ""), weight)
    }

    private func previousWeightText(for item: WorkoutExerciseLog) -> String {
        guard let weight = store.lastUsedWeight(for: item.exerciseID) else {
            return NSLocalizedString("common.no_data", comment: "")
        }
        return String(format: NSLocalizedString("stats.weight_value", comment: ""), weight)
    }

    private func isCurrentSet(
        _ currentSetPosition: CurrentWorkoutSetPosition?,
        exerciseIndex: Int,
        setIndex: Int
    ) -> Bool {
        currentSetPosition?.exerciseIndex == exerciseIndex && currentSetPosition?.setIndex == setIndex
    }

    private func currentSetPosition(in session: WorkoutSession) -> CurrentWorkoutSetPosition? {
        for (exerciseIndex, exercise) in session.exercises.enumerated() {
            if let setIndex = exercise.sets.firstIndex(where: { $0.completedAt == nil }) {
                return CurrentWorkoutSetPosition(exerciseIndex: exerciseIndex, setIndex: setIndex)
            }
        }

        return nil
    }

    private func scrollToCurrentSet(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard let updatedSession = store.activeSession,
                  let target = currentSetPosition(in: updatedSession) else { return }
            withAnimation(.easeInOut(duration: 0.32)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
    }
}

private struct WorkoutHeroCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .appSurfaceCard(padding: 22, cornerRadius: 28)
    }
}

private struct WorkoutDurationText: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(WorkoutTimeTextFormatter.durationString(from: startedAt, to: context.date))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct WorkoutLiveRestText: View {
    let lastCompletedSetDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(
                WorkoutTimeTextFormatter.liveRestString(
                    lastCompletedSetDate: lastCompletedSetDate,
                    now: context.date,
                    fallback: NSLocalizedString("common.no_data", comment: "")
                )
            )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

private struct CurrentWorkoutSetPosition: Hashable {
    let exerciseIndex: Int
    let setIndex: Int
}

private struct PresentedWorkoutSummary: Identifiable {
    let id = UUID()
    let session: WorkoutSession
    let mode: WorkoutSummaryMode
}

private struct WorkoutExerciseInfoRow: View {
    let targetWeightText: String
    let previousWeightText: String

    var body: some View {
        HStack(spacing: 8) {
            infoChip(titleKey: "workout.target_weight", value: targetWeightText)
            infoChip(titleKey: "workout.previous_weight", value: previousWeightText)
        }
    }

    private func infoChip(titleKey: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titleKey)
                .font(AppTypography.label(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
            Text(value)
                .font(AppTypography.caption())
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.stroke, lineWidth: 1)
        )
    }
}

private struct WorkoutSetRow: View {
    @Environment(AppStore.self) private var store

    let exerciseIndex: Int
    let setIndex: Int
    let set: WorkoutSetLog
    let isCurrent: Bool
    let focusedField: FocusState<WorkoutSetField?>.Binding
    var onMarkedDone: () -> Void = {}

    private var isCompleted: Bool {
        self.set.completedAt != nil
    }

    private var isUpcoming: Bool {
        !isCompleted && !isCurrent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(format: NSLocalizedString("workout.set_number", comment: ""), setIndex + 1))
                    .font(AppTypography.body(size: 16, weight: .semibold, relativeTo: .subheadline))
                Spacer()
                if isCompleted {
                    Label("workout.done_badge", systemImage: "checkmark.circle.fill")
                        .font(AppTypography.caption(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.success)
                }
            }

            HStack(spacing: 12) {
                Text("workout.reps_label")
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                repsControl
            }

            HStack(spacing: 12) {
                Text("workout.weight")
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                TextField("0", value: Binding(
                    get: { set.weight },
                    set: { newValue in updateWeight(newValue) }
                ), format: .number)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .focused(focusedField, equals: .weight(exerciseIndex, setIndex))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: 110)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
            }

            HStack(spacing: 10) {
                Button {
                    let shouldMarkDone = !isCompleted
                    updateSet { current in
                        current.completedAt = current.completedAt == nil ? .now : nil
                    }
                    if shouldMarkDone {
                        onMarkedDone()
                    }
                } label: {
                    WorkoutSetPrimaryActionLabel(
                        titleKey: isCompleted ? "action.unmark_done" : "action.mark_done",
                        systemImage: isCompleted ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }
                .buttonStyle(WorkoutSetActionButtonStyle(isCompleted: isCompleted))
                .layoutPriority(1)

                Button(role: .destructive) {
                    store.removeSetFromActiveWorkout(exerciseIndex: exerciseIndex, setIndex: setIndex)
                } label: {
                    Image(systemName: "trash")
                        .font(AppTypography.icon(size: 20, weight: .semibold))
                        .frame(width: 48, height: 46)
                }
                .buttonStyle(WorkoutSetIconButtonStyle())
            }
        }
        .opacity(contentOpacity)
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(cardStroke, lineWidth: isCurrent ? 1.2 : 1)
        )
        .shadow(color: cardShadowColor, radius: isCurrent ? 12 : 0, y: isCurrent ? 6 : 0)
    }

    private var repsControl: some View {
        HStack(spacing: 0) {
            Button {
                updateReps(max(1, set.reps - 1))
            } label: {
                Image(systemName: "minus")
                    .font(AppTypography.icon(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 26)

            TextField("0", value: Binding(
                get: { set.reps },
                set: { newValue in
                    updateReps(min(max(newValue, 1), 50))
                }
            ), format: .number)
            .textFieldStyle(.plain)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .focused(focusedField, equals: .reps(exerciseIndex, setIndex))
            .frame(width: 56)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 26)

            Button {
                updateReps(min(50, set.reps + 1))
            } label: {
                Image(systemName: "plus")
                    .font(AppTypography.icon(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .frame(width: 42, height: 42)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
        }
        .font(AppTypography.value(size: 18, weight: .semibold))
        .foregroundStyle(AppTheme.primaryText)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private var cardBackground: LinearGradient {
        if isCompleted {
            return LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.12, blue: 0.1),
                    Color(red: 0.08, green: 0.14, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        if isCurrent {
            return LinearGradient(
                colors: [
                    AppTheme.surfacePressed,
                    AppTheme.surfaceElevated
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                AppTheme.surfaceElevated,
                AppTheme.surface
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardStroke: Color {
        if isCompleted {
            return AppTheme.success.opacity(0.5)
        }

        return isCurrent ? AppTheme.accent.opacity(0.6) : AppTheme.border
    }

    private var contentOpacity: Double {
        isUpcoming ? 0.82 : 1
    }

    private var cardShadowColor: Color {
        isCurrent ? AppTheme.accent.opacity(0.14) : .clear
    }

    private func updateSet(_ change: (inout WorkoutSetLog) -> Void) {
        store.updateActiveSession { session in
            change(&session.exercises[exerciseIndex].sets[setIndex])
        }
    }

    private func updateWeight(_ newWeight: Double) {
        store.updateActiveSession { session in
            guard exerciseIndex < session.exercises.count else { return }
            guard setIndex < session.exercises[exerciseIndex].sets.count else { return }

            session.exercises[exerciseIndex].sets[setIndex].weight = newWeight

            if setIndex + 1 < session.exercises[exerciseIndex].sets.count {
                for index in (setIndex + 1)..<session.exercises[exerciseIndex].sets.count
                where session.exercises[exerciseIndex].sets[index].completedAt == nil {
                    session.exercises[exerciseIndex].sets[index].weight = newWeight
                }
            }
        }
    }

    private func updateReps(_ newReps: Int) {
        store.updateActiveSession { session in
            guard exerciseIndex < session.exercises.count else { return }
            guard setIndex < session.exercises[exerciseIndex].sets.count else { return }

            session.exercises[exerciseIndex].sets[setIndex].reps = newReps

            if setIndex + 1 < session.exercises[exerciseIndex].sets.count {
                for index in (setIndex + 1)..<session.exercises[exerciseIndex].sets.count
                where session.exercises[exerciseIndex].sets[index].completedAt == nil {
                    session.exercises[exerciseIndex].sets[index].reps = newReps
                }
            }
        }
    }
}

private enum WorkoutSetField: Hashable {
    case reps(Int, Int)
    case weight(Int, Int)
}

private struct WorkoutSetPrimaryActionLabel: View {
    let titleKey: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(AppTypography.icon(size: 15, weight: .semibold))
            Text(titleKey)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 42)
        .contentShape(Capsule())
    }
}

private struct WorkoutSetActionButtonStyle: ButtonStyle {
    let isCompleted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.label(size: 12, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background(configuration: configuration), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(borderColor.opacity(configuration.isPressed ? 0.65 : 1), lineWidth: 1)
            )
    }

    private func background(configuration: Configuration) -> LinearGradient {
        let baseColors: [Color] = isCompleted
            ? [
                AppTheme.success.opacity(0.26),
                AppTheme.success.opacity(0.18)
            ]
            : [
                AppTheme.accent.opacity(0.26),
                AppTheme.accent.opacity(0.18)
            ]

        let adjusted = baseColors.map { color in
            configuration.isPressed ? color.opacity(0.82) : color
        }

        return LinearGradient(colors: adjusted, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var borderColor: Color {
        isCompleted ? AppTheme.success.opacity(0.7) : AppTheme.accent.opacity(0.45)
    }
}

private struct WorkoutSetIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppTheme.primaryText)
            .frame(width: 44, height: 44)
            .background(
                configuration.isPressed ? AppTheme.surfacePressed : AppTheme.surfaceElevated,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
    }
}

private struct WorkoutFinishButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.button(size: 17))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                configuration.isPressed ? AppTheme.destructive.opacity(0.84) : AppTheme.destructive,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: AppTheme.destructive.opacity(0.16), radius: 12, y: 8)
    }
}

private struct WorkoutMetricPanel<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppTypography.caption(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(3)
            content
                .font(AppTypography.heading(size: 22))
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118, alignment: .topLeading)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.stroke, lineWidth: 1)
        )
    }
}

private struct WorkoutExerciseProgress {
    let total: Int
    let completed: Int
    let remaining: Int
    let currentStep: Int
}

private struct WorkoutExerciseProgressCard: View {
    let progress: WorkoutExerciseProgress

    private var normalizedProgress: CGFloat {
        guard progress.total > 1 else { return 0 }
        return CGFloat(max(progress.currentStep - 1, 0)) / CGFloat(progress.total - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("workout.progress_title")
                        .font(AppTypography.body(size: 18, weight: .medium, relativeTo: .headline))
                        .foregroundStyle(Color.white.opacity(0.76))
                    Text(String(format: NSLocalizedString("workout.progress_value", comment: ""), progress.completed, progress.remaining))
                        .font(AppTypography.body(size: 15, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                }

                Spacer()
            }

            GeometryReader { proxy in
                let bubbleSize: CGFloat = 54
                let trackHeight: CGFloat = 18
                let edgeInset = bubbleSize / 2
                let usableWidth = max(proxy.size.width - bubbleSize, 1)
                let bubbleOffset = progress.total > 1 ? usableWidth * normalizedProgress : usableWidth / 2
                let progressFillWidth = min(max(bubbleOffset + (bubbleSize / 2), bubbleSize / 2), proxy.size.width)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: trackHeight)
                        .overlay {
                            markerRow(edgeInset: edgeInset)
                        }
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )

                    Capsule()
                        .fill(progressGradient)
                        .frame(width: progressFillWidth, height: trackHeight)

                    progressBubble
                        .frame(width: bubbleSize, height: bubbleSize)
                        .offset(x: bubbleOffset)
                }
            }
            .frame(height: 56)
        }
        .padding(16)
        .background(progressCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var progressGradient: LinearGradient {
        LinearGradient(
            colors: [AppTheme.accent, AppTheme.accent.opacity(0.72)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var progressCardBackground: LinearGradient {
        LinearGradient(
            colors: [
                AppTheme.surfaceElevated,
                Color(red: 0.11, green: 0.11, blue: 0.14),
                Color(red: 0.08, green: 0.08, blue: 0.1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var progressBubble: some View {
        ZStack {
            Circle()
                .fill(AppTheme.accent)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )

            Text("\(progress.currentStep)")
                .font(AppTypography.metric(size: 24))
                .foregroundStyle(Color.white.opacity(0.94))
        }
    }

    @ViewBuilder
    private func markerRow(edgeInset: CGFloat) -> some View {
        if progress.total <= 1 {
            Circle()
                .fill(Color.black.opacity(0.22))
                .frame(width: 11, height: 11)
        } else {
            HStack(spacing: 0) {
                ForEach(0..<progress.total, id: \.self) { index in
                    Circle()
                        .fill(Color.black.opacity(0.22))
                        .frame(width: 11, height: 11)

                    if index < progress.total - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, edgeInset)
        }
    }
}

enum WorkoutTimeTextFormatter {
    static func durationString(from startedAt: Date, to now: Date) -> String {
        formatDuration(elapsedSeconds: Int(now.timeIntervalSince(startedAt)))
    }

    static func formatDuration(elapsedSeconds: Int) -> String {
        format(seconds: elapsedSeconds, includeHours: elapsedSeconds >= 3600)
    }

    static func liveRestString(lastCompletedSetDate: Date?, now: Date, fallback: String) -> String {
        guard let lastCompletedSetDate else { return fallback }
        return formatRest(elapsedSeconds: Int(now.timeIntervalSince(lastCompletedSetDate)))
    }

    static func formatRest(elapsedSeconds: Int) -> String {
        format(seconds: elapsedSeconds, includeHours: false)
    }

    private static func format(seconds: Int, includeHours: Bool) -> String {
        let clampedSeconds = max(seconds, 0)
        let hours = clampedSeconds / 3600
        let minutes = includeHours
            ? (clampedSeconds % 3600) / 60
            : clampedSeconds / 60
        let secondsComponent = clampedSeconds % 60

        if includeHours {
            return String(format: "%02d:%02d:%02d", hours, minutes, secondsComponent)
        }

        return String(format: "%02d:%02d", minutes, secondsComponent)
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
