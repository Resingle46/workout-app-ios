import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

private enum WorkoutLiveActivityPalette {
    static let background = Color(red: 0.18, green: 0.20, blue: 0.27)
    static let surface = Color.white.opacity(0.10)
    static let surfaceStroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.56, green: 0.80, blue: 1.0)
    static let accentSurface = Color(red: 0.32, green: 0.52, blue: 0.94).opacity(0.20)
    static let progressSurface = Color.green.opacity(0.18)
    static let progressTint = Color(red: 0.39, green: 0.92, blue: 0.55)
    static let restSurface = Color.orange.opacity(0.20)
    static let restStroke = Color.orange.opacity(0.26)
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

    static func setMetricsText(for state: WorkoutActivityAttributes.ContentState) -> String {
        let repsText = state.currentSetReps.map { "\($0)" }
        let weightText = state.currentSetWeight.flatMap(formattedWeightText(for:))

        switch (weightText, repsText) {
        case let (weight?, reps?):
            return "\(weight) × \(reps)"
        case let (weight?, nil):
            return weight
        case let (nil, reps?):
            return "× \(reps)"
        default:
            return currentSetLabel(for: state)
        }
    }

    static func compactSetSummary(for state: WorkoutActivityAttributes.ContentState) -> String {
        let label = currentSetLabel(for: state)
        let metrics = setMetricsText(for: state)

        guard metrics != label else {
            return label
        }

        return "\(label) · \(metrics)"
    }

    private static func formattedWeightText(for weight: Double) -> String? {
        guard weight > 0 else {
            return nil
        }

        return weightFormatter.string(from: Measurement(value: weight, unit: UnitMass.kilograms))
    }
}

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(WorkoutLiveActivityPalette.background)
                .activitySystemActionForegroundColor(Color.white)
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
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(WorkoutLiveActivityFormatting.compactSetSummary(for: context.state))
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            progressChip(for: context.state)
                        }

                        if let lastCompletedSetAt = context.state.lastCompletedSetAt {
                            compactTimerChip(
                                systemImage: "pause.fill",
                                timerDate: lastCompletedSetAt,
                                tint: .orange,
                                backgroundColor: WorkoutLiveActivityPalette.restSurface
                            )
                        }
                    }
                }
            } compactLeading: {
                if context.state.lastCompletedSetAt != nil {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.orange)
                } else {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .foregroundStyle(WorkoutLiveActivityPalette.accent)
                }
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.state.lastCompletedSetAt == nil ? "figure.strengthtraining.traditional" : "pause.fill")
            }
        }
    }

    private func progressChip(for state: WorkoutActivityAttributes.ContentState) -> some View {
        compactTextChip(
            systemImage: "checkmark.circle.fill",
            text: WorkoutLiveActivityFormatting.progressText(for: state),
            tint: WorkoutLiveActivityPalette.progressTint,
            backgroundColor: WorkoutLiveActivityPalette.progressSurface
        )
    }

    private func compactTextChip(
        systemImage: String,
        text: String,
        tint: Color,
        backgroundColor: Color
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
        )
    }

    private func compactTimerChip(
        systemImage: String,
        timerDate: Date,
        tint: Color,
        backgroundColor: Color
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(timerDate, style: .timer)
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
        )
    }
}

private struct WorkoutLiveActivityLockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            Text(context.state.currentExerciseName)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 10) {
                currentSetCard

                if let lastCompletedSetAt = context.state.lastCompletedSetAt {
                    restCard(lastCompletedSetAt)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WorkoutLiveActivityPalette.accent)

                Text(context.state.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WorkoutLiveActivityPalette.accent)

                Text(context.attributes.startedAt, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
    }

    private var currentSetCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(WorkoutLiveActivityFormatting.currentSetLabel(for: context.state))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)

                Spacer(minLength: 8)

                progressChip
            }

            Text(WorkoutLiveActivityFormatting.setMetricsText(for: context.state))
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(WorkoutLiveActivityPalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(WorkoutLiveActivityPalette.surfaceStroke, lineWidth: 1)
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
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(WorkoutLiveActivityPalette.progressSurface)
        )
    }

    private func restCard(_ lastCompletedSetAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "pause.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            Text(lastCompletedSetAt, style: .timer)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: 92, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(WorkoutLiveActivityPalette.restSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(WorkoutLiveActivityPalette.restStroke, lineWidth: 1)
        )
    }
}
