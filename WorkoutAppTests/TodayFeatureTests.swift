import XCTest
@testable import WorkoutApp

@MainActor
final class TodayFeatureTests: XCTestCase {
    func testPreferredProgramResolverPrefersSelectedProgram() {
        let exercise = makeExercise(name: "Bench Press")
        let firstWorkout = makeWorkout(title: "Upper A", exercise: exercise)
        let secondWorkout = makeWorkout(title: "Lower A", exercise: exercise)
        let firstProgram = WorkoutProgram(title: "Program A", workouts: [firstWorkout])
        let secondProgram = WorkoutProgram(title: "Program B", workouts: [secondWorkout])

        let resolved = PreferredProgramResolver.resolve(
            programs: [firstProgram, secondProgram],
            preferredProgramID: secondProgram.id,
            history: []
        )

        XCTAssertEqual(resolved?.id, secondProgram.id)
    }

    func testPreferredProgramResolverFallsBackToRecentWorkoutProgram() {
        let exercise = makeExercise(name: "Bench Press")
        let firstWorkout = makeWorkout(title: "Upper A", exercise: exercise)
        let secondWorkout = makeWorkout(title: "Lower A", exercise: exercise)
        let firstProgram = WorkoutProgram(title: "Program A", workouts: [firstWorkout])
        let secondProgram = WorkoutProgram(title: "Program B", workouts: [secondWorkout])
        let lastSession = makeFinishedSession(
            workout: secondWorkout,
            exercise: exercise,
            startedAt: fixedNow.addingTimeInterval(-2 * 24 * 60 * 60)
        )

        let resolved = PreferredProgramResolver.resolve(
            programs: [firstProgram, secondProgram],
            history: [lastSession]
        )

        XCTAssertEqual(resolved?.id, secondProgram.id)
    }

    func testTodayBuilderPrefersActiveWorkoutHero() {
        let exercise = makeExercise(name: "Bench Press")
        let workout = makeWorkout(title: "Upper A", exercise: exercise)
        let program = WorkoutProgram(title: "Starter", workouts: [workout])
        let activeSession = makeActiveSession(workout: workout, exercise: exercise, startedAt: fixedNow.addingTimeInterval(-900))
        let store = makeStore(programs: [program], exercises: [exercise], history: [], activeSession: activeSession)

        let state = TodayRecommendationBuilder.build(from: store, now: fixedNow, calendar: calendar)

        switch state.hero {
        case let .active(hero):
            XCTAssertEqual(hero.session.id, activeSession.id)
        default:
            XCTFail("Expected active hero state")
        }
    }

    func testTodayBuilderShowsRecommendedWorkoutWhenDue() {
        let exercise = makeExercise(name: "Bench Press")
        let firstWorkout = makeWorkout(title: "Upper A", exercise: exercise)
        let secondWorkout = makeWorkout(title: "Lower A", exercise: exercise)
        let program = WorkoutProgram(title: "Starter", workouts: [firstWorkout, secondWorkout])
        let lastSession = makeFinishedSession(workout: firstWorkout, exercise: exercise, startedAt: fixedNow.addingTimeInterval(-3 * 24 * 60 * 60))
        let profile = makeProfile(goal: .strength, weeklyTarget: 3)
        let store = makeStore(programs: [program], exercises: [exercise], history: [lastSession], profile: profile)

        let state = TodayRecommendationBuilder.build(from: store, now: fixedNow, calendar: calendar)

        switch state.hero {
        case let .recommended(hero):
            XCTAssertEqual(hero.recommendation.workout.id, secondWorkout.id)
        default:
            XCTFail("Expected recommended hero state")
        }
    }

