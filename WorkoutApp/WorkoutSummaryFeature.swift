import CryptoKit
import Foundation
import Observation
import OSLog

private let workoutSummaryDefaultPrewarmDebounceDuration: Duration = .milliseconds(300)
private let workoutSummaryDefaultMaxPollingDuration: TimeInterval = 180
private let workoutSummaryDeferredResumeDelay: Duration = .seconds(20)
private let workoutSummaryDefaultPollIntervalMs: @Sendable (Int) -> Int = { attempt in
    switch attempt {
    case 0:
        return 1_500
    case 1:
        return 3_000
    default:
        return 5_000
    }
}

enum WorkoutSummaryRequestMode: String, Codable, Hashable, Sendable {
    case prewarm
    case final
}

enum WorkoutSummaryTrigger: String, Codable, Hashable, Sendable {
    case prewarmOneRemainingSet = "prewarm_one_remaining_set"
    case prewarmAllSetsCompleted = "prewarm_all_sets_completed"
    case finalAfterFinish = "final_after_finish"
}

enum WorkoutSummaryInputMode: String, Codable, Hashable, Sendable {
    case projectedFinal = "projected_final"
    case finishedSession = "finished_session"
}

struct WorkoutSummarySetPayload: Codable, Hashable, Sendable {
    var index: Int
    var reps: Int
    var weight: Double
    var isCompleted: Bool
}

struct WorkoutSummaryCurrentWorkoutExercisePayload: Codable, Hashable, Sendable {
    var templateExerciseID: UUID
    var exerciseID: UUID
    var exerciseName: String
    var groupKind: WorkoutExerciseTemplate.GroupKind
    var groupID: UUID?
    var sets: [WorkoutSummarySetPayload]
    var completedSetsCount: Int
    var totalSetsCount: Int
    var totalVolume: Double
}

struct WorkoutSummaryCurrentWorkoutPayload: Codable, Hashable, Sendable {
    var workoutTemplateID: UUID
    var title: String
    var exerciseCount: Int
    var completedSetsCount: Int
    var totalSetsCount: Int
    var totalVolume: Double
    var exercises: [WorkoutSummaryCurrentWorkoutExercisePayload]
}

struct WorkoutSummaryHistorySetPayload: Codable, Hashable, Sendable {
    var reps: Int
    var weight: Double
}

struct WorkoutSummaryHistorySessionPayload: Codable, Hashable, Sendable {
    var sessionID: UUID
    var workoutTitle: String
    var startedAt: Date
    var completedSetsCount: Int
    var bestWeight: Double?
    var averageReps: Double?
    var totalVolume: Double
    var completedSets: [WorkoutSummaryHistorySetPayload]
}

struct WorkoutSummaryExerciseHistoryPayload: Codable, Hashable, Sendable {
    var exerciseID: UUID
    var exerciseName: String
    var sessions: [WorkoutSummaryHistorySessionPayload]
}

struct WorkoutSummaryJobCreateRequest: Codable, Hashable, Sendable {
    var locale: String
    var installID: String
    var provider: CoachAIProvider
    var clientRequestID: String
    var sessionID: UUID
    var fingerprint: String
    var requestMode: WorkoutSummaryRequestMode
    var trigger: WorkoutSummaryTrigger
    var inputMode: WorkoutSummaryInputMode
    var currentWorkout: WorkoutSummaryCurrentWorkoutPayload
    var recentExerciseHistory: [WorkoutSummaryExerciseHistoryPayload]
}

struct WorkoutSummaryResponse: Codable, Hashable, Sendable {
    var headline: String
    var summary: String
    var highlights: [String]
    var nextWorkoutFocus: [String]
    var provider: CoachAIProvider? = nil
    var generationStatus: CoachResponseGenerationStatus? = nil
}

struct WorkoutSummaryJobResult: Codable, Hashable, Sendable {
    var headline: String
    var summary: String
    var highlights: [String]
    var nextWorkoutFocus: [String]
    var provider: CoachAIProvider? = nil
    var generationStatus: CoachResponseGenerationStatus? = nil
    var inferenceMode: CoachChatInferenceMode
    var modelDurationMs: Int?
    var totalJobDurationMs: Int?
}

struct WorkoutSummaryJobCreateResponse: Codable, Hashable, Sendable {
    var jobID: String
    var sessionID: UUID
    var fingerprint: String
    var status: CoachChatJobStatus
    var createdAt: Date
    var pollAfterMs: Int
    var reusedExistingJob: Bool
    var metadata: CoachJobMetadata?
}

struct WorkoutSummaryJobStatusResponse: Codable, Hashable, Sendable {
    var jobID: String
    var sessionID: UUID
    var fingerprint: String
    var status: CoachChatJobStatus
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var result: WorkoutSummaryJobResult?
    var error: CoachChatJobError?
    var metadata: CoachJobMetadata?
}

enum WorkoutSummaryCardState: Hashable, Sendable {
    case hidden
    case loading
    case unavailable
    case ready(WorkoutSummaryJobResult)
}

struct WorkoutSummaryPreparedRequest: Hashable, Sendable {
    var request: WorkoutSummaryJobCreateRequest

    var sessionID: UUID {
        request.sessionID
    }

    var fingerprint: String {
        request.fingerprint
    }
}

