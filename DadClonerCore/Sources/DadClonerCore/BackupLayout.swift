import Foundation

/// Names DadCloner uses on the backup drive, and the entries it never
/// copies or archives. Single source of truth for both the rsync excludes
/// and the orphan scanner, so the two can't drift apart.
public enum BackupLayout {

    /// Folder (inside the backup destination) holding archived files.
    public static let archiveDirectoryName = "DadCloner_Archive"

    /// Marker file identifying a drive as a DadCloner backup destination.
    public static let backupMarkerFilename = ".dadcloner_backup"

    /// Entry names skipped at any depth: our own metadata plus macOS
    /// volume bookkeeping. Hidden *user* files are intentionally not here —
    /// rsync copies them, so they must be archived too.
    public static let excludedNames: Set<String> = [
        archiveDirectoryName,
        backupMarkerFilename,
        ".DS_Store",
        ".Spotlight-V100",
        ".fseventsd",
        ".Trashes",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
        ".PKInstallSandboxManager-SystemSoftware"
    ]
}
