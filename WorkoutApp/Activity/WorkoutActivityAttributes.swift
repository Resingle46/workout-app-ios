import Foundation

#if canImport(ActivityKit)
import ActivityKit

struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var currentExerciseName: String
        var currentSetNumber: Int?
        var currentSetLabel: String?
        var currentSetReps: Int?
        var currentSetWeight: Double?
        var completedSetCount: Int
        var totalSetCount: Int
        var lastCompletedSetAt: Date?
        var updatedAt: Date
    }

    var sessionID: String
    var startedAt: Date
}
#endif
