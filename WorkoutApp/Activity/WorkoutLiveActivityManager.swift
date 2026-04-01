import Foundation
import OSLog

#if canImport(ActivityKit)
import ActivityKit
#endif

private let workoutLiveActivityLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "WorkoutApp",
    category: "live_activity"
)

private let workoutLiveActivityWeightFormatter: MeasurementFormatter = {
    let formatter = MeasurementFormatter()
    formatter.locale = .current
    formatter.unitStyle = .medium
    formatter.unitOptions = .providedUnit

    let numberFormatter = NumberFormatter()
    numberFormatter.locale = .current
    numberFormatter.minimumFractionDigits = 0
    numberFormatter.maximumFractionDigits = 1
    formatter.numberFormatter = numberFormatter
    return formatter
}()

struct WorkoutLiveActivitySnapshot: Equatable, Sendable {
    var sessionID: UUID
    var startedAt: Date
    var title: String
    var currentExerciseName: String
    var currentSetID: UUID?
    var currentSetNumber: Int?
    var currentSetLabel: String?
    var currentSetReps: Int?
    var currentSetWeight: Double?
    var currentSetValueText: String?
    var completedSetCount: Int
    var totalSetCount: Int
    var lastCompletedSetAt: Date?
    var updatedAt: Date
}

private struct WorkoutLiveActivityExerciseContext: Equatable, Sendable {
    var exerciseName: String
    var currentSetID: UUID?
    var currentSetNumber: Int?
    var currentSetLabel: String?
    var currentSetReps: Int?
    var currentSetWeight: Double?
    var currentSetValueText: String?
}

struct WorkoutLiveActivityDiagnosticsSnapshot: Hashable, Sendable {
    var runtimeSupported: Bool
    var areActivitiesEnabled: Bool?
    var activeSessionID: String?
    var knownActivityCount: Int
    var startedActivityID: String?
    var lastRequestStatus: String?
    var lastUpdateStatus: String?
    var lastEndStatus: String?
    var lastReconcileStatus: String?
    var lastSnapshotStatus: String?
    var lastErrorOrReason: String?
    var lastEventAt: Date?

    static let empty = WorkoutLiveActivityDiagnosticsSnapshot(
        runtimeSupported: false,
        areActivitiesEnabled: nil,
        activeSessionID: nil,
        knownActivityCount: 0,
        startedActivityID: nil,
        lastRequestStatus: nil,
        lastUpdateStatus: nil,
        lastEndStatus: nil,
        lastReconcileStatus: nil,
        lastSnapshotStatus: nil,
        lastErrorOrReason: nil,
        lastEventAt: nil
    )
}

@MainActor
final class WorkoutLiveActivityDiagnostics {
    private var current = WorkoutLiveActivityDiagnosticsSnapshot.empty

    init() {
        #if canImport(ActivityKit)
        current.runtimeSupported = true
        #endif
    }

    func snapshot() -> WorkoutLiveActivityDiagnosticsSnapshot {
        current
    }

    func recordInvocation(
        source: String,
        activeSessionID: String?,
        snapshotBuilt: Bool,
        reason: String?
    ) {
        current.runtimeSupported = true
        current.activeSessionID = activeSessionID
        current.lastReconcileStatus = "\(source)_called"
        current.lastSnapshotStatus = snapshotBuilt ? "built" : "nil"
        current.lastErrorOrReason = reason
        current.lastEventAt = .now
    }

    func recordUnsupportedPath(activeSessionID: String?, reason: String) {
        current.runtimeSupported = false
        current.areActivitiesEnabled = nil
        current.activeSessionID = activeSessionID
        current.knownActivityCount = 0
        current.startedActivityID = nil
        current.lastRequestStatus = "unsupported_path"
        current.lastUpdateStatus = "unsupported_path"
        current.lastEndStatus = "unsupported_path"
        current.lastReconcileStatus = "unsupported_path"
        current.lastSnapshotStatus = activeSessionID == nil ? "nil" : "built"
        current.lastErrorOrReason = reason
        current.lastEventAt = .now
    }

