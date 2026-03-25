import XCTest
@testable import WorkoutApp

final class BackupCoordinatorTests: XCTestCase {
    func testBackupEnvelopeRoundTripsSnapshot() throws {
        let snapshot = makeSnapshot()
        let createdAt = Date(timeIntervalSince1970: 1_710_000_000)
        let envelope = try BackupEnvelope.make(
            snapshot: snapshot,
            createdAt: createdAt,
            appVersion: "2.1",
            buildNumber: "7"
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(BackupEnvelope.self, from: data)

        XCTAssertEqual(decoded, envelope)
    }

    func testSnapshotHashChangesWhenSnapshotChanges() throws {
        let snapshot = makeSnapshot()
        var changedSnapshot = snapshot
        changedSnapshot.profile.weight = 92

        XCTAssertNotEqual(
            try BackupHashing.hash(for: snapshot),
            try BackupHashing.hash(for: changedSnapshot)
        )
    }

    func testBackupWritesJSONFileToSelectedFolder() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let status = try await fixture.coordinator.selectBackupFolder(fixture.folderURL)
        XCTAssertEqual(status.availability, .ready)

        let backupStatus = await fixture.coordinator.backupNow(snapshot: makeSnapshot())
        let files = try backupFiles(in: fixture.folderURL)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(backupStatus.latestBackup?.fileName, files.first?.lastPathComponent)
        XCTAssertEqual(backupStatus.availability, .ready)
    }

    func testRotationKeepsOnlyThreeLatestBackups() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.coordinator.selectBackupFolder(fixture.folderURL)

        for index in 0..<4 {
            fixture.clock.currentDate = Date(timeIntervalSince1970: 1_710_000_000 + TimeInterval(index * 60))
            var snapshot = makeSnapshot()
            snapshot.profile.age += index
            _ = await fixture.coordinator.backupNow(snapshot: snapshot)
        }

