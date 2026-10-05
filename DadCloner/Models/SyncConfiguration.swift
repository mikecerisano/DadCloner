import Foundation
import DadClonerCore

/// Stores the backup configuration persistently using UserDefaults.
/// Uses volume UUIDs (not just paths) to ensure we're syncing the correct drives.
///
/// Properties are computed over UserDefaults, so each one reports its own
/// reads and writes to Observation (`tracked` / `mutate`); otherwise SwiftUI
/// would never learn that they changed.
@Observable
final class SyncConfiguration {

    // MARK: - Singleton
    static let shared = SyncConfiguration()

    // MARK: - UserDefaults Keys
    private enum Keys {
        static let isConfigured = "dadcloner.isConfigured"
        static let sourceDrivePath = "dadcloner.sourceDrivePath"
        static let sourceDriveUUID = "dadcloner.sourceDriveUUID"
        static let sourceDriveName = "dadcloner.sourceDriveName"
        static let sourceVolumeSubpath = "dadcloner.sourceVolumeSubpath"
        static let backupDrivePath = "dadcloner.backupDrivePath"
        static let backupDriveUUID = "dadcloner.backupDriveUUID"
        static let backupDriveName = "dadcloner.backupDriveName"
        static let backupVolumeSubpath = "dadcloner.backupVolumeSubpath"
        static let scheduleHour = "dadcloner.scheduleHour"
        static let scheduleMinute = "dadcloner.scheduleMinute"
        static let lastSyncDate = "dadcloner.lastSyncDate"
        static let lastSyncAttemptDate = "dadcloner.lastSyncAttemptDate"
        static let lastSyncSuccess = "dadcloner.lastSyncSuccess"
        static let lastSyncError = "dadcloner.lastSyncError"
        static let lastSyncWarning = "dadcloner.lastSyncWarning"
        static let isSchedulePaused = "dadcloner.isSchedulePaused"
    }

    // MARK: - Backup Layout

    /// This file is created on the backup drive to mark it as a valid backup destination.
    /// Prevents accidentally syncing to the wrong drive.
    static let backupMarkerFilename = BackupLayout.backupMarkerFilename

    /// Folder on backup drive where all synced data is stored
    static let backupFolderName = "DadCloner Backup"

    /// Directory on backup drive where deleted and replaced files are archived
    static let archiveDirectoryName = BackupLayout.archiveDirectoryName

    @ObservationIgnored private let defaults = UserDefaults.standard

    // MARK: - Observation plumbing

    private func tracked<T>(_ keyPath: KeyPath<SyncConfiguration, T>, _ read: () -> T) -> T {
        access(keyPath: keyPath)
        return read()
    }

    private func mutate<T>(_ keyPath: KeyPath<SyncConfiguration, T>, _ write: () -> Void) {
        withMutation(keyPath: keyPath, write)
    }

    // MARK: - Properties

    /// Whether initial setup has been completed
    var isConfigured: Bool {
        get { tracked(\.isConfigured) { defaults.bool(forKey: Keys.isConfigured) } }
        set { mutate(\.isConfigured) { defaults.set(newValue, forKey: Keys.isConfigured) } }
    }

    /// Path to source drive (e.g., "/Volumes/WorkDrive")
    var sourceDrivePath: String {
        get { tracked(\.sourceDrivePath) { defaults.string(forKey: Keys.sourceDrivePath) ?? "" } }
        set { mutate(\.sourceDrivePath) { defaults.set(newValue, forKey: Keys.sourceDrivePath) } }
    }

    /// UUID of source drive - used to verify correct drive is mounted
    var sourceDriveUUID: String {
        get { tracked(\.sourceDriveUUID) { defaults.string(forKey: Keys.sourceDriveUUID) ?? "" } }
        set { mutate(\.sourceDriveUUID) { defaults.set(newValue, forKey: Keys.sourceDriveUUID) } }
    }

    /// Human-readable name of source drive
    var sourceDriveName: String {
        get { tracked(\.sourceDriveName) { defaults.string(forKey: Keys.sourceDriveName) ?? "" } }
        set { mutate(\.sourceDriveName) { defaults.set(newValue, forKey: Keys.sourceDriveName) } }
    }

    /// Path to backup drive (e.g., "/Volumes/BackupDrive")
    var backupDrivePath: String {
        get { tracked(\.backupDrivePath) { defaults.string(forKey: Keys.backupDrivePath) ?? "" } }
        set { mutate(\.backupDrivePath) { defaults.set(newValue, forKey: Keys.backupDrivePath) } }
    }

