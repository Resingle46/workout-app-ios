import Foundation

enum ProgressionAction: String, Codable, Hashable, Sendable {
    case insufficientData = "insufficient_data"
    case hold
    case increaseWeight = "increase_weight"
    case deload
}

enum ProgressionDecisionReason: String, Codable, Hashable, Sendable {
    case insufficientComparableHistory = "insufficient_comparable_history"
    case sparseCurrentSession = "sparse_current_session"
    case sparseHistory = "sparse_history"
    case largeFrequencyGap = "large_frequency_gap"
    case prescriptionMismatch = "prescription_mismatch"
    case partialPrescriptionMismatch = "partial_prescription_mismatch"
    case conflictingSignals = "conflicting_signals"
    case stablePerformance = "stable_performance"
    case repeatedClearSuccess = "repeated_clear_success"
    case repeatedDeterioration = "repeated_deterioration"
    case plateauDetected = "plateau_detected"
    case noMeaningfulImprovement = "no_meaningful_improvement"
    case weeklyContextCaution = "weekly_context_caution"
}

enum ProgressionConfidenceLevel: String, Codable, Hashable, Sendable {
    case low
    case medium
    case high
}

struct ProgressionConfidence: Codable, Hashable, Sendable {
    var score: Double

    init(score: Double) {
        self.score = min(max(score, 0), 1)
    }

    var level: ProgressionConfidenceLevel {
        switch score {
        case ..<0.4:
            return .low
        case ..<0.75:
            return .medium
        default:
            return .high
        }
    }

    var allowsNumericReference: Bool {
        score >= 0.66
    }
}

enum ProgressionDataQuality: String, Codable, Hashable, Sendable {
    case usable = "usable"
    case sparseOrNoisy = "sparse_or_noisy"
}

enum ProgressionExposureComparability: String, Codable, Hashable, Sendable {
    case comparable
    case sparseOrNoisy = "sparse_or_noisy"
    case setShapeMismatch = "set_shape_mismatch"
}

enum ProgressionPrescriptionCompatibility: String, Codable, Hashable, Sendable {
    case compatible
    case partialMismatch = "partial_mismatch"
    case mismatch
}

struct ProgressionSessionMetrics: Codable, Hashable, Sendable {
    var completedSetCount: Int
    var averageWeight: Double
    var topWeight: Double
    var minimumWeight: Double
    var averageReps: Double
    var minimumReps: Int
    var maximumReps: Int
    var totalVolume: Double
    var hasUsableLoadData: Bool

    var weightSpread: Double {
        max(topWeight - minimumWeight, 0)
    }
}

struct ProgressionExerciseSession: Codable, Hashable, Sendable, Identifiable {
    var id: UUID { sessionID }
    var sessionID: UUID
    var performedAt: Date
    var templateExerciseIDs: [UUID]
    var metrics: ProgressionSessionMetrics
    var dataQuality: ProgressionDataQuality
    var comparability: ProgressionExposureComparability
}

struct ProgressionWeeklyContext: Codable, Hashable, Sendable {
    var strengthPercentChange: Int

    var isCautionary: Bool {
        strengthPercentChange <= -10
    }
}

struct ProgressionEngineInput: Codable, Hashable, Sendable {
    var exerciseID: UUID
    var currentTemplateExerciseID: UUID?
    var exposures: [ProgressionExerciseSession]
    var prescriptionCompatibility: ProgressionPrescriptionCompatibility
    var daysSincePreviousExposure: Int?
    var weeklyContext: ProgressionWeeklyContext?
}

struct ProgressionDecision: Codable, Hashable, Sendable {
    var action: ProgressionAction
    var confidence: ProgressionConfidence
    var referenceWeight: Double?
    var recommendedWeight: Double?
    var reasons: [ProgressionDecisionReason]
    var comparableExposureCount: Int
}
