import Foundation
import OSLog

private let workoutLiveActivityCommandProcessorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "WorkoutApp",
    category: "live_activity_command_processor"
)

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
    private let commandStoreProvider: @Sendable () throws -> WorkoutExternalCommandStore
    private let debugRecorder: any DebugEventRecording

    init(
        commandStoreProvider: @escaping @Sendable () throws -> WorkoutExternalCommandStore = {
            try WorkoutExternalCommandStore.shared()
        },
        debugRecorder: any DebugEventRecording = NoopDebugEventRecorder()
    ) {
        self.commandStoreProvider = commandStoreProvider
        self.debugRecorder = debugRecorder
    }

    convenience init(
        commandStore: WorkoutExternalCommandStore,
        debugRecorder: any DebugEventRecording = NoopDebugEventRecorder()
    ) {
        self.init(
            commandStoreProvider: { commandStore },
            debugRecorder: debugRecorder
        )
    }

    @discardableResult
    func processPendingCommands(
        using store: AppStore,
        liveActivitySynchronizer: any WorkoutLiveActivitySynchronizing
    ) async -> Bool {
        let commandStore: WorkoutExternalCommandStore
        do {
            commandStore = try commandStoreProvider()
        } catch {
            log(
                "external_command_store_unavailable",
                level: .warning,
                metadata: ["error": String(describing: error)]
            )
            return false
        }

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
            log("external_command_pickup_empty")
            return false
        }

        log(
            "external_command_pickup_started",
            metadata: ["count": "\(commands.count)"]
        )

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
            log("external_command_checkpoint_flushed")
        }
        log(
            "external_command_live_activity_sync_started",
            metadata: [
                "didMutate": didMutateSession ? "true" : "false",
                "sessionID": store.activeSession?.id.uuidString ?? "none"
            ]
        )
        await liveActivitySynchronizer.sync(activeSession: store.activeSession, using: store)
        log(
            "external_command_live_activity_sync_finished",
            metadata: [
                "didMutate": didMutateSession ? "true" : "false",
                "sessionID": store.activeSession?.id.uuidString ?? "none"
            ]
        )
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

        let metadataDescription = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        if metadataDescription.isEmpty {
            workoutLiveActivityCommandProcessorLogger.log(
                level: osLogLevel(for: level),
                "\(message, privacy: .public)"
            )
        } else {
            workoutLiveActivityCommandProcessorLogger.log(
                level: osLogLevel(for: level),
                "\(message, privacy: .public) \(metadataDescription, privacy: .public)"
            )
        }
    }

    private func osLogLevel(for level: DebugLogLevel) -> OSLogType {
        switch level {
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .error
        case .error:
            return .fault
        }
    }
}
