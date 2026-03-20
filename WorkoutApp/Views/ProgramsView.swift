import SwiftUI

struct ProgramsView: View {
    @Environment(AppStore.self) private var store
    @State private var showingCreateProgram = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if store.programs.isEmpty {
                    emptyState
                } else {
                    ForEach(store.programs) { program in
                        NavigationLink(destination: ProgramDetailView(programID: program.id)) {
                            AppCard {
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(program.title)
                                                .font(.system(size: 24, weight: .black, design: .rounded))
                                                .foregroundStyle(AppTheme.primaryText)
                                            Text(String(format: NSLocalizedString("program.workout_count", comment: ""), program.workouts.count))
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(AppTheme.secondaryText)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.headline.weight(.bold))
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }

                                    Divider()
                                        .overlay(AppTheme.stroke)

                                    if program.workouts.isEmpty {
                                        Text("program.no_workouts")
                                            .font(.subheadline)
                                            .foregroundStyle(AppTheme.secondaryText)
                                    } else {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(Array(program.workouts.prefix(3).enumerated()), id: \.element.id) { index, workout in
                                                HStack {
                                                    Text("\(index + 1).")
                                                        .foregroundStyle(AppTheme.secondaryText)
                                                    Text(workout.title)
                                                        .foregroundStyle(AppTheme.primaryText)
                                                    Spacer()
                                                    Text(String(format: NSLocalizedString("program.exercise_count", comment: ""), workout.exercises.count))
                                                        .font(.caption.weight(.medium))
                                                        .foregroundStyle(AppTheme.secondaryText)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCreateProgram = true
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.primaryText)
                }
            }
        }
        .sheet(isPresented: $showingCreateProgram) {
            CreateProgramView()
        }
        .appScreenBackground()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("programs.title")
                .font(.system(size: 38, weight: .black, design: .rounded))
            Text("programs.subtitle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private var emptyState: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("programs.empty_title")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                Text("programs.empty_description")
                    .font(.body)
                    .foregroundStyle(AppTheme.secondaryText)
                Button {
                    showingCreateProgram = true
                } label: {
                    Text("action.create_program")
                }
                .buttonStyle(AppPrimaryButtonStyle())
            }
        }
    }
}

struct ProgramDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let programID: UUID
    @State private var showingCreateWorkout = false

    private var program: WorkoutProgram? {
        store.program(for: programID)
    }

    var body: some View {
        Group {
            if let program {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        AppCard {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(program.title)
                                    .font(.system(size: 30, weight: .black, design: .rounded))
                                Text(String(format: NSLocalizedString("program.workout_count", comment: ""), program.workouts.count))
                                    .foregroundStyle(AppTheme.secondaryText)

                                HStack(spacing: 12) {
                                    Button {
                                        showingCreateWorkout = true
                                    } label: {
                                        Label("action.add_workout", systemImage: "plus")
                                    }
                                    .buttonStyle(AppSecondaryButtonStyle())
                                }
                            }
                        }

                        if program.workouts.isEmpty {
                            AppCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    AppSectionTitle(titleKey: "program.no_workouts_label")
                                    Text("program.no_workouts_description")
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                            }
                        } else {
                            ForEach(program.workouts) { workout in
                                AppCard {
                                    VStack(alignment: .leading, spacing: 16) {
                                        HStack(alignment: .top, spacing: 12) {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text(workout.title)
                                                    .font(.title3.weight(.heavy))
                                                Text(workout.focus.isEmpty ? String(localized: "workout.focus_empty") : workout.focus)
                                                    .font(.subheadline)
                                                    .foregroundStyle(AppTheme.secondaryText)
                                                Text(String(format: NSLocalizedString("program.exercise_count", comment: ""), workout.exercises.count))
                                                    .font(.caption.weight(.medium))
                                                    .foregroundStyle(AppTheme.secondaryText)
                                            }

                                            Spacer()

                                            Menu {
                                                Button(role: .destructive) {
                                                    store.deleteWorkout(programID: programID, workoutID: workout.id)
                                                } label: {
                                                    Label("common.delete", systemImage: "trash")
                                                }
                                            } label: {
                                                Image(systemName: "ellipsis.circle")
                                                    .font(.title3)
                                                    .foregroundStyle(AppTheme.secondaryText)
                                            }
                                        }

                                        VStack(spacing: 12) {
                                            NavigationLink(destination: WorkoutTemplateDetailView(programID: programID, workoutID: workout.id)) {
                                                Label("program.open_workout", systemImage: "square.grid.2x2")
                                            }
                                            .buttonStyle(AppSecondaryButtonStyle())

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
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 28)
                }
                .navigationTitle(program.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showingCreateWorkout = true
                            } label: {
                                Label("action.add_workout", systemImage: "plus")
                            }

                            Button(role: .destructive) {
                                store.deleteProgram(id: programID)
                                dismiss()
                            } label: {
                                Label("program.delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(AppTheme.primaryText)
                        }
                    }
                }
                .sheet(isPresented: $showingCreateWorkout) {
                    CreateWorkoutView(programID: programID)
                }
                .appScreenBackground()
            } else {
                ContentUnavailableView("error.not_found", systemImage: "exclamationmark.triangle")
                    .appScreenBackground()
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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppCard {
                        VStack(alignment: .leading, spacing: 16) {
                            AppSectionTitle(titleKey: "program.name")
                            AppInputField(titleKey: "program.name", text: $title)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("program.create")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.addProgram(title: trimmedTitle.isEmpty ? NSLocalizedString("program.default_name", comment: "") : trimmedTitle)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .appScreenBackground()
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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppCard {
                        VStack(alignment: .leading, spacing: 16) {
                            AppSectionTitle(titleKey: "workout.name")
                            AppInputField(titleKey: "workout.name", text: $title)
                            AppSectionTitle(titleKey: "workout.focus")
                            AppInputField(titleKey: "workout.focus", text: $focus)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("action.add_workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedFocus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.addWorkout(
                            programID: programID,
                            title: trimmedTitle.isEmpty ? NSLocalizedString("workout.default_name", comment: "") : trimmedTitle,
                            focus: trimmedFocus
                        )
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .appScreenBackground()
        }
    }
}

private struct AppInputField: View {
    let titleKey: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        TextField(titleKey, text: $text)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.stroke, lineWidth: 1)
            )
    }
}
