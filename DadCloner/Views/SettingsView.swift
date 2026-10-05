import SwiftUI
import AppKit

/// Post-setup settings: change the schedule, pause automatic backups,
/// toggle launch at login, or re-run drive selection. Before this view
/// existed, the only way to change anything was the destructive Reset.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var config = SyncConfiguration.shared
    @State private var scheduler = SchedulerManager.shared
    @State private var launchAtLogin = LaunchAtLogin.shared
    @State private var scheduleTime: Date = Date()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            Form {
                Section("Schedule") {
                    DatePicker(
                        "Daily backup time",
                        selection: $scheduleTime,
                        displayedComponents: .hourAndMinute
                    )
                    .onChange(of: scheduleTime) { _, newValue in
                        let components = Calendar.current.dateComponents(
                            [.hour, .minute], from: newValue)
                        let newHour = components.hour ?? 2
                        let newMinute = components.minute ?? 0
                        guard newHour != config.scheduleHour || newMinute != config.scheduleMinute else { return }
                        scheduler.updateSchedule(
                            hour: newHour,
                            minute: newMinute
                        )
                    }

                    Toggle("Pause automatic backups", isOn: Binding(
                        get: { config.isSchedulePaused },
                        set: { scheduler.setPaused($0) }
                    ))

                    Toggle("Start at login", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.isEnabled = $0 }
                    ))

                    if launchAtLogin.requiresApproval {
                        HStack {
                            Text("Allow DadCloner in Login Items to finish turning this on.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Open Settings") {
                                launchAtLogin.openLoginItemsSettings()
                            }
                            .font(.caption)
                        }
                    }
                }

                Section("Drives") {
                    LabeledContent("Source", value: config.sourceDriveName)
                    LabeledContent("Backup", value: config.backupDriveName)

                    Button("Change Drives…") {
                        dismiss()
                        (NSApp.delegate as? AppDelegate)?.showSetupWindow()
                    }
                    .disabled(SyncManager.shared.status.isRunning)
                }

                Section("Updates") {
                    LabeledContent(
                        "Version",
                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    )
                    Button("Check for Updates…") {
                        (NSApp.delegate as? AppDelegate)?.checkForUpdates()
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 380, height: 420)
        .onAppear {
            launchAtLogin.refresh()
            var components = DateComponents()
            components.hour = config.scheduleHour
            components.minute = config.scheduleMinute
            scheduleTime = Calendar.current.date(from: components) ?? Date()
        }
    }
}

#Preview {
    SettingsView()
}
