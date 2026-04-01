import ActivityKit
import AppIntents
import Foundation
import SwiftUI
import WidgetKit

private enum WorkoutLiveActivityPalette {
    static let background = Color(red: 0.15, green: 0.15, blue: 0.17)
    static let primaryText = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.62)
    static let accent = Color.white.opacity(0.90)
    static let progressFill = Color.white.opacity(0.07)
    static let progressTint = Color(red: 0.47, green: 0.93, blue: 0.60)
    static let restTint = Color(red: 1.0, green: 0.72, blue: 0.38)
}

private enum WorkoutLiveActivityMetrics {
    static let outerSpacing: CGFloat = 12
    static let panelSpacing: CGFloat = 8
    static let horizontalGap: CGFloat = 8
    static let actionSpacing: CGFloat = 9
    static let containerHorizontalPadding: CGFloat = 16
    static let containerVerticalPadding: CGFloat = 14
    static let minimumLockScreenHeight: CGFloat = 152
}

private enum WorkoutLiveActivityFormatting {
    private static let weightFormatter: MeasurementFormatter = {
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

    static func progressText(for state: WorkoutActivityAttributes.ContentState) -> String {
        if state.totalSetCount > 0 {
            return "\(state.completedSetCount)/\(state.totalSetCount)"
        }

        return "\(state.completedSetCount)"
    }

    static func currentSetLabel(for state: WorkoutActivityAttributes.ContentState) -> String {
        state.currentSetLabel ?? progressText(for: state)
    }

    static func primarySetValueText(for state: WorkoutActivityAttributes.ContentState) -> String {
        if let currentSetValueText = state.currentSetValueText,
           !currentSetValueText.isEmpty {
            return currentSetValueText
        }

        if let weight = state.currentSetWeight,
           weight > 0,
           let reps = state.currentSetReps,
           reps > 0 {
            return "\(formattedWeightText(for: weight)) × \(reps)"
        }

        if let weight = state.currentSetWeight,
           weight > 0 {
            return formattedWeightText(for: weight)
        }

        if let reps = state.currentSetReps,
           reps > 0 {
            return "\(reps) reps"
        }

        return currentSetLabel(for: state)
    }

    static func compactSummaryText(for state: WorkoutActivityAttributes.ContentState) -> String {
        let label = currentSetLabel(for: state)
        let value = primarySetValueText(for: state)

        guard value != label else {
            return value
        }

        return "\(label) · \(value)"
    }

    private static func formattedWeightText(for weight: Double) -> String {
        weightFormatter.string(from: Measurement(value: weight, unit: UnitMass.kilograms))
    }
}

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(WorkoutLiveActivityPalette.background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.currentExerciseName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        Text(WorkoutLiveActivityFormatting.currentSetLabel(for: context.state))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.headline.monospacedDigit())

