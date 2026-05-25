import Foundation
import UserNotifications

/// Sync operation status
enum SyncStatus: Equatable {
    case idle
    case validating
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

/// Core sync manager - handles all backup operations with safety checks
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

    /// Lock file to prevent concurrent syncs
    private var lockFileHandle: FileHandle?
    private var lockFilePath: String {
        let tempDir = NSTemporaryDirectory()
        return (tempDir as NSString).appendingPathComponent("dadcloner.lock")
    }

    private let fileManager = FileManager.default
    private let logger = SyncLogger.shared
    private let config = SyncConfiguration.shared
    private let driveMonitor = DriveMonitor.shared

    // MARK: - Initialization
    private init() {}

    // MARK: - Main Sync Operation

    /// Perform a full sync operation
    /// This is the main entry point for backup operations
    @MainActor
    func performSync() async -> Bool {
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

        // Start logging session
        _ = logger.startSession()

        var success = false

        do {
            filesProcessed = 0
            filesArchived = 0
            currentFile = ""

            // Step 1: Validate drives
            status = .validating
            currentProgress = 0.05
            try await validateDrives()

            // Step 2: Archive deleted files
            status = .archiving
            currentProgress = 0.1
            try await archiveDeletedFiles()

            // Step 3: Perform rsync
            status = .syncing
            currentProgress = 0.3
            try await performRsync()

            // Step 4: Verify and finish
            status = .finishing
            currentProgress = 0.95
            try await verifySync()

            success = true
            status = .completed
            currentProgress = 1.0

            // Record success
            config.recordSyncResult(success: true)
            logger.success("Sync completed: \(filesProcessed) files updated, \(filesArchived) files archived")

            // Send notification
            await sendNotification(
                title: "Backup Complete",
                body: "Successfully synced \(filesProcessed) file(s), archived \(filesArchived) file(s)"
            )

        } catch let error as SyncError {
            status = .failed(error.localizedDescription)
            logger.error("Sync failed", details: error.localizedDescription)
            config.recordSyncResult(success: false)

            await sendNotification(
                title: "Backup Failed",
                body: error.localizedDescription
            )

        } catch {
            status = .failed(error.localizedDescription)
            logger.error("Sync failed with unexpected error", details: error.localizedDescription)
            config.recordSyncResult(success: false)

            await sendNotification(
                title: "Backup Failed",
                body: error.localizedDescription
            )
        }

        // End logging session
        logger.endSession(success: success)

        if success {
            // Leave the completion state visible briefly, but keep failures visible
            // until the next manual or scheduled sync so the user can inspect them.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            status = .idle
            filesProcessed = 0
            filesArchived = 0
            currentFile = ""
        }

        return success
    }

    // MARK: - Step 1: Validate Drives

    private func validateDrives() async throws {
        logger.info("Validating drives...")

        // Refresh drive status
        driveMonitor.refreshMountedVolumes()

        // Check source drive
        let sourceResult = driveMonitor.validateSourceDrive()
        guard sourceResult.isValid else {
            throw SyncError.sourceValidationFailed(sourceResult.errorMessage)
        }
        logger.info("Source drive validated: \(config.sourceDriveName)")

        // Check backup drive
        let backupResult = driveMonitor.validateBackupDrive()
        guard backupResult.isValid else {
            throw SyncError.backupValidationFailed(backupResult.errorMessage)
        }
        logger.info("Backup drive validated: \(config.backupDriveName)")

        // Double-check UUIDs as an extra safety measure
        guard let sourceUUID = DriveMonitor.getVolumeUUID(at: config.sourceDrivePath),
              sourceUUID == config.sourceDriveUUID else {
            throw SyncError.sourceValidationFailed("Source drive UUID mismatch - ABORTING for safety")
        }

        guard let backupUUID = DriveMonitor.getVolumeUUID(at: config.backupDrivePath),
              backupUUID == config.backupDriveUUID else {
            throw SyncError.backupValidationFailed("Backup drive UUID mismatch - ABORTING for safety")
        }

        // CRITICAL: Ensure source and backup are different drives
        // This prevents catastrophic misconfiguration where same drive is used for both
        guard sourceUUID != backupUUID else {
            throw SyncError.sourceValidationFailed("CRITICAL: Source and backup drives are the same! This is a misconfiguration. ABORTING.")
        }

        guard config.sourceDrivePath != config.backupDrivePath else {
            throw SyncError.sourceValidationFailed("CRITICAL: Source and backup paths are identical! ABORTING.")
        }

        // Verify backup marker still exists
        guard fileManager.fileExists(atPath: config.backupMarkerPath) else {
            throw SyncError.backupValidationFailed("Backup marker file missing - refusing to sync to potentially wrong drive")
        }

        logger.success("Drive validation complete")
    }

