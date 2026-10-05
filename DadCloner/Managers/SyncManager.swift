import Foundation
import UserNotifications
import DadClonerCore

/// Sync operation status
enum SyncStatus: Equatable {
    case idle
    case validating
    case scanning
    case archiving
    case syncing
    case finishing
    case failed(String)
    case completed

    var isRunning: Bool {
        switch self {
        case .idle, .failed, .completed:
            return false
        default:
            return true
        }
    }

    var displayText: String {
        switch self {
        case .idle:
            return "Ready"
        case .validating:
            return "Validating drives..."
        case .scanning:
            return "Checking for changes..."
        case .archiving:
            return "Archiving deleted files..."
        case .syncing:
            return "Syncing files..."
        case .finishing:
            return "Finishing up..."
        case .failed(let message):
            return "Failed: \(message)"
        case .completed:
            return "Completed"
        }
    }
}

/// A sync stopped because an unusually large number of backed-up files
/// are missing from the source. The user must confirm before they move.
struct MassArchiveRequest: Equatable {
    let orphanedCount: Int
    let scannedCount: Int
}

/// Core sync manager - handles all backup operations with safety checks.
///
/// Main-actor isolated: all observable state is mutated on the main thread.
/// Long filesystem walks run in detached tasks and hand back plain values.
@MainActor
@Observable
final class SyncManager {

    // MARK: - Singleton
    static let shared = SyncManager()

    // MARK: - Properties
    private(set) var status: SyncStatus = .idle {
        didSet {
            NotificationCenter.default.post(name: .dadClonerSyncStatusDidChange, object: nil)
        }
    }
    private(set) var currentProgress: Double = 0
    private(set) var filesProcessed: Int = 0
    private(set) var filesArchived: Int = 0
    private(set) var currentFile: String = ""

    /// Set when the last sync stopped for mass-archive confirmation.
    private(set) var pendingMassArchive: MassArchiveRequest?

    /// Lock file to prevent concurrent syncs
    @ObservationIgnored private var lockFileHandle: FileHandle?
    private var lockFilePath: String {
        let tempDir = NSTemporaryDirectory()
        return (tempDir as NSString).appendingPathComponent("dadcloner.lock")
    }

    @ObservationIgnored private var currentProcess: Process?
    @ObservationIgnored private var isCancelling = false
    @ObservationIgnored private var runWhenIdle: [() -> Void] = []

    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private let logger = SyncLogger.shared
    @ObservationIgnored private let config = SyncConfiguration.shared
    @ObservationIgnored private let driveMonitor = DriveMonitor.shared

    /// Configuration captured at the start of a sync, so changing drives
    /// (or resetting) mid-run can't redirect a sync that's already going.
    private struct SyncPaths {
        let source: String
        let sourceUUID: String
        let sourceName: String
        let backupDrive: String
        let backupUUID: String
        let backupName: String
        let destination: String
        let archive: String
        let marker: String
    }

    // MARK: - Initialization
    private init() {}

    // MARK: - Main Sync Operation