                        Text(WorkoutLiveActivityFormatting.progressText(for: context.state))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: WorkoutLiveActivityMetrics.actionSpacing) {
                        HStack(alignment: .center, spacing: 8) {
                            Text(WorkoutLiveActivityFormatting.compactSummaryText(for: context.state))
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            progressChip(for: context.state)

                            if let lastCompletedSetAt = context.state.lastCompletedSetAt {
                                restTimerChip(lastCompletedSetAt)
                            }
                        }

                        if let actionIntent = completionIntent(
                            sessionID: context.attributes.sessionID,
                            currentSetID: context.state.currentSetID
                        ) {
                            liveActivityActionButton(intent: actionIntent, fullWidth: true)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.lastCompletedSetAt == nil ? "figure.strengthtraining.traditional" : "pause.fill")
                    .foregroundStyle(context.state.lastCompletedSetAt == nil ? WorkoutLiveActivityPalette.accent : WorkoutLiveActivityPalette.restTint)
            } compactTrailing: {
                Text(WorkoutLiveActivityFormatting.progressText(for: context.state))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.state.lastCompletedSetAt == nil ? "figure.strengthtraining.traditional" : "pause.fill")
            }
        }
    }

    private func progressChip(for state: WorkoutActivityAttributes.ContentState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(WorkoutLiveActivityPalette.progressTint)

            Text(WorkoutLiveActivityFormatting.progressText(for: state))
                .monospacedDigit()
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(WorkoutLiveActivityPalette.secondaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(WorkoutLiveActivityPalette.progressFill)
        )
    }

    private func restTimerChip(_ lastCompletedSetAt: Date) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "pause.fill")
                .foregroundStyle(WorkoutLiveActivityPalette.restTint)

            Text(lastCompletedSetAt, style: .timer)
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private func completionIntent(
        sessionID: String,
        currentSetID: UUID?
    ) -> CompleteCurrentSetIntent? {
        guard let currentSetID else {
            return nil
        }

        return CompleteCurrentSetIntent(
            sessionID: sessionID,
            currentSetID: currentSetID.uuidString
        )
    }

    private func liveActivityActionButton(
        intent: CompleteCurrentSetIntent,
        fullWidth: Bool
    ) -> some View {
        Button(intent: intent) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                Text("action.complete_current_set_live")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(WorkoutLiveActivityPalette.background)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(WorkoutLiveActivityPalette.progressTint)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct WorkoutLiveActivityLockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: WorkoutLiveActivityMetrics.outerSpacing) {
            headerRow
            exerciseTitle
            detailRow

            Text(progressSummary)
                .font(.caption)
                .foregroundStyle(WorkoutLiveActivityPalette.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let lastCompletedSetAt = context.state.lastCompletedSetAt {
                restStatusView(lastCompletedSetAt)
            }

            if let actionIntent = completionIntent {
                liveActivityActionButton(intent: actionIntent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: WorkoutLiveActivityMetrics.minimumLockScreenHeight, alignment: .topLeading)
        .padding(.horizontal, WorkoutLiveActivityMetrics.containerHorizontalPadding)
        .padding(.vertical, WorkoutLiveActivityMetrics.containerVerticalPadding)
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(displayTitle)
                .font(.headline.weight(.semibold))
                .foregroundStyle(WorkoutLiveActivityPalette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(context.attributes.startedAt, style: .timer)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(WorkoutLiveActivityPalette.secondaryText)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var exerciseTitle: some View {
        Text(exerciseNameText)
            .font(.title3.weight(.semibold))
            .foregroundStyle(WorkoutLiveActivityPalette.primaryText)
            .lineLimit(2)
            .minimumScaleFactor(0.86)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailRow: some View {
        VStack(alignment: .leading, spacing: WorkoutLiveActivityMetrics.panelSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: WorkoutLiveActivityMetrics.horizontalGap) {
                Text(currentSetLabelText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WorkoutLiveActivityPalette.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                progressChip
            }

            Text(primaryValueText)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(WorkoutLiveActivityPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var progressChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(WorkoutLiveActivityPalette.progressTint)

            Text(WorkoutLiveActivityFormatting.progressText(for: context.state))
                .monospacedDigit()
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(WorkoutLiveActivityPalette.secondaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(WorkoutLiveActivityPalette.progressFill)
        )
    }

    private func restStatusView(_ lastCompletedSetAt: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WorkoutLiveActivityPalette.restTint)

            Text(lastCompletedSetAt, style: .timer)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(WorkoutLiveActivityPalette.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private var completionIntent: CompleteCurrentSetIntent? {
        guard let currentSetID = context.state.currentSetID else {
            return nil
        }

        return CompleteCurrentSetIntent(
            sessionID: context.attributes.sessionID,
            currentSetID: currentSetID.uuidString
        )
    }

    private var displayTitle: String {
        let title = context.state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Workout" : title
    }

    private var exerciseNameText: String {
        let name = context.state.currentExerciseName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Workout in progress" : name
    }

    private var currentSetLabelText: String {
        let label = (context.state.currentSetLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty {
            return WorkoutLiveActivityFormatting.currentSetLabel(for: context.state)
        }

        return label
    }

    private var primaryValueText: String {
        let value = (context.state.currentSetValueText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            return value
        }

        if let reps = context.state.currentSetReps,
           reps > 0,
           let weight = context.state.currentSetWeight,
           weight > 0 {
            if weight.rounded(.towardZero) == weight {
                return "\(Int(weight)) kg x \(reps)"
            }
            return "\(weight.formatted(.number.precision(.fractionLength(0...1)))) kg x \(reps)"
        }

        if let reps = context.state.currentSetReps,
           reps > 0 {
            return "\(reps) reps"
        }

        if let weight = context.state.currentSetWeight,
           weight > 0 {
            if weight.rounded(.towardZero) == weight {
                return "\(Int(weight)) kg"
            }
            return "\(weight.formatted(.number.precision(.fractionLength(0...1)))) kg"
        }

        return currentSetLabelText
    }

    private var progressSummary: String {
        if context.state.totalSetCount > 0 {
            return "Progress: \(context.state.completedSetCount) of \(context.state.totalSetCount) sets"
        }

        return "Completed sets: \(context.state.completedSetCount)"
    }

    private func liveActivityActionButton(intent: CompleteCurrentSetIntent) -> some View {
        Button(intent: intent) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                Text("action.complete_current_set_live")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .foregroundStyle(WorkoutLiveActivityPalette.background)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(WorkoutLiveActivityPalette.progressTint)
            )
        }
        .buttonStyle(.plain)
    }
}