    // MARK: - Step 2: Archive Deleted Files

    private func archiveDeletedFiles() async throws {
        logger.info("Checking for files to archive...")

        let sourcePath = config.sourceDrivePath
        let backupPath = config.backupDestinationPath
        let archivePath = config.archivePath

        // Create today's archive folder with timestamp to avoid collisions
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let todayFolder = dateFormatter.string(from: Date())
        let todayArchivePath = (archivePath as NSString).appendingPathComponent(todayFolder)

        // Get list of files in backup that don't exist in source
        // These are files that were deleted from source and need to be archived
        let orphanedFiles = try findOrphanedFiles(
            backupPath: backupPath,
            sourcePath: sourcePath
        )

        if orphanedFiles.isEmpty {
            logger.info("No orphaned files to archive")
            return
        }

        logger.info("Found \(orphanedFiles.count) file(s) to archive")

        // Create archive folder if needed
        if !fileManager.fileExists(atPath: todayArchivePath) {
            try fileManager.createDirectory(atPath: todayArchivePath, withIntermediateDirectories: true)
        }

        // Track failures - we will abort sync if ANY file fails to archive
        var failedFiles: [(path: String, error: String)] = []

        // Move each orphaned file to archive
        for relativePath in orphanedFiles {
            let sourceFile = (backupPath as NSString).appendingPathComponent(relativePath)
            var archiveFile = (todayArchivePath as NSString).appendingPathComponent(relativePath)

            // Create parent directory in archive if needed
            let archiveParent = (archiveFile as NSString).deletingLastPathComponent
            if !fileManager.fileExists(atPath: archiveParent) {
                do {
                    try fileManager.createDirectory(atPath: archiveParent, withIntermediateDirectories: true)
                } catch {
                    failedFiles.append((relativePath, "Could not create archive directory: \(error.localizedDescription)"))
                    continue
                }
            }

            // Handle collision: if archive file already exists, add timestamp
            if fileManager.fileExists(atPath: archiveFile) {
                let timeFormatter = DateFormatter()
                timeFormatter.dateFormat = "HHmmss"
                let timestamp = timeFormatter.string(from: Date())

                let fileName = (relativePath as NSString).lastPathComponent
                let fileExt = (fileName as NSString).pathExtension
                let baseName = (fileName as NSString).deletingPathExtension

                let newFileName: String
                if fileExt.isEmpty {
                    newFileName = "\(baseName)_\(timestamp)"
                } else {
                    newFileName = "\(baseName)_\(timestamp).\(fileExt)"
                }

                let parentPath = (archiveFile as NSString).deletingLastPathComponent
                archiveFile = (parentPath as NSString).appendingPathComponent(newFileName)
                logger.info("Archive collision detected, using: \(newFileName)")
            }

            do {
                // Move file to archive
                try fileManager.moveItem(atPath: sourceFile, toPath: archiveFile)

                // VERIFY the move succeeded
                guard fileManager.fileExists(atPath: archiveFile) else {
                    failedFiles.append((relativePath, "File move appeared to succeed but archive file does not exist"))
                    continue
                }

                // Verify source was removed (move, not copy)
                if fileManager.fileExists(atPath: sourceFile) {
                    // This shouldn't happen, but if it does, we have a problem
                    logger.warning("Move did not remove source file: \(relativePath)")
                }

                filesArchived += 1
                currentFile = relativePath
                logger.info("Archived: \(relativePath)")
            } catch {
                failedFiles.append((relativePath, error.localizedDescription))
            }
        }

        removeEmptyOrphanedDirectories(backupPath: backupPath, sourcePath: sourcePath)

        // If ANY files failed to archive, ABORT the sync
        // This is critical - we don't want to run rsync if archiving failed
        // because that could lead to confusion about what was/wasn't archived
        if !failedFiles.isEmpty {
            logger.error("Failed to archive \(failedFiles.count) file(s):")
            for (path, error) in failedFiles {
                logger.error("  - \(path): \(error)")
            }
            throw SyncError.archiveFailed("Failed to archive \(failedFiles.count) file(s). Sync aborted to prevent data inconsistency. Check logs for details.")
        }

        logger.success("Archived \(filesArchived) file(s)")
    }