@MainActor
enum WorkoutSummaryRequestBuilder {
    static func prewarmRequest(
        for session: WorkoutSession,
        using appStore: AppStore,
        installID: String,
        provider: CoachAIProvider
    ) throws -> WorkoutSummaryPreparedRequest? {
        let remainingIncompleteSets = incompleteSetCount(in: session)
        guard remainingIncompleteSets <= 1 else {
            return nil
        }

        let trigger: WorkoutSummaryTrigger
        let sourceSession: WorkoutSession

        switch remainingIncompleteSets {
        case 1:
            guard let projectedSession = projectedFinalSession(from: session) else {
                return nil
            }
            trigger = .prewarmOneRemainingSet
            sourceSession = projectedSession
        case 0:
            trigger = .prewarmAllSetsCompleted
            sourceSession = session
        default:
            return nil
        }

        return try buildPreparedRequest(
            from: sourceSession,
            using: appStore,
            installID: installID,
            provider: provider,
            requestMode: .prewarm,
            trigger: trigger,
            inputMode: .projectedFinal
        )
    }

    static func finalRequest(
        for session: WorkoutSession,
        using appStore: AppStore,
        installID: String,
        provider: CoachAIProvider
    ) throws -> WorkoutSummaryPreparedRequest {
        try buildPreparedRequest(
            from: session,
            using: appStore,
            installID: installID,
            provider: provider,
            requestMode: .final,
            trigger: .finalAfterFinish,
            inputMode: .finishedSession
        )
    }

    private static func buildPreparedRequest(
        from session: WorkoutSession,
        using appStore: AppStore,
        installID: String,
        provider: CoachAIProvider,
        requestMode: WorkoutSummaryRequestMode,
        trigger: WorkoutSummaryTrigger,
        inputMode: WorkoutSummaryInputMode
    ) throws -> WorkoutSummaryPreparedRequest {
        let currentWorkout = buildCurrentWorkout(from: session, using: appStore)
        let recentExerciseHistory = buildRecentExerciseHistory(from: session, using: appStore)
        let locale = appStore.selectedLanguageCode
        let fingerprint = try fingerprint(
            provider: provider,
            locale: locale,
            currentWorkout: currentWorkout,
            recentExerciseHistory: recentExerciseHistory
        )

        return WorkoutSummaryPreparedRequest(
            request: WorkoutSummaryJobCreateRequest(
                locale: locale,
                installID: installID,
                provider: provider,
                clientRequestID: UUID().uuidString.lowercased(),
                sessionID: session.id,
                fingerprint: fingerprint,
                requestMode: requestMode,
                trigger: trigger,
                inputMode: inputMode,
                currentWorkout: currentWorkout,
                recentExerciseHistory: recentExerciseHistory
            )
        )
    }

