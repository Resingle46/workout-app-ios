import Foundation
import Observation
import SwiftUI

struct CoachRuntimeConfiguration: Hashable, Sendable {
    var isFeatureEnabled: Bool
    var backendBaseURL: URL?

    init(isFeatureEnabled: Bool, backendBaseURL: URL?) {
        self.isFeatureEnabled = isFeatureEnabled
        self.backendBaseURL = backendBaseURL
    }

    init(bundle: Bundle) {
        let infoDictionary = bundle.infoDictionary ?? [:]
        let isFeatureEnabled = infoDictionary["CoachFeatureEnabled"] as? Bool ?? false
        let baseURLString = (infoDictionary["CoachBackendBaseURL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let backendBaseURL: URL?
        if let baseURLString, !baseURLString.isEmpty {
            backendBaseURL = URL(string: baseURLString)
        } else {
            backendBaseURL = nil
        }

        self.init(
            isFeatureEnabled: isFeatureEnabled,
            backendBaseURL: backendBaseURL
        )
    }

    var canUseRemoteCoach: Bool {
        isFeatureEnabled && backendBaseURL != nil
    }
}

enum CoachClientError: LocalizedError, Equatable {
    case featureDisabled
    case missingBaseURL
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .featureDisabled:
            return coachLocalizedString("coach.error.feature_disabled")
        case .missingBaseURL:
            return coachLocalizedString("coach.error.missing_base_url")
        case .invalidResponse:
            return coachLocalizedString("coach.error.invalid_response")
        case .httpStatus(let code):
            return String(
                format: coachLocalizedString("coach.error.http_status"),
                code
            )
        }
    }
}

enum CoachCapabilityScope: String, Codable, Hashable, Sendable {
    case draftChanges = "draft_changes"
}

enum CoachInsightsOrigin: Hashable, Sendable {
    case remote
    case fallback
}

protocol CoachAPIClient: Sendable {
    func fetchProfileInsights(
        locale: String,
        context: CoachContextPayload,
        capabilityScope: CoachCapabilityScope
    ) async throws -> CoachProfileInsights

    func sendChat(
        locale: String,
        question: String,
        previousResponseID: String?,
        context: CoachContextPayload,
        capabilityScope: CoachCapabilityScope
    ) async throws -> CoachChatResponse
}

struct CoachProfileInsightsRequest: Codable, Sendable {
    var locale: String
    var context: CoachContextPayload
    var capabilityScope: CoachCapabilityScope
}

struct CoachChatRequest: Codable, Sendable {
    var locale: String
    var question: String
    var previousResponseID: String?
    var context: CoachContextPayload
    var capabilityScope: CoachCapabilityScope
}

struct CoachProfileInsights: Codable, Hashable, Sendable {
    var summary: String
    var recommendations: [String]
    var suggestedChanges: [CoachSuggestedChange]
}

struct CoachChatResponse: Codable, Hashable, Sendable {
    var answerMarkdown: String
    var responseID: String?
    var followUps: [String]
    var suggestedChanges: [CoachSuggestedChange]
}

enum CoachChatRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
}

struct CoachChatMessage: Identifiable, Hashable, Sendable {
    var id: String
    var role: CoachChatRole
    var content: String
    var followUps: [String]
    var suggestedChanges: [CoachSuggestedChange]

    init(
        id: String = UUID().uuidString,
        role: CoachChatRole,
        content: String,
        followUps: [String] = [],
        suggestedChanges: [CoachSuggestedChange] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.followUps = followUps
        self.suggestedChanges = suggestedChanges
    }
}

enum CoachSuggestedChangeType: String, Codable, Hashable, Sendable {
    case setWeeklyWorkoutTarget
    case addWorkoutDay
    case deleteWorkoutDay
    case swapWorkoutExercise
    case updateTemplateExercisePrescription
}

struct CoachSuggestedChange: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var type: CoachSuggestedChangeType
    var title: String
    var summary: String
    var weeklyWorkoutTarget: Int?
    var programID: UUID?
    var workoutID: UUID?
    var templateExerciseID: UUID?
    var replacementExerciseID: UUID?
    var workoutTitle: String?
    var workoutFocus: String?
    var reps: Int?
    var setsCount: Int?
    var suggestedWeight: Double?

    var isApplicable: Bool {
        switch type {
        case .setWeeklyWorkoutTarget:
            return weeklyWorkoutTarget != nil
        case .addWorkoutDay:
            return programID != nil && workoutTitle != nil
        case .deleteWorkoutDay:
            return programID != nil && workoutID != nil
        case .swapWorkoutExercise:
            return programID != nil &&
                workoutID != nil &&
                templateExerciseID != nil &&
                replacementExerciseID != nil
        case .updateTemplateExercisePrescription:
            return programID != nil &&
                workoutID != nil &&
                templateExerciseID != nil &&
                reps != nil &&
                setsCount != nil &&
                suggestedWeight != nil
        }
    }
}

struct CoachContextPayload: Codable, Hashable, Sendable {
    var localeIdentifier: String
    var historyMode: String
    var profile: UserProfile
    var preferredProgram: CoachProgramContext?
    var activeWorkout: CoachActiveWorkoutContext?
    var analytics: CoachAnalyticsContext
    var recentFinishedSessions: [CoachRecentSessionContext]
}

struct CoachProgramContext: Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var workoutCount: Int
    var workouts: [CoachWorkoutDayContext]
}

struct CoachWorkoutDayContext: Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var focus: String
    var exerciseCount: Int
    var exercises: [CoachPlannedExerciseContext]
}

