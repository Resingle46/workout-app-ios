import SwiftUI

struct WorkoutTemplateDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appBottomRailInset) private var bottomRailInset

    let programID: UUID
    let workoutID: UUID

    @State private var showingAddExercise = false
    @State private var editingExercise: EditableTemplateExercise?

    private var workout: WorkoutTemplate? {
        store.workout(programID: programID, workoutID: workoutID)
    }

    var body: some View {
        Group {
            if let workout {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(for: workout)

                        if workout.exercises.isEmpty {
                            AppCard {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("template.empty_title")
                                        .font(AppTypography.heading(size: 24))
                                    Text("template.empty_description")
                                        .foregroundStyle(AppTheme.secondaryText)
                                    Button {
                                        showingAddExercise = true
                                    } label: {
                                        Label("action.add_exercise", systemImage: "plus")
                                    }
                                    .buttonStyle(AppPrimaryButtonStyle())
                                }
                            }
                        } else {
                            ForEach(groupedExercises(workout.exercises), id: \.id) { group in
                                exerciseGroupCard(group)
                            }

                            Button {
                                showingAddExercise = true
                            } label: {
                                Label("action.add_exercise", systemImage: "plus")
                            }
                            .buttonStyle(AppSecondaryButtonStyle())
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 28 + bottomRailInset)
                }
                .navigationTitle(workout.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingAddExercise = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundStyle(AppTheme.primaryText)
                        }
                    }
                }
                .sheet(isPresented: $showingAddExercise) {
                    AddExerciseToWorkoutView(workoutID: workoutID)
                }
                .sheet(item: $editingExercise) { exercise in
                    TemplateExerciseConfigSheet(
                        title: exercise.exerciseName,
                        setsCount: exercise.setsCount,
                        reps: exercise.reps,
                        suggestedWeight: exercise.suggestedWeight,
                        onCancel: {
                            editingExercise = nil
                        },
                        onSave: { newSetsCount, newReps, newWeight in
                            store.updateTemplateExercise(
                                programID: programID,
                                workoutID: workoutID,
                                templateExerciseID: exercise.id,
                                reps: newReps,
                                setsCount: newSetsCount,
                                suggestedWeight: newWeight
                            )
                            editingExercise = nil
                        }
                    )
                }
                .appScreenBackground()
            } else {
                ContentUnavailableView("error.not_found", systemImage: "exclamationmark.triangle")
                    .appScreenBackground()
            }
        }
    }

    private func header(for workout: WorkoutTemplate) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                Text(workout.title)
                    .font(AppTypography.title(size: 30))
                Text(workout.focus.isEmpty ? String(localized: "workout.focus_empty") : workout.focus)
                    .foregroundStyle(AppTheme.secondaryText)
                Text(String(format: NSLocalizedString("program.exercise_count", comment: ""), workout.exercises.count))
                    .font(AppTypography.body(size: 17, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(AppTheme.secondaryText)

                VStack(spacing: 12) {
                    Button {
                        store.startWorkout(template: workout)
                    } label: {
                        Label("action.start_workout", systemImage: "play.fill")
                    }
                    .buttonStyle(AppPrimaryButtonStyle())
                }
            }
        }
    }

    private func exerciseGroupCard(_ group: WorkoutExerciseTemplateGroup) -> some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                if group.isSuperset {
                    HStack {
                        Label("label.superset", systemImage: "bolt.fill")
                            .font(AppTypography.caption(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AppTheme.accentMuted, in: Capsule())
                        Spacer()
                    }
                }

                ForEach(group.items) { item in
                    if let exercise = store.exercise(for: item.exerciseID) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(exercise.localizedName)
                                        .font(AppTypography.heading(size: 21))
                                    if !exercise.equipment.isEmpty {
                                        Text(exercise.localizedEquipment)
                                            .font(AppTypography.body(size: 16, relativeTo: .subheadline))
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }
                                }

                                Spacer()

                                Menu {
                                    Button {
                                        editingExercise = EditableTemplateExercise(
                                            id: item.id,
                                            exerciseName: exercise.localizedName,
                                            setsCount: item.sets.count,
                                            reps: item.sets.first?.reps ?? 12,
                                            suggestedWeight: item.sets.first?.suggestedWeight ?? 0
                                        )
                                    } label: {
                                        Label("action.edit", systemImage: "slider.horizontal.3")
                                    }

                                    Button(role: .destructive) {
                                        store.deleteTemplateExercise(programID: programID, workoutID: workoutID, templateExerciseID: item.id)
                                    } label: {
                                        Label("common.delete", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(AppTypography.icon(size: 20, weight: .medium))
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                            }

                            templateExerciseTable(for: item)

                            if item.id != (group.items.last?.id ?? item.id) {
                                Divider()
                                    .overlay(AppTheme.stroke)
                            }
                        }
                    }
                }
            }
        }
    }

    private func templateExerciseTable(for item: WorkoutExerciseTemplate) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tableHeaderCell("template.table_set", alignment: .leading)
                tableHeaderCell("template.table_weight", alignment: .center)
                tableHeaderCell("template.table_reps", alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            ForEach(Array(item.sets.enumerated()), id: \.element.id) { index, set in
                HStack(spacing: 0) {
                    tableValueCell("\(index + 1)", alignment: .leading)
                    tableValueCell(set.suggestedWeight.appNumberText, alignment: .center)
                    tableValueCell("\(set.reps)", alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    index.isMultiple(of: 2)
                        ? AppTheme.surface.opacity(0.35)
                        : AppTheme.surfaceElevated.opacity(0.82)
                )
            }
        }
        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.stroke, lineWidth: 1)
        )
    }

    private func tableHeaderCell(_ titleKey: LocalizedStringKey, alignment: Alignment) -> some View {
        Text(titleKey)
            .font(AppTypography.caption(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.secondaryText)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func tableValueCell(_ value: String, alignment: Alignment) -> some View {
        Text(value)
            .font(AppTypography.value(size: 18, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func groupedExercises(_ items: [WorkoutExerciseTemplate]) -> [WorkoutExerciseTemplateGroup] {
        var result: [WorkoutExerciseTemplateGroup] = []
        var handled = Set<UUID>()

        for item in items {
            guard !handled.contains(item.id) else { continue }

            if item.groupKind == .superset, let groupID = item.groupID {
                let groupItems = items.filter { $0.groupKind == .superset && $0.groupID == groupID }
                groupItems.forEach { handled.insert($0.id) }
                result.append(WorkoutExerciseTemplateGroup(id: groupID, isSuperset: true, items: groupItems))
            } else {
                handled.insert(item.id)
                result.append(WorkoutExerciseTemplateGroup(id: item.id, isSuperset: false, items: [item]))
            }
        }

        return result
    }
}

private struct WorkoutExerciseTemplateGroup: Identifiable {
    let id: UUID
    let isSuperset: Bool
    let items: [WorkoutExerciseTemplate]
}

private struct EditableTemplateExercise: Identifiable {
    let id: UUID
    let exerciseName: String
    let setsCount: Int
    let reps: Int
    let suggestedWeight: Double
}

struct AddExerciseToWorkoutView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let workoutID: UUID

    @State private var query = ""
    @State private var selectedCategoryID: UUID?
    @State private var stagedCustomExercises: [Exercise] = []
    @State private var stagedExercises: [StagedWorkoutExercise] = []
    @State private var isSupersetEnabled = false
    @State private var currentSupersetGroupID: UUID?
    @State private var showingCreateExercise = false
    @State private var pendingConfiguration: PendingExerciseConfiguration?

    private var availableExercises: [Exercise] {
        stagedCustomExercises + store.exercises
    }

    private var filteredExercises: [Exercise] {
        availableExercises.filter { exercise in
            let matchesCategory = selectedCategoryID == nil || exercise.categoryID == selectedCategoryID
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesQuery = normalizedQuery.isEmpty ||
                exercise.searchableTexts.contains(where: { $0.localizedCaseInsensitiveContains(normalizedQuery) })
            return matchesCategory && matchesQuery
        }
    }

    private var currentSupersetDraftCount: Int {
        guard let currentSupersetGroupID else { return 0 }
        return stagedExercises.filter { $0.groupKind == .superset && $0.groupID == currentSupersetGroupID }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AppCard {
                        VStack(alignment: .leading, spacing: 16) {
                            AppSectionTitle(titleKey: "catalog.search")

                            TemplateEditorTextField(titleKey: "catalog.search_placeholder", text: $query)

                            Picker(NSLocalizedString("catalog.category", comment: ""), selection: $selectedCategoryID) {
                                Text("common.all").tag(UUID?.none)
                                ForEach(store.categories) { category in
                                    Text(LocalizedStringKey(category.nameKey)).tag(UUID?.some(category.id))
                                }
                            }
                            .pickerStyle(.menu)

                            Toggle(isOn: Binding(
                                get: { isSupersetEnabled },
                                set: { handleSupersetToggleChange($0) }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("template.superset")
                                        .font(AppTypography.body(size: 18, weight: .semibold, relativeTo: .headline))
                                    Text(
                                        LocalizedStringKey(
                                            currentSupersetDraftCount == 0
                                                ? "template.superset_hint_single"
                                                : "template.superset_hint_pair"
                                        )
                                    )
                                    .font(AppTypography.caption(size: 13, weight: .regular))
                                    .foregroundStyle(AppTheme.secondaryText)
                                }
                            }

                            Button {
                                showingCreateExercise = true
                            } label: {
                                Label("catalog.create_custom", systemImage: "plus.circle")
                            }
                            .buttonStyle(AppSecondaryButtonStyle())
                        }
                    }

                    AppCard {
                        VStack(alignment: .leading, spacing: 14) {
                            AppSectionTitle(titleKey: "catalog.results")

                            if filteredExercises.isEmpty {
                                Text("catalog.no_results")
                                    .foregroundStyle(AppTheme.secondaryText)
                            } else {
                                ForEach(filteredExercises) { exercise in
                                    ExerciseSelectionCard(
                                        exercise: exercise,
                                        category: store.category(for: exercise.categoryID),
                                        isSelected: stagedExercises.contains(where: { $0.exercise.id == exercise.id }),
                                        action: { presentConfiguration(for: exercise) }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("action.add_exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") {
                        commitStagedExercises()
                    }
                }
            }
            .sheet(isPresented: $showingCreateExercise) {
                CreateCustomExerciseView { name, equipment, notes, categoryID in
                    let exercise = Exercise(name: name, categoryID: categoryID, equipment: equipment, notes: notes)
                    stagedCustomExercises.removeAll { $0.id == exercise.id }
                    stagedCustomExercises.insert(exercise, at: 0)
                    selectedCategoryID = categoryID
                    presentConfiguration(for: exercise)
                }
            }
            .sheet(item: $pendingConfiguration) { configuration in
                TemplateExerciseConfigSheet(
                    title: configuration.title,
                    setsCount: configuration.setsCount,
                    reps: configuration.reps,
                    suggestedWeight: configuration.suggestedWeight,
                    onCancel: {
                        pendingConfiguration = nil
                    },
                    onSave: { setsCount, reps, weight in
                        stageExercise(
                            configuration: configuration,
                            reps: reps,
                            setsCount: setsCount,
                            suggestedWeight: weight
                        )
                        pendingConfiguration = nil
                    }
                )
                .presentationDetents([.height(380)])
                .presentationDragIndicator(.hidden)
                .presentationBackground(AppTheme.surface)
            }
            .appScreenBackground()
        }
    }

    private func presentConfiguration(for exercise: Exercise) {
        guard pendingConfiguration == nil else { return }

        let stagedExercise = stagedExercises.first(where: { $0.exercise.id == exercise.id })
        let groupContext = resolvedGroupContext(for: stagedExercise)

        pendingConfiguration = PendingExerciseConfiguration(
            exercise: exercise,
            title: exercise.localizedName,
            setsCount: stagedExercise?.setsCount ?? 4,
            reps: stagedExercise?.reps ?? 12,
            suggestedWeight: stagedExercise?.suggestedWeight ?? 0,
            groupKind: groupContext.groupKind,
            groupID: groupContext.groupID
        )
    }

    private func stageExercise(
        configuration: PendingExerciseConfiguration,
        reps: Int,
        setsCount: Int,
        suggestedWeight: Double
    ) {
        let stagedExercise = StagedWorkoutExercise(
            exercise: configuration.exercise,
            setsCount: setsCount,
            reps: reps,
            suggestedWeight: suggestedWeight,
            groupKind: configuration.groupKind,
            groupID: configuration.groupID
        )

        if let existingIndex = stagedExercises.firstIndex(where: { $0.exercise.id == configuration.exercise.id }) {
            stagedExercises[existingIndex] = stagedExercise
        } else {
            stagedExercises.append(stagedExercise)
        }

        if stagedExercise.groupKind == .superset, let groupID = stagedExercise.groupID {
            synchronizeStagedSupersetSetCounts(groupID: groupID, targetSetCount: setsCount, excludingExerciseID: stagedExercise.exercise.id)
        }
    }

    private func commitStagedExercises() {
        let finalizedExercises = finalizedStagedExercisesForCommit()
        let selectedCustomIDs = Set(finalizedExercises.map(\.exercise.id))

        for customExercise in stagedCustomExercises where selectedCustomIDs.contains(customExercise.id) {
            if store.exercise(for: customExercise.id) == nil {
                store.addCustomExercise(customExercise)
            }
        }

        store.addExercises(
            to: workoutID,
            drafts: finalizedExercises.map {
                WorkoutExerciseDraft(
                    exerciseID: $0.exercise.id,
                    reps: $0.reps,
                    setsCount: $0.setsCount,
                    suggestedWeight: $0.suggestedWeight,
                    groupKind: $0.groupKind,
                    groupID: $0.groupID
                )
            }
        )

        dismiss()
    }

    private func handleSupersetToggleChange(_ isEnabled: Bool) {
        if isEnabled {
            isSupersetEnabled = true
            currentSupersetGroupID = currentSupersetGroupID ?? UUID()
        } else {
            finalizeCurrentSupersetDraftGroup()
            isSupersetEnabled = false
        }
    }

    private func resolvedGroupContext(for stagedExercise: StagedWorkoutExercise?) -> (groupKind: WorkoutExerciseTemplate.GroupKind, groupID: UUID?) {
        if let stagedExercise {
            return (stagedExercise.groupKind, stagedExercise.groupID)
        }

        guard isSupersetEnabled else {
            return (.regular, nil)
        }

        let groupID = currentSupersetGroupID ?? UUID()
        currentSupersetGroupID = groupID
        return (.superset, groupID)
    }

    private func synchronizeStagedSupersetSetCounts(groupID: UUID, targetSetCount: Int, excludingExerciseID: UUID) {
        for index in stagedExercises.indices {
            guard stagedExercises[index].groupKind == .superset,
                  stagedExercises[index].groupID == groupID,
                  stagedExercises[index].exercise.id != excludingExerciseID else { continue }

            stagedExercises[index].setsCount = targetSetCount
        }
    }

    private func finalizeCurrentSupersetDraftGroup() {
        guard let currentSupersetGroupID else {
            self.currentSupersetGroupID = nil
            return
        }

        let groupIndices = stagedExercises.indices.filter {
            stagedExercises[$0].groupKind == .superset && stagedExercises[$0].groupID == currentSupersetGroupID
        }

        if groupIndices.count == 1 {
            let index = groupIndices[0]
            stagedExercises[index].groupKind = .regular
            stagedExercises[index].groupID = nil
        }

        self.currentSupersetGroupID = nil
    }

    private func finalizedStagedExercisesForCommit() -> [StagedWorkoutExercise] {
        var finalized = stagedExercises

        let groupedSupersets = Dictionary(grouping: finalized.enumerated().filter {
            $0.element.groupKind == .superset && $0.element.groupID != nil
        }) { $0.element.groupID! }

        for (_, entries) in groupedSupersets where entries.count < 2 {
            for entry in entries {
                finalized[entry.offset].groupKind = .regular
                finalized[entry.offset].groupID = nil
            }
        }

        return finalized
    }
}

private struct StagedWorkoutExercise: Identifiable {
    var id: UUID { exercise.id }
    let exercise: Exercise
    var setsCount: Int
    var reps: Int
    var suggestedWeight: Double
    var groupKind: WorkoutExerciseTemplate.GroupKind
    var groupID: UUID?
}

private struct PendingExerciseConfiguration: Identifiable {
    let id = UUID()
    let exercise: Exercise
    let title: String
    let setsCount: Int
    let reps: Int
    let suggestedWeight: Double
    let groupKind: WorkoutExerciseTemplate.GroupKind
    let groupID: UUID?
}

private struct ExerciseSelectionCard: View {
    let exercise: Exercise
    let category: ExerciseCategory?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.14))
                    Image(systemName: category?.symbol ?? "figure.strengthtraining.functional")
                        .font(AppTypography.icon(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    if let category {
                        Text(LocalizedStringKey(category.nameKey))
                            .font(AppTypography.label(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }

                    Text(exercise.localizedName)
                        .font(AppTypography.body(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    if !exercise.equipment.isEmpty {
                        Text(exercise.localizedEquipment)
                            .font(AppTypography.caption(size: 13, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.74))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(isSelected ? Color.white : Color.black.opacity(0.28))
                        .frame(width: 34, height: 34)
                        .shadow(color: Color.black.opacity(0.2), radius: 8, y: 4)

                    Image(systemName: isSelected ? "checkmark" : "plus")
                        .font(AppTypography.icon(size: 15, weight: .bold))
                        .foregroundStyle(
                            isSelected
                                ? LinearGradient(
                                    colors: [AppTheme.neonBlue, AppTheme.neonViolet],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.92), Color.white.opacity(0.72)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.28) : Color.white.opacity(0.12), lineWidth: 1.1)
            )
            .shadow(color: shadowColor, radius: 18, y: 10)
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: isSelected
                        ? [
                            Color(red: 0.24, green: 0.14, blue: 0.95),
                            Color(red: 0.34, green: 0.19, blue: 0.99),
                            Color(red: 0.24, green: 0.56, blue: 0.97)
                        ]
                        : [
                            Color(red: 0.16, green: 0.13, blue: 0.56),
                            Color(red: 0.28, green: 0.16, blue: 0.88),
                            Color(red: 0.19, green: 0.22, blue: 0.72)
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(AppTheme.neonViolet.opacity(isSelected ? 0.42 : 0.26))
                    .frame(width: 150, height: 150)
                    .blur(radius: 40)
                    .offset(x: -20, y: -34)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(AppTheme.neonCyan.opacity(isSelected ? 0.36 : 0.2))
                    .frame(width: 130, height: 130)
                    .blur(radius: 34)
                    .offset(x: 24, y: 28)
            }
    }

    private var shadowColor: Color {
        isSelected ? AppTheme.neonBlue.opacity(0.34) : AppTheme.neonViolet.opacity(0.18)
    }
}

struct CreateCustomExerciseView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let onSave: (String, String, String, UUID) -> Void

    @State private var name = ""
    @State private var equipment = ""
    @State private var notes = ""
    @State private var selectedCategoryID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AppCard {
                        VStack(alignment: .leading, spacing: 16) {
                            AppSectionTitle(titleKey: "exercise.name")
                            TemplateEditorTextField(titleKey: "exercise.name", text: $name)

                            AppSectionTitle(titleKey: "catalog.category")
                            Picker(NSLocalizedString("catalog.category", comment: ""), selection: $selectedCategoryID) {
                                ForEach(store.categories) { category in
                                    Text(LocalizedStringKey(category.nameKey)).tag(UUID?.some(category.id))
                                }
                            }
                            .pickerStyle(.menu)

                            AppSectionTitle(titleKey: "exercise.equipment")
                            TemplateEditorTextField(titleKey: "exercise.equipment", text: $equipment)

                            AppSectionTitle(titleKey: "exercise.notes")
                            TextField(String(localized: "exercise.notes"), text: $notes, axis: .vertical)
                                .lineLimit(4...8)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(AppTheme.stroke, lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("exercise.new")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        guard let categoryID = selectedCategoryID else { return }
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmedName, equipment.trimmingCharacters(in: .whitespacesAndNewlines), notes.trimmingCharacters(in: .whitespacesAndNewlines), categoryID)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedCategoryID == nil)
                }
            }
            .onAppear {
                selectedCategoryID = selectedCategoryID ?? store.categories.first?.id
            }
            .appScreenBackground()
        }
    }
}

struct TemplateExerciseConfigSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let setsCount: Int
    let reps: Int
    let suggestedWeight: Double
    let onCancel: () -> Void
    let onSave: (Int, Int, Double) -> Void

    @State private var selectedSetsCount: Int
    @State private var selectedReps: Int
    @State private var weightStep: Int

    init(
        title: String,
        setsCount: Int,
        reps: Int,
        suggestedWeight: Double,
        onCancel: @escaping () -> Void,
        onSave: @escaping (Int, Int, Double) -> Void
    ) {
        self.title = title
        self.setsCount = setsCount
        self.reps = reps
        self.suggestedWeight = suggestedWeight
        self.onCancel = onCancel
        self.onSave = onSave
        _selectedSetsCount = State(initialValue: setsCount)
        _selectedReps = State(initialValue: reps)
        _weightStep = State(initialValue: min(max(Int((suggestedWeight * 2).rounded()), 0), 600))
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 44, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 18)

            HStack {
                Button("action.cancel") {
                    onCancel()
                    dismiss()
                }
                .foregroundStyle(AppTheme.secondaryText)

                Spacer()

                Text(title)
                    .font(AppTypography.heading(size: 18))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Button("action.done") {
                    onSave(selectedSetsCount, selectedReps, Double(weightStep) / 2)
                    dismiss()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            HStack(spacing: 0) {
                wheelColumn(titleKey: "template.weight_picker", width: 150) {
                    Picker("", selection: $weightStep) {
                        ForEach(0...600, id: \.self) { step in
                            Text("\(Double(step) / 2, specifier: "%.1f")")
                                .tag(step)
                        }
                    }
                    .pickerStyle(.wheel)
                }

                wheelColumn(titleKey: "template.sets_picker", width: 110) {
                    Picker("", selection: $selectedSetsCount) {
                        ForEach(1...10, id: \.self) { value in
                            Text("\(value)")
                                .tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                }

                wheelColumn(titleKey: "template.reps_picker", width: 110) {
                    Picker("", selection: $selectedReps) {
                        ForEach(1...30, id: \.self) { value in
                            Text("\(value)")
                                .tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                }
            }
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.surface.ignoresSafeArea())
    }

    private func wheelColumn<Content: View>(titleKey: LocalizedStringKey, width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            Text(titleKey)
                .font(AppTypography.caption(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
            content()
                .frame(width: width, height: 180)
                .clipped()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TemplateEditorTextField: View {
    let titleKey: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        TextField(titleKey, text: $text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.words)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.stroke, lineWidth: 1)
            )
    }
}