    func testTodayBuilderShowsBackOnTrackAfterLongGap() {
        let exercise = makeExercise(name: "Bench Press")
        let firstWorkout = makeWorkout(title: "Upper A", exercise: exercise)
        let secondWorkout = makeWorkout(title: "Lower A", exercise: exercise)
        let program = WorkoutProgram(title: "Starter", workouts: [firstWorkout, secondWorkout])
        let lastSession = makeFinishedSession(workout: firstWorkout, exercise: exercise, startedAt: fixedNow.addingTimeInterval(-14 * 24 * 60 * 60))
        let profile = makeProfile(goal: .strength, weeklyTarget: 3)
        let store = makeStore(programs: [program], exercises: [exercise], history: [lastSession], profile: profile)

        let state = TodayRecommendationBuilder.build(from: store, now: fixedNow, calendar: calendar)

        switch state.hero {
        case let .backOnTrack(hero):
            XCTAssertEqual(hero.recommendation.workout.id, secondWorkout.id)
        default:
            XCTFail("Expected back-on-track hero state")
        }
    }

    func testTodayBuilderShowsRecoveryWhenWeeklyTargetAlreadyMet() {
        let exercise = makeExercise(name: "Bench Press")
        let workout = makeWorkout(title: "Upper A", exercise: exercise)
        let program = WorkoutProgram(title: "Starter", workouts: [workout])
        let lastSession = makeFinishedSession(workout: workout, exercise: exercise, startedAt: fixedNow.addingTimeInterval(-24 * 60 * 60))
        let profile = makeProfile(goal: .strength, weeklyTarget: 1)
        let store = makeStore(programs: [program], exercises: [exercise], history: [lastSession], profile: profile)

        let state = TodayRecommendationBuilder.build(from: store, now: fixedNow, calendar: calendar)

        switch state.hero {
        case let .recovery(hero):
            XCTAssertEqual(hero.workoutsThisWeek, 1)
            XCTAssertEqual(hero.weeklyTarget, 1)
        default:
            XCTFail("Expected recovery hero state")
        }
    }

    func testTodayBuilderShowsFirstWorkoutWithoutHistory() {
        let exercise = makeExercise(name: "Bench Press")
        let workout = makeWorkout(title: "Upper A", exercise: exercise)
        let program = WorkoutProgram(title: "Starter", workouts: [workout])
        let store = makeStore(programs: [program], exercises: [exercise], history: [], profile: makeProfile(goal: .notSet, weeklyTarget: 3))

        let state = TodayRecommendationBuilder.build(from: store, now: fixedNow, calendar: calendar)

        switch state.hero {
        case let .firstWorkout(hero):
            XCTAssertEqual(hero.recommendation.workout.id, workout.id)
        default:
            XCTFail("Expected first-workout hero state")
        }
    }

    func testTodayBuilderShowsExplicitEmptyStateWithoutPrograms() {
        let exercise = makeExercise(name: "Bench Press")
        let store = makeStore(programs: [], exercises: [exercise], history: [], profile: makeProfile(goal: .notSet, weeklyTarget: 3))

        let state = TodayRecommendationBuilder.build(from: store, now: fixedNow, calendar: calendar)

        switch state.hero {
        case let .empty(hero):
            XCTAssertFalse(hero.hasPrograms)
        default:
            XCTFail("Expected empty hero state")
        }
    }

    func testAttentionResolverPrioritizesCompatibilityIssue() {
        let issue = ProfileGoalCompatibilityIssue(
            id: "missing-goal",
            kind: .missingGoal,
            currentWeeklyTarget: nil,
            recommendedWeeklyTargetLowerBound: nil,
            observedWorkoutsPerWeek: nil,
            etaWeeksUpperBound: nil,
            systemImage: "questionmark.circle.fill"
        )
        let compatibilitySummary = ProfileGoalCompatibilitySummary(
            primaryGoal: .notSet,
            currentWeight: 80,
            targetBodyWeight: nil,
            weeklyWorkoutTarget: 3,
            averageWorkoutsPerWeek: nil,
            usesObservedHistory: false,
            issues: [issue]
        )
        let pr = ProfilePRItem(
            id: "pr",
            exerciseID: UUID(),
            exerciseName: "Bench Press",
            achievedAt: fixedNow,
            weight: 100,
            previousWeight: 95
        )

        let attention = TodayAttentionResolver.resolve(
            compatibilitySummary: compatibilitySummary,
            recentPersonalRecords: [pr],
            consistencySummary: ProfileConsistencySummary(
                workoutsThisWeek: 1,
                weeklyTarget: 3,
                streakWeeks: 0,
                recentWeeklyActivity: [],
                mostFrequentWeekday: nil
            ),
            weeklyStrengthSummary: WeeklyStrengthSummary(percentChange: 12, currentVolume: 1000, previousVolume: 900)
        )

        XCTAssertEqual(attention?.kind, .compatibility)
        XCTAssertEqual(attention?.message, ProfileCompatibilityMessageFormatter.message(for: issue))
    }


