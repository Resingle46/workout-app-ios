import Foundation

@MainActor
protocol WorkoutLiveActivitySynchronizing: AnyObject {
    func sync(activeSession: WorkoutSession?, using store: AppStore) async
}

extension WorkoutLiveActivityManager: WorkoutLiveActivitySynchronizing {}

enum WorkoutCurrentSetCompletionIgnoreReason: String, Equatable, Sendable {
    case noActiveSession
    case sessionMismatch
    case noIncompleteSet
    case setMismatch
}

struct WorkoutCurrentSetCompletionOutcome: Equatable, Sendable {
    var sessionID: UUID
    var setID: UUID
    var completedAt: Date
}

enum WorkoutCurrentSetCompletionResult: Equatable, Sendable {
    case completed(WorkoutCurrentSetCompletionOutcome)
    case ignored(WorkoutCurrentSetCompletionIgnoreReason)
}

@MainActor
final class WorkoutLiveActivityCommandProcessor {
    private let commandStore: WorkoutExternalCommandStore
    private let debugRecorder: any DebugEventRecording

    init(
        commandStore: WorkoutExternalCommandStore = WorkoutExternalCommandStore(),
        debugRecorder: any DebugEventRecording = NoopDebugEventRecorder()
    ) {
        self.commandStore = commandStore
        self.debugRecorder = debugRecorder
    }

    @discardableResult
    func processPendingCommands(
        using store: AppStore,
        liveActivitySynchronizer: any WorkoutLiveActivitySynchronizing
    ) async -> Bool {
        let commands: [WorkoutExternalCommand]
        do {
            commands = try commandStore.pendingCommands()
        } catch {
            log(
                "external_command_load_failed",
                level: .warning,
                metadata: ["error": String(describing: error)]
            )
            return false
        }

        guard !commands.isEmpty else {
            return false
        }

        var didMutateSession = false
        for command in commands {
            let result: WorkoutCurrentSetCompletionResult

            switch command.kind {
            case .completeCurrentSet:
                result = store.completeCurrentSet(
                    expectedSessionID: command.sessionID,
                    expectedSetID: command.currentSetID,
                    completedAt: command.createdAt
                )
            }

            switch result {
            case .completed(let outcome):
                didMutateSession = true
                log(
                    "external_command_applied",
                    metadata: [
                        "kind": command.kind.rawValue,
                        "sessionID": outcome.sessionID.uuidString,
                        "setID": outcome.setID.uuidString
                    ]
                )
            case .ignored(let reason):
                log(
                    "external_command_ignored",
                    metadata: [
                        "kind": command.kind.rawValue,
                        "sessionID": command.sessionID.uuidString,
                        "setID": command.currentSetID.uuidString,
                        "reason": reason.rawValue
                    ]
                )
            }

            do {
                try commandStore.acknowledge(command)
            } catch {
                log(
                    "external_command_ack_failed",
                    level: .warning,
                    metadata: [
                        "kind": command.kind.rawValue,
                        "sessionID": command.sessionID.uuidString,
                        "setID": command.currentSetID.uuidString,
                        "error": String(describing: error)
                    ]
                )
            }
        }

        if didMutateSession {
            store.flushActiveWorkoutCheckpointNow()
        }
        await liveActivitySynchronizer.sync(activeSession: store.activeSession, using: store)
        guard didMutateSession else {
            return false
        }

        return true
    }

    private func log(
        _ message: String,
        level: DebugLogLevel = .info,
        metadata: [String: String] = [:]
    ) {
        debugRecorder.log(
            category: .liveActivity,
            level: level,
            message: message,
            metadata: metadata
        )
    }
}
