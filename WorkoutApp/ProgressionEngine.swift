import Foundation

struct ProgressionEngine {
    struct Configuration: Hashable, Sendable {
        var minimumComparableExposureCount: Int
        var minimumStrongSignalExposureCount: Int
        var maximumDaysSincePreviousExposure: Int
        var meaningfulWeightChange: Double
        var meaningfulRepChange: Double
        var allowedRepDropForProgression: Double
        var deteriorationRepDropThreshold: Double
        var plateauWeightRangeThreshold: Double
        var plateauRepRangeThreshold: Double
        var weightIncreaseStep: Double
        var deloadPercentage: Double
        var maximumReferenceWeightSpread: Double

        static let `default` = Configuration(
            minimumComparableExposureCount: 2,
            minimumStrongSignalExposureCount: 3,
            maximumDaysSincePreviousExposure: 21,
            meaningfulWeightChange: 1,
            meaningfulRepChange: 1,
            allowedRepDropForProgression: 0.5,
            deteriorationRepDropThreshold: 1,
            plateauWeightRangeThreshold: 1,
            plateauRepRangeThreshold: 1,
            weightIncreaseStep: 2.5,
            deloadPercentage: 0.10,
            maximumReferenceWeightSpread: 5
        )
    }

    private struct TransitionAssessment {
        var isImprovement: Bool
        var isDeterioration: Bool
    }

    var configuration: Configuration = .default

    func evaluate(_ input: ProgressionEngineInput) -> ProgressionDecision {
        guard let currentExposure = input.exposures.first else {
            return insufficientDecision(
                reasons: [.insufficientComparableHistory],
                comparableExposureCount: 0
            )
        }

        if currentExposure.dataQuality == .sparseOrNoisy {
            return insufficientDecision(
                reasons: [.sparseCurrentSession],
                comparableExposureCount: 0
            )
        }

        if input.prescriptionCompatibility == .mismatch {
            return insufficientDecision(
                reasons: [.prescriptionMismatch],
                comparableExposureCount: 0
            )
        }

        if let daysSincePreviousExposure = input.daysSincePreviousExposure,
           daysSincePreviousExposure > configuration.maximumDaysSincePreviousExposure {
            return insufficientDecision(
                reasons: [.largeFrequencyGap],
                comparableExposureCount: 0
            )
        }

        let comparableExposures = input.exposures.filter { $0.comparability == .comparable }
        let comparableExposureCount = comparableExposures.count

        guard comparableExposureCount >= configuration.minimumComparableExposureCount else {
            var reasons: [ProgressionDecisionReason] = [.insufficientComparableHistory]
            if input.exposures.dropFirst().contains(where: { $0.dataQuality == .sparseOrNoisy }) {
                reasons.append(.sparseHistory)
            }
            if input.prescriptionCompatibility == .partialMismatch {
                reasons.append(.partialPrescriptionMismatch)
            }

            return insufficientDecision(
                reasons: reasons,
                comparableExposureCount: comparableExposureCount
            )
        }

        let referenceWeight = stableReferenceWeight(for: currentExposure)
        let recentComparisons = buildRecentComparisons(from: comparableExposures)
        let weeklyContextIsCautionary = input.weeklyContext?.isCautionary == true

        if comparableExposureCount >= configuration.minimumStrongSignalExposureCount,
           input.prescriptionCompatibility == .compatible,
           shouldDeload(
                comparableExposures: comparableExposures,
                recentComparisons: recentComparisons
           ),
           let referenceWeight {
            var reasons: [ProgressionDecisionReason] = [
                .repeatedDeterioration,
                .noMeaningfulImprovement,
                .plateauDetected
            ]
            if weeklyContextIsCautionary {
                reasons.append(.weeklyContextCaution)
            }

            return ProgressionDecision(
                action: .deload,
                confidence: ProgressionConfidence(score: weeklyContextIsCautionary ? 0.77 : 0.82),
                referenceWeight: referenceWeight,
                recommendedWeight: roundedToHalf(referenceWeight * (1 - configuration.deloadPercentage)),
                reasons: reasons,
                comparableExposureCount: comparableExposureCount
            )
        }

        if comparableExposureCount >= configuration.minimumStrongSignalExposureCount,
           input.prescriptionCompatibility == .compatible,
           shouldIncreaseWeight(recentComparisons: recentComparisons),
           let referenceWeight {
            var reasons: [ProgressionDecisionReason] = [.repeatedClearSuccess]
            if weeklyContextIsCautionary {
                reasons.append(.weeklyContextCaution)
            }

            return ProgressionDecision(
                action: .increaseWeight,
                confidence: ProgressionConfidence(score: weeklyContextIsCautionary ? 0.78 : 0.84),
                referenceWeight: referenceWeight,
                recommendedWeight: roundedToHalf(referenceWeight + configuration.weightIncreaseStep),
                reasons: reasons,
                comparableExposureCount: comparableExposureCount
            )
        }

        var holdReasons: [ProgressionDecisionReason] = []
        if input.prescriptionCompatibility == .partialMismatch {
            holdReasons.append(.partialPrescriptionMismatch)
        }
        if recentComparisons.contains(where: { $0.isImprovement }) &&
            recentComparisons.contains(where: { $0.isDeterioration }) {
            holdReasons.append(.conflictingSignals)
        }
        if holdReasons.isEmpty {
            holdReasons.append(.stablePerformance)
        }
        if weeklyContextIsCautionary {
            holdReasons.append(.weeklyContextCaution)
        }

        let holdConfidence = ProgressionConfidence(
            score: referenceWeight == nil || input.prescriptionCompatibility != .compatible ? 0.58 : 0.68
        )

        return ProgressionDecision(
            action: .hold,
            confidence: holdConfidence,
            referenceWeight: holdConfidence.allowsNumericReference ? referenceWeight : nil,
            recommendedWeight: nil,
            reasons: holdReasons,
            comparableExposureCount: comparableExposureCount
        )
    }