    /// Find files in backup that don't exist in source
    private func findOrphanedFiles(backupPath: String, sourcePath: String) throws -> [String] {
        var orphanedFiles: [String] = []

        // Skip special system directories and our own files
        // NOTE: We intentionally DO include hidden user files (like .bashrc, .gitconfig)
        // because rsync copies them, so we need to archive them too
        let skipPaths: Set<String> = [
            SyncConfiguration.archiveDirectoryName,
            SyncConfiguration.backupMarkerFilename,
            ".DS_Store",
            ".Spotlight-V100",
            ".fseventsd",
            ".Trashes",
            ".TemporaryItems",
            ".DocumentRevisions-V100",
            ".PKInstallSandboxManager-SystemSoftware"
        ]

        // Use enumerator to walk the backup directory
        // IMPORTANT: We do NOT skip hidden files - rsync copies them, so we must archive them too
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: backupPath),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []  // No options = include hidden files
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            // Get relative path
            let fullPath = fileURL.path
            guard fullPath.hasPrefix(backupPath) else { continue }

            var relativePath = String(fullPath.dropFirst(backupPath.count))
            if relativePath.hasPrefix("/") {
                relativePath = String(relativePath.dropFirst())
            }

            // Skip special system directories
            let firstComponent = relativePath.components(separatedBy: "/").first ?? ""
            if skipPaths.contains(firstComponent) {
                if let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            // Check if this is a file or symlink (not just directory)
            // We need to handle both regular files AND symlinks since rsync copies symlinks
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                continue
            }

            let isRegularFile = resourceValues.isRegularFile ?? false
            let isSymlink = resourceValues.isSymbolicLink ?? false

            guard isRegularFile || isSymlink else {
                continue
            }