    func testTodayCoachInsightsResolverBuildsCompactReadyState() {
        let insights = CoachProfileInsights(
            summary: "Your lower-body progress is mostly limited by missed sessions.",
            keyObservations: ["Bench volume has stayed stable for two weeks."],
            topConstraints: ["You missed two lower sessions in the last ten days."],
            recommendations: ["Start with Lower A next and keep the top sets at RPE 7-8."],
            confidenceNotes: ["Recent data is slightly sparse."],
            executionContext: CoachProfileExecutionContext(
                mode: "profile",
                effectiveWeeklyFrequency: 2,
                shouldTreatProgramCountAsMismatch: false,
                programWorkoutCount: 4,
                weeklyTarget: 3,
                statedWeeklyFrequency: 3,
                observedAverageWorkoutsPerWeek: 2,
                templateRotationSemantics: "in_order",
                authoritativeSignal: "history",
                userNote: nil,
                explanation: "Adherence is the main limiter right now.",
                evidence: ["Last 4 weeks"]
            ),
            generationStatus: .model,
            insightSource: .freshModel,
            provider: nil,
            selectedModel: "gpt-5.4-mini"
        )

        let state = TodayCoachInsightsResolver.resolve(
            insights: insights,
            origin: .freshModel,
            isLoading: false,
            canUseRemoteCoach: true,
            lastErrorDescription: nil,
            languageCode: "en"
        )

        switch state {
        case let .ready(content):
            XCTAssertEqual(content.summary, "Your lower-body progress is mostly limited by missed sessions.")
            XCTAssertEqual(content.explanation, "Adherence is the main limiter right now.")
            XCTAssertEqual(content.items.count, 2)
            XCTAssertEqual(content.items[0].message, "Start with Lower A next and keep the top sets at RPE 7-8.")
            XCTAssertEqual(content.items[1].message, "You missed two lower sessions in the last ten days.")
            XCTAssertEqual(content.modelLabel, "gpt-5.4-mini")
            XCTAssertNil(content.noteKey)
        default:
            XCTFail("Expected ready insights state")
        }
    }

    func testTodayCoachInsightsResolverFiltersMismatchedLanguageInRussianLocale() {
        let insights = CoachProfileInsights(
            summary: "Сегодня лучше сохранить текущий ритм и не форсировать объём.",
            keyObservations: ["Bench volume has stayed stable for two weeks."],
            topConstraints: ["Вы пропустили две тренировки ног за последние десять дней."],
            recommendations: ["Начните со следующей тренировки и держите верхние подходы на RPE 7-8."],
            confidenceNotes: ["Recent data is slightly sparse."],
            executionContext: CoachProfileExecutionContext(
                mode: "profile",
                effectiveWeeklyFrequency: 2,
                shouldTreatProgramCountAsMismatch: false,
                programWorkoutCount: 4,
                weeklyTarget: 3,
                statedWeeklyFrequency: 3,
                observedAverageWorkoutsPerWeek: 2,
                templateRotationSemantics: "in_order",
                authoritativeSignal: "history",
                userNote: nil,
                explanation: "Rolling template execution should be preserved.",
                evidence: ["Last 4 weeks"]
            ),
            generationStatus: .model,
            insightSource: .freshModel,
            provider: nil,
            selectedModel: nil
        )

        let state = TodayCoachInsightsResolver.resolve(
            insights: insights,
            origin: .freshModel,
            isLoading: false,
            canUseRemoteCoach: true,
            lastErrorDescription: nil,
            languageCode: "ru"
        )

        switch state {
        case let .ready(content):
            XCTAssertEqual(content.summary, "Сегодня лучше сохранить текущий ритм и не форсировать объём.")
            XCTAssertNil(content.explanation)
            XCTAssertEqual(content.items.count, 2)
            XCTAssertEqual(content.items[0].message, "Начните со следующей тренировки и держите верхние подходы на RPE 7-8.")
            XCTAssertEqual(content.items[1].message, "Вы пропустили две тренировки ног за последние десять дней.")
        default:
            XCTFail("Expected ready insights state")
        }
    }