    private func insufficientDecision(
        reasons: [ProgressionDecisionReason],
        comparableExposureCount: Int
    ) -> ProgressionDecision {
        ProgressionDecision(
            action: .insufficientData,
            confidence: ProgressionConfidence(score: 0.2),
            referenceWeight: nil,
            recommendedWeight: nil,
            reasons: reasons,
            comparableExposureCount: comparableExposureCount
        )
    }

    private func buildRecentComparisons(
        from comparableExposures: [ProgressionExerciseSession]
    ) -> [TransitionAssessment] {
        guard comparableExposures.count > 1 else {
            return []
        }

        let pairCount = min(comparableExposures.count - 1, 2)
        return (0..<pairCount).map { index in
            assessTransition(
                newer: comparableExposures[index],
                older: comparableExposures[index + 1]
            )
        }
    }

    private func assessTransition(
        newer: ProgressionExerciseSession,
        older: ProgressionExerciseSession
    ) -> TransitionAssessment {
        let averageWeightDelta = newer.metrics.averageWeight - older.metrics.averageWeight
        let topWeightDelta = newer.metrics.topWeight - older.metrics.topWeight
        let averageRepsDelta = newer.metrics.averageReps - older.metrics.averageReps

        let isImprovement =
            (averageWeightDelta >= configuration.meaningfulWeightChange ||
             topWeightDelta >= configuration.meaningfulWeightChange) &&
            averageRepsDelta >= -configuration.allowedRepDropForProgression

        let isDeterioration =
            ((averageWeightDelta <= -configuration.meaningfulWeightChange ||
              topWeightDelta <= -configuration.meaningfulWeightChange) &&
             averageRepsDelta <= configuration.allowedRepDropForProgression) ||
            (averageRepsDelta <= -configuration.deteriorationRepDropThreshold &&
             topWeightDelta <= configuration.plateauWeightRangeThreshold)

        return TransitionAssessment(
            isImprovement: isImprovement,
            isDeterioration: !isImprovement && isDeterioration
        )
    }

    private func shouldIncreaseWeight(
        recentComparisons: [TransitionAssessment]
    ) -> Bool {
        recentComparisons.count >= 2 &&
        recentComparisons.allSatisfy { $0.isImprovement }
    }

    private func shouldDeload(
        comparableExposures: [ProgressionExerciseSession],
        recentComparisons: [TransitionAssessment]
    ) -> Bool {
        guard recentComparisons.count >= 2,
              recentComparisons.allSatisfy({ $0.isDeterioration }) else {
            return false
        }

        let comparisonWindow = Array(comparableExposures.prefix(3))
        guard comparisonWindow.count >= 3 else {
            return false
        }

        let latest = comparisonWindow[0].metrics
        let oldest = comparisonWindow[comparisonWindow.count - 1].metrics
        let hasMeaningfulWindowImprovement =
            latest.topWeight >= oldest.topWeight + configuration.meaningfulWeightChange ||
            latest.averageWeight >= oldest.averageWeight + configuration.meaningfulWeightChange ||
            latest.averageReps >= oldest.averageReps + configuration.meaningfulRepChange

        let hasPlateauOrStagnation = comparisonWindow.dropFirst().allSatisfy { exposure in
            exposure.metrics.topWeight <= oldest.topWeight + configuration.plateauWeightRangeThreshold &&
            exposure.metrics.averageWeight <= oldest.averageWeight + configuration.plateauWeightRangeThreshold &&
            exposure.metrics.averageReps <= oldest.averageReps + configuration.plateauRepRangeThreshold
        }

        return !hasMeaningfulWindowImprovement && hasPlateauOrStagnation
    }

    private func stableReferenceWeight(
        for exposure: ProgressionExerciseSession
    ) -> Double? {
        guard exposure.metrics.hasUsableLoadData,
              exposure.metrics.topWeight > 0,
              exposure.metrics.weightSpread <= configuration.maximumReferenceWeightSpread else {
            return nil
        }

        return roundedToHalf(exposure.metrics.topWeight)
    }

    private func roundedToHalf(_ value: Double) -> Double {
        (value * 2).rounded() / 2
    }
}
