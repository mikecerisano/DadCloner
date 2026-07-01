import SwiftUI
import AppKit

/// Post-setup settings: change the schedule, pause automatic backups,
/// toggle launch at login, or re-run drive selection. Before this view
/// existed, the only way to change anything was the destructive Reset.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var config = SyncConfiguration.shared
    @State private var scheduler = SchedulerManager.shared
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
                        scheduler.updateSchedule(
                            hour: components.hour ?? 2,
                            minute: components.minute ?? 0
                        )
                    }

                    Toggle("Pause automatic backups", isOn: Binding(
                        get: { config.isSchedulePaused },
                        set: { scheduler.setPaused($0) }
                    ))

                    Toggle("Start at login", isOn: Binding(
                        get: { LaunchAtLogin.shared.isEnabled },
                        set: { LaunchAtLogin.shared.isEnabled = $0 }
                    ))
                }

                Section("Drives") {
                    LabeledContent("Source", value: config.sourceDriveName)
                    LabeledContent("Backup", value: config.backupDriveName)

                    Button("Change Drives…") {
                        dismiss()
                        (NSApp.delegate as? AppDelegate)?.showSetupWindow()
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 380, height: 340)
        .onAppear {
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
