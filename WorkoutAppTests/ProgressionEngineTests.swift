import XCTest
@testable import WorkoutApp

final class ProgressionEngineTests: XCTestCase {
    func testSparseHistoryReturnsInsufficientData() {
        let input = makeInput(
            exposures: [
                makeExposure(
                    completedSetCount: 3,
                    averageWeight: 80,
                    topWeight: 80,
                    minimumWeight: 80,
                    averageReps: 8
                )
            ]
        )

        let decision = ProgressionEngine().evaluate(input)

        XCTAssertEqual(decision.action, .insufficientData)
        XCTAssertTrue(decision.reasons.contains(.insufficientComparableHistory))
    }

    func testSparseCurrentSessionReturnsInsufficientData() {
        let currentExposure = makeExposure(
            completedSetCount: 1,
            averageWeight: 80,
            topWeight: 80,
            minimumWeight: 80,
            averageReps: 8,
            dataQuality: .sparseOrNoisy,
            comparability: .sparseOrNoisy
        )
        let previousExposure = makeExposure(
            completedSetCount: 3,
            averageWeight: 77.5,
            topWeight: 77.5,
            minimumWeight: 77.5,
            averageReps: 8
        )

        let decision = ProgressionEngine().evaluate(
            makeInput(exposures: [currentExposure, previousExposure])
        )

        XCTAssertEqual(decision.action, .insufficientData)
        XCTAssertTrue(decision.reasons.contains(.sparseCurrentSession))
    }

    func testConflictingSignalsReturnHold() {
        let input = makeInput(
            exposures: [
                makeExposure(
                    daysAgo: 0,
                    completedSetCount: 3,
                    averageWeight: 100,
                    topWeight: 100,
                    minimumWeight: 100,
                    averageReps: 8
                ),
                makeExposure(
                    daysAgo: 7,
                    completedSetCount: 3,
                    averageWeight: 97.5,
                    topWeight: 97.5,
                    minimumWeight: 97.5,
                    averageReps: 8
                ),
                makeExposure(
                    daysAgo: 14,
                    completedSetCount: 3,
                    averageWeight: 100,
                    topWeight: 100,
                    minimumWeight: 100,
                    averageReps: 8
                )
            ]
        )

        let decision = ProgressionEngine().evaluate(input)

        XCTAssertEqual(decision.action, .hold)
        XCTAssertTrue(decision.reasons.contains(.conflictingSignals))
        XCTAssertNil(decision.recommendedWeight)
    }

    func testRepeatedSuccessReturnsIncreaseWeight() {
        let input = makeInput(
            exposures: [
                makeExposure(
                    daysAgo: 0,
                    completedSetCount: 3,
                    averageWeight: 100,
                    topWeight: 100,
                    minimumWeight: 100,
                    averageReps: 8
                ),
                makeExposure(
                    daysAgo: 7,
                    completedSetCount: 3,
                    averageWeight: 97.5,
                    topWeight: 97.5,
                    minimumWeight: 97.5,
                    averageReps: 8
                ),
                makeExposure(
                    daysAgo: 14,
                    completedSetCount: 3,
                    averageWeight: 95,
                    topWeight: 95,
                    minimumWeight: 95,
                    averageReps: 8
                )
            ]
        )

        let decision = ProgressionEngine().evaluate(input)

        XCTAssertEqual(decision.action, .increaseWeight)
        XCTAssertEqual(decision.recommendedWeight, 102.5)
        XCTAssertTrue(decision.reasons.contains(.repeatedClearSuccess))
    }

    func testPlateauAndRepeatedFailureReturnDeload() {
        let input = makeInput(
            exposures: [
                makeExposure(
                    daysAgo: 0,
                    completedSetCount: 3,
                    averageWeight: 90,
                    topWeight: 90,
                    minimumWeight: 90,
                    averageReps: 6
                ),
                makeExposure(
                    daysAgo: 7,
                    completedSetCount: 3,
                    averageWeight: 95,
                    topWeight: 95,
                    minimumWeight: 95,
                    averageReps: 7
                ),
                makeExposure(
                    daysAgo: 14,
                    completedSetCount: 3,
                    averageWeight: 100,
                    topWeight: 100,
                    minimumWeight: 100,
                    averageReps: 8
                )
            ]
        )

        let decision = ProgressionEngine().evaluate(input)

        XCTAssertEqual(decision.action, .deload)
        XCTAssertEqual(decision.recommendedWeight, 81)
        XCTAssertTrue(decision.reasons.contains(.repeatedDeterioration))
        XCTAssertTrue(decision.reasons.contains(.plateauDetected))
    }

    func testPartialDeteriorationWithoutFullCriteriaReturnsHold() {
        let input = makeInput(
            exposures: [
                makeExposure(
                    daysAgo: 0,
                    completedSetCount: 3,
                    averageWeight: 97.5,
                    topWeight: 97.5,
                    minimumWeight: 97.5,
                    averageReps: 7.5
                ),
                makeExposure(
                    daysAgo: 7,
                    completedSetCount: 3,
                    averageWeight: 100,
                    topWeight: 100,
                    minimumWeight: 100,
                    averageReps: 8
                ),
                makeExposure(
                    daysAgo: 14,
                    completedSetCount: 3,
                    averageWeight: 97.5,
                    topWeight: 97.5,
                    minimumWeight: 97.5,
                    averageReps: 8
                )
            ]
        )

        let decision = ProgressionEngine().evaluate(input)

        XCTAssertEqual(decision.action, .hold)
    }

