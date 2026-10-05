import Foundation

/// Finds files present in the backup but missing from the source
/// ("orphans" — deleted on the source, due to be archived), and removes
/// directories left empty after their contents were archived.
public struct OrphanScanner {

    /// Entry names never treated as orphans, at any depth. Matches rsync's
    /// unanchored `--exclude` semantics.
    public static let skipNames: Set<String> = BackupLayout.excludedNames

    public struct ScanResult: Equatable, Sendable {
        /// Relative paths of orphaned files and symlinks.
        public var orphaned: [String]
        /// Number of files and symlinks examined in the backup.
        public var scannedFileCount: Int
    }

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Relative paths of regular files and symlinks that exist under
    /// `backupPath` but not under `sourcePath`.
    public func findOrphanedFiles(backupPath: String, sourcePath: String) throws -> [String] {
        try scan(backupPath: backupPath, sourcePath: sourcePath).orphaned
    }

    /// Like `findOrphanedFiles`, but also reports how many backup files were
    /// examined so callers can sanity-check the orphan count.
    public func scan(backupPath: String, sourcePath: String) throws -> ScanResult {
        var result = ScanResult(orphaned: [], scannedFileCount: 0)

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: backupPath),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [] // include hidden files
        ) else {
            return result
        }

        for case let fileURL as URL in enumerator {
            guard let relativePath = relativePath(of: fileURL.path, under: backupPath) else { continue }

            if OrphanScanner.skipNames.contains(fileURL.lastPathComponent) {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                continue
            }
            guard (values.isRegularFile ?? false) || (values.isSymbolicLink ?? false) else {
                continue
            }

            result.scannedFileCount += 1
            let sourceFile = (sourcePath as NSString).appendingPathComponent(relativePath)
            if !itemExists(atPath: sourceFile) {
                result.orphaned.append(relativePath)
            }
        }

        return result
    }

    /// Removes directories under `backupPath` that no longer exist under
    /// `sourcePath` and are empty (their contents were archived).
    /// Deepest directories are removed first so emptied parents follow.
    public func removeEmptyOrphanedDirectories(
        backupPath: String,
        sourcePath: String
    ) -> (removed: [String], warnings: [String]) {
        var candidates: [String] = []
        var removed: [String] = []
        var warnings: [String] = []

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: backupPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return ([], [])
        }

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            guard let relativePath = relativePath(of: fileURL.path, under: backupPath) else { continue }

            if OrphanScanner.skipNames.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            if !itemExists(atPath: (sourcePath as NSString).appendingPathComponent(relativePath)) {
                candidates.append(fileURL.path)
            }
        }

        for directory in candidates.sorted(by: { $0.count > $1.count }) {
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: directory)
                    .filter { $0 != ".DS_Store" }
                if contents.isEmpty {
                    try fileManager.removeItem(atPath: directory)
                    removed.append(directory)
                }
            } catch {
                warnings.append("\(directory): \(error.localizedDescription)")
            }
        }

        return (removed, warnings)
    }

    // MARK: - Helpers

    private func relativePath(of fullPath: String, under basePath: String) -> String? {
        guard fullPath.hasPrefix(basePath) else { return nil }
        var relative = String(fullPath.dropFirst(basePath.count))
        if relative.hasPrefix("/") {
            relative = String(relative.dropFirst())
        }
        return relative
    }

    /// False only when the source definitely has nothing at `path`
    /// (ENOENT / ENOTDIR). Any other error — permission denied, a macOS
    /// privacy block, an I/O error on a failing disk — counts as present,
    /// so an unreadable file is never mistaken for a deleted one.
    private func itemExists(atPath path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 {
            return true
        }
        return errno != ENOENT && errno != ENOTDIR
    }
}
