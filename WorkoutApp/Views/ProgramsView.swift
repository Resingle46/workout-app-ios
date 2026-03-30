import SwiftUI

struct ProgramsView: View {
    var body: some View {
        ProgramsLibraryView()
    }
}

struct ProgramsLibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appBottomRailInset) private var bottomRailInset
    @State private var showingCreateProgram = false
    let onNavigateBack: (() -> Void)? = nil
    let onOpenProgram: ((UUID) -> Void)? = nil

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header

                if store.programs.isEmpty {
                    emptyState
                } else {
                    ForEach(store.programs) { program in
                        if let onOpenProgram {
                            Button {
                                onOpenProgram(program.id)
                            } label: {
                                programOverviewCard(program)
                            }
                            .buttonStyle(AppInteractiveCardButtonStyle())
                            .padding(.horizontal, 8)
                        } else {
                            NavigationLink(destination: ProgramDetailView(programID: program.id)) {
                                programOverviewCard(program)
                            }
                            .buttonStyle(AppInteractiveCardButtonStyle())
                            .padding(.horizontal, 8)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 28 + bottomRailInset)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingCreateProgram) {
            CreateProgramView()
        }
        .appScreenBackground()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let onNavigateBack {
                Button(action: onNavigateBack) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(AppTypography.icon(size: 14, weight: .bold))
                        Text("today.programs.back")
                            .font(AppTypography.caption(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppTheme.surfaceElevated, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            AppPageHeaderModule(titleKey: "header.programs.title", subtitleKey: "header.programs.subtitle") {
                Button {
                    showingCreateProgram = true
                } label: {
                    Image(systemName: "plus")
                        .font(AppTypography.icon(size: 20, weight: .medium))
                        .foregroundStyle(AppTheme.primaryText)
                        .frame(width: 42, height: 42)
                        .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(AppTheme.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        ProgramsCompactCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("programs.empty_title")
                    .font(AppTypography.title(size: 26))
                Text("programs.empty_description")
                    .font(AppTypography.body())
                    .foregroundStyle(AppTheme.secondaryText)
                Button {
                    showingCreateProgram = true
                } label: {
                    Text("action.create_program")
                }
                .buttonStyle(AppPrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func programOverviewCard(_ program: WorkoutProgram) -> some View {
        ProgramsCompactCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(program.title)
                            .font(AppTypography.heading(size: 24))
                            .foregroundStyle(AppTheme.primaryText)
                        Text(String(format: NSLocalizedString("program.workout_count", comment: ""), program.workouts.count))
                            .font(AppTypography.body(size: 17, weight: .medium, relativeTo: .subheadline))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppTypography.icon(size: 17, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Divider()
                    .overlay(AppTheme.stroke)

                if program.workouts.isEmpty {
                    Text("program.no_workouts")
                        .font(AppTypography.body(size: 16, relativeTo: .subheadline))
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
                                    .font(AppTypography.caption())
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ProgramsCompactCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .font(AppTypography.body())
            .appSurfaceCard(padding: 18)
    }
}

struct ProgramDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appBottomRailInset) private var bottomRailInset
    @Environment(\.dismiss) private var dismiss

    let programID: UUID
    let onOpenWorkoutTemplate: ((UUID) -> Void)? = nil
    @State private var showingCreateWorkout = false
    @State private var editingProgram: EditableProgram?
    @State private var editingWorkout: EditableWorkout?

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
                                    .font(AppTypography.title(size: 30))
                                Text(String(format: NSLocalizedString("program.workout_count", comment: ""), program.workouts.count))
                                    .font(AppTypography.body(size: 18, weight: .medium))
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
                                        .font(AppTypography.body(size: 16, relativeTo: .subheadline))
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
                                                    .font(AppTypography.heading(size: 21))
                                                Group {
                                                    if workout.focus.isEmpty {
                                                        Text("workout.focus_empty")
                                                    } else {
                                                        Text(workout.focus)
                                                    }
                                                }
                                                    .font(AppTypography.body(size: 16, relativeTo: .subheadline))
                                                    .foregroundStyle(AppTheme.secondaryText)
                                                Text(String(format: NSLocalizedString("program.exercise_count", comment: ""), workout.exercises.count))
                                                    .font(AppTypography.caption())
                                                    .foregroundStyle(AppTheme.secondaryText)
                                            }

                                            Spacer()

                                            Menu {
                                                Button {
                                                    editingWorkout = EditableWorkout(
                                                        id: workout.id,
                                                        title: workout.title,
                                                        focus: workout.focus
                                                    )
                                                } label: {
                                                    Label("action.edit", systemImage: "pencil")
                                                }

                                                Button(role: .destructive) {
                                                    store.deleteWorkout(programID: programID, workoutID: workout.id)
                                                } label: {
                                                    Label("common.delete", systemImage: "trash")
                                                }
                                            } label: {
                                                Image(systemName: "ellipsis.circle")
                                                    .font(AppTypography.icon(size: 20, weight: .medium))
                                                    .foregroundStyle(AppTheme.secondaryText)
                                            }
                                        }

                                        VStack(spacing: 12) {
                                            if let onOpenWorkoutTemplate {
                                                Button {
                                                    onOpenWorkoutTemplate(workout.id)
                                                } label: {
                                                    Label("program.open_workout", systemImage: "square.grid.2x2")
                                                }
                                                .buttonStyle(AppSecondaryButtonStyle())
                                            } else {
                                                NavigationLink(destination: WorkoutTemplateDetailView(programID: programID, workoutID: workout.id)) {
                                                    Label("program.open_workout", systemImage: "square.grid.2x2")
                                                }
                                                .buttonStyle(AppSecondaryButtonStyle())
                                            }

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
                    .padding(.bottom, 28 + bottomRailInset)
                }
                .navigationTitle(program.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                editingProgram = EditableProgram(
                                    id: program.id,
                                    title: program.title
                                )
                            } label: {
                                Label("action.edit", systemImage: "pencil")
                            }

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
                .sheet(item: $editingProgram) { editableProgram in
                    CreateProgramView(
                        programID: editableProgram.id,
                        initialTitle: editableProgram.title
                    )
                }
                .sheet(item: $editingWorkout) { editableWorkout in
                    CreateWorkoutView(
                        programID: programID,
                        workoutID: editableWorkout.id,
                        initialTitle: editableWorkout.title,
                        initialFocus: editableWorkout.focus
                    )
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
    let programID: UUID?
    @State private var title: String

    private var isEditing: Bool {
        programID != nil
    }

    init(programID: UUID? = nil, initialTitle: String = "") {
        self.programID = programID
        _title = State(initialValue: initialTitle)
    }

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
            .navigationTitle(isEditing ? "program.edit" : "program.create")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let resolvedTitle = trimmedTitle.isEmpty
                            ? NSLocalizedString("program.default_name", comment: "")
                            : trimmedTitle

                        if let programID {
                            store.updateProgram(id: programID, title: resolvedTitle)
                        } else {
                            store.addProgram(title: resolvedTitle)
                        }
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
    let workoutID: UUID?

    @State private var title: String
    @State private var focus: String

    private var isEditing: Bool {
        workoutID != nil
    }

    init(
        programID: UUID,
        workoutID: UUID? = nil,
        initialTitle: String = "",
        initialFocus: String = ""
    ) {
        self.programID = programID
        self.workoutID = workoutID
        _title = State(initialValue: initialTitle)
        _focus = State(initialValue: initialFocus)
    }

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
            .navigationTitle(isEditing ? "workout.edit" : "action.add_workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.save") {
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedFocus = focus.trimmingCharacters(in: .whitespacesAndNewlines)
                        let resolvedTitle = trimmedTitle.isEmpty
                            ? NSLocalizedString("workout.default_name", comment: "")
                            : trimmedTitle

                        if let workoutID {
                            store.updateWorkout(
                                programID: programID,
                                workoutID: workoutID,
                                title: resolvedTitle,
                                focus: trimmedFocus
                            )
                        } else {
                            store.addWorkout(
                                programID: programID,
                                title: resolvedTitle,
                                focus: trimmedFocus
                            )
                        }
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .appScreenBackground()
        }
    }
}

private struct EditableProgram: Identifiable {
    let id: UUID
    let title: String
}

private struct EditableWorkout: Identifiable {
    let id: UUID
    let title: String
    let focus: String
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
