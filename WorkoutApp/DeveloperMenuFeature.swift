import SwiftUI
import UIKit

struct DeveloperMenuSettingsCard: View {
    @AppStorage(DeveloperMenuPreferences.unlockKey) private var isDeveloperMenuUnlocked = false
    @State private var versionTapCount = 0
    @State private var unlockStatusMessage: String?

    private var versionLabelValue: String {
        "\(BackupConstants.appVersion) (\(BackupConstants.buildNumber))"
    }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 16) {
                AppSectionTitle(titleKey: "developer.settings.section")

                Button(action: handleVersionTap) {
                    settingsRow(
                        titleKey: "developer.settings.version",
                        value: versionLabelValue,
                        showsChevron: false
                    )
                }
                .buttonStyle(.plain)

                if let unlockStatusMessage, !unlockStatusMessage.isEmpty {
                    Text(unlockStatusMessage)
                        .font(AppTypography.caption(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.success)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isDeveloperMenuUnlocked {
                    NavigationLink(destination: DeveloperMenuView()) {
                        settingsRow(
                            titleKey: "developer.menu.title",
                            value: localized("developer.settings.unlocked")
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func handleVersionTap() {
        guard !isDeveloperMenuUnlocked else {
            return
        }

        versionTapCount += 1
        guard versionTapCount >= 10 else {
            return
        }

        isDeveloperMenuUnlocked = true
        versionTapCount = 0
        unlockStatusMessage = localized("developer.settings.unlock_success")
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if isDeveloperMenuUnlocked {
                unlockStatusMessage = nil
            }
        }
    }

    private func settingsRow(
        titleKey: LocalizedStringKey,
        value: String,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 12) {
            Text(titleKey)
                .font(AppTypography.body(size: 17))
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 12)

            Text(value)
                .font(AppTypography.body(size: 15, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.trailing)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}

@MainActor
struct DeveloperMenuView: View {
    @Environment(DebugDiagnosticsController.self) private var debugController
    @Environment(CoachStore.self) private var coachStore
    @Environment(WorkoutSummaryStore.self) private var workoutSummaryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.appBottomRailInset) private var bottomRailInset
    @State private var selectedProvider: CoachAIProvider = CoachRuntimeConfigurationStore(bundle: .main).runtimeConfiguration.provider

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                runtimeCard
                liveActivityCard
                CoachBackendSettingsCard()
                backupCard
                coachCard
                networkCard
                logsCard
                actionsCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .padding(.bottom, bottomRailInset)
        }
        .navigationTitle("developer.menu.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    debugController.refreshReport()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(AppTypography.icon(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.primaryText)
                }
            }
        }
        .sheet(
            item: Binding(
                get: { debugController.sharePayload },
                set: { value in
                    if value == nil {
                        debugController.clearPreparedExport()
                    }
                }
            )
        ) { payload in
            DebugActivityShareSheet(
                activityItems: [payload.fileURL],
                subject: payload.title,
                onComplete: {
                    debugController.clearPreparedExport()
                }
            )
        }
        .task {
            selectedProvider = CoachRuntimeConfigurationStore(bundle: .main).runtimeConfiguration.provider
            debugController.refreshReport()
        }
        .appScreenBackground()
    }

    private var liveActivityLogs: [DebugLogEntry] {
        Array(
            debugController.report.logs
                .lazy
                .filter { $0.category == .liveActivity }
                .prefix(25)
        )
    }

    private var runtimeCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                AppSectionTitle(titleKey: "developer.section.runtime")
                DeveloperMenuValueRow(
                    titleKey: "developer.runtime.app_version",
                    value: debugController.report.runtime.appVersion
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.runtime.build_number",
                    value: debugController.report.runtime.buildNumber
                )
                DeveloperMenuMaskedValueRow(
                    titleKey: "developer.runtime.install_id",
                    value: debugController.report.runtime.installID
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.runtime.install_secret_ready",
                    value: boolValue(debugController.report.runtime.installSecretReady)
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.runtime.identity_storage_mode",
                    value: debugController.report.runtime.identityStorageMode
                        ?? localized("developer.value.none")
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.runtime.backend_base_url",
                    value: debugController.report.runtime.backendBaseURL
                        ?? localized("developer.value.not_configured"),
                    allowsWrap: true
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.runtime.remote_coach_available",
                    value: boolValue(debugController.report.runtime.remoteCoachAvailable)
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.runtime.ai_provider",
                    value: debugController.report.runtime.selectedAIProvider
                        ?? localized("developer.value.none")
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI Provider")
                        .font(AppTypography.body(size: 15))
                        .foregroundStyle(AppTheme.secondaryText)
                    Picker("AI Provider", selection: $selectedProvider) {
                        ForEach(CoachAIProvider.allCases, id: \.self) { provider in
                            Text(provider.debugName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .onChange(of: selectedProvider) { _, provider in
            let store = CoachRuntimeConfigurationStore(bundle: .main)
            store.provider = provider
            let configuration = store.save()
            coachStore.updateConfiguration(configuration)
            workoutSummaryStore.updateConfiguration(configuration)
            debugController.refreshReport()
        }
    }

    private var liveActivityCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                AppSectionTitle(titleKey: "developer.section.live_activity")
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.info_plist_enabled",
                    value: boolValue(debugController.report.liveActivity.infoPlistSupportsLiveActivities)
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.runtime_supported",
                    value: boolValue(debugController.report.liveActivity.runtimeSupported)
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.activities_enabled",
                    value: boolValue(debugController.report.liveActivity.areActivitiesEnabled)
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.embedded_extensions",
                    value: debugController.report.liveActivity.embeddedExtensionBundleIDs.nilIfEmpty?
                        .joined(separator: ", ")
                        ?? localized("developer.value.none"),
                    allowsWrap: true
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.active_session_id",
                    value: debugController.report.liveActivity.activeSessionID
                        ?? localized("developer.value.none"),
                    copyValue: debugController.report.liveActivity.activeSessionID
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.known_activity_count",
                    value: String(debugController.report.liveActivity.knownActivityCount)
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.started_activity_id",
                    value: debugController.report.liveActivity.startedActivityID
                        ?? localized("developer.value.none"),
                    copyValue: debugController.report.liveActivity.startedActivityID
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.last_request_status",
                    value: debugController.report.liveActivity.lastRequestStatus
                        ?? localized("developer.value.none")
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.last_update_status",
                    value: debugController.report.liveActivity.lastUpdateStatus
                        ?? localized("developer.value.none")
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.last_end_status",
                    value: debugController.report.liveActivity.lastEndStatus
                        ?? localized("developer.value.none")
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.last_reconcile_status",
                    value: debugController.report.liveActivity.lastReconcileStatus
                        ?? localized("developer.value.none")
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.last_snapshot_status",
                    value: debugController.report.liveActivity.lastSnapshotStatus
                        ?? localized("developer.value.none")
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.last_error_reason",
                    value: debugController.report.liveActivity.lastErrorOrReason
                        ?? localized("developer.value.none"),
                    allowsWrap: true
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.live_activity.last_event_at",
                    value: debugController.report.liveActivity.lastEventAt.map(formattedDate)
                        ?? localized("developer.value.none")
                )

                if liveActivityLogs.isEmpty {
                    DeveloperMenuEmptyState(textKey: "developer.live_activity.events_empty")
                } else {
                    ForEach(liveActivityLogs) { entry in
                        DeveloperMenuLogCard(entry: entry, locale: locale)
                    }
                }
            }
        }
    }

    private var backupCard: some View {
        BackupControlsCard()
    }

    private var coachCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                AppSectionTitle(titleKey: "developer.section.coach")
                DeveloperMenuMaskedValueRow(
                    titleKey: "developer.coach.active_chat_job_id",
                    value: debugController.report.coach.activeChatJobID
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.coach.active_chat_provider",
                    value: debugController.report.coach.activeChatProvider
                        ?? localized("developer.value.none")
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.coach.pending_summary_provider",
                    value: debugController.report.coach.pendingWorkoutSummaryProvider
                        ?? localized("developer.value.none")
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.coach.can_resume_pending_chat_job",
                    value: boolValue(debugController.report.coach.canResumePendingChatJob)
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.coach.last_chat_error",
                    value: debugController.report.coach.lastChatError
                        ?? localized("developer.value.none"),
                    allowsWrap: true
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.coach.last_chat_provider",
                    value: debugController.report.coach.lastChatProvider
                        ?? localized("developer.value.none")
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.coach.last_insights_error",
                    value: debugController.report.coach.lastInsightsError
                        ?? localized("developer.value.none"),
                    allowsWrap: true
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.coach.last_insights_provider",
                    value: debugController.report.coach.lastInsightsProvider
                        ?? localized("developer.value.none")
                )
                DeveloperMenuValueRow(
                    titleKey: "developer.coach.last_summary_provider",
                    value: debugController.report.coach.lastWorkoutSummaryProvider
                        ?? localized("developer.value.none")
                )
            }
        }
    }

    private var networkCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                AppSectionTitle(titleKey: "developer.section.network")

                if debugController.report.network.isEmpty {
                    DeveloperMenuEmptyState(textKey: "developer.network.empty")
                } else {
                    ForEach(debugController.report.network) { trace in
                        DeveloperMenuTraceCard(trace: trace, locale: locale)
                    }
                }
            }
        }
    }

    private var logsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                AppSectionTitle(titleKey: "developer.section.logs")

                if debugController.report.logs.isEmpty {
                    DeveloperMenuEmptyState(textKey: "developer.logs.empty")
                } else {
                    ForEach(debugController.report.logs) { entry in
                        DeveloperMenuLogCard(entry: entry, locale: locale)
                    }
                }
            }
        }
    }

    private var actionsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 14) {
                AppSectionTitle(titleKey: "developer.section.actions")

                if let actionStatusMessage = debugController.actionStatusMessage,
                   !actionStatusMessage.isEmpty {
                    Text(actionStatusMessage)
                        .font(AppTypography.caption(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("developer.action.refresh_report") {
                    debugController.refreshReport()
                }
                .buttonStyle(AppSecondaryButtonStyle())

                Button("developer.action.copy_payload") {
                    debugController.copyDebugPayload()
                }
                .buttonStyle(AppPrimaryButtonStyle())

                Button("developer.action.export_payload") {
                    debugController.prepareDebugPayloadExport()
                }
                .buttonStyle(AppSecondaryButtonStyle())

                Button("developer.action.ping_health") {
                    Task {
                        await debugController.pingHealth()
                    }
                }
                .buttonStyle(AppSecondaryButtonStyle())
                .disabled(!debugController.canPingHealth || debugController.isPingingHealth)
                .opacity((debugController.canPingHealth && !debugController.isPingingHealth) ? 1 : 0.55)

                Button("developer.action.clear_logs") {
                    debugController.clearDebugData()
                }
                .buttonStyle(AppSecondaryButtonStyle())

                Button("developer.action.hide_menu") {
                    debugController.hideDeveloperMenu()
                    dismiss()
                }
                .buttonStyle(AppSecondaryButtonStyle())
            }
        }
    }

    private func boolValue(_ value: Bool) -> String {
        value ? localized("developer.value.yes") : localized("developer.value.no")
    }

    private func boolValue(_ value: Bool?) -> String {
        guard let value else {
            return localized("developer.value.none")
        }

        return boolValue(value)
    }

    private func valueOrNone(_ value: Int?) -> String {
        value.map(String.init) ?? localized("developer.value.none")
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .hour()
                .minute()
                .second()
                .locale(locale)
        )
    }

    private func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }
}

