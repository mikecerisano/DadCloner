import Foundation

/// Builds the rsync argument list. Pure; no I/O.
public enum RsyncCommand {

    /// Arguments for mirroring `source` into `destination`.
    ///
    /// Never deletes from the destination (no `--delete`). Files the run
    /// would overwrite are moved into `replacedDir` first (`--backup`), so
    /// a corrupted or accidentally saved-over source file can't destroy the
    /// last good copy.
    public static func arguments(source: String, destination: String, replacedDir: String) -> [String] {
        var args = [
            "-a",                    // archive: recursive, perms, times, symlinks
            "-X",                    // extended attributes, incl. resource forks & Finder info
            "--crtimes",             // creation dates
            "--one-file-system",     // never wander into other mounted volumes
            "-v",
            "--itemize-changes",
            "--info=progress2",
            "--backup",
            "--backup-dir=\(replacedDir)"
        ]
        for name in BackupLayout.excludedNames.sorted() {
            args += ["--exclude", name]
        }
        args.append(withTrailingSlash(source))
        args.append(withTrailingSlash(destination))
        return args
    }

    /// Arguments for a dry run that reports what would change plus stats.
    public static func dryRunArguments(source: String, destination: String, replacedDir: String) -> [String] {
        ["--dry-run", "--stats"] + arguments(source: source, destination: destination, replacedDir: replacedDir)
    }

    /// Per-run folder (inside the archive) that receives overwritten files.
    public static func replacedFolder(archiveRoot: String, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'replaced' HH.mm.ss"
        return (archiveRoot as NSString).appendingPathComponent(formatter.string(from: now))
    }

    private static func withTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }
}

/// How an rsync exit status should be treated.
public enum RsyncOutcome: Equatable {
    case success
    /// Finished, but some files couldn't be transferred (exit 23) or
    /// vanished mid-run (exit 24). Everything else was copied.
    case partial
    case failure

    public init(exitCode: Int32) {
        switch exitCode {
        case 0: self = .success
        case 23, 24: self = .partial
        default: self = .failure
        }
    }
}