    /// Perform a full sync operation.
    /// - Parameter confirmedMassArchiveCount: the user confirmed archiving
    ///   this many files (see `MassArchiveRequest`). A noticeably larger
    ///   count found now still needs a fresh confirmation.
    func performSync(confirmedMassArchiveCount: Int? = nil) async -> Bool {
        // Prevent concurrent syncs
        guard !status.isRunning else {
            logger.warning("Sync already in progress, skipping")
            return false
        }

        // Try to acquire lock
        guard acquireLock() else {
            logger.error("Could not acquire sync lock - another sync may be in progress")
            status = .failed("Another sync is in progress")
            return false
        }

        defer {
            releaseLock()
        }

        // Keep the Mac from idle-sleeping (and the app from being napped)
        // while a long copy is running.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Backing up files"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // Refresh first: this may follow a remounted drive to its new path.
        driveMonitor.refreshMountedVolumes()

        let paths = SyncPaths(
            source: config.sourceDrivePath,
            sourceUUID: config.sourceDriveUUID,
            sourceName: config.sourceDriveName,
            backupDrive: config.backupDrivePath,
            backupUUID: config.backupDriveUUID,
            backupName: config.backupDriveName,
            destination: config.backupDestinationPath,
            archive: config.archivePath,
            marker: config.backupMarkerPath
        )

        // Start logging session
        _ = logger.startSession()

        var success = false
        var skippedItems: [String] = []
        var notes: [String] = []
        isCancelling = false
        pendingMassArchive = nil
        filesProcessed = 0
        filesArchived = 0
        currentFile = ""

        do {
            // Step 1: Validate drives
            status = .validating
            currentProgress = 0.02
            try validateDrives(paths)

            // Step 2: Dry run. Proves the source is readable and sizes the
            // transfer *before* anything on the backup is moved.
            status = .scanning
            currentProgress = 0.05
            try await dryRun(paths)

            // Step 3: Archive files deleted from the source. A suspiciously
            // large batch is held for confirmation, but the backup of new
            // and changed files still goes ahead.
            status = .archiving
            currentProgress = 0.15
            if let note = try await archiveDeletedFiles(paths, confirmedMassArchiveCount: confirmedMassArchiveCount) {
                notes.append(note)
            }

            // Step 4: Perform rsync
            status = .syncing
            currentProgress = 0.3
            skippedItems = try await performRsync(paths)

            // Step 5: Verify and finish
            status = .finishing
            currentProgress = 0.95
            try verifySync(paths)

            success = true
            status = .completed
            currentProgress = 1.0

            if !skippedItems.isEmpty {
                notes.append(Self.partialSummary(skippedItems))
            }
            let warning = notes.isEmpty ? nil : notes.joined(separator: " ")
            let isNewWarning = warning != config.lastSyncWarning
            recordResult(paths, success: true, warning: warning)

            if let warning {
                logger.warning("Sync completed with warnings: \(filesProcessed) files updated, \(filesArchived) files archived", details: (notes + skippedItems).joined(separator: "\n"))
                if isNewWarning {
                    await sendNotification(title: "Backup Finished With Warnings", body: warning)
                }
            } else {
                logger.success("Sync completed: \(filesProcessed) files updated, \(filesArchived) files archived")
                await sendNotification(
                    title: "Backup Complete",
                    body: "Successfully synced \(filesProcessed) file(s), archived \(filesArchived) file(s)"
                )
            }

        } catch {
            let message = error.localizedDescription
            status = .failed(message)
            logger.error("Sync failed", details: message)

            // Only alert when something new went wrong, so a persistent
            // problem doesn't notify on every hourly retry.
            let isNewProblem = config.lastSyncSuccess || config.lastSyncError != message
            recordResult(paths, success: false, error: message)

            if isNewProblem, !isCancelling {
                await sendNotification(title: "Backup Failed", body: message)
            }
        }

        // End logging session
        logger.endSession(success: success)
        releaseLock()

        // Run anything waiting for the sync to end (quit, update install),
        // now that the log is written.
        let waiting = runWhenIdle
        runWhenIdle.removeAll()
        waiting.forEach { $0() }

        if success {
            // Leave the completion state visible briefly, but keep failures visible
            // until the next manual or scheduled sync so the user can inspect them.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if status == .completed {
                status = .idle
                filesProcessed = 0
                filesArchived = 0
                currentFile = ""
            }
        }

