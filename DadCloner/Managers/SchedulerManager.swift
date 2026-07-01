import Foundation
import AppKit
import UserNotifications

/// Manages scheduled daily backups.
///
/// Uses a repeating once-a-minute tick that fires the sync when the scheduled
/// time has passed, rather than a one-shot timer aimed at the exact moment.
/// A timer can't wake a sleeping Mac, so the tick plus a wake observer means
/// a backup missed during sleep starts as soon as the Mac wakes.
@Observable
final class SchedulerManager {

    // MARK: - Singleton
    static let shared = SchedulerManager()

    // MARK: - Properties
    private(set) var isScheduleEnabled: Bool = true
    private(set) var nextScheduledSync: Date?

    private var tickTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
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
        updateNextScheduledSync()
        startTickTimer()
        observeWake()
        logger.info("Scheduler started - next sync at \(config.scheduleTimeFormatted)")

        runCatchUpIfNeeded(reason: "app launch")
    }

    /// Stop the scheduler
    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        isScheduleEnabled = false
        nextScheduledSync = nil
        logger.info("Scheduler stopped")
    }

    /// Update the schedule time
    func updateSchedule(hour: Int, minute: Int) {
        config.scheduleHour = hour
        config.scheduleMinute = minute
        updateNextScheduledSync()
        logger.info("Schedule updated to \(config.scheduleTimeFormatted)")
    }

    // MARK: - Scheduling Logic

    private func startTickTimer() {
        tickTimer?.invalidate()

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 10
        // .common so the timer keeps firing while the menu bar popover is open
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("Mac woke from sleep - checking backup schedule")
            self?.tick()
        }
    }

    private func tick() {
        guard isScheduleEnabled, config.isConfigured else { return }

        guard let next = nextScheduledSync else {
            updateNextScheduledSync()
            return
        }

        if Date() >= next {
            performScheduledSync()
        } else {
            runCatchUpIfNeeded(reason: "overdue backup")
        }
    }

    /// The next time the configured schedule occurs strictly after `date`.
    private func nextOccurrence(after date: Date) -> Date? {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = config.scheduleHour
        components.minute = config.scheduleMinute
        components.second = 0

        guard let today = calendar.date(from: components) else { return nil }
        if today > date {
            return today
        }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    private func updateNextScheduledSync() {
        guard config.isConfigured else {
            nextScheduledSync = nil
            return
        }
        nextScheduledSync = nextOccurrence(after: Date())
    }

    // MARK: - Sync Execution

    private func performScheduledSync() {
        // Advance the schedule first so ticks during the sync don't refire
        nextScheduledSync = nextOccurrence(after: Date())

        guard !syncManager.status.isRunning else { return }
        logger.info("Starting scheduled sync...")

        Task { @MainActor in
            let success = await syncManager.performSync()

            if success {
                logger.success("Scheduled sync completed successfully")
            } else {
                logger.error("Scheduled sync failed")
            }
        }
    }

    /// Run a sync now if the backup is overdue, the drives are ready, and we
    /// haven't attempted one within the last hour (see `shouldAttemptCatchUpSync`).
    private func runCatchUpIfNeeded(reason: String) {
        guard isScheduleEnabled, config.isConfigured else { return }
        guard !syncManager.status.isRunning else { return }

        DriveMonitor.shared.refreshMountedVolumes()
        guard config.shouldAttemptCatchUpSync, DriveMonitor.shared.areDrivesReady else { return }

        logger.info("Backup is overdue and drives are ready; starting catch-up sync (\(reason))")
        Task { @MainActor in
            _ = await syncManager.performSync()
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
