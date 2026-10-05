import Foundation

/// Pure date math for the backup schedule. All functions take `now`
/// explicitly so behavior is deterministic under test.
public enum BackupPolicy {

    /// A backup is overdue when the last success is older than this.
    public static let overdueInterval: TimeInterval = 25 * 3600

    /// Minimum spacing between automatic attempts while failing.
    public static let retryInterval: TimeInterval = 3600

    public static func isOverdue(lastSuccess: Date?, now: Date) -> Bool {
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > overdueInterval
    }

    public static func shouldAttemptCatchUp(lastSuccess: Date?, lastAttempt: Date?, now: Date) -> Bool {
        guard isOverdue(lastSuccess: lastSuccess, now: now) else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) > retryInterval
    }

    /// Archiving at least this many files at once needs the user's OK.
    public static let massArchiveFileCount = 1000
    /// ...as does archiving at least this fraction of the backup
    /// (once at least `massArchiveMinimumCount` files are involved).
    public static let massArchiveFraction = 0.25
    public static let massArchiveMinimumCount = 50

    /// Whether this many orphans looks less like normal housekeeping and
    /// more like an unreadable or wrong source (a dying drive, a permission
    /// problem) or a large reorganization the user should confirm.
    public static func isMassArchive(orphaned: Int, scanned: Int) -> Bool {
        if orphaned >= massArchiveFileCount { return true }
        guard orphaned >= massArchiveMinimumCount, scanned > 0 else { return false }
        return Double(orphaned) / Double(scanned) >= massArchiveFraction
    }

    /// The next time the daily schedule occurs strictly after `date`.
    public static func nextOccurrence(hour: Int, minute: Int, after date: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let today = calendar.date(from: components) else { return nil }
        if today > date {
            return today
        }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }
}