    func testTodayCoachInsightsResolverUsesFirstValidItemAsSummaryWhenSummaryIsWrongLanguage() {
        let insights = CoachProfileInsights(
            summary: "Your current split works best when you keep a steady weekly rhythm.",
            keyObservations: ["Последняя тренировка прошла уверенно по основным движениям."],
            topConstraints: ["Сейчас главный лимитер — пропуски тренировок ног."],
            recommendations: ["Вернитесь со следующей тренировки по плану и не добавляйте лишний объём."],
            generationStatus: .model,
            insightSource: .freshModel,
            provider: nil,
            selectedModel: nil
        )

        let state = TodayCoachInsightsResolver.resolve(
            insights: insights,
            origin: .freshModel,
            isLoading: false,
            canUseRemoteCoach: true,
            lastErrorDescription: nil,
            languageCode: "ru"
        )

        switch state {
        case let .ready(content):
            XCTAssertEqual(content.summary, "Вернитесь со следующей тренировки по плану и не добавляйте лишний объём.")
            XCTAssertEqual(content.items.count, 1)
            XCTAssertEqual(content.items[0].message, "Сейчас главный лимитер — пропуски тренировок ног.")
        default:
            XCTFail("Expected ready insights state")
        }
    }

    func testTodayCoachInsightsResolverReturnsLoadingWithoutInsights() {
        let state = TodayCoachInsightsResolver.resolve(
            insights: nil,
            origin: .fallback,
            isLoading: true,
            canUseRemoteCoach: true,
            lastErrorDescription: nil,
            languageCode: "en"
        )

        XCTAssertEqual(state, .loading)
    }

    func testTodayCoachInsightsResolverUsesLocalFallbackUnavailableMessage() {
        let state = TodayCoachInsightsResolver.resolve(
            insights: nil,
            origin: .fallback,
            isLoading: false,
            canUseRemoteCoach: false,
            lastErrorDescription: nil,
            languageCode: "ru"
        )

        XCTAssertEqual(state, .unavailable("today.insights.empty_local"))
    }

    func testTodayCoachInsightsResolverReturnsUnavailableWhenAllInsightTextIsWrongLanguage() {
        let insights = CoachProfileInsights(
            summary: "Your lower-body progress is mostly limited by missed sessions.",
            keyObservations: ["Bench volume has stayed stable for two weeks."],
            topConstraints: ["You missed two lower sessions in the last ten days."],
            recommendations: ["Start with Lower A next and keep the top sets at RPE 7-8."],
            generationStatus: .model,
            insightSource: .freshModel,
            provider: nil,
            selectedModel: nil
        )

        let state = TodayCoachInsightsResolver.resolve(
            insights: insights,
            origin: .freshModel,
            isLoading: false,
            canUseRemoteCoach: true,
            lastErrorDescription: nil,
            languageCode: "ru"
        )

        XCTAssertEqual(state, .unavailable("today.insights.empty"))
    }

