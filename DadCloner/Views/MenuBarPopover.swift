import SwiftUI
import AppKit
import UserNotifications

/// Status indicator for the menu bar icon
enum MenuBarStatus {
    case ready      // Green - all good
    case warning    // Yellow - overdue or drive issue
    case syncing    // Gray with animation - sync in progress
    case error      // Red - something wrong

    var iconName: String {
        switch self {
        case .ready:
            return "externaldrive.fill.badge.checkmark"
        case .warning:
            return "externaldrive.fill.badge.exclamationmark"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .error:
            return "externaldrive.fill.badge.xmark"
        }
    }

    var color: Color {
        switch self {
        case .ready:
            return .green
        case .warning:
            return .orange
        case .syncing:
            return .gray
        case .error:
            return .red
        }
    }
}

/// Main popover view shown when clicking the menu bar icon
struct MenuBarPopover: View {
    @State private var syncManager = SyncManager.shared
    @State private var config = SyncConfiguration.shared
    @State private var driveMonitor = DriveMonitor.shared
    @State private var scheduler = SchedulerManager.shared
    @State private var notificationStatus: UNAuthorizationStatus?

    @State private var showingLog = false
    @State private var showingResetConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with status
            headerSection
                .padding(16)

            Divider()

            // Drive status
            driveStatusSection
                .padding(16)

            Divider()

            // Actions
            actionsSection
                .padding(16)

            Divider()

            // Footer
            footerSection
                .padding(12)
        }
        .frame(width: 300)
        .sheet(isPresented: $showingLog) {
            LogView()
        }
        .onAppear {
            Task {
                await refreshNotificationStatus()
            }
        }
        .confirmationDialog(
            "Reset Configuration?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) {
                resetConfiguration()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all settings and you'll need to set up DadCloner again.")
        }
    }

    // MARK: - Status Calculation

    private var currentStatus: MenuBarStatus {
        if syncManager.status.isRunning {
            return .syncing
        }

        if !config.isConfigured {
            return .warning
        }

        if !driveMonitor.areDrivesReady {
            if !driveMonitor.sourceStatus.isValid || !driveMonitor.backupStatus.isValid {
                return .error
            }
            return .warning
        }

        if config.isBackupOverdue {
            return .warning
        }

        if !config.lastSyncSuccess && config.lastSyncDate != nil {
            return .warning
        }

        return .ready
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(spacing: 12) {
            // Status icon
            ZStack {
                Circle()
                    .fill(currentStatus.color.opacity(0.2))
                    .frame(width: 44, height: 44)

                Image(systemName: currentStatus.iconName)
                    .font(.title2)
                    .foregroundColor(currentStatus.color)
                    .symbolEffect(.pulse, isActive: currentStatus == .syncing)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("DadCloner")
                    .font(.headline)

                if syncManager.status.isRunning {
                    Text(syncManager.status.displayText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !config.isConfigured {
                    Button("Setup required") {
                        openSetup()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundColor(.orange)
                } else {
                    Text("Last backup: \(config.timeSinceLastSync)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Drive Status Section

    private var driveStatusSection: some View {
        VStack(spacing: 12) {
            // Source drive
            driveStatusRow(
                name: config.sourceDriveName.isEmpty ? "Source Drive" : config.sourceDriveName,
                status: driveMonitor.sourceStatus,
                icon: "externaldrive"
            )

            // Backup drive
            driveStatusRow(
                name: config.backupDriveName.isEmpty ? "Backup Drive" : config.backupDriveName,
                status: driveMonitor.backupStatus,
                icon: "externaldrive.badge.checkmark"
            )

            // Next scheduled sync
            if config.isConfigured && !syncManager.status.isRunning {
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                        .frame(width: 20)

                    Text("Next: \(scheduler.nextSyncDescription)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()
                }
            }
        }
    }

    private func driveStatusRow(name: String, status: DriveValidationResult, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(status.isValid ? .green : .orange)
                .frame(width: 20)

            Text(name)
                .lineLimit(1)

            Spacer()

            if status.isValid {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else {
                Text(status == .notMounted ? "Not mounted" : "Issue")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 8) {
            // Backup Now button
            Button(action: backupNow) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(syncManager.status.isRunning ? "Syncing..." : "Backup Now")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(syncManager.status.isRunning || !driveMonitor.areDrivesReady)

            // Progress bar if syncing
            if syncManager.status.isRunning {
                ProgressView(value: syncManager.currentProgress)
                    .progressViewStyle(.linear)

                if !syncManager.currentFile.isEmpty {
                    Text(syncManager.currentFile)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let status = notificationStatus, status != .authorized {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .foregroundColor(.orange)
                    Text(status == .denied ? "Notifications off" : "Notifications not enabled")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    if status == .notDetermined {
                        Button("Request") {
                            requestNotificationPermission()
                        }
                        .font(.caption)
                    } else if status == .denied {
                        Button("Open Settings") {
                            openNotificationSettings()
                        }
                        .font(.caption)
                    }
                }
            }

            HStack(spacing: 12) {
                // Open Archive button
                Button(action: openArchive) {
                    HStack {
                        Image(systemName: "archivebox")
                        Text("Archive")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!config.isConfigured)

                // View Log button
                Button(action: { showingLog = true }) {
                    HStack {
                        Image(systemName: "doc.text")
                        Text("Log")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        VStack(spacing: 8) {
            // Launch at login toggle
            Toggle(isOn: Binding(
                get: { LaunchAtLogin.shared.isEnabled },
                set: { LaunchAtLogin.shared.isEnabled = $0 }
            )) {
                Text("Start at login")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            HStack {
                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Text("Quit")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                // Hidden reset option (hold Option key)
                Button(action: { showingResetConfirmation = true }) {
                    Text("Reset")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func backupNow() {
        Task {
            await scheduler.triggerManualSync()
        }
    }

    private func openArchive() {
        let archivePath = config.archivePath
        if FileManager.default.fileExists(atPath: archivePath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: archivePath))
        }
    }

    private func resetConfiguration() {
        scheduler.stop()
        config.resetConfiguration()
        // App will show setup view since isConfigured is now false
    }

    private func openSetup() {
        (NSApp.delegate as? AppDelegate)?.showSetupWindow()
    }

    private func requestNotificationPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            await refreshNotificationStatus()
        }
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Simple log viewer
struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logContent: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sync Log")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            ScrollView {
                Text(logContent)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            Divider()

            HStack {
                Button("Open in Finder") {
                    let path = SyncLogger.shared.getLogFilePath()
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Spacer()
                Button("Refresh") {
                    loadLog()
                }
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        .onAppear {
            loadLog()
        }
    }

    private func loadLog() {
        logContent = SyncLogger.shared.readLogFile()
    }
}

#Preview {
    MenuBarPopover()
        .frame(width: 300)
}
