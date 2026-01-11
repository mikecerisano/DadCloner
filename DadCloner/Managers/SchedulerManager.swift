import Foundation
import UserNotifications

/// Manages scheduled daily backups
@Observable
final class SchedulerManager {

    // MARK: - Singleton
    static let shared = SchedulerManager()

    // MARK: - Properties
    private(set) var isScheduleEnabled: Bool = true
    private(set) var nextScheduledSync: Date?

    private var timer: Timer?
    private let config = SyncConfiguration.shared
    private let syncManager = SyncManager.shared
    private let logger = SyncLogger.shared

    // MARK: - Initialization
    private init() {
        updateNextScheduledSync()
    }

    // MARK: - Schedule Management

    /// Start the scheduler
    func start() {
        guard config.isConfigured else {
            logger.warning("Cannot start scheduler - not configured")
            return
        }

        isScheduleEnabled = true
        scheduleNextSync()
        logger.info("Scheduler started - next sync at \(config.scheduleTimeFormatted)")
    }

    /// Stop the scheduler
    func stop() {
        timer?.invalidate()
        timer = nil
        isScheduleEnabled = false
        nextScheduledSync = nil
        logger.info("Scheduler stopped")
    }

    /// Update the schedule time
    func updateSchedule(hour: Int, minute: Int) {
        config.scheduleHour = hour
        config.scheduleMinute = minute

        // Reschedule if active
        if isScheduleEnabled {
            scheduleNextSync()
        }

        updateNextScheduledSync()
        logger.info("Schedule updated to \(config.scheduleTimeFormatted)")
    }

    // MARK: - Scheduling Logic

    private func scheduleNextSync() {
        // Cancel existing timer
        timer?.invalidate()

        // Calculate next sync time
        guard let nextSync = calculateNextSyncTime() else {
            logger.error("Could not calculate next sync time")
            return
        }

        nextScheduledSync = nextSync

        // Create timer
        let interval = nextSync.timeIntervalSinceNow
        guard interval > 0 else {
            // If time has passed today, schedule for tomorrow
            if let tomorrowSync = calculateNextSyncTime(forTomorrow: true) {
                nextScheduledSync = tomorrowSync
                let tomorrowInterval = tomorrowSync.timeIntervalSinceNow
                timer = Timer.scheduledTimer(withTimeInterval: tomorrowInterval, repeats: false) { [weak self] _ in
                    self?.performScheduledSync()
                }
            }
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.performScheduledSync()
        }

        // Make sure timer runs even when menu is open
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func calculateNextSyncTime(forTomorrow: Bool = false) -> Date? {
        var components = DateComponents()
        components.hour = config.scheduleHour
        components.minute = config.scheduleMinute
        components.second = 0

        let calendar = Calendar.current

        if forTomorrow {
            // Get tomorrow's date
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) else {
                return nil
            }
            let tomorrowComponents = calendar.dateComponents([.year, .month, .day], from: tomorrow)
            components.year = tomorrowComponents.year
            components.month = tomorrowComponents.month
            components.day = tomorrowComponents.day
        } else {
            // Get today's date
            let todayComponents = calendar.dateComponents([.year, .month, .day], from: Date())
            components.year = todayComponents.year
            components.month = todayComponents.month
            components.day = todayComponents.day
        }

        return calendar.date(from: components)
    }

    private func updateNextScheduledSync() {
        guard config.isConfigured else {
            nextScheduledSync = nil
            return
        }

        if let next = calculateNextSyncTime() {
            if next.timeIntervalSinceNow > 0 {
                nextScheduledSync = next
            } else {
                nextScheduledSync = calculateNextSyncTime(forTomorrow: true)
            }
        }
    }

    // MARK: - Sync Execution

    private func performScheduledSync() {
        logger.info("Starting scheduled sync...")

        Task { @MainActor in
            let success = await syncManager.performSync()

            if success {
                logger.success("Scheduled sync completed successfully")
            } else {
                logger.error("Scheduled sync failed")
            }

            // Schedule next sync
            scheduleNextSync()
        }
    }

    // MARK: - Manual Sync

    /// Trigger a manual sync
    @MainActor
    func triggerManualSync() async -> Bool {
        logger.info("Manual sync triggered")
        return await syncManager.performSync()
    }

    // MARK: - Status

    /// Human-readable description of next sync time
    var nextSyncDescription: String {
        guard let next = nextScheduledSync else {
            return "Not scheduled"
        }

        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(next) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if calendar.isDateInTomorrow(next) {
            formatter.dateFormat = "'Tomorrow at' h:mm a"
        } else {
            formatter.dateFormat = "EEEE 'at' h:mm a"
        }

        return formatter.string(from: next)
    }

    /// Time until next sync, formatted
    var timeUntilNextSync: String {
        guard let next = nextScheduledSync else {
            return "N/A"
        }

        let interval = next.timeIntervalSinceNow
        guard interval > 0 else {
            return "Now"
        }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