private extension Array where Element == String {
    var nilIfEmpty: [String]? {
        isEmpty ? nil : self
    }
}

private struct DeveloperMenuValueRow: View {
    let titleKey: LocalizedStringKey
    let value: String
    var copyValue: String? = nil
    var allowsWrap = false

    @Environment(DebugDiagnosticsController.self) private var debugController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(titleKey)
                .font(AppTypography.body(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)

            Spacer(minLength: 12)

            Text(value)
                .font(AppTypography.body(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: allowsWrap)

            if copyValue != nil {
                Button {
                    debugController.copyValue(copyValue)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(AppTypography.icon(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(AppTheme.surface)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct DeveloperMenuMaskedValueRow: View {
    let titleKey: LocalizedStringKey
    let value: DebugMaskedValue?

    var body: some View {
        DeveloperMenuValueRow(
            titleKey: titleKey,
            value: value?.displayValueMasked
                ?? Bundle.main.localizedString(forKey: "developer.value.none", value: nil, table: nil),
            copyValue: value?.copyValueFull
        )
    }
}

private struct DeveloperMenuTraceCard: View {
    let trace: DebugNetworkTrace
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(trace.method)
                    .font(AppTypography.caption(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppTheme.accentMuted, in: Capsule())

                Text(trace.path)
                    .font(AppTypography.body(size: 14, weight: .medium))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(2)

                Spacer(minLength: 12)

                Text(trace.statusCode.map(String.init) ?? "ERR")
                    .font(AppTypography.caption(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: 14) {
                traceMetaLabel(title: "developer.network.duration", value: "\(trace.durationMs) ms")
                traceMetaLabel(title: "developer.network.started_at", value: formattedDate(trace.startedAt))
            }

            if let requestID = trace.requestID, !requestID.isEmpty {
                traceMetaLabel(title: "developer.network.request_id", value: requestID)
            }

            if let clientRequestID = trace.clientRequestID, !clientRequestID.isEmpty {
                traceMetaLabel(title: "developer.network.client_request_id", value: clientRequestID)
            }

            if let errorDescription = trace.errorDescription, !errorDescription.isEmpty {
                Text(errorDescription)
                    .font(AppTypography.caption(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private var statusColor: Color {
        guard let statusCode = trace.statusCode else {
            return AppTheme.warning
        }

        switch statusCode {
        case 200..<300:
            return AppTheme.success
        case 400..<500:
            return AppTheme.warning
        default:
            return AppTheme.destructive
        }
    }

    private func traceMetaLabel(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title))
                .font(AppTypography.label(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.tertiaryText)
            Text(value)
                .font(AppTypography.caption(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .hour()
                .minute()
                .second()
                .locale(locale)
        )
    }
}

private struct DeveloperMenuLogCard: View {
    let entry: DebugLogEntry
    let locale: Locale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(entry.category.rawValue)
                    .font(AppTypography.caption(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppTheme.surfaceElevated, in: Capsule())

                Text(entry.level.rawValue.uppercased())
                    .font(AppTypography.caption(size: 11, weight: .semibold))
                    .foregroundStyle(levelColor)

                Spacer(minLength: 12)

                Text(formattedDate(entry.timestamp))
                    .font(AppTypography.caption(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.tertiaryText)
            }

            Text(entry.message)
                .font(AppTypography.body(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !entry.metadata.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entry.metadata.keys.sorted(), id: \.self) { key in
                        if let value = entry.metadata[key] {
                            HStack(alignment: .top, spacing: 8) {
                                Text(key)
                                    .font(AppTypography.caption(size: 11, weight: .semibold))
                                    .foregroundStyle(AppTheme.tertiaryText)
                                Text(value)
                                    .font(AppTypography.caption(size: 12, weight: .medium))
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppTheme.border, lineWidth: 1)
        )
    }

    private var levelColor: Color {
        switch entry.level {
        case .info:
            return AppTheme.secondaryText
        case .warning:
            return AppTheme.warning
        case .error:
            return AppTheme.destructive
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .hour()
                .minute()
                .second()
                .locale(locale)
        )
    }
}

private struct DeveloperMenuEmptyState: View {
    let textKey: LocalizedStringKey

    var body: some View {
        Text(textKey)
            .font(AppTypography.body(size: 15, weight: .medium))
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DebugActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let subject: String
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        controller.setValue(subject, forKey: "subject")
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
