import Foundation

/// Represents a single log entry for sync operations
struct SyncLogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let message: String
    let details: String?

    enum LogLevel: String, Codable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case success = "SUCCESS"
    }

    init(level: LogLevel, message: String, details: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.level = level
        self.message = message
        self.details = details
    }

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    var logLine: String {
        var line = "[\(formattedTimestamp)] [\(level.rawValue)] \(message)"
        if let details = details, !details.isEmpty {
            line += "\n    \(details.replacingOccurrences(of: "\n", with: "\n    "))"
        }
        return line
    }
}

/// Represents a complete sync session
struct SyncSession: Identifiable, Codable {
    let id: UUID
    let startTime: Date
    var endTime: Date?
    var entries: [SyncLogEntry]
    var filesUpdated: Int
    var filesArchived: Int
    var bytesTransferred: Int64
    var success: Bool

    init() {
        self.id = UUID()
        self.startTime = Date()
        self.endTime = nil
        self.entries = []
        self.filesUpdated = 0
        self.filesArchived = 0
        self.bytesTransferred = 0
        self.success = false
    }

    mutating func log(_ level: SyncLogEntry.LogLevel, _ message: String, details: String? = nil) {
        entries.append(SyncLogEntry(level: level, message: message, details: details))
    }

    mutating func finish(success: Bool) {
        self.endTime = Date()
        self.success = success
        if success {
            log(.success, "Sync completed successfully")
        } else {
            log(.error, "Sync failed")
        }
    }

    var duration: TimeInterval {
        let end = endTime ?? Date()
        return end.timeIntervalSince(startTime)
    }

    var durationFormatted: String {
        let seconds = Int(duration)
        if seconds < 60 {
            return "\(seconds) second\(seconds == 1 ? "" : "s")"
        } else {
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            if remainingSeconds == 0 {
                return "\(minutes) minute\(minutes == 1 ? "" : "s")"
            }
            return "\(minutes)m \(remainingSeconds)s"
        }
    }

    var summary: String {
        var parts: [String] = []
        if filesUpdated > 0 {
            parts.append("\(filesUpdated) file\(filesUpdated == 1 ? "" : "s") updated")
        }
        if filesArchived > 0 {
            parts.append("\(filesArchived) file\(filesArchived == 1 ? "" : "s") archived")
        }
        if parts.isEmpty {
            return "No changes"
        }
        return parts.joined(separator: ", ")
    }
}

/// Manages persistent logging to the sync log file
@Observable
final class SyncLogger {

    // MARK: - Singleton
    static let shared = SyncLogger()

    // MARK: - Properties
    private(set) var currentSession: SyncSession?
    private(set) var recentEntries: [SyncLogEntry] = []

    private let maxRecentEntries = 100
    private let logFilename = "sync_log.txt"

    private var logFilePath: String {
        let archivePath = SyncConfiguration.shared.archivePath
        return (archivePath as NSString).appendingPathComponent(logFilename)
    }

    // MARK: - Initialization
    private init() {}

    // MARK: - Session Management

    /// Start a new sync session
    func startSession() -> SyncSession {
        let session = SyncSession()
        currentSession = session
        log(.info, "Starting sync session")
        log(.info, "Source: \(SyncConfiguration.shared.sourceDrivePath)")
        log(.info, "Backup: \(SyncConfiguration.shared.backupDestinationPath)")
        return session
    }

    /// End the current session
    func endSession(success: Bool) {
        guard var session = currentSession else { return }
        session.finish(success: success)
        currentSession = session

        // Write session summary to log file
        writeSessionToFile(session)

        currentSession = nil
    }

    // MARK: - Logging

    /// Log an entry to the current session
    func log(_ level: SyncLogEntry.LogLevel, _ message: String, details: String? = nil) {
        let entry = SyncLogEntry(level: level, message: message, details: details)

        // Add to current session
        currentSession?.entries.append(entry)

        // Add to recent entries for display
        recentEntries.append(entry)
        if recentEntries.count > maxRecentEntries {
            recentEntries.removeFirst()
        }

        // Print to console for debugging
        print(entry.logLine)
    }

    /// Log info level
    func info(_ message: String, details: String? = nil) {
        log(.info, message, details: details)
    }

    /// Log warning level
    func warning(_ message: String, details: String? = nil) {
        log(.warning, message, details: details)
    }

    /// Log error level
    func error(_ message: String, details: String? = nil) {
        log(.error, message, details: details)
    }

    /// Log success level
    func success(_ message: String, details: String? = nil) {
        log(.success, message, details: details)
    }

    // MARK: - File Operations

    /// Write a session to the log file
    private func writeSessionToFile(_ session: SyncSession) {
        var logContent = """

        ================================================================================
        SYNC SESSION: \(session.startTime)
        ================================================================================

        """

        for entry in session.entries {
            logContent += entry.logLine + "\n"
        }

        logContent += """

        --------------------------------------------------------------------------------
        Summary: \(session.summary)
        Duration: \(session.durationFormatted)
        Result: \(session.success ? "SUCCESS" : "FAILED")
        --------------------------------------------------------------------------------

        """

        // Append to log file
        do {
            let fileManager = FileManager.default

            // Ensure archive directory exists
            let archivePath = SyncConfiguration.shared.archivePath
            if !fileManager.fileExists(atPath: archivePath) {
                try fileManager.createDirectory(atPath: archivePath, withIntermediateDirectories: true)
            }

            // Append or create log file
            if fileManager.fileExists(atPath: logFilePath) {
                let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logFilePath))
                fileHandle.seekToEndOfFile()
                if let data = logContent.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            } else {
                try logContent.write(toFile: logFilePath, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Failed to write to log file: \(error)")
        }
    }

    /// Read the full log file contents
    func readLogFile() -> String {
        do {
            return try String(contentsOfFile: logFilePath, encoding: .utf8)
        } catch {
            return "No log file found or unable to read log."
        }
    }

    /// Get the path to the log file
    func getLogFilePath() -> String {
        return logFilePath
    }
}
