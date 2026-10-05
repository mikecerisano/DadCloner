import Foundation
import AppKit
import UserNotifications
import DadClonerCore

/// Manages scheduled daily backups.
///
/// Uses a repeating once-a-minute tick that fires the sync when the scheduled
/// time has passed, rather than a one-shot timer aimed at the exact moment.
/// A timer can't wake a sleeping Mac, so the tick plus a wake observer means
/// a backup missed during sleep starts as soon as the Mac wakes.
///
/// If the drives aren't connected at the scheduled time, the run is
/// deferred (no failure, no alert) and starts once they're plugged in.
@MainActor
@Observable
final class SchedulerManager {

    // MARK: - Singleton
    static let shared = SchedulerManager()

    // MARK: - Properties
    private(set) var isScheduleEnabled: Bool = true
    private(set) var nextScheduledSync: Date?

    /// A scheduled run came due while the drives were disconnected.
    @ObservationIgnored private var deferredScheduledSync = false

    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private let config = SyncConfiguration.shared
    @ObservationIgnored private let syncManager = SyncManager.shared
    @ObservationIgnored private let logger = SyncLogger.shared

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

        guard !config.isSchedulePaused else {
            isScheduleEnabled = false
            logger.info("Scheduler not started - automatic backups are paused")
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
        deferredScheduledSync = false
        logger.info("Scheduler stopped")
    }

    /// Update the schedule time
    func updateSchedule(hour: Int, minute: Int) {
        config.scheduleHour = hour
        config.scheduleMinute = minute
        updateNextScheduledSync()
        logger.info("Schedule updated to \(config.scheduleTimeFormatted)")
    }

    /// Pause or resume automatic backups. Manual syncs are unaffected.
    func setPaused(_ paused: Bool) {
        config.isSchedulePaused = paused
        if paused {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Scheduling Logic

    private func startTickTimer() {
        tickTimer?.invalidate()

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
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
            MainActor.assumeIsolated {
                self?.logger.info("Mac woke from sleep - checking backup schedule")
                self?.tick()
            }
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
        } else if deferredScheduledSync {
            runDeferredSyncIfReady()
        } else {
            runCatchUpIfNeeded(reason: "overdue backup")
        }
    }

    /// The next time the configured schedule occurs strictly after `date`.
    private func nextOccurrence(after date: Date) -> Date? {
        BackupPolicy.nextOccurrence(
            hour: config.scheduleHour,
            minute: config.scheduleMinute,
            after: date,
            calendar: Calendar.current
        )
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

        // Defer only when a drive is simply unplugged. Any other problem
        // (wrong drive, missing marker, read-only) runs the sync so it fails
        // with a clear reason and a notification.
        let drives = DriveMonitor.shared
        drives.refreshMountedVolumes()
        guard drives.sourceStatus != .notMounted, drives.backupStatus != .notMounted else {
            deferredScheduledSync = true
            logger.info("Scheduled backup deferred - drives not ready (\(DriveMonitor.shared.statusMessage)). It will run when they are.")
            return
        }

        deferredScheduledSync = false
        logger.info("Starting scheduled sync...")

        Task {
            let success = await syncManager.performSync()

            if success {
                logger.success("Scheduled sync completed successfully")
            } else {
                logger.error("Scheduled sync failed")
            }
        }
    }

    /// Start a deferred scheduled sync once both drives are back.
    private func runDeferredSyncIfReady() {
        guard !syncManager.status.isRunning else { return }
        DriveMonitor.shared.refreshMountedVolumes()
        guard DriveMonitor.shared.areDrivesReady else { return }

        deferredScheduledSync = false
        logger.info("Drives are back; running the deferred scheduled sync")
        Task {
            _ = await syncManager.performSync()
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
        Task {
            _ = await syncManager.performSync()
        }
    }

    // MARK: - Manual Sync

    /// Trigger a manual sync
    func triggerManualSync(confirmedMassArchiveCount: Int? = nil) async -> Bool {
        if let count = confirmedMassArchiveCount {
            logger.info("Manual sync triggered (archiving \(count) files confirmed)")
        } else {
            logger.info("Manual sync triggered")
        }
        let success = await syncManager.performSync(confirmedMassArchiveCount: confirmedMassArchiveCount)
        if success {
            deferredScheduledSync = false
        }
        return success
    }

    // MARK: - Status

    /// Human-readable description of next sync time
    var nextSyncDescription: String {
        if config.isSchedulePaused {
            return "Paused"
        }

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