    func recordSnapshotNil(
        activeSessionID: String?,
        areActivitiesEnabled: Bool,
        activityCount: Int,
        endedAny: Bool,
        reason: String
    ) {
        current.runtimeSupported = true
        current.areActivitiesEnabled = areActivitiesEnabled
        current.activeSessionID = activeSessionID
        current.knownActivityCount = activityCount
        current.startedActivityID = nil
        current.lastRequestStatus = "not_needed"
        current.lastUpdateStatus = "not_needed"
        current.lastEndStatus = endedAny ? "succeeded" : "skipped_no_activities"
        current.lastReconcileStatus = "ended_nil_snapshot"
        current.lastSnapshotStatus = "nil"
        current.lastErrorOrReason = reason
        current.lastEventAt = .now
    }

    func recordAuthorizationDisabled(
        activeSessionID: String?,
        activityCount: Int,
        currentActivityID: String?
    ) {
        current.runtimeSupported = true
        current.areActivitiesEnabled = false
        current.activeSessionID = activeSessionID
        current.knownActivityCount = activityCount
        current.startedActivityID = currentActivityID
        current.lastRequestStatus = "skipped_authorization_disabled"
        current.lastUpdateStatus = "skipped_authorization_disabled"
        current.lastEndStatus = "not_needed"
        current.lastReconcileStatus = "authorization_disabled"
        current.lastSnapshotStatus = "built"
        current.lastErrorOrReason = "activities_disabled"
        current.lastEventAt = .now
    }

    func recordSnapshotUnchanged(
        activeSessionID: String?,
        activityCount: Int,
        activityID: String?,
        endedAny: Bool
    ) {
        current.runtimeSupported = true
        current.areActivitiesEnabled = true
        current.activeSessionID = activeSessionID
        current.knownActivityCount = activityCount
        current.startedActivityID = activityID
        current.lastRequestStatus = "not_needed"
        current.lastUpdateStatus = "skipped_unchanged"
        current.lastEndStatus = endedAny ? "succeeded" : "not_needed"
        current.lastReconcileStatus = "skipped_snapshot_unchanged"
        current.lastSnapshotStatus = "built"
        current.lastErrorOrReason = nil
        current.lastEventAt = .now
    }

    func recordUpdateSucceeded(
        activeSessionID: String?,
        activityCount: Int,
        activityID: String,
        endedAny: Bool
    ) {
        current.runtimeSupported = true
        current.areActivitiesEnabled = true
        current.activeSessionID = activeSessionID
        current.knownActivityCount = activityCount
        current.startedActivityID = activityID
        current.lastRequestStatus = "not_needed"
        current.lastUpdateStatus = "succeeded"
        current.lastEndStatus = endedAny ? "succeeded" : "not_needed"
        current.lastReconcileStatus = "updated_existing_activity"
        current.lastSnapshotStatus = "built"
        current.lastErrorOrReason = nil
        current.lastEventAt = .now
    }

    func recordRequestSucceeded(
        activeSessionID: String?,
        activityCount: Int,
        activityID: String,
        endedAny: Bool
    ) {
        current.runtimeSupported = true
        current.areActivitiesEnabled = true
        current.activeSessionID = activeSessionID
        current.knownActivityCount = activityCount
        current.startedActivityID = activityID
        current.lastRequestStatus = "succeeded"
        current.lastUpdateStatus = "not_needed"
        current.lastEndStatus = endedAny ? "succeeded" : "not_needed"
        current.lastReconcileStatus = "requested_new_activity"
        current.lastSnapshotStatus = "built"
        current.lastErrorOrReason = nil
        current.lastEventAt = .now
    }