    /// UUID of backup drive - used to verify correct drive is mounted
    var backupDriveUUID: String {
        get { tracked(\.backupDriveUUID) { defaults.string(forKey: Keys.backupDriveUUID) ?? "" } }
        set { mutate(\.backupDriveUUID) { defaults.set(newValue, forKey: Keys.backupDriveUUID) } }
    }

    /// Human-readable name of backup drive
    var backupDriveName: String {
        get { tracked(\.backupDriveName) { defaults.string(forKey: Keys.backupDriveName) ?? "" } }
        set { mutate(\.backupDriveName) { defaults.set(newValue, forKey: Keys.backupDriveName) } }
    }

    /// Hour for scheduled daily backup (0-23)
    var scheduleHour: Int {
        get { tracked(\.scheduleHour) { defaults.integer(forKey: Keys.scheduleHour) } }
        set { mutate(\.scheduleHour) { defaults.set(newValue, forKey: Keys.scheduleHour) } }
    }

    /// Minute for scheduled daily backup (0-59)
    var scheduleMinute: Int {
        get { tracked(\.scheduleMinute) { defaults.integer(forKey: Keys.scheduleMinute) } }
        set { mutate(\.scheduleMinute) { defaults.set(newValue, forKey: Keys.scheduleMinute) } }
    }

    /// Last successful sync date (nil if never synced successfully)
    var lastSyncDate: Date? {
        get { tracked(\.lastSyncDate) { defaults.object(forKey: Keys.lastSyncDate) as? Date } }
        set { mutate(\.lastSyncDate) { defaults.set(newValue, forKey: Keys.lastSyncDate) } }
    }

    /// Last sync attempt date, successful or not (nil if never attempted)
    var lastSyncAttemptDate: Date? {
        get { tracked(\.lastSyncAttemptDate) { defaults.object(forKey: Keys.lastSyncAttemptDate) as? Date } }
        set { mutate(\.lastSyncAttemptDate) { defaults.set(newValue, forKey: Keys.lastSyncAttemptDate) } }
    }

    /// Whether last sync was successful
    var lastSyncSuccess: Bool {
        get { tracked(\.lastSyncSuccess) { defaults.bool(forKey: Keys.lastSyncSuccess) } }
        set { mutate(\.lastSyncSuccess) { defaults.set(newValue, forKey: Keys.lastSyncSuccess) } }
    }

    /// Human-readable reason the last sync failed (nil after a success)
    var lastSyncError: String? {
        get { tracked(\.lastSyncError) { defaults.string(forKey: Keys.lastSyncError) } }
        set { mutate(\.lastSyncError) { defaults.set(newValue, forKey: Keys.lastSyncError) } }
    }

    /// Set when the last sync succeeded but some files couldn't be copied
    var lastSyncWarning: String? {
        get { tracked(\.lastSyncWarning) { defaults.string(forKey: Keys.lastSyncWarning) } }
        set { mutate(\.lastSyncWarning) { defaults.set(newValue, forKey: Keys.lastSyncWarning) } }
    }

    /// Whether automatic backups are paused (manual Backup Now still works)
    var isSchedulePaused: Bool {
        get { tracked(\.isSchedulePaused) { defaults.bool(forKey: Keys.isSchedulePaused) } }
        set { mutate(\.isSchedulePaused) { defaults.set(newValue, forKey: Keys.isSchedulePaused) } }
    }

    /// Path of the chosen source folder relative to its volume root ("" for
    /// the whole drive). Lets us find the drive again if macOS mounts it
    /// somewhere else, e.g. "/Volumes/Work 1".
    private var sourceVolumeSubpath: String? {
        get { defaults.string(forKey: Keys.sourceVolumeSubpath) }
        set { defaults.set(newValue, forKey: Keys.sourceVolumeSubpath) }
    }

    private var backupVolumeSubpath: String? {
        get { defaults.string(forKey: Keys.backupVolumeSubpath) }
        set { defaults.set(newValue, forKey: Keys.backupVolumeSubpath) }
    }

    // MARK: - Computed Properties

    /// Full path to the archive directory on backup drive
    var archivePath: String {
        return (backupDestinationPath as NSString).appendingPathComponent(SyncConfiguration.archiveDirectoryName)
    }

    /// Full path to the backup marker file
    var backupMarkerPath: String {
        return (backupDrivePath as NSString).appendingPathComponent(SyncConfiguration.backupMarkerFilename)
    }

    /// Full path to the backup destination folder
    var backupDestinationPath: String {
        guard !backupDrivePath.isEmpty else { return "" }
        let lastComponent = (backupDrivePath as NSString).lastPathComponent
        if lastComponent == SyncConfiguration.backupFolderName {
            return backupDrivePath
        }
        return (backupDrivePath as NSString).appendingPathComponent(SyncConfiguration.backupFolderName)
    }