    func testTodayCoachInsightsResolverAddsFallbackNoteWhenRemoteFails() {
        let insights = CoachProfileInsights(
            summary: "Local analytics suggest you should keep the next session simple.",
            recommendations: ["Resume with the next workout in order."],
            generationStatus: .fallback,
            insightSource: .fallback,
            provider: nil,
            selectedModel: nil
        )

        let state = TodayCoachInsightsResolver.resolve(
            insights: insights,
            origin: .fallback,
            isLoading: false,
            canUseRemoteCoach: true,
            lastErrorDescription: "Backend timeout",
            languageCode: "en"
        )

        switch state {
        case let .ready(content):
            XCTAssertEqual(content.noteKey, "today.insights.note.local_fallback")
        default:
            XCTFail("Expected ready fallback insights state")
        }
    }
}

private let fixedNow = Date(timeIntervalSince1970: 1_775_404_800)
private let calendar = AppStore.statisticsCalendar(locale: Locale(identifier: "en_US"))

private func makeStore(
    programs: [WorkoutProgram],
    exercises: [Exercise],
    history: [WorkoutSession],
    profile: UserProfile = makeProfile(goal: .strength, weeklyTarget: 3),
    coachAnalysisSettings: CoachAnalysisSettings = .empty,
    activeSession: WorkoutSession? = nil
) -> AppStore {
    let store = AppStore()
    store.apply(snapshot: AppSnapshot(
        programs: programs,
        exercises: exercises,
        history: history,
        profile: profile,
        coachAnalysisSettings: coachAnalysisSettings
    ))
    store.activeSession = activeSession
    return store
}

private func makeProfile(
    goal: TrainingGoal,
    weeklyTarget: Int
) -> UserProfile {
    UserProfile(
        sex: "M",
        age: 29,
        weight: 82,
        height: 180,
        appLanguageCode: "en",
        primaryGoal: goal,
        experienceLevel: .intermediate,
        weeklyWorkoutTarget: weeklyTarget,
        targetBodyWeight: goal == .fatLoss ? 78 : nil
    )
}

private func makeExercise(
    id: UUID = UUID(),
    name: String
) -> Exercise {
    Exercise(
        id: id,
        name: name,
        categoryID: SeedData.chestCategoryID,
        equipment: "Barbell",
        notes: ""
    )
}

private func makeWorkout(
    id: UUID = UUID(),
    title: String,
    exercise: Exercise
) -> WorkoutTemplate {
    WorkoutTemplate(
        id: id,
        title: title,
        focus: title,
        exercises: [
            WorkoutExerciseTemplate(
                exerciseID: exercise.id,
                sets: [WorkoutSetTemplate(reps: 5, suggestedWeight: 80)]
            )
        ]
    )
}

private func makeFinishedSession(
    workout: WorkoutTemplate,
    exercise: Exercise,
    startedAt: Date
) -> WorkoutSession {
    WorkoutSession(
        workoutTemplateID: workout.id,
        title: workout.title,
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(600),
        exercises: [
            WorkoutExerciseLog(
                templateExerciseID: workout.exercises[0].id,
                exerciseID: exercise.id,
                groupKind: .regular,
                groupID: nil,
                sets: [
                    WorkoutSetLog(
                        reps: 5,
                        weight: 80,
                        completedAt: startedAt.addingTimeInterval(120)
                    )
                ]
            )
        ]
    )
}

private func makeActiveSession(
    workout: WorkoutTemplate,
    exercise: Exercise,
    startedAt: Date
) -> WorkoutSession {
    WorkoutSession(
        workoutTemplateID: workout.id,
        title: workout.title,
        startedAt: startedAt,
        endedAt: nil,
        exercises: [
            WorkoutExerciseLog(
                templateExerciseID: workout.exercises[0].id,
                exerciseID: exercise.id,
                groupKind: .regular,
                groupID: nil,
                sets: [
                    WorkoutSetLog(reps: 5, weight: 80, completedAt: startedAt.addingTimeInterval(120)),
                    WorkoutSetLog(reps: 5, weight: 80, completedAt: nil)
                ]
            )
        ]
    )
}