    func recordRequestFailed(
        activeSessionID: String?,
        activityCount: Int,
        endedAny: Bool,
        reason: String
    ) {
        current.runtimeSupported = true
        current.areActivitiesEnabled = true
        current.activeSessionID = activeSessionID
        current.knownActivityCount = activityCount
        current.startedActivityID = nil
        current.lastRequestStatus = "failed"
        current.lastUpdateStatus = "not_needed"
        current.lastEndStatus = endedAny ? "succeeded" : "not_needed"
        current.lastReconcileStatus = "request_failed"
        current.lastSnapshotStatus = "built"
        current.lastErrorOrReason = reason
        current.lastEventAt = .now
    }
}

@MainActor
final class WorkoutLiveActivityManager {
    private let diagnostics: WorkoutLiveActivityDiagnostics
    private let debugRecorder: any DebugEventRecording
    private var lastRenderedSnapshot: WorkoutLiveActivitySnapshot?

    init(
        diagnostics: WorkoutLiveActivityDiagnostics,
        debugRecorder: any DebugEventRecording = NoopDebugEventRecorder()
    ) {
        self.diagnostics = diagnostics
        self.debugRecorder = debugRecorder
    }

    func sync(activeSession: WorkoutSession?, using store: AppStore) async {
        await handle(
            source: "sync",
            activeSession: activeSession,
            using: store
        )
    }

    func reconcile(activeSession: WorkoutSession?, using store: AppStore) async {
        await handle(
            source: "reconcile",
            activeSession: activeSession,
            using: store
        )
    }

    private func handle(
        source: String,
        activeSession: WorkoutSession?,
        using store: AppStore
    ) async {
        let activeSessionID = activeSession?.id.uuidString
        logEvent(
            "\(source)_called",
            metadata: ["sessionID": activeSessionID ?? "none"]
        )

        let snapshot = activeSession.flatMap { Self.makeSnapshot(session: $0, using: store) }
        let snapshotReason: String?
        if activeSession == nil {
            snapshotReason = "no_active_session"
        } else if snapshot == nil {
            snapshotReason = "snapshot_builder_returned_nil"
        } else {
            snapshotReason = nil
        }
        diagnostics.recordInvocation(
            source: source,
            activeSessionID: activeSessionID,
            snapshotBuilt: snapshot != nil,
            reason: snapshotReason
        )
        logEvent(
            snapshot == nil ? "snapshot_nil" : "snapshot_built",
            level: snapshot == nil ? .warning : .info,
            metadata: [
                "source": source,
                "reason": snapshotReason ?? "built",
                "sessionID": activeSessionID ?? "none"
            ]
        )

        await reconcile(
            snapshot: snapshot,
            activeSessionID: activeSessionID,
            source: source
        )
    }

    static func makeSnapshot(
        session: WorkoutSession,
        using store: AppStore,
        updatedAt: Date = .now
    ) -> WorkoutLiveActivitySnapshot? {
        let allSets = session.exercises.flatMap(\.sets)
        let completedSetCount = allSets.filter { $0.completedAt != nil }.count
        let totalSetCount = allSets.count
        let lastCompletedSetAt = allSets.compactMap(\.completedAt).max()
        let currentExerciseContext = firstIncompleteExerciseContext(in: session, using: store)
            ?? fallbackExerciseContext(in: session, using: store)

        return WorkoutLiveActivitySnapshot(
            sessionID: session.id,
            startedAt: session.startedAt,
            title: session.title,
            currentExerciseName: currentExerciseContext?.exerciseName
                ?? NSLocalizedString("header.workout.subtitle", comment: ""),
            currentSetID: firstIncompleteSetID(in: session),
            currentSetNumber: currentExerciseContext?.currentSetNumber,
            currentSetLabel: currentExerciseContext?.currentSetLabel,
            currentSetReps: currentExerciseContext?.currentSetReps,
            currentSetWeight: currentExerciseContext?.currentSetWeight,
            currentSetValueText: currentExerciseContext?.currentSetValueText,
            completedSetCount: completedSetCount,
            totalSetCount: totalSetCount,
            lastCompletedSetAt: lastCompletedSetAt,
            updatedAt: updatedAt
        )
    }

