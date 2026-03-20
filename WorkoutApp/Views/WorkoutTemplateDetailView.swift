import SwiftUI

struct WorkoutTemplateDetailView: View {
    @Environment(AppStore.self) private var store

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
                                        .font(.system(size: 24, weight: .black, design: .rounded))
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
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 28)
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
                    .font(.system(size: 30, weight: .black, design: .rounded))
                Text(workout.focus.isEmpty ? String(localized: "workout.focus_empty") : workout.focus)
                    .foregroundStyle(AppTheme.secondaryText)
                Text(String(format: NSLocalizedString("program.exercise_count", comment: ""), workout.exercises.count))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)

                VStack(spacing: 12) {
                    Button {
                        store.startWorkout(template: workout)
                    } label: {
                        Label("action.start_workout", systemImage: "play.fill")
                    }
                    .buttonStyle(AppPrimaryButtonStyle())

                    Button {
                        showingAddExercise = true
                    } label: {
                        Label("action.add_exercise", systemImage: "plus")
                    }
                    .buttonStyle(AppSecondaryButtonStyle())
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
                            .font(.caption.weight(.semibold))
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
                                    Text(exercise.name)
                                        .font(.title3.weight(.heavy))
                                    if !exercise.equipment.isEmpty {
                                        Text(exercise.equipment)
                                            .font(.subheadline)
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }
                                    Text(summary(for: item))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AppTheme.secondaryText)
                                }

                                Spacer()

                                Menu {
                                    Button {
                                        editingExercise = EditableTemplateExercise(
                                            id: item.id,
                                            exerciseName: exercise.name,
                                            setsCount: item.sets.count,
                                            reps: item.sets.first?.reps ?? 10,
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
                                        .font(.title3)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                            }

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

    private func summary(for item: WorkoutExerciseTemplate) -> String {
        let setsCount = item.sets.count
        let reps = item.sets.first?.reps ?? 0
        let suggestedWeight = item.sets.first?.suggestedWeight ?? 0
        return String(
            format: NSLocalizedString("template.exercise_meta", comment: ""),
            setsCount,
            reps,
            suggestedWeight.appNumberText
        )
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
    @State private var selectedExerciseIDs: [UUID] = []
    @State private var isSuperset = false
    @State private var showingCreateExercise = false
    @State private var pendingConfiguration: PendingExerciseConfiguration?

    private var filteredExercises: [Exercise] {
        store.exercises.filter { exercise in
            let matchesCategory = selectedCategoryID == nil || exercise.categoryID == selectedCategoryID
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesQuery = normalizedQuery.isEmpty ||
                exercise.name.localizedCaseInsensitiveContains(normalizedQuery) ||
                exercise.equipment.localizedCaseInsensitiveContains(normalizedQuery)
            return matchesCategory && matchesQuery
        }
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

                            Toggle(isOn: $isSuperset) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("template.superset")
                                        .font(.headline)
                                    Text(LocalizedStringKey(isSuperset ? "template.superset_hint_pair" : "template.superset_hint_single"))
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                            }
                            .onChange(of: isSuperset) { _, newValue in
                                if !newValue, selectedExerciseIDs.count > 1 {
                                    selectedExerciseIDs = Array(selectedExerciseIDs.prefix(1))
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
                                    Button {
                                        toggleSelection(for: exercise.id)
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(exercise.name)
                                                    .foregroundStyle(AppTheme.primaryText)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                if !exercise.equipment.isEmpty {
                                                    Text(exercise.equipment)
                                                        .font(.caption)
                                                        .foregroundStyle(AppTheme.secondaryText)
                                                }
                                            }

                                            Spacer()

                                            Image(systemName: selectedExerciseIDs.contains(exercise.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.title3)
                                                .foregroundStyle(selectedExerciseIDs.contains(exercise.id) ? AppTheme.accent : AppTheme.secondaryText)
                                        }
                                        .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)

                                    if exercise.id != (filteredExercises.last?.id ?? exercise.id) {
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
            .navigationTitle("action.add_exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingCreateExercise) {
                CreateCustomExerciseView { name, equipment, notes, categoryID in
                    let exercise = store.addCustomExercise(name: name, categoryID: categoryID, equipment: equipment, notes: notes)
                    selectedCategoryID = categoryID
                    if isSuperset {
                        if selectedExerciseIDs.count == 1 {
                            selectedExerciseIDs.append(exercise.id)
                            presentConfigurationIfNeeded()
                        } else {
                            selectedExerciseIDs = [exercise.id]
                        }
                    } else {
                        selectedExerciseIDs = [exercise.id]
                        presentConfigurationIfNeeded()
                    }
                }
            }
            .sheet(item: $pendingConfiguration) { configuration in
                TemplateExerciseConfigSheet(
                    title: configuration.title,
                    setsCount: 3,
                    reps: 10,
                    suggestedWeight: 0,
                    onCancel: {
                        pendingConfiguration = nil
                        selectedExerciseIDs.removeAll()
                    },
                    onSave: { setsCount, reps, weight in
                        if configuration.isSuperset {
                            let groupID = UUID()
                            for exerciseID in configuration.exerciseIDs {
                                store.addExercise(
                                    to: workoutID,
                                    exerciseID: exerciseID,
                                    reps: reps,
                                    setsCount: setsCount,
                                    suggestedWeight: weight,
                                    groupKind: .superset,
                                    groupID: groupID
                                )
                            }
                        } else if let exerciseID = configuration.exerciseIDs.first {
                            store.addExercise(
                                to: workoutID,
                                exerciseID: exerciseID,
                                reps: reps,
                                setsCount: setsCount,
                                suggestedWeight: weight,
                                groupKind: .regular,
                                groupID: nil
                            )
                        }

                        pendingConfiguration = nil
                        selectedExerciseIDs.removeAll()
                        dismiss()
                    }
                )
                .presentationDetents([.height(380)])
                .presentationDragIndicator(.visible)
            }
            .appScreenBackground()
        }
    }

    private func toggleSelection(for exerciseID: UUID) {
        if let index = selectedExerciseIDs.firstIndex(of: exerciseID) {
            selectedExerciseIDs.remove(at: index)
            return
        }

        if isSuperset {
            guard selectedExerciseIDs.count < 2 else { return }
            selectedExerciseIDs.append(exerciseID)
        } else {
            selectedExerciseIDs = [exerciseID]
        }

        presentConfigurationIfNeeded()
    }

    private func presentConfigurationIfNeeded() {
        guard pendingConfiguration == nil else { return }

        if isSuperset, selectedExerciseIDs.count == 2 {
            let names = selectedExerciseIDs.compactMap { store.exercise(for: $0)?.name }
            pendingConfiguration = PendingExerciseConfiguration(
                exerciseIDs: selectedExerciseIDs,
                isSuperset: true,
                title: names.joined(separator: " + ")
            )
        } else if !isSuperset, let exerciseID = selectedExerciseIDs.first, let exercise = store.exercise(for: exerciseID) {
            pendingConfiguration = PendingExerciseConfiguration(
                exerciseIDs: [exerciseID],
                isSuperset: false,
                title: exercise.name
            )
        }
    }
}

private struct PendingExerciseConfiguration: Identifiable {
    let id = UUID()
    let exerciseIDs: [UUID]
    let isSuperset: Bool
    let title: String
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
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.title3.weight(.heavy))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

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
                .padding(.bottom, 8)
            }
            .navigationTitle("template.configure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") {
                        onSave(selectedSetsCount, selectedReps, Double(weightStep) / 2)
                        dismiss()
                    }
                }
            }
            .appScreenBackground()
        }
    }

    private func wheelColumn<Content: View>(titleKey: LocalizedStringKey, width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            Text(titleKey)
                .font(.caption.weight(.semibold))
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