        let files = try backupFiles(in: fixture.folderURL)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.first?.lastPathComponent, "WorkoutApp-backup-2024-03-09-16-03-00.json")
    }

    func testRestoreLatestReturnsNewestValidSnapshot() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.coordinator.selectBackupFolder(fixture.folderURL)

        var firstSnapshot = makeSnapshot()
        firstSnapshot.profile.weight = 80
        fixture.clock.currentDate = Date(timeIntervalSince1970: 1_710_000_000)
        _ = await fixture.coordinator.backupNow(snapshot: firstSnapshot)

        var secondSnapshot = makeSnapshot()
        secondSnapshot.profile.weight = 96
        fixture.clock.currentDate = Date(timeIntervalSince1970: 1_710_000_120)
        _ = await fixture.coordinator.backupNow(snapshot: secondSnapshot)

        let restored = try await fixture.coordinator.restoreLatestBackup()
        XCTAssertEqual(restored.snapshot, secondSnapshot)
    }

    func testBackupIsSkippedWhenSnapshotDidNotChange() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.coordinator.selectBackupFolder(fixture.folderURL)

        let snapshot = makeSnapshot()
        fixture.clock.currentDate = Date(timeIntervalSince1970: 1_710_000_000)
        _ = await fixture.coordinator.backupNow(snapshot: snapshot)

        fixture.clock.currentDate = Date(timeIntervalSince1970: 1_710_000_120)
        _ = await fixture.coordinator.backupNow(snapshot: snapshot)

        let files = try backupFiles(in: fixture.folderURL)
        XCTAssertEqual(files.count, 1)
    }

    func testRefreshStatusMarksLostFolderAccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.coordinator.selectBackupFolder(fixture.folderURL)
        try FileManager.default.removeItem(at: fixture.folderURL)

        let status = await fixture.coordinator.refreshStatus()
        XCTAssertEqual(status.availability, .accessLost)
    }

    @MainActor
    func testAppStoreApplyReplacesLocalSnapshot() {
        let store = AppStore()
        let snapshot = makeSnapshot()

        store.startWorkout(template: WorkoutTemplate(title: "Temporary", focus: "Temp", exercises: []))
        store.apply(snapshot: snapshot)

        XCTAssertEqual(store.currentSnapshot(), snapshot)
        XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.history, snapshot.history.sorted { $0.startedAt > $1.startedAt })
        XCTAssertEqual(store.profile, snapshot.profile)
    }

    @MainActor
    func testAppStoreApplyNormalizesSeedExerciseCategoriesAndAppendsMissingSeedCatalog() {
        let legacyCategoryID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let benchID = UUID(uuidString: "ABCDEFAB-CDEF-CDEF-CDEF-ABCDEFABCDEF")!
        let customID = UUID(uuidString: "FEDCBAFE-DCBA-DCBA-DCBA-FEDCBAFEDCBA")!

        let snapshot = AppSnapshot(
            programs: [],
            exercises: [
                Exercise(id: benchID, name: "Barbell Bench Press", categoryID: legacyCategoryID, equipment: "Something Old", notes: "seed"),
                Exercise(id: customID, name: "My Custom Curl", categoryID: legacyCategoryID, equipment: "Band", notes: "custom")
            ],
            history: [],
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "en")
        )

        let store = AppStore()
        store.apply(snapshot: snapshot)

        let migratedBench = try? XCTUnwrap(store.exercises.first(where: { $0.id == benchID }))
        XCTAssertEqual(migratedBench?.categoryID, SeedData.chestCategoryID)
        XCTAssertEqual(migratedBench?.equipment, "Barbell")
        XCTAssertEqual(store.exercises.first(where: { $0.id == customID })?.categoryID, legacyCategoryID)
        XCTAssertEqual(
            store.exercises.filter { $0.name == "Barbell Bench Press" }.count,
            1
        )
        XCTAssertNotNil(store.exercises.first(where: { $0.name == "Bent Over Shrug" }))
        XCTAssertNil(store.exercises.first(where: { $0.name == "Mountain Climber" }))
        XCTAssertNotNil(store.exercises.first(where: { $0.name == "Close Grip Bench Press" }))
    }

    @MainActor
    func testAppStoreApplyRenamesFacePullAndDropsDeprecatedUnreferencedSeedExercise() {
        let facePullID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let deprecatedID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        let snapshot = AppSnapshot(
            programs: [],
            exercises: [
                Exercise(id: facePullID, name: "Face Pull", categoryID: SeedData.shouldersCategoryID, equipment: "Band", notes: ""),
                Exercise(id: deprecatedID, name: "Walking Lunges", categoryID: SeedData.legsCategoryID, equipment: "Dumbbells", notes: "")
            ],
            history: [],
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "en")
        )

        let store = AppStore()
        store.apply(snapshot: snapshot)

        let migratedFacePull = try? XCTUnwrap(store.exercises.first(where: { $0.id == facePullID }))
        XCTAssertEqual(migratedFacePull?.name, "Cable Face Pull")
        XCTAssertEqual(migratedFacePull?.categoryID, SeedData.backCategoryID)
        XCTAssertEqual(migratedFacePull?.equipment, "Cable / Rope")
        XCTAssertNil(store.exercises.first(where: { $0.id == deprecatedID }))
    }

    @MainActor
    func testLocalizedEquipmentUsesRussianTranslationsForSeedEquipment() {
        let exercise = Exercise(
            name: "My Custom Lift",
            categoryID: SeedData.backCategoryID,
            equipment: "Barbell / Bench",
            notes: ""
        )
        let snapshot = AppSnapshot(
            programs: [],
            exercises: [exercise],
            history: [],
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "ru")
        )

        let store = AppStore()
        store.apply(snapshot: snapshot)

        let localizedExercise = try? XCTUnwrap(store.exercises.first(where: { $0.name == "My Custom Lift" }))
        XCTAssertEqual(localizedExercise?.localizedEquipment, "Штанга / Скамья")
    }

    @MainActor
    func testAppStoreAddCustomExercisePreservesProvidedIdentifier() {
        let store = AppStore()
        let exerciseID = UUID(uuidString: "12121212-3434-5656-7878-909090909090")!
        let exercise = Exercise(
            id: exerciseID,
            name: "Tempo Row",
            categoryID: SeedData.backCategoryID,
            equipment: "Cable",
            notes: "Custom"
        )

        store.addCustomExercise(exercise)

        XCTAssertEqual(store.exercises.first(where: { $0.id == exerciseID })?.name, "Tempo Row")
    }

    @MainActor
    func testAddExercisesPreservesSupersetGroupingAndOrder() {
        let programID = UUID(uuidString: "ABABABAB-1111-1111-1111-ABABABABABAB")!
        let workoutID = UUID(uuidString: "CDCDCDCD-2222-2222-2222-CDCDCDCDCDCD")!
        let exerciseA = makeExercise(id: UUID(uuidString: "10101010-0000-0000-0000-000000000001")!, name: "Bench")
        let exerciseB = makeExercise(id: UUID(uuidString: "10101010-0000-0000-0000-000000000002")!, name: "Fly")
        let exerciseC = makeExercise(id: UUID(uuidString: "10101010-0000-0000-0000-000000000003")!, name: "Row")
        let groupID = UUID(uuidString: "30303030-0000-0000-0000-000000000003")!

        let store = AppStore()
        store.apply(snapshot: makeProgramSnapshot(
            programs: [
                WorkoutProgram(
                    id: programID,
                    title: "Program",
                    workouts: [WorkoutTemplate(id: workoutID, title: "Day", focus: "", exercises: [])]
                )
            ],
            exercises: [exerciseA, exerciseB, exerciseC]
        ))

        store.addExercises(
            to: workoutID,
            drafts: [
                WorkoutExerciseDraft(exerciseID: exerciseA.id, reps: 8, setsCount: 3, suggestedWeight: 80, groupKind: .regular, groupID: nil),
                WorkoutExerciseDraft(exerciseID: exerciseB.id, reps: 12, setsCount: 3, suggestedWeight: 18, groupKind: .superset, groupID: groupID),
                WorkoutExerciseDraft(exerciseID: exerciseC.id, reps: 10, setsCount: 3, suggestedWeight: 60, groupKind: .superset, groupID: groupID)
            ]
        )

        let workout = store.workout(programID: programID, workoutID: workoutID)

        XCTAssertEqual(workout?.exercises.map(\.exerciseID), [exerciseA.id, exerciseB.id, exerciseC.id])
        XCTAssertEqual(workout?.exercises[0].groupKind, .regular)
        XCTAssertEqual(workout?.exercises[1].groupKind, .superset)
        XCTAssertEqual(workout?.exercises[2].groupKind, .superset)
        XCTAssertEqual(workout?.exercises[1].groupID, groupID)
        XCTAssertEqual(workout?.exercises[2].groupID, groupID)
    }

    @MainActor
    func testUpdateTemplateExerciseSynchronizesSupersetSetCountAcrossGroup() {
        let programID = UUID(uuidString: "40404040-0000-0000-0000-000000000004")!
        let workoutID = UUID(uuidString: "50505050-0000-0000-0000-000000000005")!
        let templateAID = UUID(uuidString: "60606060-0000-0000-0000-000000000006")!
        let templateBID = UUID(uuidString: "70707070-0000-0000-0000-000000000007")!
        let groupID = UUID(uuidString: "80808080-0000-0000-0000-000000000008")!
        let exerciseA = makeExercise(id: UUID(uuidString: "90909090-0000-0000-0000-000000000009")!, name: "Bench")
        let exerciseB = makeExercise(id: UUID(uuidString: "91919191-0000-0000-0000-000000000010")!, name: "Fly")

        let workout = WorkoutTemplate(
            id: workoutID,
            title: "Push",
            focus: "",
            exercises: [
                WorkoutExerciseTemplate(
                    id: templateAID,
                    exerciseID: exerciseA.id,
                    sets: [WorkoutSetTemplate(reps: 8, suggestedWeight: 80), WorkoutSetTemplate(reps: 8, suggestedWeight: 80)],
                    groupKind: .superset,
                    groupID: groupID
                ),
                WorkoutExerciseTemplate(
                    id: templateBID,
                    exerciseID: exerciseB.id,
                    sets: [WorkoutSetTemplate(reps: 12, suggestedWeight: 20), WorkoutSetTemplate(reps: 12, suggestedWeight: 20)],
                    groupKind: .superset,
                    groupID: groupID
                )
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeProgramSnapshot(
            programs: [WorkoutProgram(id: programID, title: "Program", workouts: [workout])],
            exercises: [exerciseA, exerciseB]
        ))

        store.updateTemplateExercise(
            programID: programID,
            workoutID: workoutID,
            templateExerciseID: templateAID,
            reps: 6,
            setsCount: 4,
            suggestedWeight: 90
        )

        let updatedWorkout = store.workout(programID: programID, workoutID: workoutID)
        XCTAssertEqual(updatedWorkout?.exercises[0].sets.count, 4)
        XCTAssertEqual(updatedWorkout?.exercises[1].sets.count, 4)
        XCTAssertEqual(updatedWorkout?.exercises[1].sets.first?.reps, 12)
        XCTAssertEqual(updatedWorkout?.exercises[1].sets.first?.suggestedWeight, 20)
    }

    @MainActor
    func testStartWorkoutNormalizesSupersetSetCountFromFirstExercise() {
        let groupID = UUID(uuidString: "A0A0A0A0-0000-0000-0000-000000000011")!
        let exerciseA = makeExercise(id: UUID(uuidString: "A1A1A1A1-0000-0000-0000-000000000012")!, name: "Bench")
        let exerciseB = makeExercise(id: UUID(uuidString: "A2A2A2A2-0000-0000-0000-000000000013")!, name: "Fly")
        let template = WorkoutTemplate(
            title: "Push",
            focus: "",
            exercises: [
                WorkoutExerciseTemplate(
                    exerciseID: exerciseA.id,
                    sets: [
                        WorkoutSetTemplate(reps: 8, suggestedWeight: 80),
                        WorkoutSetTemplate(reps: 8, suggestedWeight: 80),
                        WorkoutSetTemplate(reps: 8, suggestedWeight: 80),
                        WorkoutSetTemplate(reps: 8, suggestedWeight: 80)
                    ],
                    groupKind: .superset,
                    groupID: groupID
                ),
                WorkoutExerciseTemplate(
                    exerciseID: exerciseB.id,
                    sets: [
                        WorkoutSetTemplate(reps: 12, suggestedWeight: 20),
                        WorkoutSetTemplate(reps: 12, suggestedWeight: 20)
                    ],
                    groupKind: .superset,
                    groupID: groupID
                )
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeProgramSnapshot(programs: [], exercises: [exerciseA, exerciseB]))

        store.startWorkout(template: template)

        XCTAssertEqual(store.activeSession?.exercises[0].sets.count, 4)
        XCTAssertEqual(store.activeSession?.exercises[1].sets.count, 4)
    }

    func testActiveWorkoutDisplayResolverBuildsSupersetRoundsAndCurrentOrder() {
        let exerciseA = makeExercise(id: UUID(uuidString: "B1B1B1B1-0000-0000-0000-000000000014")!, name: "Bench")
        let exerciseB = makeExercise(id: UUID(uuidString: "B2B2B2B2-0000-0000-0000-000000000015")!, name: "Fly")
        let groupID = UUID(uuidString: "B3B3B3B3-0000-0000-0000-000000000016")!
        let session = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 20, hour: 10),
            endedAt: nil,
            exerciseLogs: [
                makeExerciseLog(groupID: groupID, groupKind: .superset, exerciseID: exerciseA.id, sets: [(80, 8, true), (80, 8, false)]),
                makeExerciseLog(groupID: groupID, groupKind: .superset, exerciseID: exerciseB.id, sets: [(20, 12, false), (20, 12, false)])
            ]
        )

        let blocks = ActiveWorkoutDisplayResolver.buildBlocks(
            session: session,
            exercisesByID: [exerciseA.id: exerciseA, exerciseB.id: exerciseB]
        )

        guard let firstBlock = blocks.first, case .superset(let block) = firstBlock else {
            return XCTFail("Expected superset block")
        }

        XCTAssertEqual(block.rounds.count, 2)
        XCTAssertEqual(block.rounds[0].items.count, 2)
        XCTAssertEqual(block.rounds[0].items.map(\.exercise.id), [exerciseA.id, exerciseB.id])
        XCTAssertEqual(
            ActiveWorkoutDisplayResolver.currentSetPosition(in: blocks),
            CurrentWorkoutSetPosition(exerciseIndex: 1, setIndex: 0)
        )
    }

    func testActiveWorkoutDisplayResolverProgressTreatsSupersetAsSingleLogicalStep() {
        let exerciseA = makeExercise(id: UUID(uuidString: "C1C1C1C1-0000-0000-0000-000000000017")!, name: "Bench")
        let exerciseB = makeExercise(id: UUID(uuidString: "C2C2C2C2-0000-0000-0000-000000000018")!, name: "Fly")
        let exerciseC = makeExercise(id: UUID(uuidString: "C3C3C3C3-0000-0000-0000-000000000019")!, name: "Row")
        let groupID = UUID(uuidString: "C4C4C4C4-0000-0000-0000-000000000020")!
        let session = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 20, hour: 10),
            endedAt: nil,
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(80, 8, true)]),
                makeExerciseLog(groupID: groupID, groupKind: .superset, exerciseID: exerciseB.id, sets: [(20, 12, false)]),
                makeExerciseLog(groupID: groupID, groupKind: .superset, exerciseID: exerciseC.id, sets: [(60, 10, false)])
            ]
        )

        let blocks = ActiveWorkoutDisplayResolver.buildBlocks(
            session: session,
            exercisesByID: [exerciseA.id: exerciseA, exerciseB.id: exerciseB, exerciseC.id: exerciseC]
        )
        let progress = ActiveWorkoutDisplayResolver.progress(for: blocks)

        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.completed, 1)
        XCTAssertEqual(progress.remaining, 1)
        XCTAssertEqual(progress.currentStep, 2)
    }

    @MainActor
    func testExerciseCatalogIndexFiltersByLocalizedQueryAndCategory() {
        let snapshot = AppSnapshot(
            programs: [],
            exercises: [
                Exercise(name: "Barbell Bench Press", categoryID: SeedData.chestCategoryID, equipment: "Barbell"),
                Exercise(name: "Barbell Row", categoryID: SeedData.backCategoryID, equipment: "Barbell")
            ],
            history: [],
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "ru")
        )

        let store = AppStore()
        store.apply(snapshot: snapshot)

        let index = ExerciseCatalogIndex.build(
            exercises: store.exercises,
            categories: store.categories,
            localeIdentifier: store.locale.identifier
        )

        let localizedRows = index.filteredRows(categoryID: nil, query: "штанги лёжа")
        XCTAssertEqual(localizedRows.map(\.exercise.name), ["Barbell Bench Press"])

        let backRows = index.filteredRows(categoryID: SeedData.backCategoryID, query: "")
        XCTAssertTrue(backRows.allSatisfy { $0.categoryID == SeedData.backCategoryID })
        XCTAssertTrue(backRows.contains(where: { $0.exercise.name == "Barbell Row" }))
    }

    @MainActor
    func testActiveWorkoutDerivedStateBuildsWeightProgressAndRestLookups() {
        let workoutID = UUID(uuidString: "D1D1D1D1-0000-0000-0000-000000000021")!
        let exerciseID = UUID(uuidString: "D2D2D2D2-0000-0000-0000-000000000022")!
        let templateExerciseID = UUID(uuidString: "D3D3D3D3-0000-0000-0000-000000000023")!
        let exercise = Exercise(id: exerciseID, name: "Barbell Bench Press", categoryID: SeedData.chestCategoryID, equipment: "Barbell")
        let template = WorkoutTemplate(
            id: workoutID,
            title: "Push",
            focus: "",
            exercises: [
                WorkoutExerciseTemplate(
                    id: templateExerciseID,
                    exerciseID: exerciseID,
                    sets: [
                        WorkoutSetTemplate(reps: 8, suggestedWeight: 80),
                        WorkoutSetTemplate(reps: 8, suggestedWeight: 80),
                        WorkoutSetTemplate(reps: 8, suggestedWeight: 80)
                    ]
                )
            ]
        )
        let previousSession = WorkoutSession(
            workoutTemplateID: workoutID,
            title: "Push",
            startedAt: makeDate(year: 2024, month: 3, day: 18, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 18, hour: 11),
            exercises: [
                WorkoutExerciseLog(
                    templateExerciseID: templateExerciseID,
                    exerciseID: exerciseID,
                    groupKind: .regular,
                    groupID: nil,
                    sets: [
                        WorkoutSetLog(reps: 8, weight: 77.5, completedAt: makeDate(year: 2024, month: 3, day: 18, hour: 10, minute: 5))
                    ]
                )
            ]
        )

        let store = AppStore()
        store.apply(snapshot: AppSnapshot(
            programs: [WorkoutProgram(title: "Program", workouts: [template])],
            exercises: [exercise],
            history: [previousSession],
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "en")
        ))
        store.startWorkout(template: template)
        store.updateActiveSession { session in
            session.exercises[0].sets[0].completedAt = makeDate(year: 2024, month: 3, day: 20, hour: 10, minute: 0)
            session.exercises[0].sets[1].completedAt = makeDate(year: 2024, month: 3, day: 20, hour: 10, minute: 1)
            session.exercises[0].sets[1].weight = 82.5
        }

        let activeSession = try! XCTUnwrap(store.activeSession)
        let derivedState = ActiveWorkoutDerivedState.build(session: activeSession, store: store)
        let activeExercise = activeSession.exercises[0]

        XCTAssertEqual(
            derivedState.targetWeightText(for: activeExercise),
            String(format: NSLocalizedString("stats.weight_value", comment: ""), 80.0)
        )
        XCTAssertEqual(
            derivedState.previousWeightText(for: activeExercise),
            String(format: NSLocalizedString("stats.weight_value", comment: ""), 77.5)
        )
        XCTAssertEqual(derivedState.progress.total, 1)
        XCTAssertEqual(derivedState.progress.completed, 0)
        XCTAssertEqual(derivedState.currentSetPosition, CurrentWorkoutSetPosition(exerciseIndex: 0, setIndex: 2))
        XCTAssertEqual(
            derivedState.restSummary(for: activeExercise).summaryText,
            String(format: NSLocalizedString("workout.avg_rest", comment: ""), 60)
        )
        XCTAssertNotNil(derivedState.restSummary(for: activeExercise).previousRestText)
        XCTAssertEqual(derivedState.lastCompletedSetDate, makeDate(year: 2024, month: 3, day: 20, hour: 10, minute: 1))
    }

    func testWorkoutDurationFormatterUsesMinuteSecondBelowOneHour() {
        XCTAssertEqual(WorkoutTimeTextFormatter.formatDuration(elapsedSeconds: 3_599), "59:59")
    }

    func testWorkoutDurationFormatterUsesHourMinuteSecondFromOneHour() {
        XCTAssertEqual(WorkoutTimeTextFormatter.formatDuration(elapsedSeconds: 3_605), "01:00:05")
    }

    func testWorkoutLiveRestFormatterReturnsFallbackWithoutLastCompletedSetDate() {
        XCTAssertEqual(
            WorkoutTimeTextFormatter.liveRestString(
                lastCompletedSetDate: nil,
                now: Date(timeIntervalSince1970: 1_710_000_120),
                fallback: "--"
            ),
            "--"
        )
    }

    func testTabBarPresentationResolverReturnsExpandedOutsideWorkoutTab() {
        XCTAssertEqual(
            RootTabBarPresentationResolver.resolve(
                selectedTab: .programs,
                hasActiveWorkout: true,
                workoutTabsExpanded: false
            ),
            .expanded
        )
    }

    func testTabBarPresentationResolverReturnsExpandedWhenNoActiveWorkout() {
        XCTAssertEqual(
            RootTabBarPresentationResolver.resolve(
                selectedTab: .workout,
                hasActiveWorkout: false,
                workoutTabsExpanded: false
            ),
            .expanded
        )
    }

    func testTabBarPresentationResolverReturnsCollapsedWorkoutByDefault() {
        XCTAssertEqual(
            RootTabBarPresentationResolver.resolve(
                selectedTab: .workout,
                hasActiveWorkout: true,
                workoutTabsExpanded: false
            ),
            .collapsedWorkout
        )
    }

    func testTabBarPresentationResolverReturnsExpandedFromWorkoutAfterToggle() {
        XCTAssertEqual(
            RootTabBarPresentationResolver.resolve(
                selectedTab: .workout,
                hasActiveWorkout: true,
                workoutTabsExpanded: true
            ),
            .expandedFromWorkout
        )
    }

    @MainActor
    func testWeeklyStrengthSummaryCountsOnlyMatchedExercisesFromCurrentWeek() {
        let exerciseA = makeExercise(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Bench")
        let exerciseB = makeExercise(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Row")
        let exerciseC = makeExercise(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, name: "Squat")
        let currentWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 20, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 20, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(60, 5, true), (60, 5, true)]),
                makeExerciseLog(exerciseID: exerciseC.id, sets: [(100, 5, true)])
            ]
        )
        let previousWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 13, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 13, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(30, 5, true), (30, 5, true)]),
                makeExerciseLog(exerciseID: exerciseB.id, sets: [(200, 10, true)])
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeStatisticsSnapshot(exercises: [exerciseA, exerciseB, exerciseC], history: [currentWeekSession, previousWeekSession]))

        let summary = store.weeklyStrengthSummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 21, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "ru_RU")
        )

        XCTAssertEqual(summary.currentVolume, 600, accuracy: 0.001)
        XCTAssertEqual(summary.previousVolume, 300, accuracy: 0.001)
        XCTAssertEqual(summary.percentChange, 100)
    }

    @MainActor
    func testWeeklyStrengthSummaryReturnsNegativeChangeWhenVolumeDrops() {
        let exerciseA = makeExercise(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, name: "Press")
        let currentWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 20, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 20, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(20, 5, true), (20, 5, true)])
            ]
        )
        let previousWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 14, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 14, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(40, 5, true), (40, 5, true)])
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeStatisticsSnapshot(exercises: [exerciseA], history: [currentWeekSession, previousWeekSession]))

        let summary = store.weeklyStrengthSummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 21, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "ru_RU")
        )

        XCTAssertEqual(summary.percentChange, -50)
    }

    @MainActor
    func testWeeklyStrengthSummaryReturnsZeroWhenWeeksDoNotShareExercises() {
        let exerciseA = makeExercise(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, name: "Bench")
        let exerciseB = makeExercise(id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!, name: "Row")
        let currentWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 20, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 20, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(60, 5, true)])
            ]
        )
        let previousWeekSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 13, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 13, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseB.id, sets: [(60, 5, true)])
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeStatisticsSnapshot(exercises: [exerciseA, exerciseB], history: [currentWeekSession, previousWeekSession]))

        let summary = store.weeklyStrengthSummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 21, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "ru_RU")
        )

        XCTAssertEqual(summary.currentVolume, 0, accuracy: 0.001)
        XCTAssertEqual(summary.previousVolume, 0, accuracy: 0.001)
        XCTAssertEqual(summary.percentChange, 0)
    }

    @MainActor
    func testWeeklyStrengthSummaryUsesWeekBoundariesFromCalendar() {
        let exerciseA = makeExercise(id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!, name: "Squat")
        let sundaySession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 17, hour: 20),
            endedAt: makeDate(year: 2024, month: 3, day: 17, hour: 21),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(40, 5, true)])
            ]
        )
        let mondaySession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 18, hour: 8),
            endedAt: makeDate(year: 2024, month: 3, day: 18, hour: 9),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(60, 5, true)])
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeStatisticsSnapshot(exercises: [exerciseA], history: [mondaySession, sundaySession]))

        let summary = store.weeklyStrengthSummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 20, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "ru_RU")
        )

        XCTAssertEqual(summary.currentVolume, 300, accuracy: 0.001)
        XCTAssertEqual(summary.previousVolume, 200, accuracy: 0.001)
        XCTAssertEqual(summary.percentChange, 50)
    }

    @MainActor
    func testRecentSessionAveragesReturnsLatestThreeCompletedSessionsForExercise() {
        let exerciseA = makeExercise(id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!, name: "Bench")
        let exerciseB = makeExercise(id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!, name: "Row")
        let newestSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 20, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 20, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(100, 5, true), (90, 8, true)]),
                makeExerciseLog(exerciseID: exerciseB.id, sets: [(70, 8, true)])
            ]
        )
        let secondSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 17, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 17, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(80, 10, true), (75, 8, false)])
            ]
        )
        let ignoredSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 15, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 15, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseB.id, sets: [(85, 6, true)])
            ]
        )
        let thirdSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 12, hour: 10),
            endedAt: makeDate(year: 2024, month: 3, day: 12, hour: 11),
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(70, 12, true)])
            ]
        )
        let unfinishedSession = makeSession(
            startedAt: makeDate(year: 2024, month: 3, day: 11, hour: 10),
            endedAt: nil,
            exerciseLogs: [
                makeExerciseLog(exerciseID: exerciseA.id, sets: [(120, 3, true)])
            ]
        )

        let store = AppStore()
        store.apply(snapshot: makeStatisticsSnapshot(exercises: [exerciseA, exerciseB], history: [newestSession, secondSession, ignoredSession, thirdSession, unfinishedSession]))

        let averages = store.recentSessionAverages(for: exerciseA.id)

        XCTAssertEqual(averages.map(\.id), [newestSession.id, secondSession.id, thirdSession.id])
        XCTAssertEqual(averages[0].averageWeight, 95, accuracy: 0.001)
        XCTAssertEqual(averages[0].averageReps, 6.5, accuracy: 0.001)
        XCTAssertEqual(averages[0].setsCount, 2)
        XCTAssertEqual(averages[1].averageWeight, 80, accuracy: 0.001)
        XCTAssertEqual(averages[1].averageReps, 10, accuracy: 0.001)
        XCTAssertEqual(averages[1].setsCount, 1)
        XCTAssertEqual(averages[2].averageWeight, 70, accuracy: 0.001)
        XCTAssertEqual(averages[2].averageReps, 12, accuracy: 0.001)
        XCTAssertEqual(averages[2].setsCount, 1)
    }

    @MainActor
    func testProfileGoalSummaryCalculatesSafePaceAndETAForTargetWeight() {
        let store = AppStore()
        var snapshot = makeStatisticsSnapshot(exercises: [], history: [])
        snapshot.profile = UserProfile(
            sex: "M",
            age: 30,
            weight: 80,
            height: 180,
            appLanguageCode: "en",
            primaryGoal: .fatLoss,
            experienceLevel: .intermediate,
            weeklyWorkoutTarget: 3,
            targetBodyWeight: 72
        )
        store.apply(snapshot: snapshot)

        let summary = store.profileGoalSummary()

        XCTAssertEqual(summary.direction, .lose)
        XCTAssertEqual(try XCTUnwrap(summary.remainingWeightDelta), -8, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.safeWeeklyChangeLowerBound), 0.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.safeWeeklyChangeUpperBound), 0.6, accuracy: 0.001)
        XCTAssertEqual(summary.etaWeeksLowerBound, 14)
        XCTAssertEqual(summary.etaWeeksUpperBound, 40)
        XCTAssertTrue(summary.usesCurrentWeightOnly)
    }

    @MainActor
    func testProfileMetabolismSummaryUsesObservedHistoryWhenEnoughSessionsExist() {
        let exercise = makeExercise(id: UUID(uuidString: "AAAA1111-1111-1111-1111-111111111111")!, name: "Bench")
        let sessionDays = [3, 6, 10, 13, 17, 20, 23, 24]
        let sessions = sessionDays.map { day in
            makeSession(
                startedAt: makeDate(year: 2024, month: 3, day: day, hour: 10),
                endedAt: makeDate(year: 2024, month: 3, day: day, hour: 11),
                exerciseLogs: [makeExerciseLog(exerciseID: exercise.id, sets: [(60, 5, true)])]
            )
        }

        let store = AppStore()
        var snapshot = makeStatisticsSnapshot(exercises: [exercise], history: sessions)
        snapshot.profile = UserProfile(
            sex: "M",
            age: 30,
            weight: 80,
            height: 180,
            appLanguageCode: "en",
            primaryGoal: .strength,
            experienceLevel: .intermediate,
            weeklyWorkoutTarget: 4,
            targetBodyWeight: nil
        )
        store.apply(snapshot: snapshot)

        let summary = store.profileMetabolismSummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 25, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "en_US")
        )

        XCTAssertEqual(summary.estimateSource, .history)
        XCTAssertEqual(summary.averageWorkoutsPerWeek, 2, accuracy: 0.001)
        XCTAssertEqual(summary.activityFactorLowerBound, 1.4, accuracy: 0.001)
        XCTAssertEqual(summary.activityFactorUpperBound, 1.5, accuracy: 0.001)
        XCTAssertEqual(summary.bmr, 1780)
        XCTAssertEqual(summary.maintenanceCaloriesLowerBound, 2492)
        XCTAssertEqual(summary.maintenanceCaloriesUpperBound, 2670)
    }

    @MainActor
    func testProfileMetabolismSummaryFallsBackToWeeklyTargetWhenHistoryIsSparse() {
        let store = AppStore()
        var snapshot = makeStatisticsSnapshot(exercises: [], history: [])
        snapshot.profile = UserProfile(
            sex: "F",
            age: 30,
            weight: 60,
            height: 165,
            appLanguageCode: "en",
            primaryGoal: .generalFitness,
            experienceLevel: .beginner,
            weeklyWorkoutTarget: 4,
            targetBodyWeight: nil
        )
        store.apply(snapshot: snapshot)

        let summary = store.profileMetabolismSummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 25, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "en_US")
        )

        XCTAssertEqual(summary.estimateSource, .target)
        XCTAssertEqual(summary.averageWorkoutsPerWeek, 4, accuracy: 0.001)
        XCTAssertEqual(summary.activityFactorLowerBound, 1.5, accuracy: 0.001)
        XCTAssertEqual(summary.activityFactorUpperBound, 1.6, accuracy: 0.001)
        XCTAssertEqual(summary.bmr, 1320)
    }

    @MainActor
    func testProfileTrainingRecommendationSummaryReturnsGenericFallbackWhenGoalIsNotSet() {
        let store = AppStore()
        var snapshot = makeStatisticsSnapshot(exercises: [], history: [])
        snapshot.profile = UserProfile(
            sex: "M",
            age: 29,
            weight: 88,
            height: 182,
            appLanguageCode: "en",
            primaryGoal: .notSet,
            experienceLevel: .notSet,
            weeklyWorkoutTarget: 5,
            targetBodyWeight: nil
        )
        store.apply(snapshot: snapshot)

        let summary = store.profileTrainingRecommendationSummary()

        XCTAssertTrue(summary.isGenericFallback)
        XCTAssertEqual(summary.recommendedWeeklyTargetLowerBound, 3)
        XCTAssertEqual(summary.recommendedWeeklyTargetUpperBound, 3)
        XCTAssertEqual(summary.split, .fullBody)
        XCTAssertEqual(summary.weeklySetsLowerBound, 6)
        XCTAssertEqual(summary.weeklySetsUpperBound, 10)
    }

    @MainActor
    func testProfileTrainingRecommendationSummaryReturnsStrengthRangesForIntermediate() {
        let store = AppStore()
        var snapshot = makeStatisticsSnapshot(exercises: [], history: [])
        snapshot.profile = UserProfile(
            sex: "M",
            age: 29,
            weight: 88,
            height: 182,
            appLanguageCode: "en",
            primaryGoal: .strength,
            experienceLevel: .intermediate,
            weeklyWorkoutTarget: 4,
            targetBodyWeight: nil
        )
        store.apply(snapshot: snapshot)

        let summary = store.profileTrainingRecommendationSummary()

        XCTAssertFalse(summary.isGenericFallback)
        XCTAssertEqual(summary.recommendedWeeklyTargetLowerBound, 3)
        XCTAssertEqual(summary.recommendedWeeklyTargetUpperBound, 5)
        XCTAssertEqual(summary.mainRepLowerBound, 3)
        XCTAssertEqual(summary.mainRepUpperBound, 6)
        XCTAssertEqual(summary.accessoryRepLowerBound, 6)
        XCTAssertEqual(summary.accessoryRepUpperBound, 10)
        XCTAssertEqual(summary.weeklySetsLowerBound, 10)
        XCTAssertEqual(summary.weeklySetsUpperBound, 14)
        XCTAssertEqual(summary.split, .upperLower)
    }

    @MainActor
    func testProfileTrainingRecommendationSummaryUsesSavedProgramWorkoutCountForSplit() {
        let store = AppStore()
        var snapshot = makeStatisticsSnapshot(exercises: [], history: [])
        snapshot.programs = [
            WorkoutProgram(
                title: "4 Day Program",
                workouts: [
                    WorkoutTemplate(title: "Day 1", focus: "", exercises: []),
                    WorkoutTemplate(title: "Day 2", focus: "", exercises: []),
                    WorkoutTemplate(title: "Day 3", focus: "", exercises: []),
                    WorkoutTemplate(title: "Day 4", focus: "", exercises: [])
                ]
            )
        ]
        snapshot.profile = UserProfile(
            sex: "M",
            age: 29,
            weight: 88,
            height: 182,
            appLanguageCode: "en",
            primaryGoal: .strength,
            experienceLevel: .intermediate,
            weeklyWorkoutTarget: 2,
            targetBodyWeight: nil
        )
        store.apply(snapshot: snapshot)

        let summary = store.profileTrainingRecommendationSummary()

        XCTAssertEqual(summary.splitWorkoutDays, 4)
        XCTAssertEqual(summary.splitProgramTitle, "4 Day Program")
        XCTAssertEqual(summary.split, .upperLower)
    }

    @MainActor
    func testProfileGoalCompatibilitySummaryFlagsDirectionMismatchAndLowFrequency() {
        let store = AppStore()
        var snapshot = makeStatisticsSnapshot(exercises: [], history: [])
        snapshot.profile = UserProfile(
            sex: "M",
            age: 29,
            weight: 80,
            height: 180,
            appLanguageCode: "en",
            primaryGoal: .fatLoss,
            experienceLevel: .intermediate,
            weeklyWorkoutTarget: 1,
            targetBodyWeight: 85
        )
        store.apply(snapshot: snapshot)

        let summary = store.profileGoalCompatibilitySummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 25, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "en_US")
        )

        XCTAssertTrue(summary.issues.contains { $0.kind == .goalTargetMismatch })
        XCTAssertTrue(summary.issues.contains { $0.kind == .frequencyTooLow })
        XCTAssertFalse(summary.issues.contains { $0.kind == .adherenceGap })
    }

    @MainActor
    func testProfileGoalCompatibilitySummaryFlagsAdherenceGapAndLongTimeline() {
        let exercise = makeExercise(id: UUID(uuidString: "BBBB1111-1111-1111-1111-111111111111")!, name: "Bench")
        let sessions = [
            makeSession(
                startedAt: makeDate(year: 2024, month: 3, day: 8, hour: 10),
                endedAt: makeDate(year: 2024, month: 3, day: 8, hour: 11),
                exerciseLogs: [makeExerciseLog(exerciseID: exercise.id, sets: [(60, 5, true)])]
            ),
            makeSession(
                startedAt: makeDate(year: 2024, month: 3, day: 22, hour: 10),
                endedAt: makeDate(year: 2024, month: 3, day: 22, hour: 11),
                exerciseLogs: [makeExerciseLog(exerciseID: exercise.id, sets: [(60, 5, true)])]
            )
        ]

        let store = AppStore()
        var snapshot = makeStatisticsSnapshot(exercises: [exercise], history: sessions)
        snapshot.profile = UserProfile(
            sex: "M",
            age: 29,
            weight: 100,
            height: 182,
            appLanguageCode: "en",
            primaryGoal: .fatLoss,
            experienceLevel: .intermediate,
            weeklyWorkoutTarget: 4,
            targetBodyWeight: 80
        )
        store.apply(snapshot: snapshot)

        let summary = store.profileGoalCompatibilitySummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 25, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "en_US")
        )

        XCTAssertTrue(summary.issues.contains { $0.kind == .adherenceGap })
        XCTAssertTrue(summary.issues.contains { $0.kind == .longGoalTimeline })
        XCTAssertEqual(try XCTUnwrap(summary.averageWorkoutsPerWeek), 0.5, accuracy: 0.001)
    }

    @MainActor
    func testProfileGoalCompatibilitySummaryFlagsSavedProgramFrequencyMismatch() {
        let store = AppStore()
        var snapshot = makeStatisticsSnapshot(exercises: [], history: [])
        snapshot.programs = [
            WorkoutProgram(
                title: "4 Day Program",
                workouts: [
                    WorkoutTemplate(title: "Day 1", focus: "", exercises: []),
                    WorkoutTemplate(title: "Day 2", focus: "", exercises: []),
                    WorkoutTemplate(title: "Day 3", focus: "", exercises: []),
                    WorkoutTemplate(title: "Day 4", focus: "", exercises: [])
                ]
            )
        ]
        snapshot.profile = UserProfile(
            sex: "M",
            age: 29,
            weight: 88,
            height: 182,
            appLanguageCode: "en",
            primaryGoal: .generalFitness,
            experienceLevel: .intermediate,
            weeklyWorkoutTarget: 2,
            targetBodyWeight: nil
        )
        store.apply(snapshot: snapshot)

        let summary = store.profileGoalCompatibilitySummary(
            referenceDate: makeDate(year: 2024, month: 3, day: 25, hour: 12),
            calendar: statisticsCalendar(localeIdentifier: "en_US")
        )

        XCTAssertTrue(summary.issues.contains { $0.kind == .programFrequencyMismatch })
    }

    @MainActor
    func testProfileStrengthToBodyweightSummaryUsesBestCompletedLoadForCanonicalLifts() {
        let bench = makeExercise(id: UUID(uuidString: "CCCC1111-1111-1111-1111-111111111111")!, name: "Barbell Bench Press")
        let squat = makeExercise(id: UUID(uuidString: "DDDD1111-1111-1111-1111-111111111111")!, name: "Back Squat")
        let sessions = [
            makeSession(
                startedAt: makeDate(year: 2024, month: 3, day: 10, hour: 10),
                endedAt: makeDate(year: 2024, month: 3, day: 10, hour: 11),
                exerciseLogs: [
                    makeExerciseLog(exerciseID: bench.id, sets: [(95, 5, true)]),
                    makeExerciseLog(exerciseID: squat.id, sets: [(130, 5, true)])
                ]
            ),
            makeSession(
                startedAt: makeDate(year: 2024, month: 3, day: 20, hour: 10),
                endedAt: makeDate(year: 2024, month: 3, day: 20, hour: 11),
                exerciseLogs: [
                    makeExerciseLog(exerciseID: bench.id, sets: [(100, 3, true), (105, 3, false)]),
                    makeExerciseLog(exerciseID: squat.id, sets: [(140, 3, true)])
                ]
            )
        ]

        let store = AppStore()
        var snapshot = makeStatisticsSnapshot(exercises: [bench, squat], history: sessions)
        snapshot.profile = UserProfile(
            sex: "M",
            age: 29,
            weight: 80,
            height: 182,
            appLanguageCode: "en",
            primaryGoal: .strength,
            experienceLevel: .intermediate,
            weeklyWorkoutTarget: 4,
            targetBodyWeight: nil
        )
        store.apply(snapshot: snapshot)

        let summary = store.profileStrengthToBodyweightSummary()
        let benchLift = summary.lifts.first { $0.lift == .benchPress }
        let squatLift = summary.lifts.first { $0.lift == .backSquat }
        let deadliftLift = summary.lifts.first { $0.lift == .deadlift }

        XCTAssertEqual(try XCTUnwrap(benchLift?.bestLoad), 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(benchLift?.relativeToBodyWeight), 1.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(squatLift?.bestLoad), 140, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(squatLift?.relativeToBodyWeight), 1.75, accuracy: 0.001)
        XCTAssertNil(deadliftLift?.bestLoad)
        XCTAssertNil(deadliftLift?.relativeToBodyWeight)
    }

    @MainActor
    func testCoachContextBuilderCapsRecentHistoryAndPropagatesLocale() {
        let exercise = makeExercise(id: UUID(uuidString: "EFEF1111-1111-1111-1111-111111111111")!, name: "Bench")
        let workoutID = UUID(uuidString: "CDCD1111-1111-1111-1111-111111111111")!
        let sessions = (1...10).map { day in
            WorkoutSession(
                workoutTemplateID: workoutID,
                title: "Session \(day)",
                startedAt: makeDate(year: 2024, month: 3, day: day, hour: 10),
                endedAt: makeDate(year: 2024, month: 3, day: day, hour: 11),
                exercises: [
                    WorkoutExerciseLog(
                        templateExerciseID: UUID(),
                        exerciseID: exercise.id,
                        groupKind: .regular,
                        groupID: nil,
                        sets: [
                            WorkoutSetLog(reps: 5, weight: Double(60 + day), completedAt: makeDate(year: 2024, month: 3, day: day, hour: 10, minute: 5))
                        ]
                    )
                ]
            )
        }
        let program = WorkoutProgram(
            title: "Strength",
            workouts: [
                WorkoutTemplate(
                    id: workoutID,
                    title: "Day 1",
                    focus: "Chest",
                    exercises: [
                        WorkoutExerciseTemplate(
                            exerciseID: exercise.id,
                            sets: [WorkoutSetTemplate(reps: 5, suggestedWeight: 80)]
                        )
                    ]
                )
            ]
        )

        let store = AppStore()
        var snapshot = AppSnapshot(
            programs: [program],
            exercises: [exercise],
            history: sessions,
            profile: UserProfile(
                sex: "M",
                age: 29,
                weight: 88,
                height: 182,
                appLanguageCode: "ru",
                primaryGoal: .strength,
                experienceLevel: .intermediate,
                weeklyWorkoutTarget: 4,
                targetBodyWeight: nil
            )
        )
        snapshot.history.sort { $0.startedAt > $1.startedAt }
        store.apply(snapshot: snapshot)

        let payload = CoachContextBuilder().build(from: store)

        XCTAssertEqual(payload.localeIdentifier, "ru")
        XCTAssertEqual(payload.historyMode, "summary_recent_history")
        XCTAssertEqual(payload.recentFinishedSessions.count, 8)
        XCTAssertEqual(payload.recentFinishedSessions.first?.title, "Session 10")
        XCTAssertEqual(payload.preferredProgram?.title, "Strength")
        XCTAssertEqual(payload.preferredProgram?.workouts.first?.exercises.first?.exerciseName, exercise.localizedName)
    }

    @MainActor
    func testCoachStoreFallsBackWhenRemoteInsightsFail() async {
        let store = AppStore()
        store.apply(snapshot: makeSnapshot())

        let coachStore = CoachStore(
            client: StubCoachAPIClient(
                shouldFailInsights: true,
                shouldFailChat: false
            ),
            configuration: CoachRuntimeConfiguration(
                isFeatureEnabled: true,
                backendBaseURL: URL(string: "https://example.com"),
                internalBearerToken: "internal-token"
            )
        )

        await coachStore.refreshProfileInsights(using: store)

        XCTAssertNotNil(coachStore.profileInsights)
        XCTAssertEqual(coachStore.profileInsightsOrigin, .fallback)
        XCTAssertNotNil(coachStore.lastInsightsErrorDescription)
    }

    @MainActor
    func testApplyCoachSuggestedChangeUpdatesWeeklyWorkoutTarget() {
        let store = AppStore()
        store.apply(snapshot: makeSnapshot())

        let applied = store.applyCoachSuggestedChange(
            CoachSuggestedChange(
                id: "set-target",
                type: .setWeeklyWorkoutTarget,
                title: "Target",
                summary: "Summary",
                weeklyWorkoutTarget: 5
            )
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(store.profile.weeklyWorkoutTarget, 5)
    }

    @MainActor
    func testApplyCoachSuggestedChangeAddsWorkoutDay() {
        let store = AppStore()
        let snapshot = makeSnapshot()
        store.apply(snapshot: snapshot)
        let programID = try! XCTUnwrap(snapshot.programs.first?.id)

        let applied = store.applyCoachSuggestedChange(
            CoachSuggestedChange(
                id: "add-day",
                type: .addWorkoutDay,
                title: "Add",
                summary: "Summary",
                programID: programID,
                workoutTitle: "Coach Day",
                workoutFocus: "Upper"
            )
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(store.programs.first?.workouts.count, 2)
        XCTAssertEqual(store.programs.first?.workouts.last?.title, "Coach Day")
    }

    @MainActor
    func testApplyCoachSuggestedChangeDeletesWorkoutDay() {
        let store = AppStore()
        var snapshot = makeSnapshot()
        let secondWorkoutID = UUID(uuidString: "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
        snapshot.programs[0].workouts.append(
            WorkoutTemplate(
                id: secondWorkoutID,
                title: "Delete Me",
                focus: "Legs",
                exercises: []
            )
        )
        store.apply(snapshot: snapshot)
        let programID = snapshot.programs[0].id

        let applied = store.applyCoachSuggestedChange(
            CoachSuggestedChange(
                id: "delete-day",
                type: .deleteWorkoutDay,
                title: "Delete",
                summary: "Summary",
                programID: programID,
                workoutID: secondWorkoutID
            )
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(store.programs.first?.workouts.count, 1)
        XCTAssertNil(store.programs.first?.workouts.first(where: { $0.id == secondWorkoutID }))
    }

    @MainActor
    func testApplyCoachSuggestedChangeSwapsWorkoutExercise() {
        let originalExercise = makeExercise(id: UUID(uuidString: "11111111-AAAA-BBBB-CCCC-111111111111")!, name: "Bench")
        let replacementExercise = makeExercise(id: UUID(uuidString: "22222222-AAAA-BBBB-CCCC-222222222222")!, name: "Incline Bench")
        let templateExerciseID = UUID(uuidString: "33333333-AAAA-BBBB-CCCC-333333333333")!
        let workoutID = UUID(uuidString: "44444444-AAAA-BBBB-CCCC-444444444444")!
        let programID = UUID(uuidString: "55555555-AAAA-BBBB-CCCC-555555555555")!

        let snapshot = AppSnapshot(
            programs: [
                WorkoutProgram(
                    id: programID,
                    title: "Program",
                    workouts: [
                        WorkoutTemplate(
                            id: workoutID,
                            title: "Day",
                            focus: "",
                            exercises: [
                                WorkoutExerciseTemplate(
                                    id: templateExerciseID,
                                    exerciseID: originalExercise.id,
                                    sets: [WorkoutSetTemplate(reps: 8, suggestedWeight: 80)]
                                )
                            ]
                        )
                    ]
                )
            ],
            exercises: [originalExercise, replacementExercise],
            history: [],
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "en")
        )

        let store = AppStore()
        store.apply(snapshot: snapshot)

        let applied = store.applyCoachSuggestedChange(
            CoachSuggestedChange(
                id: "swap-exercise",
                type: .swapWorkoutExercise,
                title: "Swap",
                summary: "Summary",
                programID: programID,
                workoutID: workoutID,
                templateExerciseID: templateExerciseID,
                replacementExerciseID: replacementExercise.id
            )
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(store.workout(programID: programID, workoutID: workoutID)?.exercises.first?.exerciseID, replacementExercise.id)
    }

    @MainActor
    func testApplyCoachSuggestedChangeUpdatesTemplatePrescription() {
        let snapshot = makeSnapshot()
        let programID = snapshot.programs[0].id
        let workoutID = snapshot.programs[0].workouts[0].id
        let templateExerciseID = snapshot.programs[0].workouts[0].exercises[0].id

        let store = AppStore()
        store.apply(snapshot: snapshot)

        let applied = store.applyCoachSuggestedChange(
            CoachSuggestedChange(
                id: "update-template",
                type: .updateTemplateExercisePrescription,
                title: "Update",
                summary: "Summary",
                programID: programID,
                workoutID: workoutID,
                templateExerciseID: templateExerciseID,
                reps: 10,
                setsCount: 4,
                suggestedWeight: 92.5
            )
        )

        XCTAssertTrue(applied)
        let updatedExercise = store.workout(programID: programID, workoutID: workoutID)?.exercises.first
        XCTAssertEqual(updatedExercise?.sets.count, 4)
        XCTAssertEqual(updatedExercise?.sets.first?.reps, 10)
        XCTAssertEqual(updatedExercise?.sets.first?.suggestedWeight, 92.5)
    }

    @MainActor
    func testCoachConversationIsEphemeralAndNotPersistedInSnapshot() async throws {
        let store = AppStore()
        store.apply(snapshot: makeSnapshot())

        let coachStore = CoachStore(
            client: StubCoachAPIClient(
                shouldFailInsights: false,
                shouldFailChat: false
            ),
            configuration: CoachRuntimeConfiguration(
                isFeatureEnabled: true,
                backendBaseURL: URL(string: "https://example.com"),
                internalBearerToken: "internal-token"
            )
        )

        await coachStore.sendMessage("How should I progress?", using: store)

        XCTAssertEqual(coachStore.messages.count, 2)
        XCTAssertEqual(coachStore.messages.first?.role, .user)
        XCTAssertEqual(coachStore.messages.last?.role, .assistant)

        let snapshotData = try JSONEncoder().encode(store.currentSnapshot())
        let snapshotJSON = String(data: snapshotData, encoding: .utf8) ?? ""
        XCTAssertFalse(snapshotJSON.contains("How should I progress?"))
        XCTAssertFalse(snapshotJSON.contains("Coach answer"))

        coachStore.resetConversation()

        XCTAssertTrue(coachStore.messages.isEmpty)
    }

    @MainActor
    func testCoachStoreSendsOnlyLastEightConversationMessages() async throws {
        let store = AppStore()
        store.apply(snapshot: makeSnapshot())
        let recorder = ChatRequestRecorder()
        let coachStore = CoachStore(
            client: RecordingCoachAPIClient(recorder: recorder),
            configuration: CoachRuntimeConfiguration(
                isFeatureEnabled: true,
                backendBaseURL: URL(string: "https://example.com"),
                internalBearerToken: "internal-token"
            )
        )

        for index in 1...5 {
            await coachStore.sendMessage("Question \(index)", using: store)
        }

        await coachStore.sendMessage("Question 6", using: store)
        let requests = await recorder.requests
        let lastRequest = try XCTUnwrap(requests.last)

        XCTAssertEqual(lastRequest.question, "Question 6")
        XCTAssertEqual(lastRequest.clientRecentTurns.count, 6)
        XCTAssertEqual(lastRequest.clientRecentTurns.first?.content, "Question 3")
        XCTAssertEqual(lastRequest.clientRecentTurns.last?.content, "Coach answer")
    }

    @MainActor
    func testCoachLocalStateStorePersistsInstallID() throws {
        let suiteName = "CoachLocalStateStoreInstallIDTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstStore = CoachLocalStateStore(
            defaults: defaults,
            generatedInstallID: "install-A"
        )
        let secondStore = CoachLocalStateStore(
            defaults: defaults,
            generatedInstallID: "install-B"
        )

        XCTAssertEqual(firstStore.installID, "install-A")
        XCTAssertEqual(secondStore.installID, "install-A")
    }

    @MainActor
    func testCoachSnapshotHashIsStableForEquivalentSnapshot() throws {
        let store = AppStore()
        let snapshot = makeSnapshot()
        store.apply(snapshot: snapshot)

        let firstHash = try CoachSnapshotHashing.hash(
            for: CoachContextBuilder().build(from: store)
        )

        let reloadedStore = AppStore()
        reloadedStore.apply(snapshot: snapshot)
        let secondHash = try CoachSnapshotHashing.hash(
            for: CoachContextBuilder().build(from: reloadedStore)
        )

        XCTAssertEqual(firstHash, secondHash)
    }

    @MainActor
    func testCoachStoreOmitsInlineSnapshotAfterSuccessfulSync() async throws {
        let store = AppStore()
        store.apply(snapshot: makeSnapshot())
        let recorder = SnapshotRequestRecorder()
        let suiteName = "CoachLocalStateStoreSyncedTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let coachStore = CoachStore(
            client: RecordingSnapshotCoachAPIClient(recorder: recorder),
            configuration: CoachRuntimeConfiguration(
                isFeatureEnabled: true,
                backendBaseURL: URL(string: "https://example.com"),
                internalBearerToken: "internal-token"
            ),
            localStateStore: CoachLocalStateStore(
                defaults: defaults,
                generatedInstallID: "install-test"
            )
        )

        await coachStore.syncSnapshotIfNeeded(using: store)
        await coachStore.refreshProfileInsights(using: store)

        let requests = await recorder.requests
        let lastRequest = try XCTUnwrap(requests.last)
        XCTAssertNil(lastRequest.snapshotEnvelope.snapshot)
    }

    @MainActor
    func testCoachStoreIncludesInlineSnapshotWhenDirty() async throws {
        let store = AppStore()
        store.apply(snapshot: makeSnapshot())
        let recorder = SnapshotRequestRecorder()
        let suiteName = "CoachLocalStateStoreDirtyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let coachStore = CoachStore(
            client: RecordingSnapshotCoachAPIClient(recorder: recorder),
            configuration: CoachRuntimeConfiguration(
                isFeatureEnabled: true,
                backendBaseURL: URL(string: "https://example.com"),
                internalBearerToken: "internal-token"
            ),
            localStateStore: CoachLocalStateStore(
                defaults: defaults,
                generatedInstallID: "install-test"
            )
        )

        await coachStore.syncSnapshotIfNeeded(using: store)
        store.profile.weeklyWorkoutTarget = 5
        await coachStore.refreshProfileInsights(using: store)

        let requests = await recorder.requests
        let lastRequest = try XCTUnwrap(requests.last)
        XCTAssertNotNil(lastRequest.snapshotEnvelope.snapshot)
    }

    @MainActor
    func testCoachRuntimeConfigurationStorePersistsOverridesOutsideSnapshot() throws {
        let suiteName = "CoachRuntimeConfigurationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let defaultConfiguration = CoachRuntimeConfiguration(
            isFeatureEnabled: false,
            backendBaseURL: nil,
            internalBearerToken: nil
        )
        let configurationStore = CoachRuntimeConfigurationStore(
            defaultConfiguration: defaultConfiguration,
            defaults: defaults
        )

        configurationStore.isFeatureEnabled = true
        configurationStore.backendBaseURLText = " https://workoutapp-ai-coach.dmitry-grinko46.workers.dev "
        configurationStore.internalBearerToken = " internal-secret-token "

        let savedConfiguration = configurationStore.save()

        XCTAssertTrue(savedConfiguration.canUseRemoteCoach)
        XCTAssertEqual(
            savedConfiguration.backendBaseURL?.absoluteString,
            "https://workoutapp-ai-coach.dmitry-grinko46.workers.dev"
        )
        XCTAssertEqual(savedConfiguration.internalBearerToken, "internal-secret-token")
        XCTAssertTrue(configurationStore.hasLocalOverrides)

        let reloadedStore = CoachRuntimeConfigurationStore(
            defaultConfiguration: defaultConfiguration,
            defaults: defaults
        )

        XCTAssertTrue(reloadedStore.isFeatureEnabled)
        XCTAssertEqual(
            reloadedStore.backendBaseURLText,
            "https://workoutapp-ai-coach.dmitry-grinko46.workers.dev"
        )
        XCTAssertEqual(reloadedStore.internalBearerToken, "internal-secret-token")
        XCTAssertTrue(reloadedStore.runtimeConfiguration.canUseRemoteCoach)

        let appStore = AppStore()
        appStore.apply(snapshot: makeSnapshot())
        let snapshotData = try JSONEncoder().encode(appStore.currentSnapshot())
        let snapshotJSON = String(data: snapshotData, encoding: .utf8) ?? ""
        XCTAssertFalse(snapshotJSON.contains("workoutapp-ai-coach.dmitry-grinko46.workers.dev"))
        XCTAssertFalse(snapshotJSON.contains("internal-secret-token"))

        let resetConfiguration = reloadedStore.resetToDefaults()
        XCTAssertFalse(resetConfiguration.isFeatureEnabled)
        XCTAssertFalse(reloadedStore.hasLocalOverrides)
        XCTAssertEqual(reloadedStore.backendBaseURLText, "")
        XCTAssertEqual(reloadedStore.internalBearerToken, "")
    }

    private func backupFiles(in folderURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.lastPathComponent.hasPrefix(BackupConstants.filePrefix) &&
            $0.pathExtension == BackupConstants.fileExtension
        }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func makeFixture() throws -> BackupTestFixture {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)

        let suiteName = "BackupCoordinatorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let clock = TestClock(currentDate: Date(timeIntervalSince1970: 1_710_000_000))
        let coordinator = BackupCoordinator(
            defaults: defaults,
            now: { clock.currentDate },
            fileManager: .default
        )

        return BackupTestFixture(
            folderURL: folderURL,
            defaultsSuiteName: suiteName,
            defaults: defaults,
            clock: clock,
            coordinator: coordinator
        )
    }

    private func makeSnapshot() -> AppSnapshot {
        let categoryID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let exerciseID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let templateExerciseID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let workoutID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let programID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!

        let exercise = Exercise(
            id: exerciseID,
            name: "Incline Bench",
            categoryID: categoryID,
            equipment: "Barbell",
            notes: "Heavy day"
        )
        let template = WorkoutExerciseTemplate(
            id: templateExerciseID,
            exerciseID: exerciseID,
            sets: [
                WorkoutSetTemplate(reps: 8, suggestedWeight: 80),
                WorkoutSetTemplate(reps: 6, suggestedWeight: 85)
            ]
        )
        let workout = WorkoutTemplate(
            id: workoutID,
            title: "Push Day",
            focus: "Chest",
            exercises: [template]
        )
        let session = WorkoutSession(
            workoutTemplateID: workoutID,
            title: "Push Day",
            startedAt: Date(timeIntervalSince1970: 1_710_000_000),
            endedAt: Date(timeIntervalSince1970: 1_710_000_900),
            exercises: [
                WorkoutExerciseLog(
                    templateExerciseID: templateExerciseID,
                    exerciseID: exerciseID,
                    groupKind: .regular,
                    groupID: nil,
                    sets: [
                        WorkoutSetLog(reps: 8, weight: 80, completedAt: Date(timeIntervalSince1970: 1_710_000_200)),
                        WorkoutSetLog(reps: 6, weight: 85, completedAt: Date(timeIntervalSince1970: 1_710_000_500))
                    ]
                )
            ]
        )

        return AppSnapshot(
            programs: [
                WorkoutProgram(id: programID, title: "Strength", workouts: [workout])
            ],
            exercises: [exercise],
            history: [session],
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "en")
        )
    }

    private func makeStatisticsSnapshot(exercises: [Exercise], history: [WorkoutSession]) -> AppSnapshot {
        AppSnapshot(
            programs: [],
            exercises: exercises,
            history: history,
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "ru")
        )
    }

    private func makeProgramSnapshot(programs: [WorkoutProgram], exercises: [Exercise]) -> AppSnapshot {
        AppSnapshot(
            programs: programs,
            exercises: exercises,
            history: [],
            profile: UserProfile(sex: "M", age: 29, weight: 88, height: 182, appLanguageCode: "en")
        )
    }

    private func makeExercise(id: UUID, name: String) -> Exercise {
        Exercise(
            id: id,
            name: name,
            categoryID: UUID(uuidString: "AAAAAAAA-1111-1111-1111-AAAAAAAAAAAA")!,
            equipment: "",
            notes: ""
        )
    }

    private func makeSession(
        startedAt: Date,
        endedAt: Date?,
        exerciseLogs: [WorkoutExerciseLog]
    ) -> WorkoutSession {
        WorkoutSession(
            workoutTemplateID: UUID(uuidString: "BBBBBBBB-1111-1111-1111-BBBBBBBBBBBB")!,
            title: "Session",
            startedAt: startedAt,
            endedAt: endedAt,
            exercises: exerciseLogs
        )
    }

    private func makeExerciseLog(
        exerciseID: UUID,
        sets: [(weight: Double, reps: Int, completed: Bool)]
    ) -> WorkoutExerciseLog {
        makeExerciseLog(groupID: nil, groupKind: .regular, exerciseID: exerciseID, sets: sets)
    }

    private func makeExerciseLog(
        groupID: UUID?,
        groupKind: WorkoutExerciseTemplate.GroupKind,
        exerciseID: UUID,
        sets: [(weight: Double, reps: Int, completed: Bool)]
    ) -> WorkoutExerciseLog {
        WorkoutExerciseLog(
            templateExerciseID: UUID(),
            exerciseID: exerciseID,
            groupKind: groupKind,
            groupID: groupID,
            sets: sets.enumerated().map { index, set in
                WorkoutSetLog(
                    reps: set.reps,
                    weight: set.weight,
                    completedAt: set.completed
                        ? Date(timeIntervalSince1970: 1_710_000_000 + TimeInterval(index * 60))
                        : nil
                )
            }
        )
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = statisticsCalendar(localeIdentifier: "ru_RU")
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return components.date!
    }

    private func statisticsCalendar(localeIdentifier: String) -> Calendar {
        AppStore.statisticsCalendar(
            locale: Locale(identifier: localeIdentifier),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }
}

