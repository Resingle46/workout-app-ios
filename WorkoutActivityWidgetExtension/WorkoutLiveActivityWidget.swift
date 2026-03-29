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
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.title3.monospacedDigit())
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(progressText(for: context.state))
                            .font(.headline.monospacedDigit())
                        if let currentSetLabel = context.state.currentSetLabel {
                            Text(currentSetLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.currentExerciseName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let lastCompletedSetAt = context.state.lastCompletedSetAt {
                            HStack(spacing: 6) {
                                Text("Rest")
                                    .foregroundStyle(.secondary)
                                Text(lastCompletedSetAt, style: .timer)
                                    .monospacedDigit()
                            }
                            .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Text(context.attributes.startedAt, style: .timer)
                    .monospacedDigit()
            } compactTrailing: {
                Text(progressText(for: context.state))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "figure.strengthtraining.traditional")
            }
        }
    }

    private func progressText(for state: WorkoutActivityAttributes.ContentState) -> String {
        "\(state.completedSetCount)/\(state.totalSetCount)"
    }
}

private struct WorkoutLiveActivityLockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.currentExerciseName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(context.attributes.startedAt, style: .timer)
                    .font(.title3.monospacedDigit())
            }

            HStack(spacing: 12) {
                Label(progressText, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                if let currentSetLabel = context.state.currentSetLabel {
                    Text(currentSetLabel)
                        .font(.subheadline.weight(.semibold))
                }
            }

            if let lastCompletedSetAt = context.state.lastCompletedSetAt {
                HStack(spacing: 6) {
                    Text("Rest")
                        .foregroundStyle(.secondary)
                    Text(lastCompletedSetAt, style: .timer)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var progressText: String {
        "\(context.state.completedSetCount)/\(context.state.totalSetCount)"
    }
}
