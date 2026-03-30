import ActivityKit
import SwiftUI
import WidgetKit

struct WorkoutLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.15, green: 0.17, blue: 0.22))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.state.currentExerciseName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.headline.monospacedDigit())
                        Text(progressValueText(for: context.state))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        compactChip(
                            systemImage: "checkmark.circle.fill",
                            text: progressValueText(for: context.state),
                            tint: .green,
                            backgroundColor: .green.opacity(0.18)
                        )

                        compactChip(
                            systemImage: "figure.strengthtraining.traditional",
                            text: currentSetText(for: context.state),
                            tint: Color(red: 0.55, green: 0.79, blue: 1.0),
                            backgroundColor: Color(red: 0.32, green: 0.52, blue: 0.93).opacity(0.20)
                        )

                        Spacer(minLength: 0)

                        if let lastCompletedSetAt = context.state.lastCompletedSetAt {
                            compactChip(
                                systemImage: "pause.circle.fill",
                                timerDate: lastCompletedSetAt,
                                tint: .orange,
                                backgroundColor: .orange.opacity(0.18)
                            )
                        }
                    }
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
        progressValueText(for: state)
    }

    private func progressValueText(for state: WorkoutActivityAttributes.ContentState) -> String {
        if state.totalSetCount > 0 {
            return "\(state.completedSetCount)/\(state.totalSetCount)"
        }
        return "\(state.completedSetCount)"
    }

    private func currentSetText(for state: WorkoutActivityAttributes.ContentState) -> String {
        state.currentSetLabel ?? progressValueText(for: state)
    }

    private func compactChip(
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

    private func compactChip(
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(red: 0.55, green: 0.79, blue: 1.0))

                    Text(context.state.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(red: 0.64, green: 0.82, blue: 1.0))
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.subheadline.monospacedDigit())
                }
            }

            Text(context.state.currentExerciseName)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            HStack(spacing: 8) {
                metricChip(
                    systemImage: "checkmark.circle.fill",
                    tint: .green,
                    backgroundColor: .green.opacity(0.18)
                ) {
                    Text(progressValueText)
                        .monospacedDigit()
                }

                metricChip(
                    systemImage: "figure.strengthtraining.traditional",
                    tint: Color(red: 0.55, green: 0.79, blue: 1.0),
                    backgroundColor: Color(red: 0.32, green: 0.52, blue: 0.93).opacity(0.20)
                ) {
                    Text(currentSetText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            if let lastCompletedSetAt = context.state.lastCompletedSetAt {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)

                    Text(lastCompletedSetAt, style: .timer)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.orange.opacity(0.18))
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var progressValueText: String {
        if context.state.totalSetCount > 0 {
            return "\(context.state.completedSetCount)/\(context.state.totalSetCount)"
        }
        return "\(context.state.completedSetCount)"
    }

    private var currentSetText: String {
        context.state.currentSetLabel ?? progressValueText
    }

    private func metricChip<Content: View>(
        systemImage: String,
        tint: Color,
        backgroundColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            content()
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
        )
    }
}