    /// Formatted schedule time for display
    var scheduleTimeFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        var components = DateComponents()
        components.hour = scheduleHour
        components.minute = scheduleMinute
        if let date = Calendar.current.date(from: components) {
            return formatter.string(from: date)
        }
        return "\(scheduleHour):\(String(format: "%02d", scheduleMinute))"
    }

    /// Time since last sync, formatted for display
    var timeSinceLastSync: String {
        guard let lastSync = lastSyncDate else {
            return "Never"
        }

        let interval = Date().timeIntervalSince(lastSync)

        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
    }

    /// Whether backup is overdue (more than 25 hours since last successful sync)
    var isBackupOverdue: Bool {
        guard isConfigured else { return false }
        return BackupPolicy.isOverdue(lastSuccess: lastSyncDate, now: Date())
    }

    /// Whether an overdue catch-up sync should run now. See BackupPolicy.
    var shouldAttemptCatchUpSync: Bool {
        guard isConfigured else { return false }
        return BackupPolicy.shouldAttemptCatchUp(
            lastSuccess: lastSyncDate,
            lastAttempt: lastSyncAttemptDate,
            now: Date()
        )
    }

    // MARK: - Initialization

    private init() {
        // Set default schedule to 2:00 AM if not configured
        if !isConfigured && scheduleHour == 0 && scheduleMinute == 0 {
            scheduleHour = 2
            scheduleMinute = 0
        }
    }

    // MARK: - Configuration Methods

    /// Configure source drive
    func configureSourceDrive(path: String, uuid: String, name: String) {
        sourceDrivePath = path
        sourceDriveUUID = uuid
        sourceDriveName = name
        sourceVolumeSubpath = SyncConfiguration.volumeSubpath(of: path)
    }

    /// Configure backup drive
    func configureBackupDrive(path: String, uuid: String, name: String) {
        backupDrivePath = path
        backupDriveUUID = uuid
        backupDriveName = name
        backupVolumeSubpath = SyncConfiguration.volumeSubpath(of: path)
    }

    /// Mark configuration as complete and create backup marker file
    /// - Returns: true if marker file was created successfully
    @discardableResult
    func finalizeConfiguration() -> Bool {
        // Create the backup marker file
        let markerContent = """
        DadCloner Backup Destination
        Configured: \(Date())
        Source Drive: \(sourceDriveName) (\(sourceDriveUUID))

        WARNING: Do not delete this file. It is used to verify this is the correct backup destination.
        """

        do {
            guard ensureBackupDestinationFolder() else {
                return false
            }

            try markerContent.write(toFile: backupMarkerPath, atomically: true, encoding: .utf8)

            // Also create the archive directory
            try FileManager.default.createDirectory(atPath: archivePath, withIntermediateDirectories: true)

            isConfigured = true
            return true
        } catch {
            print("Failed to finalize configuration: \(error)")
            return false
        }
    }

    /// Reset all configuration (requires confirmation in UI)
    func resetConfiguration() {
        // Remove backup marker if accessible
        try? FileManager.default.removeItem(atPath: backupMarkerPath)

        // Clear all stored values
        let keys = [
            Keys.isConfigured,
            Keys.sourceDrivePath,
            Keys.sourceDriveUUID,
            Keys.sourceDriveName,
            Keys.sourceVolumeSubpath,
            Keys.backupDrivePath,
            Keys.backupDriveUUID,
            Keys.backupDriveName,
            Keys.backupVolumeSubpath,
            Keys.scheduleHour,
            Keys.scheduleMinute,
            Keys.lastSyncDate,
            Keys.lastSyncAttemptDate,
            Keys.lastSyncSuccess,
            Keys.lastSyncError,
            Keys.lastSyncWarning,
            Keys.isSchedulePaused
        ]

        for key in keys {
            defaults.removeObject(forKey: key)
        }

        // Tell observers everything changed
        isConfigured = false
        sourceDrivePath = ""
        backupDrivePath = ""
        clearSyncHistory()

        // Reset default schedule
        scheduleHour = 2
        scheduleMinute = 0
    }

    /// The configured drives, so a failed re-setup can put them back.
    struct DriveSelection {
        fileprivate let values: [String: Any?]
    }

    private static let driveKeys = [
        Keys.sourceDrivePath, Keys.sourceDriveUUID, Keys.sourceDriveName, Keys.sourceVolumeSubpath,
        Keys.backupDrivePath, Keys.backupDriveUUID, Keys.backupDriveName, Keys.backupVolumeSubpath,
        Keys.scheduleHour, Keys.scheduleMinute
    ]

    func currentDriveSelection() -> DriveSelection {
        DriveSelection(values: Dictionary(uniqueKeysWithValues: Self.driveKeys.map { ($0, defaults.object(forKey: $0)) }))
    }

    func restore(_ selection: DriveSelection) {
        for (key, value) in selection.values {
            defaults.set(value ?? nil, forKey: key)
        }
        // Notify observers of the restored values
        sourceDrivePath = sourceDrivePath
        backupDrivePath = backupDrivePath
        scheduleHour = scheduleHour
    }

    /// Forget sync history, e.g. after switching to a different backup
    /// drive, so a fresh, empty backup isn't reported as recently backed up.
    func clearSyncHistory() {
        lastSyncDate = nil
        lastSyncAttemptDate = nil
        lastSyncSuccess = false
        lastSyncError = nil
        lastSyncWarning = nil
    }

    // MARK: - Mount Path Reconciliation

    /// If a configured drive is mounted somewhere other than its stored
    /// path (macOS appends " 1" when a stale mount point or another drive
    /// already owns the name), follow it by UUID. Never changes which drive
    /// is configured — only where we look for it.
    /// - Returns: descriptions of any paths that changed, for logging.
    func reconcileDrivePaths(mountedVolumes: [VolumeInfo]) -> [String] {
        var changes: [String] = []

        if let newPath = reconciledPath(
            current: sourceDrivePath,
            uuid: sourceDriveUUID,
            subpath: { sourceVolumeSubpath },
            storeSubpath: { sourceVolumeSubpath = $0 },
            mountedVolumes: mountedVolumes
        ) {
            changes.append("Source drive found at \(newPath) (was \(sourceDrivePath))")
            sourceDrivePath = newPath
        }

        if let newPath = reconciledPath(
            current: backupDrivePath,
            uuid: backupDriveUUID,
            subpath: { backupVolumeSubpath },
            storeSubpath: { backupVolumeSubpath = $0 },
            mountedVolumes: mountedVolumes
        ) {
            changes.append("Backup drive found at \(newPath) (was \(backupDrivePath))")
            backupDrivePath = newPath
        }

        return changes
    }

    private func reconciledPath(
        current: String,
        uuid: String,
        subpath: () -> String?,
        storeSubpath: (String) -> Void,
        mountedVolumes: [VolumeInfo]
    ) -> String? {
        guard !current.isEmpty, !uuid.isEmpty else { return nil }

        if DriveMonitor.getVolumeUUID(at: current) == uuid {
            // Path is right. Remember its place on the volume (older
            // configs predate this) so we can follow a remount later.
            if subpath() == nil, let relative = SyncConfiguration.volumeSubpath(of: current) {
                storeSubpath(relative)
            }
            return nil
        }

        guard let relative = subpath(),
              let volume = mountedVolumes.first(where: { $0.id == uuid }) else {
            return nil
        }
        let candidate = relative.isEmpty
            ? volume.path
            : (volume.path as NSString).appendingPathComponent(relative)
        guard candidate != current,
              FileManager.default.fileExists(atPath: candidate),
              DriveMonitor.getVolumeUUID(at: candidate) == uuid else {
            return nil
        }
        return candidate
    }

    /// `path` relative to the root of the volume containing it.
    static func volumeSubpath(of path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let volumeURL = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else {
            return nil
        }
        let root = volumeURL.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(root) else { return nil }
        var relative = String(full.dropFirst(root.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    // MARK: - Finder Metadata

    private func applyBackupFolderLabel() {
        guard !backupDestinationPath.isEmpty else { return }
        var folderURL = URL(fileURLWithPath: backupDestinationPath)
        var values = URLResourceValues()
        values.labelNumber = 4 // Blue label in Finder
        try? folderURL.setResourceValues(values)
    }

    @discardableResult
    func ensureBackupDestinationFolder() -> Bool {
        guard !backupDestinationPath.isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(atPath: backupDestinationPath, withIntermediateDirectories: true)
            applyBackupFolderLabel()
            return true
        } catch {
            print("Failed to create backup folder: \(error)")
            return false
        }
    }

    /// Record a sync attempt result. `lastSyncDate` only advances on success
    /// so overdue detection and catch-up keep working across failures.
    func recordSyncResult(success: Bool, error: String? = nil, warning: String? = nil) {
        lastSyncAttemptDate = Date()
        if success {
            lastSyncDate = Date()
        }
        lastSyncSuccess = success
        lastSyncError = success ? nil : error
        lastSyncWarning = success ? warning : nil
    }
}
