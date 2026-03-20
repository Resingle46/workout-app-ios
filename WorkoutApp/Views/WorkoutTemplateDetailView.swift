import SwiftUI

struct WorkoutTemplateDetailView: View {
    @Environment(AppStore.self) private var store
    let programID: UUID
    let workoutID: UUID
    @State private var showingAddExercise = false
    @State private var showingAddWorkout = false

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

                    ForEach(Array(workout.exercises.enumerated()), id: \.element.id) { _, item in
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
                                Text(item.sets.map { "\($0.reps)" }.joined(separator: " / ") + " reps")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
}

struct AddExerciseToWorkoutView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let workoutID: UUID
    @State private var query = ""
    @State private var selectedCategoryID: UUID?
    @State private var selectedExerciseID: UUID?
    @State private var reps = 10
    @State private var setsCount = 3
    @State private var isSuperset = false
    @State private var supersetGroupID = UUID()

    private var filteredExercises: [Exercise] {
        store.exercises.filter { exercise in
            let matchesCategory = selectedCategoryID == nil || exercise.categoryID == selectedCategoryID
            let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesQuery = normalized.isEmpty || exercise.name.localizedCaseInsensitiveContains(normalized) || exercise.equipment.localizedCaseInsensitiveContains(normalized)
            return matchesCategory && matchesQuery
        }
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
                }

                Section(NSLocalizedString("catalog.results", comment: "")) {
                    ForEach(filteredExercises) { exercise in
                        Button {
                            selectedExerciseID = exercise.id
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
                                if selectedExerciseID == exercise.id {
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
                }
            }
            .navigationTitle("action.add_exercise")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.add") {
                        guard let selectedExerciseID else { return }
                        store.addExercise(
                            to: workoutID,
                            exerciseID: selectedExerciseID,
                            reps: reps,
                            setsCount: setsCount,
                            groupKind: isSuperset ? .superset : .regular,
                            groupID: isSuperset ? supersetGroupID : nil
                        )
                        dismiss()
                    }
                    .disabled(selectedExerciseID == nil)
                }
            }
        }
    }
}
