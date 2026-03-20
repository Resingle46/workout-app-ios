import SwiftUI

struct ProgramsView: View {
    @Environment(AppStore.self) private var store
    @State private var showingCreateProgram = false

    var body: some View {
        List {
            ForEach(store.programs) { program in
                NavigationLink(destination: ProgramDetailView(programID: program.id)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(program.title)
                            .font(.headline)
                        Text(String(format: NSLocalizedString("program.workout_count", comment: ""), program.workouts.count))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("programs.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCreateProgram = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingCreateProgram) {
            CreateProgramView()
        }
    }
}

struct ProgramDetailView: View {
    @Environment(AppStore.self) private var store
    let programID: UUID
    @State private var showingCreateWorkout = false

    private var program: WorkoutProgram? {
        store.programs.first(where: { $0.id == programID })
    }

    var body: some View {
        Group {
            if let program {
                List {
                    ForEach(program.workouts) { workout in
                        NavigationLink(destination: WorkoutTemplateDetailView(programID: program.id, workoutID: workout.id)) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(workout.title)
                                    .font(.headline)
                                Text(workout.focus)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(String(format: NSLocalizedString("program.exercise_count", comment: ""), workout.exercises.count))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(NSLocalizedString("action.start", comment: "")) {
                                store.startWorkout(template: workout)
                            }
                            .tint(.green)
                        }
                    }
                }
                .navigationTitle(program.title)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingCreateWorkout = true
                        } label: {
                            Label("action.add_workout", systemImage: "plus")
                        }
                    }
                }
                .sheet(isPresented: $showingCreateWorkout) {
                    CreateWorkoutView(programID: programID)
                }
            } else {
                ContentUnavailableView("error.not_found", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

struct CreateProgramView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("program.name", comment: ""), text: $title)
            }
            .navigationTitle("program.create")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        store.addProgram(title: title.isEmpty ? NSLocalizedString("program.default_name", comment: "") : title)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct CreateWorkoutView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let programID: UUID
    @State private var title = ""
    @State private var focus = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("workout.name", comment: ""), text: $title)
                TextField(NSLocalizedString("workout.focus", comment: ""), text: $focus)
            }
            .navigationTitle("action.add_workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        store.addWorkout(programID: programID, title: title.isEmpty ? NSLocalizedString("workout.default_name", comment: "") : title, focus: focus)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
