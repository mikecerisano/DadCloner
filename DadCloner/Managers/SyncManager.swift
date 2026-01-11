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
    private(set) var status: SyncStatus = .idle
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

        // Reset state after a delay
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
        if status == .completed || status.isRunning == false {
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
        let orphanedFiles = try await findOrphanedFiles(
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
    private func findOrphanedFiles(backupPath: String, sourcePath: String) async throws -> [String] {
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
            var sourceExists = false

            if isSymlink {
                // For symlinks, check if the symlink itself exists (not its target)
                var isDir: ObjCBool = false
                sourceExists = fileManager.fileExists(atPath: sourceFile, isDirectory: &isDir)
            } else {
                sourceExists = fileManager.fileExists(atPath: sourceFile)
            }

            if !sourceExists {
                orphanedFiles.append(relativePath)
            }
        }

        return orphanedFiles
    }

    // MARK: - Step 3: Perform Rsync

    private func performRsync() async throws {
        logger.info("Starting rsync...")

        let rsyncPath = try bundledRsyncPath()
        let sourcePath = config.sourceDrivePath.hasSuffix("/") ? config.sourceDrivePath : config.sourceDrivePath + "/"
        let backupPath = config.backupDestinationPath.hasSuffix("/") ? config.backupDestinationPath : config.backupDestinationPath + "/"

        let useOverallProgress = true

        // Build rsync command with safety flags
        // CRITICAL: We NEVER use --delete flag
        var rsyncArgs = [
            "-av",                      // Archive mode, verbose
            "--update",                 // Skip files newer on destination
            "--itemize-changes",        // Show what's being changed
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
        if useOverallProgress {
            rsyncArgs.insert("--info=progress2", at: 3)
        } else {
            rsyncArgs.insert("--progress", at: 3)
        }

        logger.info("Running: rsync \(rsyncArgs.joined(separator: " "))")

        // First, do a dry run to count files
        let dryRunArgs = ["--dry-run"] + rsyncArgs
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

        // Now do the actual sync
        filesProcessed = 0
        let result = try await runProcess(
            executable: rsyncPath,
            arguments: rsyncArgs,
            stdoutLineHandler: { [weak self] line in
                guard let self = self else { return }
                Task { @MainActor in
                    self.handleRsyncOutputLine(line, totalFiles: fileCount, useOverallProgress: useOverallProgress)
                }
            },
            stderrLineHandler: { [weak self] line in
                guard let self = self else { return }
                Task { @MainActor in
                    self.handleRsyncOutputLine(line, totalFiles: fileCount, useOverallProgress: useOverallProgress)
                }
            }
        )

        if result.exitCode != 0 && result.exitCode != 24 { // 24 = vanished files, usually OK
            throw SyncError.rsyncFailed("rsync failed with exit code \(result.exitCode): \(result.stderr)")
        }

        logger.success("rsync complete: \(filesProcessed) file(s) synced")
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

        let ioQueue = DispatchQueue(label: "com.dadcloner.process.io")
        var stdoutData = Data()
        var stderrData = Data()
        var stdoutBuffer = ""
        var stderrBuffer = ""

        func drainStdoutBuffer(final: Bool) {
            while let range = stdoutBuffer.range(of: "\n") {
                let line = String(stdoutBuffer[..<range.lowerBound])
                stdoutBuffer.removeSubrange(..<range.upperBound)
                if let handler = stdoutLineHandler {
                    DispatchQueue.main.async {
                        handler(line)
                    }
                }
            }
            if final && !stdoutBuffer.isEmpty {
                let line = stdoutBuffer
                stdoutBuffer = ""
                if let handler = stdoutLineHandler {
                    DispatchQueue.main.async {
                        handler(line)
                    }
                }
            }
        }

        func drainStderrBuffer(final: Bool) {
            while let range = stderrBuffer.range(of: "\n") {
                let line = String(stderrBuffer[..<range.lowerBound])
                stderrBuffer.removeSubrange(..<range.upperBound)
                if let handler = stderrLineHandler {
                    DispatchQueue.main.async {
                        handler(line)
                    }
                }
            }
            if final && !stderrBuffer.isEmpty {
                let line = stderrBuffer
                stderrBuffer = ""
                if let handler = stderrLineHandler {
                    DispatchQueue.main.async {
                        handler(line)
                    }
                }
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            ioQueue.sync {
                stdoutData.append(data)
                if let chunk = String(data: data, encoding: .utf8) {
                    stdoutBuffer += chunk
                    drainStdoutBuffer(final: false)
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            ioQueue.sync {
                stderrData.append(data)
                if let chunk = String(data: data, encoding: .utf8) {
                    stderrBuffer += chunk
                    drainStderrBuffer(final: false)
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                ioQueue.sync {
                    let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingStdout.isEmpty {
                        stdoutData.append(remainingStdout)
                        if let chunk = String(data: remainingStdout, encoding: .utf8) {
                            stdoutBuffer += chunk
                        }
                    }
                    if !remainingStderr.isEmpty {
                        stderrData.append(remainingStderr)
                        if let chunk = String(data: remainingStderr, encoding: .utf8) {
                            stderrBuffer += chunk
                        }
                    }
                    drainStdoutBuffer(final: true)
                    drainStderrBuffer(final: true)
                }

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, stdout, stderr))
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
    private func handleRsyncOutputLine(_ line: String, totalFiles: Int, useOverallProgress: Bool) {
        if useOverallProgress, let percent = parseRsyncProgressPercent(from: line) {
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

        if !useOverallProgress {
            let clampedTotal = max(totalFiles, 1)
            let fraction = min(Double(filesProcessed) / Double(clampedTotal), 1.0)
            let start = 0.3
            let end = 0.9
            currentProgress = start + (end - start) * fraction
        }
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

        guard settings.authorizationStatus == .authorized else { return }

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

// MARK: - Error Types

enum SyncError: LocalizedError {
    case sourceValidationFailed(String)
    case backupValidationFailed(String)
    case archiveFailed(String)
    case rsyncFailed(String)
    case verificationFailed(String)
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
        case .lockFailed:
            return "Could not acquire sync lock"
        }
    }
}
