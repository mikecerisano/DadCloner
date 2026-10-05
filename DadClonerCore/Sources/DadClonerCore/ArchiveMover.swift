import Foundation

/// Moves orphaned backup files into a dated archive folder, preserving
/// their relative paths. Never deletes: every file either lands in the
/// archive or is reported as a failure and left where it was.
public struct ArchiveMover {

    public struct Failure: Equatable, Sendable {
        public let relativePath: String
        public let reason: String
    }

    public struct Result: Equatable, Sendable {
        /// Relative paths successfully moved.
        public var archived: [String] = []
        /// Archive-relative names used when a same-named file was already
        /// archived today (original relative path -> new file name).
        public var renamed: [String: String] = [:]
        public var failures: [Failure] = []
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The folder under `archiveRoot` that today's archived files go into.
    public static func dayFolder(archiveRoot: String, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (archiveRoot as NSString).appendingPathComponent(formatter.string(from: now))
    }

    /// Move each of `relativePaths` from `backupRoot` into `dayFolder`.
    public func archive(
        relativePaths: [String],
        backupRoot: String,
        dayFolder: String,
        now: Date
    ) -> Result {
        var result = Result()

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HHmmss"
        let timestamp = timeFormatter.string(from: now)

        for relativePath in relativePaths {
            let sourceFile = (backupRoot as NSString).appendingPathComponent(relativePath)
            let relativeParent = (relativePath as NSString).deletingLastPathComponent

            // Find an archive root where this file's folder path can exist.
            // If a *file* already sits where a folder is needed (e.g. "X" was
            // archived earlier today and now "X/y" is), use a sibling root
            // like "2026-10-05 143000" instead of failing.
            var archiveRoot = dayFolder
            var attempt = 0
            var parentError: Error?
            while true {
                do {
                    try ensureDirectory(relativePath: relativeParent, under: archiveRoot)
                    parentError = nil
                    break
                } catch {
                    parentError = error
                    attempt += 1
                    guard attempt <= 20 else { break }
                    let suffix = attempt == 1 ? timestamp : "\(timestamp)-\(attempt - 1)"
                    archiveRoot = "\(dayFolder) \(suffix)"
                }
            }
            if let parentError {
                result.failures.append(Failure(
                    relativePath: relativePath,
                    reason: "Could not create archive folder: \(parentError.localizedDescription)"))
                continue
            }

            var archiveFile = (archiveRoot as NSString).appendingPathComponent(relativePath)
            let archiveParent = (archiveFile as NSString).deletingLastPathComponent
            if archiveRoot != dayFolder {
                result.renamed[relativePath] = (archiveRoot as NSString).lastPathComponent + "/" + relativePath
            }

            // Same file archived earlier today: keep both, suffix the new one.
            if itemExists(atPath: archiveFile) {
                let fileName = (relativePath as NSString).lastPathComponent
                let ext = (fileName as NSString).pathExtension
                let base = (fileName as NSString).deletingPathExtension
                var candidate = ""
                var attempt = 0
                repeat {
                    let suffix = attempt == 0 ? timestamp : "\(timestamp)-\(attempt)"
                    let name = ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)"
                    candidate = (archiveParent as NSString).appendingPathComponent(name)
                    attempt += 1
                } while itemExists(atPath: candidate)
                archiveFile = candidate
                result.renamed[relativePath] = (candidate as NSString).lastPathComponent
            }

            do {
                try fileManager.moveItem(atPath: sourceFile, toPath: archiveFile)
            } catch {
                result.failures.append(Failure(relativePath: relativePath, reason: error.localizedDescription))
                continue
            }

            guard itemExists(atPath: archiveFile) else {
                result.failures.append(Failure(
                    relativePath: relativePath,
                    reason: "Move reported success but the archived file is missing"))
                continue
            }

            result.archived.append(relativePath)
        }

        return result
    }

    /// Create `root/relativePath` one component at a time, requiring each
    /// existing component to be a real directory. Symlinks are never
    /// followed, so an archived link can't redirect a move outside the archive.
    private func ensureDirectory(relativePath: String, under root: String) throws {
        var path = root
        let components = [""] + relativePath.split(separator: "/").map(String.init)
        for component in components {
            if !component.isEmpty {
                path = (path as NSString).appendingPathComponent(component)
            }
            if let type = try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType {
                guard type == .typeDirectory else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: path])
                }
            } else {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: component.isEmpty)
            }
        }
    }

    /// True if a file, directory, or symlink (even dangling) exists at path.
    private func itemExists(atPath path: String) -> Bool {
        if fileManager.fileExists(atPath: path) {
            return true
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