    private static func firstIncompleteSetID(in session: WorkoutSession) -> UUID? {
        for exerciseLog in session.exercises {
            if let setID = exerciseLog.sets.first(where: { $0.completedAt == nil })?.id {
                return setID
            }
        }

        return nil
    }

    private static func firstIncompleteExerciseContext(
        in session: WorkoutSession,
        using store: AppStore
    ) -> WorkoutLiveActivityExerciseContext? {
        for exerciseLog in session.exercises {
            guard let exercise = store.exercise(for: exerciseLog.exerciseID) else {
                continue
            }

            if let setIndex = exerciseLog.sets.firstIndex(where: { $0.completedAt == nil }) {
                return exerciseContext(
                    exerciseName: exercise.localizedName,
                    set: exerciseLog.sets[setIndex],
                    setNumber: setIndex + 1,
                    currentSetID: exerciseLog.sets[setIndex].id
                )
            }
        }

        return nil
    }

    private static func fallbackExerciseContext(
        in session: WorkoutSession,
        using store: AppStore
    ) -> WorkoutLiveActivityExerciseContext? {
        guard let exerciseLog = session.exercises.last,
              let exercise = store.exercise(for: exerciseLog.exerciseID) else {
            return nil
        }

        guard let set = exerciseLog.sets.last else {
            return WorkoutLiveActivityExerciseContext(
                exerciseName: exercise.localizedName,
                currentSetID: nil,
                currentSetNumber: nil,
                currentSetLabel: nil,
                currentSetReps: nil,
                currentSetWeight: nil,
                currentSetValueText: nil
            )
        }

        return exerciseContext(
            exerciseName: exercise.localizedName,
            set: set,
            setNumber: exerciseLog.sets.count,
            currentSetID: nil
        )
    }

    private static func exerciseContext(
        exerciseName: String,
        set: WorkoutSetLog,
        setNumber: Int,
        currentSetID: UUID?
    ) -> WorkoutLiveActivityExerciseContext {
        WorkoutLiveActivityExerciseContext(
            exerciseName: exerciseName,
            currentSetID: currentSetID,
            currentSetNumber: setNumber,
            currentSetLabel: String(
                format: NSLocalizedString("workout.set_number", comment: ""),
                setNumber
            ),
            currentSetReps: set.reps,
            currentSetWeight: set.weight,
            currentSetValueText: currentSetValueText(for: set)
        )
    }

    private static func currentSetValueText(for set: WorkoutSetLog) -> String? {
        if set.weight > 0, set.reps > 0 {
            return "\(formattedWeightText(for: set.weight)) × \(set.reps)"
        }

        if set.weight > 0 {
            return formattedWeightText(for: set.weight)
        }

        if set.reps > 0 {
            return String(
                format: NSLocalizedString("template.reps_summary", comment: ""),
                "\(set.reps)"
            )
        }

        return nil
    }

    private static func formattedWeightText(for weight: Double) -> String {
        workoutLiveActivityWeightFormatter.string(
            from: Measurement(value: weight, unit: UnitMass.kilograms)
        )
    }
}