            // Check if file exists in source
            // For symlinks, we check if the symlink itself exists, not its target
            let sourceFile = (sourcePath as NSString).appendingPathComponent(relativePath)
            if !itemExistsIncludingSymlink(atPath: sourceFile) {
                orphanedFiles.append(relativePath)
            }
        }

        return orphanedFiles
    }

    private func itemExistsIncludingSymlink(atPath path: String) -> Bool {
        if fileManager.fileExists(atPath: path) {
            return true
        }

        return (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private func removeEmptyOrphanedDirectories(backupPath: String, sourcePath: String) {
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: backupPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        var directories: [String] = []

        for case let fileURL as URL in enumerator {
            guard let isDirectory = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDirectory == true else {
                continue
            }

            let fullPath = fileURL.path
            guard fullPath.hasPrefix(backupPath) else { continue }

            var relativePath = String(fullPath.dropFirst(backupPath.count))
            if relativePath.hasPrefix("/") {
                relativePath = String(relativePath.dropFirst())
            }

            let firstComponent = relativePath.components(separatedBy: "/").first ?? ""
            let skipPaths: Set<String> = [
                SyncConfiguration.archiveDirectoryName,
                SyncConfiguration.backupMarkerFilename,
                ".DS_Store",
                ".Spotlight-V100",
                ".fseventsd",
                ".Trashes",
                ".TemporaryItems",
                ".DocumentRevisions-V100",
                ".PKInstallSandboxManager-SystemSoftware"
            ]

            if skipPaths.contains(firstComponent) {
                enumerator.skipDescendants()
                continue
            }

            if !itemExistsIncludingSymlink(atPath: (sourcePath as NSString).appendingPathComponent(relativePath)) {
                directories.append(fullPath)
            }
        }

        for directory in directories.sorted(by: { $0.count > $1.count }) {
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: directory)
                if contents.isEmpty {
                    try fileManager.removeItem(atPath: directory)
                    logger.info("Removed empty deleted folder: \(directory)")
                }
            } catch {
                logger.warning("Could not remove empty deleted folder", details: "\(directory): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Step 3: Perform Rsync

    private func performRsync() async throws {
        logger.info("Starting rsync...")

        let rsyncPath = try bundledRsyncPath()
        let sourcePath = config.sourceDrivePath.hasSuffix("/") ? config.sourceDrivePath : config.sourceDrivePath + "/"
        let backupPath = config.backupDestinationPath.hasSuffix("/") ? config.backupDestinationPath : config.backupDestinationPath + "/"

        // Build rsync command with safety flags
        // CRITICAL: We NEVER use --delete flag
        let rsyncArgs = [
            "-av",                      // Archive mode, verbose
            "--itemize-changes",        // Show what's being changed
            "--info=progress2",         // Emit overall progress for large transfers
            "--exclude", SyncConfiguration.archiveDirectoryName,
            "--exclude", SyncConfiguration.backupMarkerFilename,
            "--exclude", ".DS_Store",
            "--exclude", ".Spotlight-V100",
            "--exclude", ".fseventsd",
            "--exclude", ".Trashes",
            "--exclude", ".TemporaryItems",
            sourcePath,
            backupPath
        ]

        logger.info("Running: rsync \(rsyncArgs.joined(separator: " "))")

        // First, do a dry run to count files and estimate transfer size.
        let dryRunArgs = ["--dry-run", "--stats"] + rsyncArgs
        let dryRunResult = try await runProcess(executable: rsyncPath, arguments: dryRunArgs)

        if dryRunResult.exitCode != 0 {
            throw SyncError.rsyncFailed("Dry run failed: \(dryRunResult.stderr)")
        }

        // Count files from dry run output
        let fileCount = dryRunResult.stdout.components(separatedBy: "\n")
            .filter { $0.hasPrefix(">f") || $0.hasPrefix("<f") || $0.hasPrefix("cf") }
            .count

        logger.info("Dry run complete: \(fileCount) file(s) to sync")

        if fileCount == 0 {
            logger.info("No files need syncing")
            currentProgress = 0.9
            return
        }

        try validateAvailableSpace(forDryRunOutput: dryRunResult.stdout)

        // Now do the actual sync
        filesProcessed = 0
        let result = try await runProcess(
            executable: rsyncPath,
            arguments: rsyncArgs,
            stdoutLineHandler: { [weak self] line in
                guard let self = self else { return }
                Task { @MainActor in
                    self.handleRsyncOutputLine(line)
                }
            },
            stderrLineHandler: { [weak self] line in
                guard let self = self else { return }
                Task { @MainActor in
                    self.handleRsyncOutputLine(line)
                }
            }
        )

        if result.exitCode != 0 && result.exitCode != 24 { // 24 = vanished files, usually OK
            throw SyncError.rsyncFailed("rsync failed with exit code \(result.exitCode): \(result.stderr)")
        }

        logger.success("rsync complete: \(filesProcessed) file(s) synced")
    }

    private func validateAvailableSpace(forDryRunOutput output: String) throws {
        guard let requiredBytes = parseTransferredFileSize(from: output),
              requiredBytes > 0 else {
            logger.warning("Could not estimate transfer size from dry run; continuing")
            return
        }

        let availableBytes = try availableDiskSpace(atPath: config.backupDrivePath)
        let safetyBuffer = max(requiredBytes / 10, 512 * 1024 * 1024)
        let neededBytes = requiredBytes + safetyBuffer

        logger.info(
            "Space check: \(formatBytes(requiredBytes)) to transfer, \(formatBytes(availableBytes)) available"
        )

        guard availableBytes >= neededBytes else {
            throw SyncError.insufficientSpace(
                "Need about \(formatBytes(neededBytes)) free, but only \(formatBytes(availableBytes)) is available on \(config.backupDriveName)."
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

    private func parseTransferredFileSize(from output: String) -> Int64? {
        for line in output.components(separatedBy: .newlines) {
            let lowercasedLine = line.lowercased()
            guard lowercasedLine.contains("total transferred file size:") else {
                continue
            }

            guard let valuePart = line.split(separator: ":", maxSplits: 1).last else {
                return nil
            }

            let digits = valuePart.filter { $0.isNumber }
            return Int64(String(digits))
        }

        return nil
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Step 4: Verify

    private func verifySync() async throws {
        logger.info("Verifying sync...")

        // Verify backup marker still exists
        guard fileManager.fileExists(atPath: config.backupMarkerPath) else {
            throw SyncError.verificationFailed("Backup marker file was deleted during sync!")
        }

        // Verify archive directory exists
        guard fileManager.fileExists(atPath: config.archivePath) else {
            throw SyncError.verificationFailed("Archive directory missing")
        }

        logger.success("Verification complete")
    }

    // MARK: - Process Execution

    private func runProcess(
        executable: String,
        arguments: [String],
        stdoutLineHandler: ((String) -> Void)? = nil,
        stderrLineHandler: ((String) -> Void)? = nil
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let outputCollector = ProcessOutputCollector()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            outputCollector.appendStdout(data, handler: stdoutLineHandler)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            outputCollector.appendStderr(data, handler: stderrLineHandler)
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let output = outputCollector.finish(
                    stdoutPipe: stdoutPipe,
                    stderrPipe: stderrPipe,
                    stdoutLineHandler: stdoutLineHandler,
                    stderrLineHandler: stderrLineHandler
                )

                continuation.resume(returning: (process.terminationStatus, output.stdout, output.stderr))
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
        }
    }

    @MainActor
    private func handleRsyncOutputLine(_ line: String) {
        if let percent = parseRsyncProgressPercent(from: line) {
            let start = 0.3
            let end = 0.9
            let mapped = start + (end - start) * min(max(percent, 0.0), 1.0)
            if mapped > currentProgress {
                currentProgress = mapped
            }
            return
        }

        guard isRsyncFileLine(line) else { return }
        filesProcessed += 1
        currentFile = extractRsyncFilename(from: line)
    }

    private func isRsyncFileLine(_ line: String) -> Bool {
        return line.hasPrefix(">f") || line.hasPrefix("<f") || line.hasPrefix("cf")
    }

    private func extractRsyncFilename(from line: String) -> String {
        guard let spaceIndex = line.firstIndex(of: " ") else { return line }
        let name = line[line.index(after: spaceIndex)...]
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseRsyncProgressPercent(from line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let tokens = trimmed.split(separator: " ")
        for token in tokens {
            if token.hasSuffix("%") {
                let number = token.dropLast()
                if let value = Double(number) {
                    return value / 100.0
                }
            }
        }
        return nil
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
            handle.write("\(pid)".data(using: .utf8)!)
            return true
        }

        try? handle.close()
        return false
    }

    private func releaseLock() {
        guard let handle = lockFileHandle else { return }
        flock(handle.fileDescriptor, LOCK_UN)
        try? handle.close()
        lockFileHandle = nil
        try? fileManager.removeItem(atPath: lockFilePath)
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

private final class ProcessOutputCollector {
    private let queue = DispatchQueue(label: "com.dadcloner.process.io")
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutBuffer = ""
    private var stderrBuffer = ""

    func appendStdout(_ data: Data, handler: ((String) -> Void)?) {
        guard !data.isEmpty else { return }
        queue.sync {
            stdoutData.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                stdoutBuffer += chunk
                drainStdoutBuffer(final: false, handler: handler)
            }
        }
    }

    func appendStderr(_ data: Data, handler: ((String) -> Void)?) {
        guard !data.isEmpty else { return }
        queue.sync {
            stderrData.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                stderrBuffer += chunk
                drainStderrBuffer(final: false, handler: handler)
            }
        }
    }

    func finish(
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        stdoutLineHandler: ((String) -> Void)?,
        stderrLineHandler: ((String) -> Void)?
    ) -> (stdout: String, stderr: String) {
        queue.sync {
            let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            stdoutData.append(remainingStdout)
            stderrData.append(remainingStderr)

            if let chunk = String(data: remainingStdout, encoding: .utf8) {
                stdoutBuffer += chunk
            }
            if let chunk = String(data: remainingStderr, encoding: .utf8) {
                stderrBuffer += chunk
            }

            drainStdoutBuffer(final: true, handler: stdoutLineHandler)
            drainStderrBuffer(final: true, handler: stderrLineHandler)

            return (
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }
    }

    private func drainStdoutBuffer(final: Bool, handler: ((String) -> Void)?) {
        while let range = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<range.lowerBound])
            stdoutBuffer.removeSubrange(..<range.upperBound)
            emit(line, handler: handler)
        }

        if final && !stdoutBuffer.isEmpty {
            let line = stdoutBuffer
            stdoutBuffer = ""
            emit(line, handler: handler)
        }
    }

    private func drainStderrBuffer(final: Bool, handler: ((String) -> Void)?) {
        while let range = stderrBuffer.range(of: "\n") {
            let line = String(stderrBuffer[..<range.lowerBound])
            stderrBuffer.removeSubrange(..<range.upperBound)
            emit(line, handler: handler)
        }

        if final && !stderrBuffer.isEmpty {
            let line = stderrBuffer
            stderrBuffer = ""
            emit(line, handler: handler)
        }
    }

    private func emit(_ line: String, handler: ((String) -> Void)?) {
        guard let handler else { return }
        DispatchQueue.main.async {
            handler(line)
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
    case lockFailed

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
        case .lockFailed:
            return "Could not acquire sync lock"
        }
    }
}
