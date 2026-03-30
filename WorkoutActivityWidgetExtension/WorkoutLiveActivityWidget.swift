import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

private enum WorkoutLiveActivityPalette {
    static let background = Color(red: 0.14, green: 0.14, blue: 0.16)
    static let panel = Color.white.opacity(0.07)
    static let panelStroke = Color.white.opacity(0.06)
    static let primaryText = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.62)
    static let accent = Color.white.opacity(0.90)
    static let progressFill = Color.white.opacity(0.08)
    static let progressTint = Color(red: 0.47, green: 0.93, blue: 0.60)
    static let restTint = Color(red: 1.0, green: 0.72, blue: 0.38)
}

private enum WorkoutLiveActivityMetrics {
    static let outerSpacing: CGFloat = 8
    static let panelSpacing: CGFloat = 8
    static let horizontalGap: CGFloat = 10
    static let containerHorizontalPadding: CGFloat = 14
    static let containerVerticalPadding: CGFloat = 10
    static let panelPadding: CGFloat = 11
    static let cornerRadius: CGFloat = 14
    static let statusColumnWidth: CGFloat = 76
    static let dividerHeight: CGFloat = 32
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
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
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
}

private struct WorkoutLiveActivityLockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: WorkoutLiveActivityMetrics.outerSpacing) {
            headerRow

            Text(context.state.currentExerciseName)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(WorkoutLiveActivityPalette.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.92)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            detailPanel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkoutLiveActivityMetrics.containerHorizontalPadding)
        .padding(.vertical, WorkoutLiveActivityMetrics.containerVerticalPadding)
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(context.state.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(WorkoutLiveActivityPalette.primaryText.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(context.attributes.startedAt, style: .timer)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(WorkoutLiveActivityPalette.secondaryText)
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: WorkoutLiveActivityMetrics.panelSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(WorkoutLiveActivityFormatting.currentSetLabel(for: context.state))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WorkoutLiveActivityPalette.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                progressChip
            }

            if let lastCompletedSetAt = context.state.lastCompletedSetAt {
                HStack(alignment: .center, spacing: WorkoutLiveActivityMetrics.horizontalGap) {
                    setValueView

                    Rectangle()
                        .fill(WorkoutLiveActivityPalette.panelStroke)
                        .frame(width: 1, height: WorkoutLiveActivityMetrics.dividerHeight)

                    restStatusView(lastCompletedSetAt)
                }
            } else {
                setValueView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WorkoutLiveActivityMetrics.panelPadding)
        .background(
            RoundedRectangle(cornerRadius: WorkoutLiveActivityMetrics.cornerRadius, style: .continuous)
                .fill(WorkoutLiveActivityPalette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WorkoutLiveActivityMetrics.cornerRadius, style: .continuous)
                .stroke(WorkoutLiveActivityPalette.panelStroke, lineWidth: 1)
        )
    }

    private var progressChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(WorkoutLiveActivityPalette.progressTint)

            Text(WorkoutLiveActivityFormatting.progressText(for: context.state))
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(WorkoutLiveActivityPalette.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(WorkoutLiveActivityPalette.progressFill)
        )
    }

    private var setValueView: some View {
        Text(WorkoutLiveActivityFormatting.primarySetValueText(for: context.state))
            .font(.system(size: 23, weight: .semibold, design: .rounded))
            .foregroundStyle(WorkoutLiveActivityPalette.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func restStatusView(_ lastCompletedSetAt: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(WorkoutLiveActivityPalette.restTint)

            Text(lastCompletedSetAt, style: .timer)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(WorkoutLiveActivityPalette.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: WorkoutLiveActivityMetrics.statusColumnWidth, alignment: .trailing)
    }
}
