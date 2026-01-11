import SwiftUI
import AppKit
import UserNotifications

/// Initial setup wizard for configuring backup drives
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var currentStep: SetupStep = .welcome
    @State private var sourceVolume: VolumeInfo?
    @State private var backupVolume: VolumeInfo?
    @State private var scheduleHour: Int = 2
    @State private var scheduleMinute: Int = 0
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isFinishing: Bool = false

    private let driveMonitor = DriveMonitor.shared
    private let config = SyncConfiguration.shared

    enum SetupStep: Int, CaseIterable {
        case welcome
        case selectSource
        case selectBackup
        case schedule
        case confirm
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            progressIndicator
                .padding(.top, 20)
                .padding(.bottom, 10)

            Divider()

            // Content area
            Group {
                switch currentStep {
                case .welcome:
                    welcomeStep
                case .selectSource:
                    selectSourceStep
                case .selectBackup:
                    selectBackupStep
                case .schedule:
                    scheduleStep
                case .confirm:
                    confirmStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation buttons
            navigationButtons
                .padding(20)
        }
        .frame(width: 500, height: 450)
        .alert("Setup Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            driveMonitor.refreshMountedVolumes()
            requestNotificationPermission()
        }
    }

    // MARK: - Permissions

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                print("Notification permission granted")
            } else if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    // MARK: - Progress Indicator

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                Circle()
                    .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 10, height: 10)

                if step != SetupStep.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                        .frame(maxWidth: 40)
                }
            }
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
                .padding(.top, 30)

            Text("Welcome to DadCloner")
                .font(.title)
                .fontWeight(.bold)

            Text("This app will keep your backup drive in sync with your main work drive.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "arrow.triangle.2.circlepath", text: "Automatic daily backups")
                featureRow(icon: "archivebox", text: "Deleted files are safely archived")
                featureRow(icon: "shield.checkered", text: "Never loses your data")
            }
            .padding(.top, 20)

            Spacer()
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(text)
        }
    }

    // MARK: - Select Source Step

    private var selectSourceStep: some View {
        VStack(spacing: 20) {
            Text("Select Your Main Work Drive")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)

            Text("This is the drive with your important files that you want to back up.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            if sourceVolume != nil {
                selectedDriveCard(volume: sourceVolume!, isSource: true)
            } else {
                emptyDriveCard(isSource: true)
            }

            Button(action: selectSourceDrive) {
                Label(sourceVolume == nil ? "Select Drive" : "Change Drive", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)

            if !availableVolumes(excludingSource: false).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available Drives:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(availableVolumes(excludingSource: false)) { volume in
                        driveListRow(volume: volume) {
                            sourceVolume = volume
                        }
                    }
                }
                .padding(.horizontal, 40)
            }

            Spacer()
        }
    }

    // MARK: - Select Backup Step

    private var selectBackupStep: some View {
        VStack(spacing: 20) {
            Text("Select Your Backup Drive")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)

            Text("This is where your files will be backed up to. Make sure it has enough space!")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)
            Text("DadCloner will create a \"DadCloner Backup\" folder on this drive and store everything inside it.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            if backupVolume != nil {
                selectedDriveCard(volume: backupVolume!, isSource: false)
            } else {
                emptyDriveCard(isSource: false)
            }

            Button(action: selectBackupDrive) {
                Label(backupVolume == nil ? "Select Drive" : "Change Drive", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)

            if !availableVolumes(excludingSource: true).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available Drives:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(availableVolumes(excludingSource: true)) { volume in
                        driveListRow(volume: volume) {
                            backupVolume = volume
                        }
                    }
                }
                .padding(.horizontal, 40)
            }

            Spacer()
        }
    }

    // MARK: - Schedule Step

    private var scheduleStep: some View {
        VStack(spacing: 20) {
            Text("Set Backup Schedule")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)

            Text("When should DadCloner automatically back up your files?")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)

            HStack(spacing: 20) {
                Picker("Hour", selection: $scheduleHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(formatHour(hour)).tag(hour)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)

                Text(":")
                    .font(.title2)

                Picker("Minute", selection: $scheduleMinute) {
                    ForEach([0, 15, 30, 45], id: \.self) { minute in
                        Text(String(format: "%02d", minute)).tag(minute)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
            }
            .padding(.top, 20)

            Text("We recommend early morning (like 2:00 AM) when you're not using the computer.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 10)

            Spacer()
        }
    }

    private func formatHour(_ hour: Int) -> String {
        if hour == 0 {
            return "12 AM"
        } else if hour < 12 {
            return "\(hour) AM"
        } else if hour == 12 {
            return "12 PM"
        } else {
            return "\(hour - 12) PM"
        }
    }

    // MARK: - Confirm Step

    private var confirmStep: some View {
        VStack(spacing: 20) {
            Text("Confirm Setup")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "externaldrive")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading) {
                        Text("Source Drive")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(sourceVolume?.name ?? "Not selected")
                            .fontWeight(.medium)
                    }
                }

                HStack {
                    Image(systemName: "externaldrive.badge.checkmark")
                        .foregroundColor(.green)
                    VStack(alignment: .leading) {
                        Text("Backup Drive")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(backupVolume?.name ?? "Not selected")
                            .fontWeight(.medium)
                    }
                }

                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading) {
                        Text("Daily Backup")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(formatHour(scheduleHour)):\(String(format: "%02d", scheduleMinute))")
                            .fontWeight(.medium)
                    }
                }
            }
            .padding(20)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal, 40)

            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("Once configured, these settings cannot be easily changed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Make sure you've selected the correct drives!")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 10)

            Spacer()
        }
    }

    // MARK: - Drive Cards

    private func selectedDriveCard(volume: VolumeInfo, isSource: Bool) -> some View {
        HStack {
            Image(systemName: isSource ? "externaldrive" : "externaldrive.badge.checkmark")
                .font(.largeTitle)
                .foregroundColor(isSource ? .blue : .green)

            VStack(alignment: .leading, spacing: 4) {
                Text(volume.name)
                    .fontWeight(.semibold)
                Text(volume.formattedSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !isSource {
                    Text("\(volume.formattedFreeSpace) free")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal, 40)
    }

    private func emptyDriveCard(isSource: Bool) -> some View {
        HStack {
            Image(systemName: isSource ? "externaldrive" : "externaldrive.badge.plus")
                .font(.largeTitle)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(isSource ? "No source drive selected" : "No backup drive selected")
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5]))
                .foregroundColor(.secondary.opacity(0.3))
        )
        .padding(.horizontal, 40)
    }

    private func driveListRow(volume: VolumeInfo, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: "externaldrive")
                    .foregroundColor(.secondary)
                Text(volume.name)
                Spacer()
                Text(volume.formattedSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    withAnimation {
                        if let prev = SetupStep(rawValue: currentStep.rawValue - 1) {
                            currentStep = prev
                        }
                    }
                }
            }

            Spacer()

            if currentStep == .confirm {
                Button(action: finishSetup) {
                    if isFinishing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Finish Setup")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFinishing)
            } else {
                Button("Continue") {
                    if validateCurrentStep() {
                        withAnimation {
                            if let next = SetupStep(rawValue: currentStep.rawValue + 1) {
                                currentStep = next
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
            }
        }
    }

    private var canContinue: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .selectSource:
            return sourceVolume != nil
        case .selectBackup:
            return backupVolume != nil
        case .schedule:
            return true
        case .confirm:
            return sourceVolume != nil && backupVolume != nil
        }
    }

    private func validateCurrentStep() -> Bool {
        switch currentStep {
        case .selectSource:
            guard let source = sourceVolume else {
                showError(message: "Please select a source drive")
                return false
            }
            // Validate source is readable
            if !FileManager.default.isReadableFile(atPath: source.path) {
                showError(message: "Cannot read from selected source drive")
                return false
            }
            return true

        case .selectBackup:
            guard let backup = backupVolume else {
                showError(message: "Please select a backup drive")
                return false
            }
            // Validate backup is writable
            if !backup.isWritable {
                showError(message: "Backup drive is not writable")
                return false
            }
            // Check it's different from source
            if backup.id == sourceVolume?.id {
                showError(message: "Backup drive must be different from source drive")
                return false
            }
            return true

        default:
            return true
        }
    }

    // MARK: - Actions

    private func selectSourceDrive() {
        let panel = NSOpenPanel()
        panel.title = "Select Source Drive"
        panel.message = "Choose the drive containing your files to back up"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")

        if panel.runModal() == .OK, let url = panel.url {
            if let volume = DriveMonitor.getVolumeInfo(at: url.path) {
                sourceVolume = volume
            } else {
                showError(message: "Could not get volume information for selected drive")
            }
        }
    }

    private func selectBackupDrive() {
        let panel = NSOpenPanel()
        panel.title = "Select Backup Drive"
        panel.message = "Choose the drive to store backups"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")

        if panel.runModal() == .OK, let url = panel.url {
            if let volume = DriveMonitor.getVolumeInfo(at: url.path) {
                if volume.id == sourceVolume?.id {
                    showError(message: "Backup drive must be different from source drive")
                } else if !volume.isWritable {
                    showError(message: "Selected drive is not writable")
                } else {
                    backupVolume = volume
                }
            } else {
                showError(message: "Could not get volume information for selected drive")
            }
        }
    }

    private func availableVolumes(excludingSource: Bool) -> [VolumeInfo] {
        driveMonitor.mountedVolumes.filter { volume in
            // Exclude source volume if requested
            if excludingSource, let source = sourceVolume, volume.id == source.id {
                return false
            }
            // Only show writable volumes for backup
            return volume.isWritable
        }
    }

    private func finishSetup() {
        guard let source = sourceVolume, let backup = backupVolume else {
            showError(message: "Please select both drives")
            return
        }

        isFinishing = true

        // Configure the sync
        config.configureSourceDrive(path: source.path, uuid: source.id, name: source.name)
        config.configureBackupDrive(path: backup.path, uuid: backup.id, name: backup.name)
        config.scheduleHour = scheduleHour
        config.scheduleMinute = scheduleMinute

        // Finalize (creates marker file and archive directory)
        if config.finalizeConfiguration() {
            // Start the scheduler
            SchedulerManager.shared.start()

            // Enable launch at login so dad doesn't have to think about it
            LaunchAtLogin.shared.enable()

            // Close the setup window
            dismiss()
        } else {
            showError(message: "Failed to complete setup. Please try again.")
            isFinishing = false
        }
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}

#Preview {
    SetupView()
}
