import Foundation

/// Stores the backup configuration persistently using UserDefaults.
/// Uses volume UUIDs (not just paths) to ensure we're syncing the correct drives.
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
        static let backupDrivePath = "dadcloner.backupDrivePath"
        static let backupDriveUUID = "dadcloner.backupDriveUUID"
        static let backupDriveName = "dadcloner.backupDriveName"
        static let scheduleHour = "dadcloner.scheduleHour"
        static let scheduleMinute = "dadcloner.scheduleMinute"
        static let lastSyncDate = "dadcloner.lastSyncDate"
        static let lastSyncSuccess = "dadcloner.lastSyncSuccess"
    }

    // MARK: - Backup Marker
    /// This file is created on the backup drive to mark it as a valid backup destination.
    /// Prevents accidentally syncing to the wrong drive.
    static let backupMarkerFilename = ".dadcloner_backup"

    // MARK: - Backup Destination Folder
    /// Folder on backup drive where all synced data is stored
    static let backupFolderName = "DadCloner Backup"

    // MARK: - Archive Directory
    /// Directory on backup drive where deleted files are archived
    static let archiveDirectoryName = "DadCloner_Archive"

    // MARK: - Properties

    /// Whether initial setup has been completed
    var isConfigured: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.isConfigured) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.isConfigured) }
    }

    /// Path to source drive (e.g., "/Volumes/WorkDrive")
    var sourceDrivePath: String {
        get { UserDefaults.standard.string(forKey: Keys.sourceDrivePath) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sourceDrivePath) }
    }

    /// UUID of source drive - used to verify correct drive is mounted
    var sourceDriveUUID: String {
        get { UserDefaults.standard.string(forKey: Keys.sourceDriveUUID) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sourceDriveUUID) }
    }

    /// Human-readable name of source drive
    var sourceDriveName: String {
        get { UserDefaults.standard.string(forKey: Keys.sourceDriveName) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sourceDriveName) }
    }

    /// Path to backup drive (e.g., "/Volumes/BackupDrive")
    var backupDrivePath: String {
        get { UserDefaults.standard.string(forKey: Keys.backupDrivePath) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.backupDrivePath) }
    }

    /// UUID of backup drive - used to verify correct drive is mounted
    var backupDriveUUID: String {
        get { UserDefaults.standard.string(forKey: Keys.backupDriveUUID) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.backupDriveUUID) }
    }

    /// Human-readable name of backup drive
    var backupDriveName: String {
        get { UserDefaults.standard.string(forKey: Keys.backupDriveName) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.backupDriveName) }
    }

    /// Hour for scheduled daily backup (0-23)
    var scheduleHour: Int {
        get { UserDefaults.standard.integer(forKey: Keys.scheduleHour) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.scheduleHour) }
    }

    /// Minute for scheduled daily backup (0-59)
    var scheduleMinute: Int {
        get { UserDefaults.standard.integer(forKey: Keys.scheduleMinute) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.scheduleMinute) }
    }

    /// Last sync date (nil if never synced)
    var lastSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: Keys.lastSyncDate) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastSyncDate) }
    }

    /// Whether last sync was successful
    var lastSyncSuccess: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.lastSyncSuccess) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastSyncSuccess) }
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

    /// Whether backup is overdue (more than 25 hours since last sync)
    var isBackupOverdue: Bool {
        guard let lastSync = lastSyncDate else {
            return isConfigured // Overdue if configured but never synced
        }
        return Date().timeIntervalSince(lastSync) > 25 * 3600
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

    /// Configure source drive with validation
    /// - Parameters:
    ///   - path: Path to the drive
    ///   - uuid: Volume UUID
    ///   - name: Display name
    func configureSourceDrive(path: String, uuid: String, name: String) {
        sourceDrivePath = path
        sourceDriveUUID = uuid
        sourceDriveName = name
    }

    /// Configure backup drive with validation
    /// - Parameters:
    ///   - path: Path to the drive
    ///   - uuid: Volume UUID
    ///   - name: Display name
    func configureBackupDrive(path: String, uuid: String, name: String) {
        backupDrivePath = path
        backupDriveUUID = uuid
        backupDriveName = name
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
            Keys.backupDrivePath,
            Keys.backupDriveUUID,
            Keys.backupDriveName,
            Keys.scheduleHour,
            Keys.scheduleMinute,
            Keys.lastSyncDate,
            Keys.lastSyncSuccess
        ]

        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Reset default schedule
        scheduleHour = 2
        scheduleMinute = 0
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

    /// Record a sync attempt result
    func recordSyncResult(success: Bool) {
        lastSyncDate = Date()
        lastSyncSuccess = success
    }
}
