import SwiftUI

struct ActiveWorkoutView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appBottomRailInset) private var bottomRailInset

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
            .padding(.bottom, 24 + bottomRailInset)
        }
        .appScreenBackground()
    }

    private func activeSessionContent(for session: WorkoutSession) -> some View {
        let derivedState = ActiveWorkoutDerivedState.build(session: session, store: store)

        return ScrollViewReader { proxy in
            ScrollView {
                activeSessionScrollContent(
                    for: session,
                    derivedState: derivedState,
                    currentSetPosition: derivedState.currentSetPosition,
                    onMarkedDone: { scrollToCurrentSet(using: proxy) }
                )
            }
            .appScreenBackground()
        }
    }

    private func activeSessionScrollContent(
        for session: WorkoutSession,
        derivedState: ActiveWorkoutDerivedState,
        currentSetPosition: CurrentWorkoutSetPosition?,
        onMarkedDone: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            AppPageHeaderModule(titleKey: "header.workout.title", subtitleKey: "header.workout.subtitle")
            expandedHeader(for: session, derivedState: derivedState)
            exerciseList(derivedState: derivedState, currentSetPosition: currentSetPosition, onMarkedDone: onMarkedDone)
            finishWorkoutCTA
        }
        .padding(.horizontal, 20)
        .padding(.top, 0)
        .padding(.bottom, 32 + bottomRailInset)
    }

    private func exerciseList(
        derivedState: ActiveWorkoutDerivedState,
        currentSetPosition: CurrentWorkoutSetPosition?,
        onMarkedDone: @escaping () -> Void
    ) -> some View {
        return LazyVStack(spacing: 16) {
            ForEach(derivedState.displayBlocks) { block in
                switch block {
                case .regular(let regularBlock):
                    exerciseCard(
                        for: regularBlock,
                        derivedState: derivedState,
                        currentSetPosition: currentSetPosition,
                        onMarkedDone: onMarkedDone
                    )
                case .superset(let supersetBlock):
                    supersetCard(
                        for: supersetBlock,
                        derivedState: derivedState,
                        currentSetPosition: currentSetPosition,
                        onMarkedDone: onMarkedDone
                    )
                }
            }
        }
    }

    private func exerciseCard(
        for block: ActiveWorkoutRegularBlock,
        derivedState: ActiveWorkoutDerivedState,
        currentSetPosition: CurrentWorkoutSetPosition?,
        onMarkedDone: @escaping () -> Void
    ) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(block.exercise.localizedName)
                            .font(AppTypography.heading(size: 21))

                        WorkoutExerciseInfoRow(
                            targetWeightText: derivedState.targetWeightText(for: block.item),
                            previousWeightText: derivedState.previousWeightText(for: block.item)
                        )

                        if block.item.groupKind == .superset {
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
                    for: block.item,
                    exerciseIndex: block.exerciseIndex,
                    currentSetPosition: currentSetPosition,
                    onMarkedDone: onMarkedDone
                )

                Button {
                    store.updateActiveSession { current in
                        let fallbackSet = current.exercises[block.exerciseIndex].sets.last
                        current.exercises[block.exerciseIndex].sets.append(
                            WorkoutSetLog(
                                reps: fallbackSet?.reps ?? 10,
                                weight: fallbackSet?.weight ?? 0
                            )
                        )
                    }
                } label: {
                    Label("action.add_set", systemImage: "plus")
                }
                .buttonStyle(AppSecondaryButtonStyle())

                VStack(alignment: .leading, spacing: 6) {
                    let restSummary = derivedState.restSummary(for: block.item)
                    Text(restSummary.summaryText)
                    if let previousSetRest = restSummary.previousRestText {
                        Text(String(format: NSLocalizedString("workout.previous_rest", comment: ""), previousSetRest))
                    }
                }
                .font(AppTypography.caption(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private func supersetCard(
        for block: ActiveWorkoutSupersetBlock,
        derivedState: ActiveWorkoutDerivedState,
        currentSetPosition: CurrentWorkoutSetPosition?,
        onMarkedDone: @escaping () -> Void
    ) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("label.superset", systemImage: "bolt.fill")
                            .font(AppTypography.caption(size: 13, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(AppTheme.accentMuted, in: Capsule())

                        Text(block.items.map(\.exercise.localizedName).joined(separator: " • "))
                            .font(AppTypography.heading(size: 21))
                    }

                    Spacer()
                }

                ForEach(block.rounds) { round in
                    supersetRoundCard(
                        round,
                        derivedState: derivedState,
                        currentSetPosition: currentSetPosition,
                        onMarkedDone: onMarkedDone
                    )
                }

                Button {
                    addRound(to: block)
                } label: {
                    Label("action.add_round", systemImage: "plus")
                }
                .buttonStyle(AppSecondaryButtonStyle())
            }
        }
    }

    private func supersetRoundCard(
        _ round: ActiveWorkoutSupersetRound,
        derivedState: ActiveWorkoutDerivedState,
        currentSetPosition: CurrentWorkoutSetPosition?,
        onMarkedDone: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(format: NSLocalizedString("workout.superset_round", comment: ""), round.roundIndex + 1))
                    .font(AppTypography.body(size: 16, weight: .semibold, relativeTo: .subheadline))
                Spacer()
                if round.isCompleted {
                    Label("workout.done_badge", systemImage: "checkmark.circle.fill")
                        .font(AppTypography.caption(size: 13, weight: .bold))
                        .foregroundStyle(AppTheme.success)
                }
            }

            ForEach(Array(round.items.enumerated()), id: \.element.id) { index, roundItem in
                VStack(alignment: .leading, spacing: 12) {
                    Text(roundItem.exercise.localizedName)
                        .font(AppTypography.body(size: 18, weight: .semibold, relativeTo: .headline))

                    WorkoutExerciseInfoRow(
                        targetWeightText: derivedState.targetWeightText(for: roundItem.item),
                        previousWeightText: derivedState.previousWeightText(for: roundItem.item)
                    )

                    WorkoutSetRow(
                        exerciseIndex: roundItem.exerciseIndex,
                        setIndex: roundItem.setIndex,
                        set: roundItem.set,
                        isCurrent: isCurrentSet(
                            currentSetPosition,
                            exerciseIndex: roundItem.exerciseIndex,
                            setIndex: roundItem.setIndex
                        ),
                        focusedField: $focusedField,
                        currentFocusedField: focusedField,
                        onMarkedDone: onMarkedDone
                    )
                }

                if index < round.items.count - 1 {
                    Divider()
                        .overlay(AppTheme.stroke)
                }
            }
        }
        .padding(16)
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.stroke, lineWidth: 1)
        )
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
                currentFocusedField: focusedField,
                onMarkedDone: onMarkedDone
            )
            .id(CurrentWorkoutSetPosition(exerciseIndex: exerciseIndex, setIndex: setIndex))
        }
    }

    private func addRound(to block: ActiveWorkoutSupersetBlock) {
        store.updateActiveSession { current in
            for item in block.items {
                guard current.exercises.indices.contains(item.exerciseIndex) else { continue }
                let fallbackSet = current.exercises[item.exerciseIndex].sets.last
                current.exercises[item.exerciseIndex].sets.append(
                    WorkoutSetLog(
                        reps: fallbackSet?.reps ?? 10,
                        weight: fallbackSet?.weight ?? 0
                    )
                )
            }
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

    private func expandedHeader(for session: WorkoutSession, derivedState: ActiveWorkoutDerivedState) -> some View {
        return WorkoutHeroCard {
            VStack(alignment: .leading, spacing: 18) {
                Text(session.title)
                    .font(AppTypography.title(size: 30))

                WorkoutExerciseProgressCard(progress: derivedState.progress)

                HStack(spacing: 12) {
                    WorkoutMetricPanel(
                        title: NSLocalizedString("workout.duration", comment: "")
                    ) {
                        WorkoutDurationText(startedAt: session.startedAt)
                    }

                    WorkoutMetricPanel(
                        title: NSLocalizedString("workout.rest_live", comment: "")
                    ) {
                        WorkoutLiveRestText(lastCompletedSetDate: derivedState.lastCompletedSetDate)
                    }
                }
            }
        }
    }

    private func isCurrentSet(
        _ currentSetPosition: CurrentWorkoutSetPosition?,
        exerciseIndex: Int,
        setIndex: Int
    ) -> Bool {
        currentSetPosition?.exerciseIndex == exerciseIndex && currentSetPosition?.setIndex == setIndex
    }

    private func scrollToCurrentSet(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard let updatedSession = store.activeSession,
                  let target = ActiveWorkoutDerivedState.build(session: updatedSession, store: store).currentSetPosition else { return }
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

struct CurrentWorkoutSetPosition: Hashable, Sendable {
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
    let currentFocusedField: WorkoutSetField?
    var onMarkedDone: () -> Void = {}

    @State private var draftReps: Int
    @State private var draftWeight: Double
    @State private var pendingCommitTask: Task<Void, Never>?
    @State private var hasPendingDraftChanges = false

    init(
        exerciseIndex: Int,
        setIndex: Int,
        set: WorkoutSetLog,
        isCurrent: Bool,
        focusedField: FocusState<WorkoutSetField?>.Binding,
        currentFocusedField: WorkoutSetField?,
        onMarkedDone: @escaping () -> Void = {}
    ) {
        self.exerciseIndex = exerciseIndex
        self.setIndex = setIndex
        self.set = set
        self.isCurrent = isCurrent
        self.focusedField = focusedField
        self.currentFocusedField = currentFocusedField
        self.onMarkedDone = onMarkedDone
        _draftReps = State(initialValue: set.reps)
        _draftWeight = State(initialValue: set.weight)
    }

    private var isCompleted: Bool {
        self.set.completedAt != nil
    }

    private var isUpcoming: Bool {
        !isCompleted && !isCurrent
    }

    private var syncToken: WorkoutSetDraftSyncToken {
        WorkoutSetDraftSyncToken(id: set.id, reps: set.reps, weight: set.weight, completedAt: set.completedAt)
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

            HStack(spacing: 10) {
                Text("workout.reps_label")
                .font(AppTypography.body(size: 15, relativeTo: .body))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .layoutPriority(1)

                Spacer(minLength: 8)

                repsControl
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 12) {
                Text("workout.weight")
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                TextField("0", value: Binding(
                    get: { draftWeight },
                    set: { newValue in
                        draftWeight = newValue
                        scheduleDraftCommit()
                    }
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
                    flushDraftCommit()
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
                    flushDraftCommit()
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
        .onAppear {
            synchronizeDraftFromStore()
        }
        .onChange(of: syncToken) { _, _ in
            synchronizeDraftFromStore()
        }
        .onChange(of: currentFocusedField) { oldValue, newValue in
            if focusBelongsToRow(oldValue) && !focusBelongsToRow(newValue) {
                flushDraftCommit()
            }
        }
        .onDisappear {
            if hasPendingDraftChanges {
                flushDraftCommit()
            } else {
                pendingCommitTask?.cancel()
                pendingCommitTask = nil
            }
        }
    }

    private var repsControl: some View {
        HStack(spacing: 0) {
            Button {
                updateReps(max(1, draftReps - 1))
            } label: {
                Image(systemName: "minus")
                    .font(AppTypography.icon(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .frame(width: 40, height: 42)
            .contentShape(Rectangle())
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 26)

            TextField("0", value: Binding(
                get: { draftReps },
                set: { newValue in
                    draftReps = min(max(newValue, 1), 50)
                    scheduleDraftCommit()
                }
            ), format: .number)
            .textFieldStyle(.plain)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .focused(focusedField, equals: .reps(exerciseIndex, setIndex))
            .frame(width: 52)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 26)

            Button {
                updateReps(min(50, draftReps + 1))
            } label: {
                Image(systemName: "plus")
                    .font(AppTypography.icon(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .frame(width: 40, height: 42)
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

    private func synchronizeDraftFromStore() {
        guard !focusBelongsToRow(currentFocusedField) || !hasPendingDraftChanges else {
            return
        }

        draftReps = set.reps
        draftWeight = set.weight
    }

    private func focusBelongsToRow(_ field: WorkoutSetField?) -> Bool {
        switch field {
        case .reps(let focusedExerciseIndex, let focusedSetIndex),
             .weight(let focusedExerciseIndex, let focusedSetIndex):
            return focusedExerciseIndex == exerciseIndex && focusedSetIndex == setIndex
        default:
            return false
        }
    }

    private func scheduleDraftCommit() {
        hasPendingDraftChanges = true
        pendingCommitTask?.cancel()

        let scheduledReps = draftReps
        let scheduledWeight = draftWeight
        pendingCommitTask = Task { [scheduledReps, scheduledWeight] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }

            await MainActor.run {
                commitDraft(reps: scheduledReps, weight: scheduledWeight)
            }
        }
    }

    private func flushDraftCommit() {
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        commitDraft(reps: draftReps, weight: draftWeight)
    }

    private func commitDraft(reps: Int, weight: Double) {
        guard reps != set.reps || weight != set.weight else {
            hasPendingDraftChanges = false
            return
        }

        store.updateActiveSession { session in
            guard exerciseIndex < session.exercises.count else { return }
            guard setIndex < session.exercises[exerciseIndex].sets.count else { return }

            session.exercises[exerciseIndex].sets[setIndex].reps = reps
            session.exercises[exerciseIndex].sets[setIndex].weight = weight

            if setIndex + 1 < session.exercises[exerciseIndex].sets.count {
                for index in (setIndex + 1)..<session.exercises[exerciseIndex].sets.count
                where session.exercises[exerciseIndex].sets[index].completedAt == nil {
                    session.exercises[exerciseIndex].sets[index].reps = reps
                    session.exercises[exerciseIndex].sets[index].weight = weight
                }
            }
        }

        hasPendingDraftChanges = false
    }

    private func updateSet(_ change: (inout WorkoutSetLog) -> Void) {
        store.updateActiveSession { session in
            change(&session.exercises[exerciseIndex].sets[setIndex])
        }
    }

    private func updateReps(_ newReps: Int) {
        draftReps = newReps
        flushDraftCommit()
    }
}

private enum WorkoutSetField: Hashable {
    case reps(Int, Int)
    case weight(Int, Int)
}

private struct WorkoutSetDraftSyncToken: Hashable {
    let id: UUID
    let reps: Int
    let weight: Double
    let completedAt: Date?
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

struct WorkoutExerciseProgress {
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

enum ActiveWorkoutDisplayBlock: Hashable, Identifiable {
    case regular(ActiveWorkoutRegularBlock)
    case superset(ActiveWorkoutSupersetBlock)

    var id: UUID {
        switch self {
        case .regular(let block):
            return block.id
        case .superset(let block):
            return block.id
        }
    }

    var isCompleted: Bool {
        switch self {
        case .regular(let block):
            return block.isCompleted
        case .superset(let block):
            return block.isCompleted
        }
    }
}

struct ActiveWorkoutRegularBlock: Hashable, Identifiable {
    let exerciseIndex: Int
    let exercise: Exercise
    let item: WorkoutExerciseLog

    var id: UUID { item.id }

    var isCompleted: Bool {
        !item.sets.isEmpty && item.sets.allSatisfy { $0.completedAt != nil }
    }
}

struct ActiveWorkoutSupersetBlock: Hashable, Identifiable {
    let id: UUID
    let items: [ActiveWorkoutSupersetExercise]
    let rounds: [ActiveWorkoutSupersetRound]

    var isCompleted: Bool {
        !rounds.isEmpty && rounds.allSatisfy(\.isCompleted)
    }
}

struct ActiveWorkoutSupersetExercise: Hashable, Identifiable {
    let exerciseIndex: Int
    let exercise: Exercise
    let item: WorkoutExerciseLog

    var id: UUID { item.id }
}

struct ActiveWorkoutSupersetRound: Hashable, Identifiable {
    let groupID: UUID
    let roundIndex: Int
    let items: [ActiveWorkoutSupersetRoundItem]

    var id: String { "\(groupID.uuidString)-\(roundIndex)" }

    var isCompleted: Bool {
        items.allSatisfy(\.isCompleted)
    }
}

struct ActiveWorkoutSupersetRoundItem: Hashable, Identifiable {
    let exerciseIndex: Int
    let setIndex: Int
    let exercise: Exercise
    let item: WorkoutExerciseLog
    let set: WorkoutSetLog

    var id: CurrentWorkoutSetPosition {
        CurrentWorkoutSetPosition(exerciseIndex: exerciseIndex, setIndex: setIndex)
    }

    var isCompleted: Bool {
        self.set.completedAt != nil
    }
}

struct ActiveWorkoutRestSummary: Hashable {
    let summaryText: String
    let previousRestText: String?
}

struct ActiveWorkoutDerivedState {
    let displayBlocks: [ActiveWorkoutDisplayBlock]
    let currentSetPosition: CurrentWorkoutSetPosition?
    let progress: WorkoutExerciseProgress
    let targetWeightTextByTemplateExerciseID: [UUID: String]
    let previousWeightTextByExerciseID: [UUID: String]
    let restSummaryByExerciseLogID: [UUID: ActiveWorkoutRestSummary]
    let lastCompletedSetDate: Date?

    static let empty = ActiveWorkoutDerivedState(
        displayBlocks: [],
        currentSetPosition: nil,
        progress: WorkoutExerciseProgress(total: 1, completed: 0, remaining: 1, currentStep: 0),
        targetWeightTextByTemplateExerciseID: [:],
        previousWeightTextByExerciseID: [:],
        restSummaryByExerciseLogID: [:],
        lastCompletedSetDate: nil
    )

    static func build(session: WorkoutSession, store: AppStore) -> ActiveWorkoutDerivedState {
        let exercisesByID = Dictionary(uniqueKeysWithValues: store.exercises.map { ($0.id, $0) })
        let displayBlocks = ActiveWorkoutDisplayResolver.buildBlocks(session: session, exercisesByID: exercisesByID)
        let currentSetPosition = ActiveWorkoutDisplayResolver.currentSetPosition(in: displayBlocks)
        let progress = ActiveWorkoutDisplayResolver.progress(for: displayBlocks)
        let templateExerciseIDs = Set(session.exercises.map(\.templateExerciseID))
        let targetWeights = store.targetWeights(
            workoutTemplateID: session.workoutTemplateID,
            templateExerciseIDs: templateExerciseIDs
        )
        let exerciseIDs = Set(session.exercises.map(\.exerciseID))
        let previousWeights = store.lastUsedWeights(for: exerciseIDs)
        let targetWeightTextByTemplateExerciseID = Dictionary(uniqueKeysWithValues: templateExerciseIDs.map {
            ($0, formattedWeightText(targetWeights[$0]))
        })
        let previousWeightTextByExerciseID = Dictionary(uniqueKeysWithValues: exerciseIDs.map {
            ($0, formattedWeightText(previousWeights[$0]))
        })
        let restSummaryByExerciseLogID = Dictionary(uniqueKeysWithValues: session.exercises.map { item in
            (item.id, buildRestSummary(for: item))
        })
        let lastCompletedSetDate = session.exercises
            .flatMap(\.sets)
            .compactMap(\.completedAt)
            .max()

        return ActiveWorkoutDerivedState(
            displayBlocks: displayBlocks,
            currentSetPosition: currentSetPosition,
            progress: progress,
            targetWeightTextByTemplateExerciseID: targetWeightTextByTemplateExerciseID,
            previousWeightTextByExerciseID: previousWeightTextByExerciseID,
            restSummaryByExerciseLogID: restSummaryByExerciseLogID,
            lastCompletedSetDate: lastCompletedSetDate
        )
    }

    func targetWeightText(for item: WorkoutExerciseLog) -> String {
        targetWeightTextByTemplateExerciseID[item.templateExerciseID] ?? Self.noDataText
    }

    func previousWeightText(for item: WorkoutExerciseLog) -> String {
        previousWeightTextByExerciseID[item.exerciseID] ?? Self.noDataText
    }

    func restSummary(for item: WorkoutExerciseLog) -> ActiveWorkoutRestSummary {
        restSummaryByExerciseLogID[item.id]
            ?? ActiveWorkoutRestSummary(summaryText: Self.noDataText, previousRestText: nil)
    }

    private static func buildRestSummary(for exercise: WorkoutExerciseLog) -> ActiveWorkoutRestSummary {
        let completedDates = exercise.sets.compactMap(\.completedAt).sorted()
        guard completedDates.count > 1 else {
            return ActiveWorkoutRestSummary(
                summaryText: NSLocalizedString("workout.no_rest_data", comment: ""),
                previousRestText: nil
            )
        }

        let restDiffs = zip(completedDates.dropFirst(), completedDates).map { $0.timeIntervalSince($1) }
        let averageRest = restDiffs.reduce(0, +) / Double(restDiffs.count)
        let previousRestText = completedDates.dropLast().last.flatMap { previous in
            completedDates.last.flatMap { last in
                DateComponentsFormatter.workoutRest.string(from: previous, to: last)
            }
        }

        return ActiveWorkoutRestSummary(
            summaryText: String(format: NSLocalizedString("workout.avg_rest", comment: ""), Int(averageRest)),
            previousRestText: previousRestText
        )
    }

    private static func formattedWeightText(_ weight: Double?) -> String {
        guard let weight, weight > 0 else {
            return noDataText
        }

        return String(format: NSLocalizedString("stats.weight_value", comment: ""), weight)
    }

    private static var noDataText: String {
        NSLocalizedString("common.no_data", comment: "")
    }
}

enum ActiveWorkoutDisplayResolver {
    static func buildBlocks(session: WorkoutSession, exercisesByID: [UUID: Exercise]) -> [ActiveWorkoutDisplayBlock] {
        var supersetItemsByGroupID: [UUID: [ActiveWorkoutSupersetExercise]] = [:]
        var supersetFirstIndexByGroupID: [UUID: Int] = [:]

        for (exerciseIndex, item) in session.exercises.enumerated() {
            guard item.groupKind == .superset,
                  let groupID = item.groupID,
                  let exercise = exercisesByID[item.exerciseID] else {
                continue
            }

            if supersetFirstIndexByGroupID[groupID] == nil {
                supersetFirstIndexByGroupID[groupID] = exerciseIndex
            }

            supersetItemsByGroupID[groupID, default: []].append(
                ActiveWorkoutSupersetExercise(
                    exerciseIndex: exerciseIndex,
                    exercise: exercise,
                    item: item
                )
            )
        }

        let supersetBlocksByFirstIndex = Dictionary(uniqueKeysWithValues: supersetFirstIndexByGroupID.compactMap { groupID, firstIndex in
            guard let groupItems = supersetItemsByGroupID[groupID],
                  groupItems.count > 1 else {
                return nil
            }

            let rounds = buildSupersetRounds(groupID: groupID, groupItems: groupItems)
            return (firstIndex, ActiveWorkoutDisplayBlock.superset(
                ActiveWorkoutSupersetBlock(id: groupID, items: groupItems, rounds: rounds)
            ))
        })

        var result: [ActiveWorkoutDisplayBlock] = []

        for (exerciseIndex, item) in session.exercises.enumerated() {
            if let supersetBlock = supersetBlocksByFirstIndex[exerciseIndex] {
                result.append(supersetBlock)
                continue
            }

            if item.groupKind == .superset,
               let groupID = item.groupID,
               supersetFirstIndexByGroupID[groupID] != exerciseIndex {
                continue
            }

            guard let exercise = exercisesByID[item.exerciseID] else { continue }
            result.append(.regular(ActiveWorkoutRegularBlock(exerciseIndex: exerciseIndex, exercise: exercise, item: item)))
        }

        return result
    }

    static func currentSetPosition(in blocks: [ActiveWorkoutDisplayBlock]) -> CurrentWorkoutSetPosition? {
        for block in blocks {
            switch block {
            case .regular(let regularBlock):
                if let setIndex = regularBlock.item.sets.firstIndex(where: { $0.completedAt == nil }) {
                    return CurrentWorkoutSetPosition(exerciseIndex: regularBlock.exerciseIndex, setIndex: setIndex)
                }
            case .superset(let supersetBlock):
                for round in supersetBlock.rounds {
                    if let roundItem = round.items.first(where: { !$0.isCompleted }) {
                        return CurrentWorkoutSetPosition(exerciseIndex: roundItem.exerciseIndex, setIndex: roundItem.setIndex)
                    }
                }
            }
        }

        return nil
    }

    static func progress(for blocks: [ActiveWorkoutDisplayBlock]) -> WorkoutExerciseProgress {
        let totalBlocks = max(blocks.count, 1)
        let completedBlocks = blocks.filter { $0.isCompleted }.count
        let remainingBlocks = max(blocks.count - completedBlocks, 0)
        let currentStep = blocks.isEmpty ? 0 : min(completedBlocks + (remainingBlocks > 0 ? 1 : 0), totalBlocks)

        return WorkoutExerciseProgress(
            total: totalBlocks,
            completed: completedBlocks,
            remaining: remainingBlocks,
            currentStep: currentStep
        )
    }

    private static func buildSupersetRounds(
        groupID: UUID,
        groupItems: [ActiveWorkoutSupersetExercise]
    ) -> [ActiveWorkoutSupersetRound] {
        let targetRoundCount = groupItems.first?.item.sets.count ?? 0

        return (0..<targetRoundCount).compactMap { roundIndex in
            let roundItems = groupItems.compactMap { groupEntry -> ActiveWorkoutSupersetRoundItem? in
                guard groupEntry.item.sets.indices.contains(roundIndex) else { return nil }

                return ActiveWorkoutSupersetRoundItem(
                    exerciseIndex: groupEntry.exerciseIndex,
                    setIndex: roundIndex,
                    exercise: groupEntry.exercise,
                    item: groupEntry.item,
                    set: groupEntry.item.sets[roundIndex]
                )
            }

            guard !roundItems.isEmpty else { return nil }
            return ActiveWorkoutSupersetRound(groupID: groupID, roundIndex: roundIndex, items: roundItems)
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