private struct BackupTestFixture {
    let folderURL: URL
    let defaultsSuiteName: String
    let defaults: UserDefaults
    let clock: TestClock
    let coordinator: BackupCoordinator

    func cleanup() {
        try? FileManager.default.removeItem(at: folderURL)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

private final class TestClock: @unchecked Sendable {
    var currentDate: Date

    init(currentDate: Date) {
        self.currentDate = currentDate
    }
}

private struct StubCoachAPIClient: CoachAPIClient {
    let shouldFailInsights: Bool
    let shouldFailChat: Bool

    func syncSnapshot(_ request: CoachSnapshotSyncRequest) async throws -> CoachSnapshotSyncResponse {
        CoachSnapshotSyncResponse(
            acceptedHash: request.snapshotHash,
            storedAt: request.snapshotUpdatedAt
        )
    }

    func fetchProfileInsights(
        locale: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope
    ) async throws -> CoachProfileInsights {
        if shouldFailInsights {
            throw StubCoachError.failedInsights
        }

        return CoachProfileInsights(
            summary: "Remote summary",
            recommendations: ["Remote recommendation"],
            suggestedChanges: []
        )
    }

    func sendChat(
        locale: String,
        question: String,
        clientRecentTurns: [CoachConversationMessage],
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope
    ) async throws -> CoachChatResponse {
        if shouldFailChat {
            throw StubCoachError.failedChat
        }

        return CoachChatResponse(
            answerMarkdown: "Coach answer",
            responseID: "response-1",
            followUps: ["Next question"],
            suggestedChanges: []
        )
    }

    func deleteRemoteState(installID: String) async throws {}
}

private actor ChatRequestRecorder {
    private(set) var requests: [RecordedCoachChatRequest] = []

    func record(_ request: RecordedCoachChatRequest) {
        requests.append(request)
    }
}

private struct RecordedCoachChatRequest: Sendable {
    var question: String
    var clientRecentTurns: [CoachConversationMessage]
}

private struct RecordedCoachSnapshotRequest: Sendable {
    var snapshotEnvelope: CoachSnapshotEnvelope
}

private actor SnapshotRequestRecorder {
    private(set) var requests: [RecordedCoachSnapshotRequest] = []

    func record(_ request: RecordedCoachSnapshotRequest) {
        requests.append(request)
    }
}

private struct RecordingCoachAPIClient: CoachAPIClient {
    let recorder: ChatRequestRecorder

    func syncSnapshot(_ request: CoachSnapshotSyncRequest) async throws -> CoachSnapshotSyncResponse {
        CoachSnapshotSyncResponse(
            acceptedHash: request.snapshotHash,
            storedAt: request.snapshotUpdatedAt
        )
    }

    func fetchProfileInsights(
        locale: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope
    ) async throws -> CoachProfileInsights {
        CoachProfileInsights(
            summary: "Remote summary",
            recommendations: ["Remote recommendation"],
            suggestedChanges: []
        )
    }

    func sendChat(
        locale: String,
        question: String,
        clientRecentTurns: [CoachConversationMessage],
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope
    ) async throws -> CoachChatResponse {
        await recorder.record(
            RecordedCoachChatRequest(
                question: question,
                clientRecentTurns: clientRecentTurns
            )
        )

        return CoachChatResponse(
            answerMarkdown: "Coach answer",
            responseID: "response-1",
            followUps: ["Next question"],
            suggestedChanges: []
        )
    }

    func deleteRemoteState(installID: String) async throws {}
}

private struct RecordingSnapshotCoachAPIClient: CoachAPIClient {
    let recorder: SnapshotRequestRecorder

    func syncSnapshot(_ request: CoachSnapshotSyncRequest) async throws -> CoachSnapshotSyncResponse {
        CoachSnapshotSyncResponse(
            acceptedHash: request.snapshotHash,
            storedAt: request.snapshotUpdatedAt
        )
    }

    func fetchProfileInsights(
        locale: String,
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope
    ) async throws -> CoachProfileInsights {
        await recorder.record(
            RecordedCoachSnapshotRequest(snapshotEnvelope: snapshotEnvelope)
        )

        return CoachProfileInsights(
            summary: "Remote summary",
            recommendations: ["Remote recommendation"],
            suggestedChanges: []
        )
    }

    func sendChat(
        locale: String,
        question: String,
        clientRecentTurns: [CoachConversationMessage],
        snapshotEnvelope: CoachSnapshotEnvelope,
        capabilityScope: CoachCapabilityScope
    ) async throws -> CoachChatResponse {
        CoachChatResponse(
            answerMarkdown: "Coach answer",
            responseID: "response-1",
            followUps: ["Next question"],
            suggestedChanges: []
        )
    }

    func deleteRemoteState(installID: String) async throws {}
}

private enum StubCoachError: LocalizedError, Sendable {
    case failedInsights
    case failedChat

    var errorDescription: String? {
        switch self {
        case .failedInsights:
            return "Insights failed"
        case .failedChat:
            return "Chat failed"
        }
    }
}
