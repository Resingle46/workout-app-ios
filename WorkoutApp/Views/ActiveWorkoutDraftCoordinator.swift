import Foundation
import Observation

@MainActor
@Observable
final class ActiveWorkoutDraftCoordinator {
    @ObservationIgnored private var flushActions: [UUID: () -> Void] = [:]

    func registerFlushAction(id: UUID, action: @escaping () -> Void) {
        flushActions[id] = action
    }

    func unregisterFlushAction(id: UUID) {
        flushActions.removeValue(forKey: id)
    }

    func flushAll() {
        for action in flushActions.values {
            action()
        }
    }
}
