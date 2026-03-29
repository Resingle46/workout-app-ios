import ActivityKit
import SwiftUI
import WidgetKit

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.title)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(progressShortText(for: context.state))
                            .font(.headline.monospacedDigit())
                        Text(setLabelText(for: context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.currentExerciseName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let lastCompletedSetAt = context.state.lastCompletedSetAt {
                            restBadge(from: lastCompletedSetAt)
                        } else {
                            Text("Active")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Text(context.attributes.startedAt, style: .timer)
                    .monospacedDigit()
            } compactTrailing: {
                Text(progressShortText(for: context.state))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "figure.strengthtraining.traditional")
            }
        }
    }

    private func progressShortText(for state: WorkoutActivityAttributes.ContentState) -> String {
        if state.totalSetCount > 0 {
            return "\(state.completedSetCount)/\(state.totalSetCount)"
        }
        return "\(state.completedSetCount)"
    }

    private func setLabelText(for state: WorkoutActivityAttributes.ContentState) -> String {
        state.currentSetLabel ?? "Set"
    }

    private func restBadge(from date: Date) -> some View {
        HStack(spacing: 6) {
            Text("Rest")
                .font(.caption.weight(.semibold))
            Text(date, style: .timer)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.15))
        )
    }
}

private struct WorkoutLiveActivityLockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.state.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(context.attributes.startedAt, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(context.state.currentExerciseName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)

            Text(progressLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let lastCompletedSetAt = context.state.lastCompletedSetAt {
                restBadge(from: lastCompletedSetAt)
            } else {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var progressLine: String {
        let setLabel = context.state.currentSetLabel ?? "Set"
        if context.state.totalSetCount > 0 {
            return "\(setLabel) | \(context.state.completedSetCount) of \(context.state.totalSetCount) sets"
        }
        return "\(setLabel) | \(context.state.completedSetCount) sets"
    }

    private func restBadge(from date: Date) -> some View {
        HStack(spacing: 6) {
            Text("Rest")
                .font(.caption.weight(.semibold))
            Text(date, style: .timer)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.15))
        )
    }
}