    static func fingerprint(
        provider: CoachAIProvider,
        locale: String,
        currentWorkout: WorkoutSummaryCurrentWorkoutPayload,
        recentExerciseHistory: [WorkoutSummaryExerciseHistoryPayload]
    ) throws -> String {
        let payload = WorkoutSummaryFingerprintPayload(
            provider: provider,
            locale: locale,
            currentWorkout: currentWorkout,
            recentExerciseHistory: recentExerciseHistory
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func buildCurrentWorkout(
        from session: WorkoutSession,
        using appStore: AppStore
    ) -> WorkoutSummaryCurrentWorkoutPayload {
        let exercises = session.exercises.map { exerciseLog in
            let setPayloads = exerciseLog.sets.enumerated().map { index, set in
                WorkoutSummarySetPayload(
                    index: index,
                    reps: set.reps,
                    weight: set.weight,
                    isCompleted: set.completedAt != nil
                )
            }
            let metrics = completedSetMetrics(from: exerciseLog.sets)

            return WorkoutSummaryCurrentWorkoutExercisePayload(
                templateExerciseID: exerciseLog.templateExerciseID,
                exerciseID: exerciseLog.exerciseID,
                exerciseName: appStore.exercise(for: exerciseLog.exerciseID)?.localizedName
                    ?? exerciseLog.exerciseID.uuidString,
                groupKind: exerciseLog.groupKind,
                groupID: exerciseLog.groupID,
                sets: setPayloads,
                completedSetsCount: metrics.completedSetsCount,
                totalSetsCount: exerciseLog.sets.count,
                totalVolume: metrics.totalVolume
            )
        }

        let allSets = session.exercises.flatMap(\.sets)
        let totalMetrics = completedSetMetrics(from: allSets)

        return WorkoutSummaryCurrentWorkoutPayload(
            workoutTemplateID: session.workoutTemplateID,
            title: session.title,
            exerciseCount: session.exercises.count,
            completedSetsCount: totalMetrics.completedSetsCount,
            totalSetsCount: allSets.count,
            totalVolume: totalMetrics.totalVolume,
            exercises: exercises
        )
    }

    private static func buildRecentExerciseHistory(
        from session: WorkoutSession,
        using appStore: AppStore
    ) -> [WorkoutSummaryExerciseHistoryPayload] {
        var orderedExerciseIDs: [UUID] = []
        var seenExerciseIDs: Set<UUID> = []

        for exerciseLog in session.exercises where seenExerciseIDs.insert(exerciseLog.exerciseID).inserted {
            orderedExerciseIDs.append(exerciseLog.exerciseID)
        }

        return orderedExerciseIDs.map { exerciseID in
            let exerciseName = appStore.exercise(for: exerciseID)?.localizedName ?? exerciseID.uuidString
            let sessions = appStore.history
                .lazy
                .filter { $0.id != session.id && $0.isFinished }
                .compactMap { historySession in
                    historySessionPayload(
                        for: historySession,
                        exerciseID: exerciseID
                    )
                }
                .prefix(6)

            return WorkoutSummaryExerciseHistoryPayload(
                exerciseID: exerciseID,
                exerciseName: exerciseName,
                sessions: Array(sessions)
            )
        }
    }

    private static func historySessionPayload(
        for session: WorkoutSession,
        exerciseID: UUID
    ) -> WorkoutSummaryHistorySessionPayload? {
        let matchingLogs = session.exercises.filter { $0.exerciseID == exerciseID }
        guard !matchingLogs.isEmpty else {
            return nil
        }

        let completedSets = matchingLogs
            .flatMap(\.sets)
            .filter { $0.completedAt != nil }

        guard !completedSets.isEmpty else {
            return nil
        }

        let completedSetPayloads = completedSets.map {
            WorkoutSummaryHistorySetPayload(reps: $0.reps, weight: $0.weight)
        }
        let metrics = completedSetMetrics(from: completedSets)

        return WorkoutSummaryHistorySessionPayload(
            sessionID: session.id,
            workoutTitle: session.title,
            startedAt: session.startedAt,
            completedSetsCount: metrics.completedSetsCount,
            bestWeight: metrics.bestWeight,
            averageReps: metrics.averageReps,
            totalVolume: metrics.totalVolume,
            completedSets: completedSetPayloads
        )
    }

    private static func projectedFinalSession(from session: WorkoutSession) -> WorkoutSession? {
        var projectedSession = session

        for exerciseIndex in projectedSession.exercises.indices {
            for setIndex in projectedSession.exercises[exerciseIndex].sets.indices
            where projectedSession.exercises[exerciseIndex].sets[setIndex].completedAt == nil {
                projectedSession.exercises[exerciseIndex].sets[setIndex].completedAt = session.startedAt
                return projectedSession
            }
        }

        return nil
    }

    private static func incompleteSetCount(in session: WorkoutSession) -> Int {
        session.exercises
            .flatMap(\.sets)
            .reduce(into: 0) { count, set in
                if set.completedAt == nil {
                    count += 1
                }
            }
    }

    private static func completedSetMetrics(from sets: [WorkoutSetLog]) -> WorkoutSummaryCompletedMetrics {
        let completedSets = sets.filter { $0.completedAt != nil }
        let totalVolume = completedSets.reduce(0.0) { partialResult, set in
            partialResult + (Double(set.reps) * set.weight)
        }
        let bestWeight = completedSets.lazy.map(\.weight).filter { $0 > 0 }.max()
        let averageReps = completedSets.isEmpty
            ? nil
            : Double(completedSets.reduce(0) { $0 + $1.reps }) / Double(completedSets.count)

        return WorkoutSummaryCompletedMetrics(
            completedSetsCount: completedSets.count,
            totalVolume: totalVolume,
            bestWeight: bestWeight,
            averageReps: averageReps
        )
    }
}

private struct WorkoutSummaryFingerprintPayload: Codable, Sendable {
    var provider: CoachAIProvider
    var locale: String
    var currentWorkout: WorkoutSummaryCurrentWorkoutPayload
    var recentExerciseHistory: [WorkoutSummaryExerciseHistoryPayload]
}

private struct WorkoutSummaryCompletedMetrics: Hashable, Sendable {
    var completedSetsCount: Int
    var totalVolume: Double
    var bestWeight: Double?
    var averageReps: Double?
}

private struct WorkoutSummarySessionState: Hashable, Sendable {
    var latestFingerprint: String?
    var activeJobID: String?
    var activeProvider: CoachAIProvider?
    var activeJobFingerprint: String?
    var status: CoachChatJobStatus?
    var resultByFingerprint: [String: WorkoutSummaryJobResult] = [:]
    var error: CoachChatJobError?
    var lastTrigger: WorkoutSummaryTrigger?
    var requestMode: WorkoutSummaryRequestMode?
    var hadPrewarm = false
    var reusedPreparedResult = false
    var finalRegenerated = false
    var finalRequestedAt: Date?
    var awaitingResume = false
    var lastTouchedAt: Date = .now
}

@MainActor
@Observable
final class WorkoutSummaryStore {
    private static let initialPollAfterMs = 1_500
    private static let retainedSessionCount = 2

    private var configuration: CoachRuntimeConfiguration
    private var sessionStates: [UUID: WorkoutSummarySessionState] = [:]
    var lastSummaryProvider: CoachAIProvider?

    @ObservationIgnored private var client: any CoachAPIClient
    @ObservationIgnored private let installID: String
    @ObservationIgnored private let localStateStore: CoachLocalStateStore
    @ObservationIgnored private let prewarmDebounceDuration: Duration
    @ObservationIgnored private let maxPollingDuration: TimeInterval
    @ObservationIgnored private let pollIntervalProvider: @Sendable (Int) -> Int
    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private let debugRecorder: any DebugEventRecording
    @ObservationIgnored private var prewarmTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pollTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pollTaskJobIDs: [UUID: String] = [:]
    @ObservationIgnored private var deferredResumeTasks: [UUID: Task<Void, Never>] = [:]

    init(
        client: any CoachAPIClient,
        configuration: CoachRuntimeConfiguration,
        localStateStore: CoachLocalStateStore = CoachLocalStateStore(),
        prewarmDebounceDuration: Duration = workoutSummaryDefaultPrewarmDebounceDuration,
        maxPollingDuration: TimeInterval = workoutSummaryDefaultMaxPollingDuration,
        pollIntervalProvider: @escaping @Sendable (Int) -> Int = workoutSummaryDefaultPollIntervalMs,
        debugRecorder: any DebugEventRecording = NoopDebugEventRecorder(),
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "WorkoutApp",
            category: "WorkoutSummary"
        )
    ) {
        self.client = client
        self.configuration = configuration
        self.localStateStore = localStateStore
        self.installID = localStateStore.installID
        self.prewarmDebounceDuration = prewarmDebounceDuration
        self.maxPollingDuration = maxPollingDuration
        self.pollIntervalProvider = pollIntervalProvider
        self.debugRecorder = debugRecorder
        self.logger = logger
        for (sessionID, pendingState) in localStateStore.pendingWorkoutSummaryStates {
            sessionStates[sessionID] = WorkoutSummarySessionState(
                latestFingerprint: pendingState.fingerprint,
                activeJobID: pendingState.jobID,
                activeProvider: pendingState.provider,
                activeJobFingerprint: pendingState.fingerprint,
                status: .queued,
                requestMode: pendingState.requestMode,
                awaitingResume: pendingState.awaitingResume
            )
        }
    }

    var canUseRemoteSummary: Bool {
        configuration.canUseRemoteCoach
    }

    var pendingProviderDebugValue: String? {
        sessionStates.values.first(where: { $0.activeJobID != nil })?.activeProvider?.rawValue
    }

    func updateConfiguration(_ configuration: CoachRuntimeConfiguration) {
        let providerChanged = self.configuration.provider != configuration.provider
        self.configuration = configuration
        client = CoachAPIHTTPClient(
            configuration: configuration,
            debugRecorder: debugRecorder
        )
        if providerChanged {
            for sessionID in sessionStates.keys {
                var state = sessionState(for: sessionID)
                state.resultByFingerprint = state.resultByFingerprint.filter {
                    $0.value.provider == configuration.provider
                }
                if state.activeProvider != nil, state.activeProvider != configuration.provider {
                    state.latestFingerprint = nil
                }
                sessionStates[sessionID] = state
            }
        }
    }

    func cardState(for sessionID: UUID) -> WorkoutSummaryCardState {
        guard configuration.canUseRemoteCoach || sessionStates[sessionID] != nil else {
            return .hidden
        }
        guard let state = sessionStates[sessionID] else {
            return .loading
        }
        if let latestFingerprint = state.latestFingerprint,
           let result = state.resultByFingerprint[latestFingerprint] {
            return .ready(result)
        }
        if state.requestMode == .final,
           !state.awaitingResume,
           state.error != nil {
            return .unavailable
        }
        if state.activeJobID != nil || isPending(state.status) {
            return .loading
        }
        if state.requestMode == .final,
           state.error == nil {
            return .loading
        }
        return .hidden
    }

    func maybePrewarmSummary(
        for session: WorkoutSession,
        using appStore: AppStore
    ) async {
        guard configuration.canUseRemoteCoach else {
            return
        }

        do {
            guard let preparedRequest = try WorkoutSummaryRequestBuilder.prewarmRequest(
                for: session,
                using: appStore,
                installID: installID,
                provider: configuration.provider
            ) else {
                cancelPrewarmTask(for: session.id)
                return
            }

            var state = sessionState(for: session.id)
            state.latestFingerprint = preparedRequest.fingerprint
            state.lastTrigger = preparedRequest.request.trigger
            state.requestMode = .prewarm
            state.activeProvider = configuration.provider
            state.hadPrewarm = true
            state.lastTouchedAt = .now
            sessionStates[session.id] = state

            if state.resultByFingerprint[preparedRequest.fingerprint] != nil {
                logger.notice(
                    "prewarm_skipped_same_fingerprint session=\(session.id.uuidString, privacy: .public) fingerprint=\(preparedRequest.fingerprint, privacy: .public)"
                )
                return
            }

            if state.activeJobFingerprint == preparedRequest.fingerprint,
               isPending(state.status) {
                logger.notice(
                    "prewarm_skipped_running_job session=\(session.id.uuidString, privacy: .public) fingerprint=\(preparedRequest.fingerprint, privacy: .public)"
                )
                return
            }

            cancelPrewarmTask(for: session.id)
            let debounceDuration = prewarmDebounceDuration
            prewarmTasks[session.id] = Task { [sessionID = session.id, preparedRequest] in
                do {
                    if debounceDuration > .zero {
                        try await Task.sleep(for: debounceDuration)
                    }
                } catch {
                    return
                }

                await self.executeDebouncedPrewarm(
                    preparedRequest,
                    sessionID: sessionID
                )
            }

            logger.notice(
                "prewarm_triggered session=\(session.id.uuidString, privacy: .public) fingerprint=\(preparedRequest.fingerprint, privacy: .public) trigger=\(preparedRequest.request.trigger.rawValue, privacy: .public)"
            )
        } catch {
            logger.error(
                "prewarm_request_build_failed session=\(session.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func finalizeOrResumeSummary(
        for session: WorkoutSession,
        using appStore: AppStore
    ) async {
        cancelPrewarmTask(for: session.id)
        cancelDeferredResumeTask(for: session.id)

        guard configuration.canUseRemoteCoach else {
            return
        }

        do {
            let preparedRequest = try WorkoutSummaryRequestBuilder.finalRequest(
                for: session,
                using: appStore,
                installID: installID,
                provider: configuration.provider
            )
            let previousState = sessionState(for: session.id)
            let previousFingerprint = previousState.latestFingerprint
            let hasCachedResult = previousState.resultByFingerprint[preparedRequest.fingerprint] != nil
            let shouldResumeRunningJob =
                previousState.activeJobFingerprint == preparedRequest.fingerprint &&
                previousState.activeJobID != nil &&
                isPending(previousState.status)

            var nextState = previousState
            nextState.latestFingerprint = preparedRequest.fingerprint
            nextState.lastTrigger = .finalAfterFinish
            nextState.requestMode = .final
            nextState.activeProvider = configuration.provider
            nextState.lastTouchedAt = .now
            nextState.finalRequestedAt = previousFingerprint == preparedRequest.fingerprint
                ? (previousState.finalRequestedAt ?? .now)
                : .now

            if hasCachedResult {
                nextState.reusedPreparedResult = previousState.hadPrewarm
                nextState.status = .completed
                nextState.activeJobID = nil
                nextState.activeJobFingerprint = nil
                nextState.error = nil
                nextState.finalRequestedAt = nil
                nextState.awaitingResume = false
                sessionStates[session.id] = nextState
                logReady(
                    event: "existing_result_reused",
                    sessionID: session.id,
                    fingerprint: preparedRequest.fingerprint,
                    finalRequestedAt: previousState.finalRequestedAt,
                    result: nextState.resultByFingerprint[preparedRequest.fingerprint]
                )
                return
            }

            if shouldResumeRunningJob, let activeJobID = previousState.activeJobID {
                sessionStates[session.id] = nextState
                logger.notice(
                    "running_job_reused session=\(session.id.uuidString, privacy: .public) fingerprint=\(preparedRequest.fingerprint, privacy: .public) jobID=\(activeJobID, privacy: .public)"
                )
                await inspectOrResumeJob(
                    sessionID: session.id,
                    jobID: activeJobID,
                    fingerprint: preparedRequest.fingerprint
                )
                return
            }

            nextState.finalRegenerated = previousState.hadPrewarm && previousFingerprint != nil
            nextState.status = .queued
            nextState.activeJobID = nil
            nextState.activeJobFingerprint = preparedRequest.fingerprint
            nextState.error = nil
            nextState.awaitingResume = false
            sessionStates[session.id] = nextState
            cancelPollTask(for: session.id)
            cancelDeferredResumeTask(for: session.id)

            if nextState.finalRegenerated {
                logger.notice(
                    "final_regenerated session=\(session.id.uuidString, privacy: .public) fingerprint=\(preparedRequest.fingerprint, privacy: .public)"
                )
            }

            await createOrReuseJob(preparedRequest)
        } catch {
            logger.error(
                "final_request_build_failed session=\(session.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func retryFinalSummary(
        for session: WorkoutSession,
        using appStore: AppStore
    ) async {
        cancelPrewarmTask(for: session.id)
        cancelPollTask(for: session.id)
        cancelDeferredResumeTask(for: session.id)

        guard configuration.canUseRemoteCoach else {
            return
        }

        do {
            let preparedRequest = try WorkoutSummaryRequestBuilder.finalRequest(
                for: session,
                using: appStore,
                installID: installID,
                provider: configuration.provider
            )
            var state = sessionState(for: session.id)
            state.latestFingerprint = preparedRequest.fingerprint
            state.lastTrigger = .finalAfterFinish
            state.requestMode = .final
            state.activeProvider = configuration.provider
            state.status = .queued
            state.activeJobID = nil
            state.activeJobFingerprint = preparedRequest.fingerprint
            state.error = nil
            state.awaitingResume = false
            state.finalRequestedAt = .now
            state.lastTouchedAt = .now
            sessionStates[session.id] = state

            logger.notice(
                "summary_retry_requested session=\(session.id.uuidString, privacy: .public) fingerprint=\(preparedRequest.fingerprint, privacy: .public) provider=\(self.configuration.provider.rawValue, privacy: .public)"
            )

            await createOrReuseJob(preparedRequest)
        } catch {
            logger.error(
                "summary_retry_build_failed session=\(session.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func executeDebouncedPrewarm(
        _ preparedRequest: WorkoutSummaryPreparedRequest,
        sessionID: UUID
    ) async {
        prewarmTasks[sessionID] = nil

        let state = sessionState(for: sessionID)
        guard state.latestFingerprint == preparedRequest.fingerprint,
              state.requestMode == .prewarm else {
            return
        }

        if state.resultByFingerprint[preparedRequest.fingerprint] != nil {
            return
        }

        if state.activeJobFingerprint == preparedRequest.fingerprint,
           isPending(state.status) {
            return
        }

        await createOrReuseJob(preparedRequest)
    }

    private func createOrReuseJob(_ preparedRequest: WorkoutSummaryPreparedRequest) async {
        let sessionID = preparedRequest.sessionID
        let fingerprint = preparedRequest.fingerprint
        let state = sessionState(for: sessionID)

        guard state.latestFingerprint == fingerprint else {
            return
        }

        do {
            let response = try await client.createWorkoutSummaryJob(preparedRequest.request)
            var nextState = sessionState(for: sessionID)
            nextState.latestFingerprint = response.fingerprint
            nextState.activeJobID = response.jobID
            nextState.activeProvider = response.metadata?.provider ?? configuration.provider
            nextState.activeJobFingerprint = response.fingerprint
            nextState.status = response.status
            nextState.error = nil
            nextState.awaitingResume = false
            nextState.lastTouchedAt = .now
            sessionStates[sessionID] = nextState
            localStateStore.storePendingWorkoutSummaryState(
                .init(
                    sessionID: sessionID,
                    jobID: response.jobID,
                    fingerprint: response.fingerprint,
                    provider: nextState.activeProvider ?? configuration.provider,
                    requestMode: preparedRequest.request.requestMode,
                    awaitingResume: false
                )
            )
            cancelDeferredResumeTask(for: sessionID)

            if isTerminal(response.status) {
                await fetchJobStatusNow(
                    sessionID: sessionID,
                    jobID: response.jobID,
                    fingerprint: response.fingerprint
                )
                return
            }

            debugRecorder.log(
                category: .coach,
                message: "workout_summary_job_created",
                metadata: [
                    "sessionID": sessionID.uuidString,
                    "jobID": response.jobID,
                    "provider": (response.metadata?.provider ?? configuration.provider).rawValue,
                    "requestMode": preparedRequest.request.requestMode.rawValue
                ]
            )

            startPolling(
                sessionID: sessionID,
                jobID: response.jobID,
                fingerprint: response.fingerprint,
                initialDelayMs: response.pollAfterMs
            )
        } catch {
            handleRequestFailure(
                error,
                sessionID: sessionID,
                fingerprint: fingerprint
            )
        }
    }

    private func inspectOrResumeJob(
        sessionID: UUID,
        jobID: String,
        fingerprint: String
    ) async {
        if pollTasks[sessionID] != nil {
            return
        }

        cancelDeferredResumeTask(for: sessionID)

        do {
            let response = try await client.getWorkoutSummaryJob(
                jobID: jobID,
                installID: installID
            )

            if handleJobStatusResponse(response, expectedJobID: jobID) {
                return
            }

            startPolling(
                sessionID: sessionID,
                jobID: jobID,
                fingerprint: fingerprint,
                initialDelayMs: 0
            )
        } catch {
            if isTransientPollingError(error) {
                startPolling(
                    sessionID: sessionID,
                    jobID: jobID,
                    fingerprint: fingerprint,
                    initialDelayMs: Self.initialPollAfterMs
                )
            } else {
                handleRequestFailure(
                    error,
                    sessionID: sessionID,
                    fingerprint: fingerprint
                )
            }
        }
    }

    private func fetchJobStatusNow(
        sessionID: UUID,
        jobID: String,
        fingerprint: String
    ) async {
        do {
            let response = try await client.getWorkoutSummaryJob(
                jobID: jobID,
                installID: installID
            )

            if !handleJobStatusResponse(response, expectedJobID: jobID),
               isPending(response.status) {
                startPolling(
                    sessionID: sessionID,
                    jobID: jobID,
                    fingerprint: fingerprint,
                    initialDelayMs: 0
                )
            }
        } catch {
            handleRequestFailure(
                error,
                sessionID: sessionID,
                fingerprint: fingerprint
            )
        }
    }

    private func startPolling(
        sessionID: UUID,
        jobID: String,
        fingerprint: String,
        initialDelayMs: Int
    ) {
        cancelDeferredResumeTask(for: sessionID)
        cancelPollTask(for: sessionID)
        pollTaskJobIDs[sessionID] = jobID
        pollTasks[sessionID] = Task { [sessionID, jobID, fingerprint, initialDelayMs] in
            await self.pollJob(
                sessionID: sessionID,
                jobID: jobID,
                fingerprint: fingerprint,
                initialDelayMs: initialDelayMs
            )
        }
    }

    private func pollJob(
        sessionID: UUID,
        jobID: String,
        fingerprint: String,
        initialDelayMs: Int
    ) async {
        var nextDelayMs = max(initialDelayMs, 0)
        var pollAttempt = 0
        let pollStartedAt = Date()

        while shouldContinuePolling(
            sessionID: sessionID,
            jobID: jobID,
            fingerprint: fingerprint,
            pollStartedAt: pollStartedAt
        ) {
            if nextDelayMs > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(nextDelayMs) * 1_000_000)
                } catch {
                    clearPollTaskIfNeeded(sessionID: sessionID, jobID: jobID)
                    return
                }
            }

            do {
                let response = try await client.getWorkoutSummaryJob(
                    jobID: jobID,
                    installID: installID
                )

                if handleJobStatusResponse(response, expectedJobID: jobID) {
                    clearPollTaskIfNeeded(sessionID: sessionID, jobID: jobID)
                    return
                }
            } catch is CancellationError {
                clearPollTaskIfNeeded(sessionID: sessionID, jobID: jobID)
                return
            } catch {
                if !isTransientPollingError(error) {
                    handleRequestFailure(
                        error,
                        sessionID: sessionID,
                        fingerprint: fingerprint
                    )
                    clearPollTaskIfNeeded(sessionID: sessionID, jobID: jobID)
                    return
                }
            }

            pollAttempt += 1
            nextDelayMs = max(pollIntervalProvider(pollAttempt), 0)
        }

        handlePollingTimeout(
            sessionID: sessionID,
            jobID: jobID,
            fingerprint: fingerprint
        )
        clearPollTaskIfNeeded(sessionID: sessionID, jobID: jobID)
    }

    private func shouldContinuePolling(
        sessionID: UUID,
        jobID: String,
        fingerprint: String,
        pollStartedAt: Date
    ) -> Bool {
        guard let state = sessionStates[sessionID],
              state.activeJobID == jobID,
              state.activeJobFingerprint == fingerprint else {
            return false
        }

        guard Date().timeIntervalSince(pollStartedAt) < maxPollingDuration else {
            return false
        }

        return isPending(state.status)
    }

    @discardableResult
    private func handleJobStatusResponse(
        _ response: WorkoutSummaryJobStatusResponse,
        expectedJobID: String
    ) -> Bool {
        guard var state = sessionStates[response.sessionID],
              state.activeJobID == expectedJobID else {
            return true
        }

        state.lastTouchedAt = .now
        state.status = response.status
        state.awaitingResume = false

        if isPending(response.status) {
            sessionStates[response.sessionID] = state
            return false
        }

        state.activeJobID = nil
        state.activeJobFingerprint = nil
        state.awaitingResume = false
        localStateStore.removePendingWorkoutSummaryState(sessionID: response.sessionID)

        if response.status == .completed,
           let result = response.result {
            var storedResult = result
            storedResult.provider = result.provider ?? response.metadata?.provider ?? state.activeProvider
            state.resultByFingerprint[response.fingerprint] = storedResult
            state.error = nil
            lastSummaryProvider = storedResult.provider
            debugRecorder.log(
                category: .coach,
                message: "workout_summary_job_completed",
                metadata: [
                    "sessionID": response.sessionID.uuidString,
                    "provider": (storedResult.provider ?? configuration.provider).rawValue,
                    "status": response.status.rawValue
                ]
            )
            let waitStartedAt = state.finalRequestedAt
            state.finalRequestedAt = nil
            sessionStates[response.sessionID] = state
            cancelDeferredResumeTask(for: response.sessionID)
            logReady(
                event: "summary_ready",
                sessionID: response.sessionID,
                fingerprint: response.fingerprint,
                finalRequestedAt: waitStartedAt,
                result: result
            )
        } else {
            state.error = response.error ?? CoachChatJobError(
                code: "workout_summary_failed",
                message: workoutSummaryLocalizedString("coach.error.invalid_response"),
                retryable: false
            )
            state.finalRequestedAt = nil
            sessionStates[response.sessionID] = state
            cancelDeferredResumeTask(for: response.sessionID)
            logger.error(
                "summary_failed session=\(response.sessionID.uuidString, privacy: .public) fingerprint=\(response.fingerprint, privacy: .public) status=\(response.status.rawValue, privacy: .public) error=\(state.error?.message ?? "", privacy: .public)"
            )
        }

        purgeSessionStates()
        return true
    }

    private func handleRequestFailure(
        _ error: Error,
        sessionID: UUID,
        fingerprint: String
    ) {
        var state = sessionState(for: sessionID)
        guard state.latestFingerprint == fingerprint else {
            return
        }

        state.status = .failed
        state.activeJobID = nil
        state.activeJobFingerprint = nil
        state.error = WorkoutSummaryStore.makeJobError(from: error)
        state.finalRequestedAt = nil
        state.awaitingResume = false
        state.lastTouchedAt = .now
        sessionStates[sessionID] = state
        localStateStore.removePendingWorkoutSummaryState(sessionID: sessionID)
        cancelDeferredResumeTask(for: sessionID)

        logger.error(
            "summary_failed session=\(sessionID.uuidString, privacy: .public) fingerprint=\(fingerprint, privacy: .public) error=\(state.error?.message ?? error.localizedDescription, privacy: .public)"
        )
        debugRecorder.log(
            category: .coach,
            level: .error,
            message: "workout_summary_job_failed",
            metadata: [
                "sessionID": sessionID.uuidString,
                "provider": (state.activeProvider ?? configuration.provider).rawValue,
                "error": state.error?.message ?? error.localizedDescription
            ]
        )
        purgeSessionStates()
    }

    private func handlePollingTimeout(
        sessionID: UUID,
        jobID: String,
        fingerprint: String
    ) {
        guard var state = sessionStates[sessionID],
              state.activeJobID == jobID,
              state.activeJobFingerprint == fingerprint,
              isPending(state.status) else {
            return
        }

        state.awaitingResume = true
        state.error = nil
        state.lastTouchedAt = .now
        sessionStates[sessionID] = state
        if let provider = state.activeProvider {
            localStateStore.storePendingWorkoutSummaryState(
                .init(
                    sessionID: sessionID,
                    jobID: jobID,
                    fingerprint: fingerprint,
                    provider: provider,
                    requestMode: state.requestMode ?? .final,
                    awaitingResume: true
                )
            )
        }

        logger.notice(
            "summary_polling_suspended session=\(sessionID.uuidString, privacy: .public) fingerprint=\(fingerprint, privacy: .public) jobID=\(jobID, privacy: .public)"
        )
        debugRecorder.log(
            category: .coach,
            message: "workout_summary_job_suspended",
            metadata: [
                "sessionID": sessionID.uuidString,
                "jobID": jobID,
                "provider": (state.activeProvider ?? configuration.provider).rawValue
            ]
        )
        scheduleDeferredResume(
            sessionID: sessionID,
            jobID: jobID,
            fingerprint: fingerprint
        )
    }

    private func logReady(
        event: String,
        sessionID: UUID,
        fingerprint: String,
        finalRequestedAt: Date?,
        result: WorkoutSummaryJobResult?
    ) {
        let waitMs = finalRequestedAt.map {
            max(Int(Date().timeIntervalSince($0) * 1_000), 0)
        }

        if let waitMs {
            logger.notice(
                "\(event, privacy: .public) session=\(sessionID.uuidString, privacy: .public) fingerprint=\(fingerprint, privacy: .public) waitMs=\(waitMs, privacy: .public)"
            )
        } else {
            logger.notice(
                "\(event, privacy: .public) session=\(sessionID.uuidString, privacy: .public) fingerprint=\(fingerprint, privacy: .public)"
            )
        }

        if let result {
            logger.notice(
                "summary_payload_ready session=\(sessionID.uuidString, privacy: .public) fingerprint=\(fingerprint, privacy: .public) inferenceMode=\(result.inferenceMode.rawValue, privacy: .public) generationStatus=\((result.generationStatus ?? .fallback).rawValue, privacy: .public)"
            )
        }
    }

    private func sessionState(for sessionID: UUID) -> WorkoutSummarySessionState {
        sessionStates[sessionID] ?? WorkoutSummarySessionState()
    }

    private func cancelPrewarmTask(for sessionID: UUID) {
        prewarmTasks[sessionID]?.cancel()
        prewarmTasks[sessionID] = nil
    }

    private func cancelPollTask(for sessionID: UUID) {
        pollTasks[sessionID]?.cancel()
        pollTasks[sessionID] = nil
        pollTaskJobIDs[sessionID] = nil
    }

    private func cancelDeferredResumeTask(for sessionID: UUID) {
        deferredResumeTasks[sessionID]?.cancel()
        deferredResumeTasks[sessionID] = nil
    }

    private func clearPollTaskIfNeeded(sessionID: UUID, jobID: String) {
        if pollTaskJobIDs[sessionID] == jobID {
            pollTasks[sessionID] = nil
            pollTaskJobIDs[sessionID] = nil
        }
    }

    private func cancelAllTasks() {
        for task in prewarmTasks.values {
            task.cancel()
        }
        for task in pollTasks.values {
            task.cancel()
        }
        for task in deferredResumeTasks.values {
            task.cancel()
        }
        prewarmTasks.removeAll()
        pollTasks.removeAll()
        pollTaskJobIDs.removeAll()
        deferredResumeTasks.removeAll()
    }

    private func purgeSessionStates() {
        guard sessionStates.count > Self.retainedSessionCount else {
            return
        }

        let removableSessionIDs = sessionStates
            .sorted { $0.value.lastTouchedAt > $1.value.lastTouchedAt }
            .dropFirst(Self.retainedSessionCount)
            .map(\.key)

        for sessionID in removableSessionIDs {
            cancelPrewarmTask(for: sessionID)
            cancelPollTask(for: sessionID)
            cancelDeferredResumeTask(for: sessionID)
            localStateStore.removePendingWorkoutSummaryState(sessionID: sessionID)
            sessionStates.removeValue(forKey: sessionID)
        }
    }

    private func isPending(_ status: CoachChatJobStatus?) -> Bool {
        status == .queued || status == .running
    }

    private func isTerminal(_ status: CoachChatJobStatus) -> Bool {
        status == .completed || status == .failed || status == .canceled
    }

    private func isTransientPollingError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .dnsLookupFailed,
                 .resourceUnavailable:
                return true
            default:
                break
            }
        }

        if let clientError = error as? CoachClientError {
            return clientError.isTransientPollingFailure
        }

        return false
    }

    private static func makeJobError(from error: Error) -> CoachChatJobError {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription

        let retryable: Bool
        if let clientError = error as? CoachClientError {
            retryable = clientError.isTransientPollingFailure
        } else if let urlError = error as? URLError {
            retryable = [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .notConnectedToInternet,
                .dnsLookupFailed,
                .resourceUnavailable
            ].contains(urlError.code)
        } else {
            retryable = false
        }

        return CoachChatJobError(
            code: "workout_summary_request_failed",
            message: message,
            retryable: retryable
        )
    }

    private func scheduleDeferredResume(
        sessionID: UUID,
        jobID: String,
        fingerprint: String
    ) {
        cancelDeferredResumeTask(for: sessionID)
        deferredResumeTasks[sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(for: workoutSummaryDeferredResumeDelay)
            } catch {
                return
            }

            guard let self else {
                return
            }

            guard let state = sessionStates[sessionID],
                  state.awaitingResume,
                  state.activeJobID == jobID,
                  state.activeJobFingerprint == fingerprint,
                  isPending(state.status),
                  pollTasks[sessionID] == nil else {
                cancelDeferredResumeTask(for: sessionID)
                return
            }

            cancelDeferredResumeTask(for: sessionID)
            await inspectOrResumeJob(
                sessionID: sessionID,
                jobID: jobID,
                fingerprint: fingerprint
            )
        }
    }
}

private func workoutSummaryLocalizedString(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}
