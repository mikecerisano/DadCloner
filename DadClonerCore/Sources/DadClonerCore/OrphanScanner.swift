import Foundation
import Darwin

/// Finds files present in the backup but missing from the source
/// ("orphans" — deleted on the source, due to be archived), and removes
/// directories left empty after their contents were archived.
public struct OrphanScanner {

    /// Entries never treated as orphans: our own metadata plus macOS
    /// volume system directories. Hidden *user* files are intentionally
    /// NOT skipped — rsync copies them, so we must archive them too.
    public static let skipPaths: Set<String> = [
        "DadCloner_Archive",
        ".dadcloner_backup",
        ".DS_Store",
        ".Spotlight-V100",
        ".fseventsd",
        ".Trashes",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
        ".PKInstallSandboxManager-SystemSoftware"
    ]

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Relative paths of regular files and symlinks that exist under
    /// `backupPath` but not under `sourcePath`.
    public func findOrphanedFiles(backupPath: String, sourcePath: String) throws -> [String] {
        var orphaned: [String] = []

        // Resolve symlinks in paths for comparison (important on macOS where /var -> /private/var)
        let resolvedBackupPath = resolveSymlinks(backupPath)
        let resolvedSourcePath = resolveSymlinks(sourcePath)

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: resolvedBackupPath),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [] // include hidden files
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            let fullPath = fileURL.path
            guard fullPath.hasPrefix(resolvedBackupPath) else { continue }

            var relPath = String(fullPath.dropFirst(resolvedBackupPath.count))
            if relPath.hasPrefix("/") {
                relPath = String(relPath.dropFirst())
            }

            let firstComponent = relPath.components(separatedBy: "/").first ?? ""
            if OrphanScanner.skipPaths.contains(firstComponent) {
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

            // Check if exists in source using resolved path
            let sourceFile = (resolvedSourcePath as NSString).appendingPathComponent(relPath)
            if !itemExists(atPath: sourceFile) {
                orphaned.append(relPath)
            }
        }

        return orphaned
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

        // Resolve symlinks in paths for comparison (important on macOS where /var -> /private/var)
        let resolvedBackupPath = resolveSymlinks(backupPath)
        let resolvedSourcePath = resolveSymlinks(sourcePath)

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: resolvedBackupPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return ([], [])
        }

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let fullPath = fileURL.path
            guard fullPath.hasPrefix(resolvedBackupPath) else { continue }

            var relPath = String(fullPath.dropFirst(resolvedBackupPath.count))
            if relPath.hasPrefix("/") {
                relPath = String(relPath.dropFirst())
            }

            let firstComponent = relPath.components(separatedBy: "/").first ?? ""
            if OrphanScanner.skipPaths.contains(firstComponent) {
                enumerator.skipDescendants()
                continue
            }

            if !itemExists(atPath: (resolvedSourcePath as NSString).appendingPathComponent(relPath)) {
                // Store the full path, which we'll need for file operations
                candidates.append(fullPath)
            }
        }

        for resolvedDirPath in candidates.sorted(by: { $0.count > $1.count }) {
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: resolvedDirPath)
                if contents.isEmpty {
                    try fileManager.removeItem(atPath: resolvedDirPath)
                    // Convert back to original path format for return value
                    let normalizedPath = normalizePathToMatch(resolvedDirPath, resolvedBackupPath: resolvedBackupPath, originalBackupPath: backupPath)
                    removed.append(normalizedPath)
                }
            } catch {
                warnings.append("\(resolvedDirPath): \(error.localizedDescription)")
            }
        }

        return (removed, warnings)
    }

    /// Convert a resolved path back to the format of the original input path.
    /// This handles macOS symlinks where /var -> /private/var.
    private func normalizePathToMatch(
        _ resolvedPath: String,
        resolvedBackupPath: String,
        originalBackupPath: String
    ) -> String {
        // If the paths are already in the same format, return as-is
        if originalBackupPath == resolvedBackupPath {
            return resolvedPath
        }

        // Replace the resolved prefix with the original prefix
        guard resolvedPath.hasPrefix(resolvedBackupPath) else { return resolvedPath }
        let suffix = String(resolvedPath.dropFirst(resolvedBackupPath.count))
        return originalBackupPath + suffix
    }

    // MARK: - Helpers

    /// Resolves symlinks and standardizes paths for comparison.
    /// Important on macOS where /var -> /private/var.
    private func resolveSymlinks(_ path: String) -> String {
        // Use realpath to resolve symlinks (Darwin API)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil {
            return String(cString: buffer)
        }
        return path
    }

    /// True if a file, directory, or symlink (even dangling) exists at path.
    private func itemExists(atPath path: String) -> Bool {
        if fileManager.fileExists(atPath: path) {
            return true
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