#if canImport(ActivityKit)
private extension WorkoutLiveActivityManager {
    func reconcile(
        snapshot: WorkoutLiveActivitySnapshot?,
        activeSessionID: String?,
        source: String
    ) async {
        let activities = Activity<WorkoutActivityAttributes>.activities
        let areActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled

        guard let snapshot else {
            if !activities.isEmpty {
                logEvent(
                    "end_attempted",
                    metadata: [
                        "source": source,
                        "reason": activeSessionID == nil ? "no_active_session" : "snapshot_builder_returned_nil",
                        "endedCount": "\(activities.count)"
                    ]
                )
            }
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            let remainingActivityCount = Activity<WorkoutActivityAttributes>.activities.count
            diagnostics.recordSnapshotNil(
                activeSessionID: activeSessionID,
                areActivitiesEnabled: areActivitiesEnabled,
                activityCount: remainingActivityCount,
                endedAny: !activities.isEmpty,
                reason: activeSessionID == nil ? "no_active_session" : "snapshot_builder_returned_nil"
            )
            logEvent(
                "end_succeeded",
                metadata: [
                    "source": source,
                    "reason": activeSessionID == nil ? "no_active_session" : "snapshot_builder_returned_nil",
                    "endedCount": "\(activities.count)",
                    "activityCount": "\(remainingActivityCount)"
                ]
            )
            lastRenderedSnapshot = nil
            return
        }

        let sessionIdentifier = snapshot.sessionID.uuidString
        let matchingActivity = activities.first { $0.attributes.sessionID == sessionIdentifier }

        guard areActivitiesEnabled else {
            diagnostics.recordAuthorizationDisabled(
                activeSessionID: activeSessionID,
                activityCount: activities.count,
                currentActivityID: matchingActivity?.id
            )
            logEvent(
                "authorization_disabled",
                level: .warning,
                metadata: [
                    "source": source,
                    "sessionID": sessionIdentifier,
                    "activityCount": "\(activities.count)"
                ]
            )
            lastRenderedSnapshot = snapshot
            return
        }

        var endedActivityIDs: [String] = []
        for activity in activities where activity.attributes.sessionID != sessionIdentifier {
            if endedActivityIDs.isEmpty {
                logEvent(
                    "end_attempted",
                    metadata: [
                        "source": source,
                        "reason": "ended_mismatched_sessions",
                        "sessionID": sessionIdentifier
                    ]
                )
            }
            await activity.end(nil, dismissalPolicy: .immediate)
            endedActivityIDs.append(activity.id)
        }

        if !endedActivityIDs.isEmpty {
            logEvent(
                "end_succeeded",
                metadata: [
                    "source": source,
                    "reason": "ended_mismatched_sessions",
                    "endedCount": "\(endedActivityIDs.count)",
                    "sessionID": sessionIdentifier
                ]
            )
        }

        if lastRenderedSnapshot == snapshot, matchingActivity != nil {
            let remainingActivityCount = Activity<WorkoutActivityAttributes>.activities.count
            diagnostics.recordSnapshotUnchanged(
                activeSessionID: activeSessionID,
                activityCount: remainingActivityCount,
                activityID: matchingActivity?.id,
                endedAny: !endedActivityIDs.isEmpty
            )
            logEvent(
                "reconcile_skipped_unchanged",
                metadata: [
                    "source": source,
                    "sessionID": sessionIdentifier,
                    "activityID": matchingActivity?.id ?? "none",
                    "activityCount": "\(remainingActivityCount)"
                ]
            )
            return
        }

        let content = ActivityContent(
            state: WorkoutActivityAttributes.ContentState(
                title: snapshot.title,
                currentExerciseName: snapshot.currentExerciseName,
                currentSetID: snapshot.currentSetID,
                currentSetNumber: snapshot.currentSetNumber,
                currentSetLabel: snapshot.currentSetLabel,
                currentSetReps: snapshot.currentSetReps,
                currentSetWeight: snapshot.currentSetWeight,
                currentSetValueText: snapshot.currentSetValueText,
                completedSetCount: snapshot.completedSetCount,
                totalSetCount: snapshot.totalSetCount,
                lastCompletedSetAt: snapshot.lastCompletedSetAt,
                updatedAt: snapshot.updatedAt
            ),
            staleDate: nil
        )

        if let matchingActivity {
            logEvent(
                "update_attempted",
                metadata: [
                    "source": source,
                    "sessionID": sessionIdentifier,
                    "activityID": matchingActivity.id
                ]
            )
            await matchingActivity.update(content)
            let remainingActivityCount = Activity<WorkoutActivityAttributes>.activities.count
            diagnostics.recordUpdateSucceeded(
                activeSessionID: activeSessionID,
                activityCount: remainingActivityCount,
                activityID: matchingActivity.id,
                endedAny: !endedActivityIDs.isEmpty
            )
            logEvent(
                "update_succeeded",
                metadata: [
                    "source": source,
                    "sessionID": sessionIdentifier,
                    "activityID": matchingActivity.id,
                    "activityCount": "\(remainingActivityCount)"
                ]
            )
        } else {
            logEvent(
                "request_attempted",
                metadata: [
                    "source": source,
                    "sessionID": sessionIdentifier,
                    "activityCount": "\(Activity<WorkoutActivityAttributes>.activities.count)"
                ]
            )
            do {
                let activity = try Activity<WorkoutActivityAttributes>.request(
                    attributes: WorkoutActivityAttributes(
                        sessionID: sessionIdentifier,
                        startedAt: snapshot.startedAt
                    ),
                    content: content,
                    pushType: nil
                )
                let remainingActivityCount = Activity<WorkoutActivityAttributes>.activities.count
                diagnostics.recordRequestSucceeded(
                    activeSessionID: activeSessionID,
                    activityCount: remainingActivityCount,
                    activityID: activity.id,
                    endedAny: !endedActivityIDs.isEmpty
                )
                logEvent(
                    "request_succeeded",
                    metadata: [
                        "source": source,
                        "sessionID": sessionIdentifier,
                        "activityID": activity.id,
                        "activityCount": "\(remainingActivityCount)"
                    ]
                )
            } catch {
                let remainingActivityCount = Activity<WorkoutActivityAttributes>.activities.count
                let reason = describe(error)
                diagnostics.recordRequestFailed(
                    activeSessionID: activeSessionID,
                    activityCount: remainingActivityCount,
                    endedAny: !endedActivityIDs.isEmpty,
                    reason: reason
                )
                logEvent(
                    "request_failed",
                    level: .error,
                    metadata: [
                        "source": source,
                        "sessionID": sessionIdentifier,
                        "reason": reason,
                        "activityCount": "\(remainingActivityCount)"
                    ]
                )
                return
            }
        }

        lastRenderedSnapshot = snapshot
    }
}
#else
private extension WorkoutLiveActivityManager {
    func reconcile(
        snapshot: WorkoutLiveActivitySnapshot?,
        activeSessionID: String?,
        source _: String
    ) async {
        diagnostics.recordUnsupportedPath(
            activeSessionID: activeSessionID,
            reason: "activitykit_unavailable"
        )
        logEvent(
            "unsupported_path",
            level: .warning,
            metadata: [
                "sessionID": activeSessionID ?? "none",
                "snapshotStatus": snapshot == nil ? "nil" : "built"
            ]
        )
        lastRenderedSnapshot = snapshot
    }
}
#endif

private extension WorkoutLiveActivityManager {
    func logEvent(
        _ message: String,
        level: DebugLogLevel = .info,
        metadata: [String: String] = [:]
    ) {
        let filteredMetadata = metadata.filter { !$0.value.isEmpty }
        debugRecorder.log(
            category: .liveActivity,
            level: level,
            message: message,
            metadata: filteredMetadata
        )

        let metadataDescription = filteredMetadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        if metadataDescription.isEmpty {
            workoutLiveActivityLogger.log("\(message, privacy: .public)")
        } else {
            workoutLiveActivityLogger.log(
                "\(message, privacy: .public) \(metadataDescription, privacy: .public)"
            )
        }
    }

    func describe(_ error: Error) -> String {
        let localizedDescription = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !localizedDescription.isEmpty {
            return localizedDescription
        }

        return String(describing: error)
    }
}