    @MainActor
    func testProgressionInputsAggregateHistoryByExerciseIDAcrossTemplates() {
        let exercise = makeExercise(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Bench Press"
        )
        let currentTemplateExerciseID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let previousTemplateExerciseID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let currentSession = makeSession(
            sessionID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            workoutTemplateID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            templateExerciseID: currentTemplateExerciseID,
            title: "Push A",
            exercise: exercise,
            weights: [80, 80, 80],
            reps: [8, 8, 8],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let previousSession = makeSession(
            sessionID: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!,
            workoutTemplateID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            templateExerciseID: previousTemplateExerciseID,
            title: "Push B",
            exercise: exercise,
            weights: [77.5, 77.5, 77.5],
            reps: [8, 8, 8],
            startedAt: Date(timeIntervalSince1970: 1_699_900_000)
        )
        let store = makeAppStore(
            exercises: [exercise],
            history: [currentSession, previousSession]
        )

        let inputs = store.progressionInputs(for: currentSession)

        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].exerciseID, exercise.id)
        XCTAssertEqual(inputs[0].currentTemplateExerciseID, currentTemplateExerciseID)
        XCTAssertEqual(inputs[0].exposures.count, 2)
        XCTAssertEqual(inputs[0].exposures[1].templateExerciseIDs, [previousTemplateExerciseID])
        XCTAssertEqual(inputs[0].exposures[1].comparability, .comparable)
    }

    func testEvaluateIsDeterministicForSameInput() {
        let input = makeInput(
            exposures: [
                makeExposure(
                    daysAgo: 0,
                    completedSetCount: 3,
                    averageWeight: 100,
                    topWeight: 100,
                    minimumWeight: 100,
                    averageReps: 8
                ),
                makeExposure(
                    daysAgo: 7,
                    completedSetCount: 3,
                    averageWeight: 97.5,
                    topWeight: 97.5,
                    minimumWeight: 97.5,
                    averageReps: 8
                ),
                makeExposure(
                    daysAgo: 14,
                    completedSetCount: 3,
                    averageWeight: 95,
                    topWeight: 95,
                    minimumWeight: 95,
                    averageReps: 8
                )
            ]
        )
        let engine = ProgressionEngine()

        let first = engine.evaluate(input)
        let second = engine.evaluate(input)

        XCTAssertEqual(first, second)
    }
}

private func makeInput(
    exerciseID: UUID = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!,
    currentTemplateExerciseID: UUID? = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
    exposures: [ProgressionExerciseSession],
    prescriptionCompatibility: ProgressionPrescriptionCompatibility = .compatible,
    daysSincePreviousExposure: Int? = 7,
    weeklyContext: ProgressionWeeklyContext? = nil
) -> ProgressionEngineInput {
    ProgressionEngineInput(
        exerciseID: exerciseID,
        currentTemplateExerciseID: currentTemplateExerciseID,
        exposures: exposures,
        prescriptionCompatibility: prescriptionCompatibility,
        daysSincePreviousExposure: daysSincePreviousExposure,
        weeklyContext: weeklyContext
    )
}

private func makeExposure(
    sessionID: UUID = UUID(),
    templateExerciseID: UUID = UUID(),
    daysAgo: Int = 0,
    completedSetCount: Int,
    averageWeight: Double,
    topWeight: Double,
    minimumWeight: Double,
    averageReps: Double,
    minimumReps: Int = 6,
    maximumReps: Int = 10,
    totalVolume: Double? = nil,
    dataQuality: ProgressionDataQuality = .usable,
    comparability: ProgressionExposureComparability = .comparable
) -> ProgressionExerciseSession {
    let metrics = ProgressionSessionMetrics(
        completedSetCount: completedSetCount,
        averageWeight: averageWeight,
        topWeight: topWeight,
        minimumWeight: minimumWeight,
        averageReps: averageReps,
        minimumReps: minimumReps,
        maximumReps: maximumReps,
        totalVolume: totalVolume ?? (averageWeight * averageReps * Double(max(completedSetCount, 1))),
        hasUsableLoadData: averageWeight > 0 && topWeight > 0
    )

    return ProgressionExerciseSession(
        sessionID: sessionID,
        performedAt: Date(timeIntervalSince1970: 1_700_000_000 - TimeInterval(daysAgo * 86_400)),
        templateExerciseIDs: [templateExerciseID],
        metrics: metrics,
        dataQuality: dataQuality,
        comparability: comparability
    )
}

@MainActor
private func makeAppStore(
    exercises: [Exercise],
    history: [WorkoutSession]
) -> AppStore {
    let store = AppStore()
    store.apply(snapshot: AppSnapshot(
        programs: [],
        exercises: exercises,
        history: history,
        profile: UserProfile(sex: "M", age: 29, weight: 85, height: 180, appLanguageCode: "en")
    ))
    return store
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

private func makeSession(
    sessionID: UUID,
    workoutTemplateID: UUID,
    templateExerciseID: UUID,
    title: String,
    exercise: Exercise,
    weights: [Double],
    reps: [Int],
    startedAt: Date
) -> WorkoutSession {
    let setLogs = zip(weights, reps).enumerated().map { index, entry in
        WorkoutSetLog(
            id: UUID(),
            reps: entry.1,
            weight: entry.0,
            completedAt: startedAt.addingTimeInterval(TimeInterval((index + 1) * 120))
        )
    }

    return WorkoutSession(
        id: sessionID,
        workoutTemplateID: workoutTemplateID,
        title: title,
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(600),
        exercises: [
            WorkoutExerciseLog(
                templateExerciseID: templateExerciseID,
                exerciseID: exercise.id,
                groupKind: .regular,
                groupID: nil,
                sets: setLogs
            )
        ]
    )
}