        return success
    }

    /// Stop a running sync (terminates rsync). Safe to call when idle.
    func cancelRunningSync() {
        guard status.isRunning else { return }
        isCancelling = true
        currentProcess?.terminate()
    }

    /// Run `block` now if idle, otherwise as soon as the current sync ends.
    func whenIdle(_ block: @escaping () -> Void) {
        if status.isRunning {
            runWhenIdle.append(block)
        } else {
            block()
        }
    }

    /// Record the outcome, unless the drives were changed while this sync
    /// ran — its result says nothing about the newly chosen drives.
    private func recordResult(_ paths: SyncPaths, success: Bool, error: String? = nil, warning: String? = nil) {
        guard config.sourceDriveUUID == paths.sourceUUID,
              config.backupDriveUUID == paths.backupUUID else {
            logger.info("Drives were changed during this sync; not recording its result")
            return
        }
        config.recordSyncResult(success: success, error: error, warning: warning)
    }

    private static func partialSummary(_ warnings: [String]) -> String {
        let count = warnings.count
        return "\(count) item\(count == 1 ? "" : "s") couldn't be copied. Everything else was backed up. See the log for details."
    }

    // MARK: - Step 1: Validate Drives

    private func validateDrives(_ paths: SyncPaths) throws {
        logger.info("Validating drives...")

        // Check source drive
        let sourceResult = driveMonitor.validateSourceDrive()
        guard sourceResult.isValid else {
            throw SyncError.sourceValidationFailed(sourceResult.errorMessage)
        }

        // Check backup drive
        let backupResult = driveMonitor.validateBackupDrive()
        guard backupResult.isValid else {
            throw SyncError.backupValidationFailed(backupResult.errorMessage)
        }

        // Double-check UUIDs against the paths this sync will actually use
        guard let sourceUUID = DriveMonitor.getVolumeUUID(at: paths.source),
              sourceUUID == paths.sourceUUID else {
            throw SyncError.sourceValidationFailed("Source drive UUID mismatch - ABORTING for safety")
        }

        guard let backupUUID = DriveMonitor.getVolumeUUID(at: paths.backupDrive),
              backupUUID == paths.backupUUID else {
            throw SyncError.backupValidationFailed("Backup drive UUID mismatch - ABORTING for safety")
        }

        // CRITICAL: Ensure source and backup are different drives
        // This prevents catastrophic misconfiguration where same drive is used for both
        guard sourceUUID != backupUUID else {
            throw SyncError.sourceValidationFailed("CRITICAL: Source and backup drives are the same! This is a misconfiguration. ABORTING.")
        }

        guard paths.source != paths.backupDrive else {
            throw SyncError.sourceValidationFailed("CRITICAL: Source and backup paths are identical! ABORTING.")
        }

        // Actually list the source. A drive can be mounted yet unreadable
        // (macOS privacy permission denied, failing disk); without this,
        // every backed-up file would look deleted.
        do {
            _ = try fileManager.contentsOfDirectory(atPath: paths.source)
        } catch {
            throw SyncError.sourceValidationFailed(
                "DadCloner can't read \(paths.sourceName). If macOS asked for permission to access it, allow it in System Settings > Privacy & Security > Files and Folders. (\(error.localizedDescription))"
            )
        }
        logger.info("Source drive validated: \(paths.sourceName)")

        // Verify backup marker still exists
        guard fileManager.fileExists(atPath: paths.marker) else {
            throw SyncError.backupValidationFailed("Backup marker file missing - refusing to sync to potentially wrong drive")
        }

        // Create the destination folder if it was removed
        if !fileManager.fileExists(atPath: paths.destination) {
            guard config.ensureBackupDestinationFolder() else {
                throw SyncError.backupValidationFailed("Could not create the \(SyncConfiguration.backupFolderName) folder")
            }
            logger.info("Recreated backup folder")
        }
        try fileManager.createDirectory(atPath: paths.archive, withIntermediateDirectories: true)
        logger.info("Backup drive validated: \(paths.backupName)")

        logger.success("Drive validation complete")
    }

    // MARK: - Step 2: Dry Run

    /// Items the dry run can't read are only logged here; the real run
    /// reports them.
    private func dryRun(_ paths: SyncPaths) async throws {
        let rsyncPath = try bundledRsyncPath()
        let args = RsyncCommand.dryRunArguments(
            source: paths.source,
            destination: paths.destination,
            replacedDir: RsyncCommand.replacedFolder(archiveRoot: paths.archive, now: Date())
        )
        logger.info("Checking for changes: rsync \(args.joined(separator: " "))")

        let result = try await runProcess(executable: rsyncPath, arguments: args, collectStdout: true)
        try checkCancelled()

        let outcome = RsyncOutcome(exitCode: result.exitCode)
        if outcome == .failure {
            throw SyncError.rsyncFailed("Dry run failed (exit \(result.exitCode)): \(result.stderr)")
        }

        let fileCount = RsyncOutput.fileCount(fromItemized: result.stdout)
        logger.info("Dry run complete: \(fileCount) file(s) to copy")

        if outcome == .partial {
            logger.warning("Some items can't be read", details: RsyncOutput.errorLines(fromStderr: result.stderr).joined(separator: "\n"))
        }
        try validateAvailableSpace(forDryRunOutput: result.stdout, paths: paths)
    }

    // MARK: - Step 3: Archive Deleted Files

    /// Returns a user-facing note if archiving was held for confirmation.
    private func archiveDeletedFiles(_ paths: SyncPaths, confirmedMassArchiveCount: Int?) async throws -> String? {
        logger.info("Checking for files to archive...")

        let source = paths.source
        let destination = paths.destination

        let scan = try await Task.detached(priority: .utility) {
            try OrphanScanner().scan(backupPath: destination, sourcePath: source)
        }.value
        try checkCancelled()

        if scan.orphaned.isEmpty {
            logger.info("No orphaned files to archive")
            return nil
        }

        logger.info("Found \(scan.orphaned.count) of \(scan.scannedFileCount) backed-up file(s) missing from source")

        let orphanCount = scan.orphaned.count
        let isConfirmed = confirmedMassArchiveCount.map { orphanCount <= $0 + max($0 / 10, 10) } ?? false
        if BackupPolicy.isMassArchive(orphaned: orphanCount, scanned: scan.scannedFileCount), !isConfirmed {
            pendingMassArchive = MassArchiveRequest(
                orphanedCount: orphanCount,
                scannedCount: scan.scannedFileCount
            )
            let sample = scan.orphaned.prefix(20).joined(separator: "\n")
            logger.warning("Large archive needs confirmation; skipping archive step. First missing files:", details: sample)
            return "\(orphanCount) of \(scan.scannedFileCount) backed-up files are no longer on \(paths.sourceName), so they were left in place (new and changed files were still backed up). If you deleted or reorganized them on purpose, click \u{201C}Archive & Back Up\u{201D} in the DadCloner menu (or Backup Now if it isn't shown). If not, check the source drive."
        }

        let now = Date()
        let dayFolder = ArchiveMover.dayFolder(archiveRoot: paths.archive, now: now)
        let orphaned = scan.orphaned
        let (result, cleanup) = await Task.detached(priority: .utility) {
            let result = ArchiveMover().archive(
                relativePaths: orphaned,
                backupRoot: destination,
                dayFolder: dayFolder,
                now: now
            )
            let cleanup = OrphanScanner().removeEmptyOrphanedDirectories(
                backupPath: destination,
                sourcePath: source
            )
            return (result, cleanup)
        }.value

        filesArchived = result.archived.count
        for path in result.archived {
            logger.info("Archived: \(path)")
        }
        for (path, newName) in result.renamed.sorted(by: { $0.key < $1.key }) {
            logger.info("Archive collision for \(path), saved as \(newName)")
        }
        for dir in cleanup.removed {
            logger.info("Removed empty deleted folder: \(dir)")
        }
        for warning in cleanup.warnings {
            logger.warning("Could not remove empty deleted folder", details: warning)
        }

        // If ANY files failed to archive, ABORT the sync
        // This is critical - we don't want to run rsync if archiving failed
        // because that could lead to confusion about what was/wasn't archived
        if !result.failures.isEmpty {
            logger.error("Failed to archive \(result.failures.count) file(s):")
            for failure in result.failures {
                logger.error("  - \(failure.relativePath): \(failure.reason)")
            }
            throw SyncError.archiveFailed("Failed to archive \(result.failures.count) file(s). Sync aborted to prevent data inconsistency. Check logs for details.")
        }

        logger.success("Archived \(filesArchived) file(s)")
        try checkCancelled()
        return nil
    }

    // MARK: - Step 4: Perform Rsync

    /// Returns per-file warnings when rsync finished but skipped some items.
    private func performRsync(_ paths: SyncPaths) async throws -> [String] {
        try checkCancelled()
        let rsyncPath = try bundledRsyncPath()
        let replacedDir = RsyncCommand.replacedFolder(archiveRoot: paths.archive, now: Date())

        // CRITICAL: We NEVER use --delete. Overwritten files go to replacedDir.
        let args = RsyncCommand.arguments(
            source: paths.source,
            destination: paths.destination,
            replacedDir: replacedDir
        )
        logger.info("Running: rsync \(args.joined(separator: " "))")

        filesProcessed = 0
        let result = try await runProcess(
            executable: rsyncPath,
            arguments: args,
            collectStdout: false,
            lineHandler: { [weak self] lines in
                for line in lines {
                    self?.handleRsyncOutputLine(line)
                }
            }
        )
        try checkCancelled()

        let warnings: [String]
        switch RsyncOutcome(exitCode: result.exitCode) {
        case .success:
            warnings = []
        case .partial:
            warnings = RsyncOutput.errorLines(fromStderr: result.stderr)
            logger.warning("rsync finished but some items were skipped (exit \(result.exitCode))", details: warnings.joined(separator: "\n"))
        case .failure:
            throw SyncError.rsyncFailed("rsync failed with exit code \(result.exitCode): \(result.stderr)")
        }

        if fileManager.fileExists(atPath: replacedDir) {
            logger.info("Previous versions of changed files saved in \((replacedDir as NSString).lastPathComponent)")
        }
        logger.success("rsync complete: \(filesProcessed) file(s) synced")
        return warnings
    }

    private func validateAvailableSpace(forDryRunOutput output: String, paths: SyncPaths) throws {
        guard let requiredBytes = RsyncOutput.transferredFileSize(fromStats: output),
              requiredBytes > 0 else {
            logger.info("Nothing to transfer, or size unknown; skipping space check")
            return
        }

        let availableBytes = try availableDiskSpace(atPath: paths.backupDrive)
        let safetyBuffer = max(requiredBytes / 10, 512 * 1024 * 1024)
        let neededBytes = requiredBytes + safetyBuffer

        logger.info(
            "Space check: \(formatBytes(requiredBytes)) to transfer, \(formatBytes(availableBytes)) available"
        )

        guard availableBytes >= neededBytes else {
            throw SyncError.insufficientSpace(
                "Need about \(formatBytes(neededBytes)) free, but only \(formatBytes(availableBytes)) is available on \(paths.backupName)."
            )
        }
    }

    private func availableDiskSpace(atPath path: String) throws -> Int64 {
        let attributes = try fileManager.attributesOfFileSystem(forPath: path)
        guard let freeSpace = attributes[.systemFreeSize] as? NSNumber else {
            throw SyncError.insufficientSpace("Could not determine free space on backup drive.")
        }
        return freeSpace.int64Value
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Step 5: Final Checks

    /// Confirms the backup's own bookkeeping survived the run. (rsync
    /// verifies each file it copies; this is not a content check.)
    private func verifySync(_ paths: SyncPaths) throws {
        logger.info("Running final checks...")

        guard fileManager.fileExists(atPath: paths.marker) else {
            throw SyncError.verificationFailed("Backup marker file was deleted during sync!")
        }

        guard fileManager.fileExists(atPath: paths.archive) else {
            throw SyncError.verificationFailed("Archive directory missing")
        }

        logger.success("Final checks complete")
    }

    private func checkCancelled() throws {
        if isCancelling {
            throw SyncError.cancelled
        }
    }

    // MARK: - Process Execution

    private func runProcess(
        executable: String,
        arguments: [String],
        collectStdout: Bool,
        lineHandler: (@MainActor ([String]) -> Void)? = nil
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = ProcessOutputCollector(collectStdout: collectStdout, lineHandler: lineHandler)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.appendStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            collector.appendStderr(handle.availableData)
        }

        currentProcess = process
        defer { currentProcess = nil }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let output = collector.finish(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
                continuation.resume(returning: (process.terminationStatus, output.stdout, output.stderr))
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func handleRsyncOutputLine(_ line: String) {
        if let percent = RsyncOutput.progressPercent(from: line) {
            let start = 0.3
            let end = 0.9
            let mapped = start + (end - start) * min(max(percent, 0.0), 1.0)
            if mapped > currentProgress {
                currentProgress = mapped
            }
            return
        }

        guard RsyncOutput.isFileLine(line) else { return }
        filesProcessed += 1
        currentFile = RsyncOutput.filename(from: line)
    }

    private func bundledRsyncPath() throws -> String {
        if let path = Bundle.main.path(forResource: "rsync", ofType: nil) {
            return path
        }
        throw SyncError.rsyncFailed("Bundled rsync not found in app resources.")
    }

    // MARK: - Lock Management

    private func acquireLock() -> Bool {
        // Create lock file if it doesn't exist
        if !fileManager.fileExists(atPath: lockFilePath) {
            fileManager.createFile(atPath: lockFilePath, contents: nil)
        }

        guard let handle = FileHandle(forWritingAtPath: lockFilePath) else {
            return false
        }

        // Try to get exclusive lock
        let result = flock(handle.fileDescriptor, LOCK_EX | LOCK_NB)
        if result == 0 {
            lockFileHandle = handle
            // Write PID to lock file
            let pid = ProcessInfo.processInfo.processIdentifier
            handle.truncateFile(atOffset: 0)
            handle.write(Data("\(pid)".utf8))
            return true
        }

        try? handle.close()
        return false
    }

    /// Unlock but leave the file in place: deleting it would let another
    /// process lock a fresh file while someone still holds the old one.
    private func releaseLock() {
        guard let handle = lockFileHandle else { return }
        flock(handle.fileDescriptor, LOCK_UN)
        try? handle.close()
        lockFileHandle = nil
    }

    // MARK: - Notifications

    private func sendNotification(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()

        // Request permission if needed
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        let updatedSettings = await center.notificationSettings()
        guard updatedSettings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try? await center.add(request)
    }
}

extension Notification.Name {
    static let dadClonerSyncStatusDidChange = Notification.Name("dadClonerSyncStatusDidChange")
}

/// Collects a child process's output from pipe callbacks (any thread).
/// Lines are split on raw bytes, so multibyte characters split across reads
/// survive, and delivered to the main actor in batches.
private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let collectStdout: Bool
    private let lineHandler: (@MainActor ([String]) -> Void)?
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutSplitter = LineSplitter()
    private var stderrSplitter = LineSplitter()

    init(collectStdout: Bool, lineHandler: (@MainActor ([String]) -> Void)?) {
        self.collectStdout = collectStdout
        self.lineHandler = lineHandler
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            if collectStdout { stdoutData.append(data) }
            return lineHandler == nil ? [] : stdoutSplitter.append(data)
        }
        emit(lines)
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            stderrData.append(data)
            return lineHandler == nil ? [] : stderrSplitter.append(data)
        }
        emit(lines)
    }

    func finish(stdoutPipe: Pipe, stderrPipe: Pipe) -> (stdout: String, stderr: String) {
        appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        let (lines, stdout, stderr): ([String], String, String) = lock.withLock {
            let lines = lineHandler == nil ? [] : stdoutSplitter.finish() + stderrSplitter.finish()
            return (
                lines,
                String(decoding: stdoutData, as: UTF8.self),
                String(decoding: stderrData, as: UTF8.self)
            )
        }
        emit(lines)
        return (stdout, stderr)
    }

    private func emit(_ lines: [String]) {
        guard let lineHandler, !lines.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                lineHandler(lines)
            }
        }
    }
}

// MARK: - Error Types

enum SyncError: LocalizedError {
    case sourceValidationFailed(String)
    case backupValidationFailed(String)
    case archiveFailed(String)
    case rsyncFailed(String)
    case verificationFailed(String)
    case insufficientSpace(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceValidationFailed(let message):
            return "Source drive error: \(message)"
        case .backupValidationFailed(let message):
            return "Backup drive error: \(message)"
        case .archiveFailed(let message):
            return "Archive error: \(message)"
        case .rsyncFailed(let message):
            return "Sync error: \(message)"
        case .verificationFailed(let message):
            return "Verification error: \(message)"
        case .insufficientSpace(let message):
            return "Backup drive is low on space: \(message)"
        case .cancelled:
            return "Backup was stopped before it finished"
        }
    }
}
