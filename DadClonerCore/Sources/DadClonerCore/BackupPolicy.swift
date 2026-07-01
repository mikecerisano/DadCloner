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