struct CoachPlannedExerciseContext: Codable, Hashable, Sendable {
    var templateExerciseID: UUID
    var exerciseID: UUID
    var exerciseName: String
    var setsCount: Int
    var reps: Int
    var suggestedWeight: Double
    var groupKind: String
}

struct CoachActiveWorkoutContext: Codable, Hashable, Sendable {
    var workoutTemplateID: UUID
    var title: String
    var startedAt: Date
    var exerciseCount: Int
    var completedSetsCount: Int
    var totalSetsCount: Int
}

struct CoachAnalyticsContext: Codable, Hashable, Sendable {
    var progress30Days: CoachProgressSnapshotContext
    var goal: CoachGoalContext
    var training: CoachTrainingRecommendationContext
    var compatibility: CoachCompatibilityContext
    var consistency: CoachConsistencyContext
    var recentPersonalRecords: [CoachPersonalRecordContext]
    var relativeStrength: [CoachRelativeStrengthContext]
}

struct CoachProgressSnapshotContext: Codable, Hashable, Sendable {
    var totalFinishedWorkouts: Int
    var recentExercisesCount: Int
    var recentVolume: Double
    var averageDurationSeconds: Double?
    var lastWorkoutDate: Date?
}

struct CoachGoalContext: Codable, Hashable, Sendable {
    var primaryGoal: String
    var currentWeight: Double
    var targetBodyWeight: Double?
    var weeklyWorkoutTarget: Int
    var safeWeeklyChangeLowerBound: Double?
    var safeWeeklyChangeUpperBound: Double?
    var etaWeeksLowerBound: Int?
    var etaWeeksUpperBound: Int?
    var usesCurrentWeightOnly: Bool
}

struct CoachTrainingRecommendationContext: Codable, Hashable, Sendable {
    var currentWeeklyTarget: Int
    var recommendedWeeklyTargetLowerBound: Int
    var recommendedWeeklyTargetUpperBound: Int
    var mainRepLowerBound: Int
    var mainRepUpperBound: Int
    var accessoryRepLowerBound: Int
    var accessoryRepUpperBound: Int
    var weeklySetsLowerBound: Int
    var weeklySetsUpperBound: Int
    var split: String
    var splitWorkoutDays: Int?
    var splitProgramTitle: String?
    var isGenericFallback: Bool
}

struct CoachCompatibilityContext: Codable, Hashable, Sendable {
    var isAligned: Bool
    var issues: [CoachCompatibilityIssueContext]
}

struct CoachCompatibilityIssueContext: Codable, Hashable, Sendable {
    var kind: String
    var message: String
}

struct CoachConsistencyContext: Codable, Hashable, Sendable {
    var workoutsThisWeek: Int
    var weeklyTarget: Int
    var streakWeeks: Int
    var mostFrequentWeekday: Int?
    var recentWeeklyActivity: [CoachWeeklyActivityContext]
}

struct CoachWeeklyActivityContext: Codable, Hashable, Sendable {
    var weekStart: Date
    var workoutsCount: Int
    var meetsTarget: Bool
}

struct CoachPersonalRecordContext: Codable, Hashable, Sendable {
    var exerciseID: UUID
    var exerciseName: String
    var achievedAt: Date
    var weight: Double
    var previousWeight: Double
    var delta: Double
}

struct CoachRelativeStrengthContext: Codable, Hashable, Sendable {
    var lift: String
    var bestLoad: Double?
    var relativeToBodyWeight: Double?
}

struct CoachRecentSessionContext: Codable, Hashable, Sendable {
    var id: UUID
    var workoutTemplateID: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double?
    var completedSetsCount: Int
    var totalVolume: Double
    var exercises: [CoachRecentSessionExerciseContext]
}

struct CoachRecentSessionExerciseContext: Codable, Hashable, Sendable {
    var templateExerciseID: UUID
    var exerciseID: UUID
    var exerciseName: String
    var groupKind: String
    var completedSetsCount: Int
    var bestWeight: Double?
    var totalVolume: Double
    var averageReps: Double?
    var performedSets: [CoachPerformedSetContext]
}

struct CoachPerformedSetContext: Codable, Hashable, Sendable {
    var reps: Int
    var weight: Double
    var completedAt: Date
}

struct CoachAPIHTTPClient: CoachAPIClient {
    private let configuration: CoachRuntimeConfiguration
    private let session: URLSession

