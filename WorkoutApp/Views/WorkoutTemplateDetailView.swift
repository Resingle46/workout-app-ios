import SwiftUI

struct WorkoutTemplateDetailView: View {
    @Environment(AppStore.self) private var store
    let programID: UUID
    let workoutID: UUID
    @State private var showingAddExercise = false

    private var workout: WorkoutTemplate? {
        store.programs.first(where: { $0.id == programID })?.workouts.first(where: { $0.id == workoutID })
    }

    var body: some View {
        Group {
            if let workout {
                List {
                    Section {
                        Button {
                            store.startWorkout(template: workout)
                        } label: {
                            Label("action.start_workout", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    ForEach(groupedExercises(workout.exercises), id: \.id) { group in
                        Section {
                            ForEach(group.items) { item in
                                if let exercise = store.exercise(for: item.exerciseID) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(exercise.name)
                                                .font(.headline)
                                            if item.groupKind == .superset {
                                                Spacer()
                                                Text("label.superset")
                                                    .font(.caption.weight(.semibold))
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.orange.opacity(0.15), in: Capsule())
                                            }
                                        }
                                        Text(exercise.equipment)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Text(String(format: NSLocalizedString("template.reps_summary", comment: ""), item.sets.map { "\($0.reps)" }.joined(separator: " / ")))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            if group.isSuperset {
                                Label("label.superset", systemImage: "bolt.fill")
                            }
                        }
                    }
                }
                .navigationTitle(workout.title)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingAddExercise = true
                        } label: {
                            Label("action.add_exercise", systemImage: "plus")
                        }
                    }
                }
                .sheet(isPresented: $showingAddExercise) {
                    AddExerciseToWorkoutView(workoutID: workoutID)
                }
            } else {
                ContentUnavailableView("error.not_found", systemImage: "exclamationmark.triangle")
            }
        }
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

struct AddExerciseToWorkoutView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let workoutID: UUID
    @State private var query = ""
    @State private var selectedCategoryID: UUID?
    @State private var selectedExerciseIDs: Set<UUID> = []
    @State private var reps = 10
    @State private var setsCount = 3
    @State private var isSuperset = false
    @State private var showingCreateExercise = false

    private var filteredExercises: [Exercise] {
        store.exercises.filter { exercise in
            let matchesCategory = selectedCategoryID == nil || exercise.categoryID == selectedCategoryID
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesQuery = normalized.isEmpty || exercise.name.localizedCaseInsensitiveContains(normalized) || exercise.equipment.localizedCaseInsensitiveContains(normalized)
            return matchesCategory && matchesQuery
        }
    }

    private var canSave: Bool {
        isSuperset ? selectedExerciseIDs.count == 2 : selectedExerciseIDs.count == 1
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("catalog.search", comment: "")) {
                    TextField(NSLocalizedString("catalog.search_placeholder", comment: ""), text: $query)
                    Picker(NSLocalizedString("catalog.category", comment: ""), selection: $selectedCategoryID) {
                        Text("common.all").tag(UUID?.none)
                        ForEach(store.categories) { category in
                            Text(LocalizedStringKey(category.nameKey)).tag(UUID?.some(category.id))
                        }
                    }
                    Button {
                        showingCreateExercise = true
                    } label: {
                        Label("catalog.create_custom", systemImage: "plus.circle")
                    }
                }

                Section(NSLocalizedString("catalog.results", comment: "")) {
                    ForEach(filteredExercises) { exercise in
                        Button {
                            toggleSelection(for: exercise.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(exercise.name)
                                        .foregroundStyle(.primary)
                                    Text(exercise.equipment)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedExerciseIDs.contains(exercise.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }

                Section(NSLocalizedString("template.settings", comment: "")) {
                    Stepper(value: $setsCount, in: 1...8) {
                        Text(String(format: NSLocalizedString("template.sets", comment: ""), setsCount))
                    }
                    Stepper(value: $reps, in: 1...30) {
                        Text(String(format: NSLocalizedString("template.reps", comment: ""), reps))
                    }
                    Toggle("template.superset", isOn: $isSuperset)
                    Text(LocalizedStringKey(isSuperset ? "template.superset_hint_pair" : "template.superset_hint_single"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("action.add_exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.add") {
                        saveSelection()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingCreateExercise) {
                CreateCustomExerciseView(onSave: { name, equipment, notes, categoryID in
                    let exercise = store.addCustomExercise(name: name, categoryID: categoryID, equipment: equipment, notes: notes)
                    selectedCategoryID = categoryID
                    selectedExerciseIDs = [exercise.id]
                })
            }
        }
    }

    private func toggleSelection(for exerciseID: UUID) {
        if selectedExerciseIDs.contains(exerciseID) {
            selectedExerciseIDs.remove(exerciseID)
            return
        }

        if isSuperset {
            if selectedExerciseIDs.count < 2 {
                selectedExerciseIDs.insert(exerciseID)
            }
        } else {
            selectedExerciseIDs = [exerciseID]
        }
    }

    private func saveSelection() {
        let ids = Array(selectedExerciseIDs)
        if isSuperset {
            let groupID = UUID()
            for exerciseID in ids.prefix(2) {
                store.addExercise(
                    to: workoutID,
                    exerciseID: exerciseID,
                    reps: reps,
                    setsCount: setsCount,
                    groupKind: .superset,
                    groupID: groupID
                )
            }
        } else if let exerciseID = ids.first {
            store.addExercise(
                to: workoutID,
                exerciseID: exerciseID,
                reps: reps,
                setsCount: setsCount,
                groupKind: .regular,
                groupID: nil
            )
        }
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
            Form {
                TextField("exercise.name", text: $name)
                Picker("catalog.category", selection: $selectedCategoryID) {
                    ForEach(store.categories) { category in
                        Text(LocalizedStringKey(category.nameKey)).tag(UUID?.some(category.id))
                    }
                }
                TextField("exercise.equipment", text: $equipment)
                TextField("exercise.notes", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            }
            .navigationTitle("exercise.new")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        guard let categoryID = selectedCategoryID else { return }
                        onSave(name, equipment, notes, categoryID)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedCategoryID == nil)
                }
            }
            .onAppear {
                selectedCategoryID = selectedCategoryID ?? store.categories.first?.id
            }
        }
    }
}
