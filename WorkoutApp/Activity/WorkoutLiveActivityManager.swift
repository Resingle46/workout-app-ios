import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

struct WorkoutLiveActivitySnapshot: Equatable, Sendable {
    var sessionID: UUID
    var startedAt: Date
    var title: String
    var currentExerciseName: String
    var currentSetLabel: String?
    var completedSetCount: Int
    var totalSetCount: Int
    var lastCompletedSetAt: Date?
    var updatedAt: Date
}

@MainActor
final class WorkoutLiveActivityManager {
    private var lastRenderedSnapshot: WorkoutLiveActivitySnapshot?

    func sync(activeSession: WorkoutSession?, using store: AppStore) async {
        let snapshot = activeSession.flatMap { Self.makeSnapshot(session: $0, using: store) }
        await reconcile(snapshot: snapshot)
    }

    func reconcile(activeSession: WorkoutSession?, using store: AppStore) async {
        let snapshot = activeSession.flatMap { Self.makeSnapshot(session: $0, using: store) }
        await reconcile(snapshot: snapshot)
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
            currentSetLabel: currentExerciseContext?.currentSetLabel,
            completedSetCount: completedSetCount,
            totalSetCount: totalSetCount,
            lastCompletedSetAt: lastCompletedSetAt,
            updatedAt: updatedAt
        )
    }

    private static func firstIncompleteExerciseContext(
        in session: WorkoutSession,
        using store: AppStore
    ) -> (exerciseName: String, currentSetLabel: String?)? {
        for exerciseLog in session.exercises {
            guard let exercise = store.exercise(for: exerciseLog.exerciseID) else {
                continue
            }

            if let setIndex = exerciseLog.sets.firstIndex(where: { $0.completedAt == nil }) {
                return (
                    exercise.localizedName,
                    String(
                        format: NSLocalizedString("workout.set_number", comment: ""),
                        setIndex + 1
                    )
                )
            }
        }

        return nil
    }

    private static func fallbackExerciseContext(
        in session: WorkoutSession,
        using store: AppStore
    ) -> (exerciseName: String, currentSetLabel: String?)? {
        guard let exerciseLog = session.exercises.last,
              let exercise = store.exercise(for: exerciseLog.exerciseID) else {
            return nil
        }

        let setLabel = exerciseLog.sets.isEmpty
            ? nil
            : String(
                format: NSLocalizedString("workout.set_number", comment: ""),
                exerciseLog.sets.count
            )
        return (exercise.localizedName, setLabel)
    }
}

#if canImport(ActivityKit)
private extension WorkoutLiveActivityManager {
    func reconcile(snapshot: WorkoutLiveActivitySnapshot?) async {
        let activities = Activity<WorkoutActivityAttributes>.activities

        guard let snapshot else {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            lastRenderedSnapshot = nil
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastRenderedSnapshot = snapshot
            return
        }

        let sessionIdentifier = snapshot.sessionID.uuidString
        let matchingActivity = activities.first { $0.attributes.sessionID == sessionIdentifier }

        for activity in activities where activity.attributes.sessionID != sessionIdentifier {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        if lastRenderedSnapshot == snapshot, matchingActivity != nil {
            return
        }

        let content = ActivityContent(
            state: WorkoutActivityAttributes.ContentState(
                title: snapshot.title,
                currentExerciseName: snapshot.currentExerciseName,
                currentSetLabel: snapshot.currentSetLabel,
                completedSetCount: snapshot.completedSetCount,
                totalSetCount: snapshot.totalSetCount,
                lastCompletedSetAt: snapshot.lastCompletedSetAt,
                updatedAt: snapshot.updatedAt
            ),
            staleDate: nil
        )

        if let matchingActivity {
            await matchingActivity.update(content)
        } else {
            do {
                _ = try Activity<WorkoutActivityAttributes>.request(
                    attributes: WorkoutActivityAttributes(
                        sessionID: sessionIdentifier,
                        startedAt: snapshot.startedAt
                    ),
                    content: content,
                    pushType: nil
                )
            } catch {
                return
            }
        }

        lastRenderedSnapshot = snapshot
    }
}
#else
private extension WorkoutLiveActivityManager {
    func reconcile(snapshot: WorkoutLiveActivitySnapshot?) async {
        lastRenderedSnapshot = snapshot
    }
}
#endif