    init(
        configuration: CoachRuntimeConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    func fetchProfileInsights(
        locale: String,
        context: CoachContextPayload,
        capabilityScope: CoachCapabilityScope
    ) async throws -> CoachProfileInsights {
        try await send(
            path: "v1/coach/profile-insights",
            body: CoachProfileInsightsRequest(
                locale: locale,
                context: context,
                capabilityScope: capabilityScope
            ),
            responseType: CoachProfileInsights.self
        )
    }

    func sendChat(
        locale: String,
        question: String,
        previousResponseID: String?,
        context: CoachContextPayload,
        capabilityScope: CoachCapabilityScope
    ) async throws -> CoachChatResponse {
        try await send(
            path: "v1/coach/chat",
            body: CoachChatRequest(
                locale: locale,
                question: question,
                previousResponseID: previousResponseID,
                context: context,
                capabilityScope: capabilityScope
            ),
            responseType: CoachChatResponse.self
        )
    }

    private func send<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        body: RequestBody,
        responseType: ResponseBody.Type
    ) async throws -> ResponseBody {
        guard configuration.isFeatureEnabled else {
            throw CoachClientError.featureDisabled
        }
        guard let baseURL = configuration.backendBaseURL else {
            throw CoachClientError.missingBaseURL
        }

        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoachClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw CoachClientError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try Self.decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw CoachClientError.invalidResponse
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct CoachContextBuilder {
    private static let recentFinishedSessionsLimit = 8

    @MainActor
    func build(from store: AppStore) -> CoachContextPayload {
        let progressSummary = store.profileProgressSummary()
        let goalSummary = store.profileGoalSummary()
        let trainingSummary = store.profileTrainingRecommendationSummary()
        let compatibilitySummary = store.profileGoalCompatibilitySummary()
        let consistencySummary = store.profileConsistencySummary()
        let recentPersonalRecords = store.recentPersonalRecords()
        let relativeStrengthSummary = store.profileStrengthToBodyweightSummary()
        let preferredProgram = CoachPreferredProgramResolver.resolve(from: store)
        let recentSessions = store.history
            .filter(\.isFinished)
            .prefix(Self.recentFinishedSessionsLimit)

        return CoachContextPayload(
            localeIdentifier: store.selectedLanguageCode,
            historyMode: "summary_recent_history",
            profile: store.profile,
            preferredProgram: preferredProgram.map { program in
                CoachProgramContext(
                    id: program.id,
                    title: program.title,
                    workoutCount: program.workouts.count,
                    workouts: program.workouts.map { workout in
                        CoachWorkoutDayContext(
                            id: workout.id,
                            title: workout.title,
                            focus: workout.focus,
                            exerciseCount: workout.exercises.count,
                            exercises: workout.exercises.compactMap { templateExercise in
                                guard let exercise = store.exercise(for: templateExercise.exerciseID) else {
                                    return nil
                                }

                                return CoachPlannedExerciseContext(
                                    templateExerciseID: templateExercise.id,
                                    exerciseID: templateExercise.exerciseID,
                                    exerciseName: exercise.localizedName,
                                    setsCount: templateExercise.sets.count,
                                    reps: templateExercise.sets.first?.reps ?? 0,
                                    suggestedWeight: templateExercise.sets.first?.suggestedWeight ?? 0,
                                    groupKind: templateExercise.groupKind.rawValue
                                )
                            }
                        )
                    }
                )
            },
            activeWorkout: store.activeSession.map { session in
                CoachActiveWorkoutContext(
                    workoutTemplateID: session.workoutTemplateID,
                    title: session.title,
                    startedAt: session.startedAt,
                    exerciseCount: session.exercises.count,
                    completedSetsCount: session.exercises.flatMap(\.sets).filter { $0.completedAt != nil }.count,
                    totalSetsCount: session.exercises.flatMap(\.sets).count
                )
            },
            analytics: CoachAnalyticsContext(
                progress30Days: CoachProgressSnapshotContext(
                    totalFinishedWorkouts: progressSummary.totalFinishedWorkouts,
                    recentExercisesCount: progressSummary.recentExercisesCount,
                    recentVolume: progressSummary.recentVolume,
                    averageDurationSeconds: progressSummary.averageDuration,
                    lastWorkoutDate: progressSummary.lastWorkoutDate
                ),
                goal: CoachGoalContext(
                    primaryGoal: goalSummary.primaryGoal.rawValue,
                    currentWeight: goalSummary.currentWeight,
                    targetBodyWeight: goalSummary.targetBodyWeight,
                    weeklyWorkoutTarget: goalSummary.weeklyWorkoutTarget,
                    safeWeeklyChangeLowerBound: goalSummary.safeWeeklyChangeLowerBound,
                    safeWeeklyChangeUpperBound: goalSummary.safeWeeklyChangeUpperBound,
                    etaWeeksLowerBound: goalSummary.etaWeeksLowerBound,
                    etaWeeksUpperBound: goalSummary.etaWeeksUpperBound,
                    usesCurrentWeightOnly: goalSummary.usesCurrentWeightOnly
                ),
                training: CoachTrainingRecommendationContext(
                    currentWeeklyTarget: trainingSummary.currentWeeklyTarget,
                    recommendedWeeklyTargetLowerBound: trainingSummary.recommendedWeeklyTargetLowerBound,
                    recommendedWeeklyTargetUpperBound: trainingSummary.recommendedWeeklyTargetUpperBound,
                    mainRepLowerBound: trainingSummary.mainRepLowerBound,
                    mainRepUpperBound: trainingSummary.mainRepUpperBound,
                    accessoryRepLowerBound: trainingSummary.accessoryRepLowerBound,
                    accessoryRepUpperBound: trainingSummary.accessoryRepUpperBound,
                    weeklySetsLowerBound: trainingSummary.weeklySetsLowerBound,
                    weeklySetsUpperBound: trainingSummary.weeklySetsUpperBound,
                    split: coachSplitIdentifier(trainingSummary.split),
                    splitWorkoutDays: trainingSummary.splitWorkoutDays,
                    splitProgramTitle: trainingSummary.splitProgramTitle,
                    isGenericFallback: trainingSummary.isGenericFallback
                ),
                compatibility: CoachCompatibilityContext(
                    isAligned: compatibilitySummary.isAligned,
                    issues: compatibilitySummary.issues.map { issue in
                        CoachCompatibilityIssueContext(
                            kind: issue.kind.rawValue,
                            message: coachCompatibilityMessage(issue)
                        )
                    }
                ),
                consistency: CoachConsistencyContext(
                    workoutsThisWeek: consistencySummary.workoutsThisWeek,
                    weeklyTarget: consistencySummary.weeklyTarget,
                    streakWeeks: consistencySummary.streakWeeks,
                    mostFrequentWeekday: consistencySummary.mostFrequentWeekday,
                    recentWeeklyActivity: consistencySummary.recentWeeklyActivity.map { activity in
                        CoachWeeklyActivityContext(
                            weekStart: activity.weekStart,
                            workoutsCount: activity.workoutsCount,
                            meetsTarget: activity.meetsTarget
                        )
                    }
                ),
                recentPersonalRecords: recentPersonalRecords.map { record in
                    CoachPersonalRecordContext(
                        exerciseID: record.exerciseID,
                        exerciseName: record.exerciseName,
                        achievedAt: record.achievedAt,
                        weight: record.weight,
                        previousWeight: record.previousWeight,
                        delta: record.delta
                    )
                },
                relativeStrength: relativeStrengthSummary.lifts.map { lift in
                    CoachRelativeStrengthContext(
                        lift: lift.lift.rawValue,
                        bestLoad: lift.bestLoad,
                        relativeToBodyWeight: lift.relativeToBodyWeight
                    )
                }
            ),
            recentFinishedSessions: recentSessions.map { session in
                let completedSets = session.exercises
                    .flatMap(\.sets)
                    .filter { $0.completedAt != nil }
                let totalVolume = completedSets.reduce(0.0) { partialResult, set in
                    partialResult + (set.weight * Double(set.reps))
                }

                return CoachRecentSessionContext(
                    id: session.id,
                    workoutTemplateID: session.workoutTemplateID,
                    title: session.title,
                    startedAt: session.startedAt,
                    endedAt: session.endedAt,
                    durationSeconds: session.endedAt.map { $0.timeIntervalSince(session.startedAt) },
                    completedSetsCount: completedSets.count,
                    totalVolume: totalVolume,
                    exercises: session.exercises.map { exerciseLog in
                        let performedSets = exerciseLog.sets.compactMap { set -> CoachPerformedSetContext? in
                            guard let completedAt = set.completedAt else {
                                return nil
                            }

                            return CoachPerformedSetContext(
                                reps: set.reps,
                                weight: set.weight,
                                completedAt: completedAt
                            )
                        }
                        let totalExerciseVolume = performedSets.reduce(0.0) { partialResult, set in
                            partialResult + (set.weight * Double(set.reps))
                        }
                        let averageReps: Double? = performedSets.isEmpty
                            ? nil
                            : performedSets.reduce(0.0) { $0 + Double($1.reps) } / Double(performedSets.count)

                        return CoachRecentSessionExerciseContext(
                            templateExerciseID: exerciseLog.templateExerciseID,
                            exerciseID: exerciseLog.exerciseID,
                            exerciseName: store.exercise(for: exerciseLog.exerciseID)?.localizedName ?? exerciseLog.exerciseID.uuidString,
                            groupKind: exerciseLog.groupKind.rawValue,
                            completedSetsCount: performedSets.count,
                            bestWeight: performedSets.map(\.weight).max(),
                            totalVolume: totalExerciseVolume,
                            averageReps: averageReps,
                            performedSets: performedSets
                        )
                    }
                )
            }
        )
    }
}

struct CoachFallbackInsightsFactory {
    @MainActor
    static func make(from store: AppStore) -> CoachProfileInsights {
        let goalSummary = store.profileGoalSummary()
        let trainingSummary = store.profileTrainingRecommendationSummary()
        let compatibilitySummary = store.profileGoalCompatibilitySummary()
        let preferredProgram = CoachPreferredProgramResolver.resolve(from: store)

        var recommendations: [String] = [
            fallbackFrequencyText(trainingSummary),
            fallbackRepRangeText(trainingSummary),
            fallbackVolumeText(trainingSummary),
            fallbackSplitText(trainingSummary)
        ]

        if compatibilitySummary.isAligned {
            recommendations.append(coachLocalizedString("profile.card.compatibility.aligned"))
        } else {
            recommendations.append(
                contentsOf: compatibilitySummary.issues
                    .prefix(2)
                    .map(coachCompatibilityMessage)
            )
        }

        if let etaText = fallbackGoalETA(goalSummary) {
            recommendations.append(
                String(
                    format: coachLocalizedString("coach.fallback.goal_eta"),
                    etaText
                )
            )
        }

        var suggestedChanges: [CoachSuggestedChange] = []
        let targetRange = trainingSummary.recommendedWeeklyTargetLowerBound...trainingSummary.recommendedWeeklyTargetUpperBound
        if !targetRange.contains(trainingSummary.currentWeeklyTarget) {
            let adjustedTarget = min(
                max(trainingSummary.currentWeeklyTarget, targetRange.lowerBound),
                targetRange.upperBound
            )
            if adjustedTarget != trainingSummary.currentWeeklyTarget {
                suggestedChanges.append(
                    CoachSuggestedChange(
                        id: "fallback-weekly-target-\(adjustedTarget)",
                        type: .setWeeklyWorkoutTarget,
                        title: coachLocalizedString("coach.draft.weekly_target.title"),
                        summary: String(
                            format: coachLocalizedString("coach.draft.weekly_target.summary"),
                            adjustedTarget
                        ),
                        weeklyWorkoutTarget: adjustedTarget
                    )
                )
            }
        }

        if let preferredProgram {
            let workoutCount = preferredProgram.workouts.count
            let targetWorkoutCount = store.profile.weeklyWorkoutTarget

            if workoutCount < targetWorkoutCount {
                let nextWorkoutIndex = workoutCount + 1
                suggestedChanges.append(
                    CoachSuggestedChange(
                        id: "fallback-add-workout-\(preferredProgram.id)-\(nextWorkoutIndex)",
                        type: .addWorkoutDay,
                        title: coachLocalizedString("coach.draft.add_day.title"),
                        summary: String(
                            format: coachLocalizedString("coach.draft.add_day.summary"),
                            preferredProgram.title
                        ),
                        programID: preferredProgram.id,
                        workoutTitle: String(
                            format: coachLocalizedString("coach.draft.add_day.default_title"),
                            nextWorkoutIndex
                        ),
                        workoutFocus: fallbackWorkoutFocus(for: store.profile.primaryGoal)
                    )
                )
            } else if workoutCount > targetWorkoutCount,
                      let workoutToDelete = preferredProgram.workouts.last {
                suggestedChanges.append(
                    CoachSuggestedChange(
                        id: "fallback-delete-workout-\(workoutToDelete.id)",
                        type: .deleteWorkoutDay,
                        title: coachLocalizedString("coach.draft.delete_day.title"),
                        summary: String(
                            format: coachLocalizedString("coach.draft.delete_day.summary"),
                            workoutToDelete.title
                        ),
                        programID: preferredProgram.id,
                        workoutID: workoutToDelete.id
                    )
                )
            }
        }

        let summary: String
        if compatibilitySummary.isAligned {
            summary = coachLocalizedString("coach.fallback.summary.aligned")
        } else {
            summary = String(
                format: coachLocalizedString("coach.fallback.summary.adjustments"),
                compatibilitySummary.issues.count
            )
        }

        return CoachProfileInsights(
            summary: summary,
            recommendations: Array(recommendations.filter { !$0.isEmpty }.prefix(5)),
            suggestedChanges: suggestedChanges
        )
    }

    private static func fallbackFrequencyText(_ summary: ProfileTrainingRecommendationSummary) -> String {
        if summary.recommendedWeeklyTargetLowerBound == summary.recommendedWeeklyTargetUpperBound {
            return String(
                format: coachLocalizedString("profile.card.recommendations.frequency_single_format"),
                summary.recommendedWeeklyTargetLowerBound
            )
        }

        return String(
            format: coachLocalizedString("profile.card.recommendations.frequency_format"),
            summary.recommendedWeeklyTargetLowerBound,
            summary.recommendedWeeklyTargetUpperBound
        )
    }

    private static func fallbackRepRangeText(_ summary: ProfileTrainingRecommendationSummary) -> String {
        String(
            format: coachLocalizedString("profile.card.recommendations.rep_range_format"),
            summary.mainRepLowerBound,
            summary.mainRepUpperBound,
            summary.accessoryRepLowerBound,
            summary.accessoryRepUpperBound
        )
    }

    private static func fallbackVolumeText(_ summary: ProfileTrainingRecommendationSummary) -> String {
        String(
            format: coachLocalizedString("profile.card.recommendations.volume_format"),
            summary.weeklySetsLowerBound,
            summary.weeklySetsUpperBound
        )
    }

    private static func fallbackSplitText(_ summary: ProfileTrainingRecommendationSummary) -> String {
        if let splitWorkoutDays = summary.splitWorkoutDays {
            return String(
                format: coachLocalizedString("profile.card.recommendations.split_days_format"),
                splitWorkoutDays
            )
        }

        return coachLocalizedSplitTitle(summary.split)
    }

    private static func fallbackGoalETA(_ summary: ProfileGoalSummary) -> String? {
        guard let lowerWeeks = summary.etaWeeksLowerBound,
              let upperWeeks = summary.etaWeeksUpperBound else {
            return nil
        }

        if upperWeeks >= 8 {
            let lowerMonths = max(Int(ceil(Double(lowerWeeks) / 4.345)), 1)
            let upperMonths = max(Int(ceil(Double(upperWeeks) / 4.345)), lowerMonths)
            return String(
                format: coachLocalizedString("profile.card.goal.eta_months"),
                lowerMonths,
                upperMonths
            )
        }

        return String(
            format: coachLocalizedString("profile.card.goal.eta_weeks"),
            lowerWeeks,
            upperWeeks
        )
    }

    private static func fallbackWorkoutFocus(for goal: TrainingGoal) -> String {
        switch goal {
        case .strength:
            return coachLocalizedString("coach.draft.add_day.focus.strength")
        case .hypertrophy:
            return coachLocalizedString("coach.draft.add_day.focus.hypertrophy")
        case .fatLoss:
            return coachLocalizedString("coach.draft.add_day.focus.fat_loss")
        case .generalFitness:
            return coachLocalizedString("coach.draft.add_day.focus.general_fitness")
        case .notSet:
            return coachLocalizedString("coach.draft.add_day.focus.default")
        }
    }
}

private struct CoachPreferredProgramResolver {
    @MainActor
    static func resolve(from store: AppStore) -> WorkoutProgram? {
        if let workoutTemplateID = store.activeSession?.workoutTemplateID,
           let program = program(containing: workoutTemplateID, in: store.programs) {
            return program
        }

        if let workoutTemplateID = store.lastFinishedSession?.workoutTemplateID,
           let program = program(containing: workoutTemplateID, in: store.programs) {
            return program
        }

        if let workoutTemplateID = store.history.first(where: \.isFinished)?.workoutTemplateID,
           let program = program(containing: workoutTemplateID, in: store.programs) {
            return program
        }

        return store.programs.first(where: { !$0.workouts.isEmpty })
    }

    private static func program(containing workoutTemplateID: UUID, in programs: [WorkoutProgram]) -> WorkoutProgram? {
        programs.first { program in
            program.workouts.contains { $0.id == workoutTemplateID }
        }
    }
}

@MainActor
@Observable
final class CoachStore {
    var profileInsights: CoachProfileInsights?
    var profileInsightsOrigin: CoachInsightsOrigin = .fallback
    var messages: [CoachChatMessage] = []
    var isLoadingProfileInsights = false
    var isSendingMessage = false
    var isApplyingSuggestedChange = false
    var lastInsightsErrorDescription: String?
    var lastChatErrorDescription: String?
    var pendingSuggestedChange: CoachSuggestedChange?

    @ObservationIgnored private let client: any CoachAPIClient
    @ObservationIgnored private let contextBuilder: CoachContextBuilder
    @ObservationIgnored private let configuration: CoachRuntimeConfiguration
    @ObservationIgnored private let capabilityScope: CoachCapabilityScope
    @ObservationIgnored private var previousResponseID: String?

    init(
        client: any CoachAPIClient,
        configuration: CoachRuntimeConfiguration,
        contextBuilder: CoachContextBuilder = CoachContextBuilder(),
        capabilityScope: CoachCapabilityScope = .draftChanges
    ) {
        self.client = client
        self.configuration = configuration
        self.contextBuilder = contextBuilder
        self.capabilityScope = capabilityScope
    }

    var canUseRemoteCoach: Bool {
        configuration.canUseRemoteCoach
    }

    var aggregatedSuggestedChanges: [CoachSuggestedChange] {
        let chatChanges = messages.reversed().flatMap(\.suggestedChanges)
        let insightChanges = profileInsights?.suggestedChanges ?? []
        return (chatChanges + insightChanges).deduplicatedCoachChanges()
    }

    func refreshProfileInsights(using appStore: AppStore) async {
        isLoadingProfileInsights = true
        defer { isLoadingProfileInsights = false }

        let fallbackInsights = CoachFallbackInsightsFactory.make(from: appStore)

        guard configuration.canUseRemoteCoach else {
            profileInsights = fallbackInsights
            profileInsightsOrigin = .fallback
            lastInsightsErrorDescription = nil
            return
        }

        do {
            let context = contextBuilder.build(from: appStore)
            let remoteInsights = try await client.fetchProfileInsights(
                locale: appStore.selectedLanguageCode,
                context: context,
                capabilityScope: capabilityScope
            )
            profileInsights = remoteInsights
            profileInsightsOrigin = .remote
            lastInsightsErrorDescription = nil
        } catch {
            profileInsights = fallbackInsights
            profileInsightsOrigin = .fallback
            lastInsightsErrorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func sendMessage(_ question: String, using appStore: AppStore) async {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !isSendingMessage else {
            return
        }

        messages.append(
            CoachChatMessage(
                role: .user,
                content: trimmedQuestion
            )
        )
        isSendingMessage = true
        lastChatErrorDescription = nil
        defer { isSendingMessage = false }

        guard configuration.canUseRemoteCoach else {
            let message = coachLocalizedString("coach.error.chat_unavailable")
            messages.append(CoachChatMessage(role: .assistant, content: message))
            lastChatErrorDescription = message
            return
        }

        do {
            let context = contextBuilder.build(from: appStore)
            let response = try await client.sendChat(
                locale: appStore.selectedLanguageCode,
                question: trimmedQuestion,
                previousResponseID: previousResponseID,
                context: context,
                capabilityScope: capabilityScope
            )
            previousResponseID = response.responseID
            messages.append(
                CoachChatMessage(
                    role: .assistant,
                    content: response.answerMarkdown,
                    followUps: response.followUps,
                    suggestedChanges: response.suggestedChanges
                )
            )
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastChatErrorDescription = description
            messages.append(CoachChatMessage(role: .assistant, content: description))
        }
    }

    func requestSuggestedChangeReview(_ change: CoachSuggestedChange) {
        pendingSuggestedChange = change
    }

    func cancelSuggestedChangeReview() {
        pendingSuggestedChange = nil
    }

    func confirmPendingSuggestedChange(using appStore: AppStore) async -> Bool {
        guard let pendingSuggestedChange else {
            return false
        }

        isApplyingSuggestedChange = true
        defer { isApplyingSuggestedChange = false }

        let applied = appStore.applyCoachSuggestedChange(pendingSuggestedChange)
        if applied {
            self.pendingSuggestedChange = nil
            await refreshProfileInsights(using: appStore)
        }
        return applied
    }

    func resetConversation() {
        messages = []
        previousResponseID = nil
        lastChatErrorDescription = nil
        pendingSuggestedChange = nil
        isSendingMessage = false
    }
}

@MainActor
struct CoachView: View {
    @Environment(AppStore.self) private var store
    @Environment(CoachStore.self) private var coachStore
    @Environment(\.appBottomRailInset) private var bottomRailInset
    @State private var draftQuestion = ""

    private var quickPrompts: [String] {
        [
            coachLocalizedString("coach.quick_prompt.analyze"),
            coachLocalizedString("coach.quick_prompt.volume"),
            coachLocalizedString("coach.quick_prompt.progression"),
            coachLocalizedString("coach.quick_prompt.recovery")
        ]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                AppPageHeaderModule(
                    titleKey: "header.coach.title",
                    subtitleKey: "header.coach.subtitle"
                ) {
                    Button {
                        Task {
                            await coachStore.refreshProfileInsights(using: store)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(AppTypography.icon(size: 18, weight: .semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .frame(width: 44, height: 44)
                            .background(AppTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(AppTheme.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(coachStore.isLoadingProfileInsights || coachStore.isSendingMessage)
                }

                CoachStatusCard(
                    isRemoteAvailable: coachStore.canUseRemoteCoach,
                    lastErrorDescription: coachStore.lastInsightsErrorDescription
                )

                if let profileInsights = coachStore.profileInsights {
                    CoachInsightsOverviewCard(
                        insights: profileInsights,
                        origin: coachStore.profileInsightsOrigin
                    ) {
                        store.selectedTab = .profile
                    }
                } else if coachStore.isLoadingProfileInsights {
                    AppCard {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(AppTheme.accent)
                            Text("coach.loading.insights")
                                .font(AppTypography.body(size: 16, weight: .medium))
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionTitle(titleKey: "coach.quick_prompt.title")

                        FlowLayout(spacing: 10) {
                            ForEach(quickPrompts, id: \.self) { prompt in
                                Button(prompt) {
                                    sendQuestion(prompt)
                                }
                                .buttonStyle(CoachPromptButtonStyle())
                                .disabled(!coachStore.canUseRemoteCoach || coachStore.isSendingMessage)
                                .opacity(coachStore.canUseRemoteCoach ? 1 : 0.55)
                            }
                        }
                    }
                }

                if !coachStore.messages.isEmpty {
                    AppCard {
                        VStack(alignment: .leading, spacing: 16) {
                            AppSectionTitle(titleKey: "coach.chat.title")

                            ForEach(coachStore.messages) { message in
                                CoachChatMessageCard(message: message) { followUp in
                                    sendQuestion(followUp)
                                } onReviewChange: { change in
                                    coachStore.requestSuggestedChangeReview(change)
                                }
                            }
                        }
                    }
                }

                if !coachStore.aggregatedSuggestedChanges.isEmpty {
                    AppCard {
                        VStack(alignment: .leading, spacing: 16) {
                            AppSectionTitle(titleKey: "coach.suggested_changes.title")
                            CoachSuggestedChangesList(
                                changes: coachStore.aggregatedSuggestedChanges,
                                applyButtonTitle: coachLocalizedString("coach.action.review_apply")
                            ) { change in
                                coachStore.requestSuggestedChangeReview(change)
                            }
                        }
                    }
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionTitle(titleKey: "coach.ask.title")

                        TextField("coach.ask.placeholder", text: $draftQuestion, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(AppTypography.body(size: 16))
                            .foregroundStyle(AppTheme.primaryText)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(AppTheme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(AppTheme.border, lineWidth: 1)
                            )

                        Button("coach.action.send") {
                            sendQuestion(draftQuestion)
                        }
                        .buttonStyle(AppPrimaryButtonStyle())
                        .disabled(draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coachStore.isSendingMessage || !coachStore.canUseRemoteCoach)
                        .opacity(
                            draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !coachStore.canUseRemoteCoach
                            ? 0.55
                            : 1
                        )

                        if let chatError = coachStore.lastChatErrorDescription, !chatError.isEmpty {
                            Text(chatError)
                                .font(AppTypography.caption(size: 13, weight: .medium))
                                .foregroundStyle(AppTheme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 24 + bottomRailInset)
        }
        .task(id: store.selectedTab) {
            if store.selectedTab == .coach, coachStore.profileInsights == nil {
                await coachStore.refreshProfileInsights(using: store)
            }
        }
        .alert(
            Text("coach.apply.alert.title"),
            isPresented: Binding(
                get: { coachStore.pendingSuggestedChange != nil },
                set: { newValue in
                    if !newValue {
                        coachStore.cancelSuggestedChangeReview()
                    }
                }
            ),
            presenting: coachStore.pendingSuggestedChange
        ) { _ in
            Button("coach.action.apply") {
                Task {
                    _ = await coachStore.confirmPendingSuggestedChange(using: store)
                }
            }
            Button("action.cancel", role: .cancel) {
                coachStore.cancelSuggestedChangeReview()
            }
        } message: { change in
            Text(change.summary)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .appScreenBackground()
    }

    private func sendQuestion(_ question: String) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            return
        }

        draftQuestion = ""
        Task {
            await coachStore.sendMessage(trimmedQuestion, using: store)
        }
    }
}

private struct CoachStatusCard: View {
    let isRemoteAvailable: Bool
    let lastErrorDescription: String?

    private var statusKey: LocalizedStringKey {
        isRemoteAvailable ? "coach.status.remote" : "coach.status.fallback"
    }

    private var descriptionKey: LocalizedStringKey {
        isRemoteAvailable ? "coach.status.remote_description" : "coach.status.fallback_description"
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isRemoteAvailable ? AppTheme.success : AppTheme.warning)
                        .frame(width: 10, height: 10)

                    Text(statusKey)
                        .font(AppTypography.body(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                }

                Text(descriptionKey)
                    .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastErrorDescription, !lastErrorDescription.isEmpty {
                    Text(lastErrorDescription)
                        .font(AppTypography.caption(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct CoachInsightsOverviewCard: View {
    let insights: CoachProfileInsights
    let origin: CoachInsightsOrigin
    let onOpenProfile: () -> Void

    private var sourceKey: LocalizedStringKey {
        origin == .remote ? "coach.insights.source.remote" : "coach.insights.source.fallback"
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        AppSectionTitle(titleKey: "coach.insights.title")

                        Text(sourceKey)
                            .font(AppTypography.caption(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    Spacer(minLength: 12)

                    Button("coach.action.open_profile") {
                        onOpenProfile()
                    }
                    .buttonStyle(CoachPromptButtonStyle())
                }

                Text(insights.summary)
                    .font(AppTypography.heading(size: 23))
                    .foregroundStyle(AppTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(insights.recommendations.prefix(4).enumerated()), id: \.offset) { _, recommendation in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(AppTheme.accent)
                                .frame(width: 7, height: 7)
                                .padding(.top, 8)

                            Text(recommendation)
                                .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

private struct CoachChatMessageCard: View {
    let message: CoachChatMessage
    let onFollowUpTap: (String) -> Void
    let onReviewChange: (CoachSuggestedChange) -> Void

    private var isAssistant: Bool {
        message.role == .assistant
    }

    private var authorKey: LocalizedStringKey {
        isAssistant ? "coach.message.coach" : "coach.message.you"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: isAssistant ? "sparkles" : "person.fill")
                    .font(AppTypography.icon(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 32, height: 32)
                    .background(
                        (isAssistant ? AppTheme.accent.opacity(0.28) : AppTheme.surfaceElevated),
                        in: Circle()
                    )

                Text(authorKey)
                    .font(AppTypography.body(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
            }

            CoachMarkdownText(content: message.content, isAssistant: isAssistant)

            if !message.followUps.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(message.followUps, id: \.self) { followUp in
                        Button(followUp) {
                            onFollowUpTap(followUp)
                        }
                        .buttonStyle(CoachPromptButtonStyle())
                    }
                }
            }

            if !message.suggestedChanges.isEmpty {
                CoachSuggestedChangesList(
                    changes: message.suggestedChanges,
                    applyButtonTitle: coachLocalizedString("coach.action.review_apply")
                ) { change in
                    onReviewChange(change)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isAssistant ? AppTheme.surfaceElevated : AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }
}

struct CoachSuggestedChangesList: View {
    let changes: [CoachSuggestedChange]
    let applyButtonTitle: String
    let onReviewChange: (CoachSuggestedChange) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 10) {
                    Text(change.title)
                        .font(AppTypography.body(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)

                    Text(change.summary)
                        .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(applyButtonTitle) {
                        onReviewChange(change)
                    }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(!change.isApplicable)
                    .opacity(change.isApplicable ? 1 : 0.55)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(AppTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
            }
        }
    }
}

private struct CoachMarkdownText: View {
    let content: String
    let isAssistant: Bool

    var body: some View {
        if let attributedString = try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributedString)
                .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(isAssistant ? AppTheme.primaryText : AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(content)
                .font(AppTypography.body(size: 15, weight: .medium, relativeTo: .subheadline))
                .foregroundStyle(isAssistant ? AppTheme.primaryText : AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CoachPromptButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.caption(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(configuration.isPressed ? AppTheme.surfacePressed : AppTheme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            )
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentLineWidth: CGFloat = 0
        var currentLineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentLineWidth + size.width > maxWidth, currentLineWidth > 0 {
                totalWidth = max(totalWidth, currentLineWidth - spacing)
                totalHeight += currentLineHeight + spacing
                currentLineWidth = size.width + spacing
                currentLineHeight = size.height
            } else {
                currentLineWidth += size.width + spacing
                currentLineHeight = max(currentLineHeight, size.height)
            }
        }

        totalWidth = max(totalWidth, currentLineWidth > 0 ? currentLineWidth - spacing : 0)
        totalHeight += currentLineHeight

        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var point = bounds.origin
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x + size.width > bounds.maxX, point.x > bounds.minX {
                point.x = bounds.minX
                point.y += lineHeight + spacing
                lineHeight = 0
            }

            subview.place(
                at: point,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            point.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private extension Array where Element == CoachSuggestedChange {
    func deduplicatedCoachChanges() -> [CoachSuggestedChange] {
        var seenIDs = Set<String>()
        var result: [CoachSuggestedChange] = []

        for change in self where !seenIDs.contains(change.id) {
            seenIDs.insert(change.id)
            result.append(change)
        }

        return result
    }
}

private func coachLocalizedString(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

private func coachLocalizedSplitTitle(_ split: ProfileTrainingSplitRecommendation) -> String {
    let key: String

    switch split {
    case .fullBody:
        key = "profile.card.recommendations.split.full_body"
    case .upperLowerHybrid:
        key = "profile.card.recommendations.split.upper_lower_hybrid"
    case .upperLower:
        key = "profile.card.recommendations.split.upper_lower"
    case .upperLowerPlusSpecialization:
        key = "profile.card.recommendations.split.upper_lower_plus"
    case .highFrequencySplit:
        key = "profile.card.recommendations.split.high_frequency"
    }

    return coachLocalizedString(key)
}

private func coachSplitIdentifier(_ split: ProfileTrainingSplitRecommendation) -> String {
    switch split {
    case .fullBody:
        return "full_body"
    case .upperLowerHybrid:
        return "upper_lower_hybrid"
    case .upperLower:
        return "upper_lower"
    case .upperLowerPlusSpecialization:
        return "upper_lower_plus_specialization"
    case .highFrequencySplit:
        return "high_frequency_split"
    }
}

private func coachCompatibilityMessage(_ issue: ProfileGoalCompatibilityIssue) -> String {
    switch issue.kind {
    case .missingGoal:
        return coachLocalizedString("profile.card.compatibility.issue_missing_goal")
    case .goalTargetMismatch:
        return coachLocalizedString("profile.card.compatibility.issue_goal_target")
    case .frequencyTooLow:
        return String(
            format: coachLocalizedString("profile.card.compatibility.issue_frequency_low"),
            issue.recommendedWeeklyTargetLowerBound ?? 0,
            issue.currentWeeklyTarget ?? 0
        )
    case .frequencyTooHighForBeginner:
        return String(
            format: coachLocalizedString("profile.card.compatibility.issue_frequency_high_beginner"),
            issue.currentWeeklyTarget ?? 0
        )
    case .programFrequencyMismatch:
        return String(
            format: coachLocalizedString("profile.card.compatibility.issue_program_frequency_mismatch"),
            issue.programWorkoutCount ?? 0,
            issue.currentWeeklyTarget ?? 0
        )
    case .adherenceGap:
        return String(
            format: coachLocalizedString("profile.card.compatibility.issue_adherence_gap"),
            issue.observedWorkoutsPerWeek?.appNumberText ?? coachLocalizedString("common.no_data"),
            issue.currentWeeklyTarget ?? 0
        )
    case .longGoalTimeline:
        return String(
            format: coachLocalizedString("profile.card.compatibility.issue_long_eta"),
            issue.etaWeeksUpperBound ?? 0
        )
    }
}
