import Foundation

/// Finds files present in the backup but missing from the source
/// ("orphans" — deleted on the source, due to be archived), and removes
/// directories left empty after their contents were archived.
public struct OrphanScanner {

    /// Entries never treated as orphans: our own metadata plus macOS
    /// volume system directories. Hidden *user* files are intentionally
    /// NOT skipped — rsync copies them, so we must archive them too.
    // NOTE: "DadCloner_Archive" and ".dadcloner_backup" below must stay in
    // sync with SyncConfiguration.archiveDirectoryName / backupMarkerFilename
    // in the app target. DadClonerCore has no dependency on the app, so this
    // is enforced by convention — if you rename either there, update it here.
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

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: backupPath),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [] // include hidden files
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            guard let relativePath = relativePath(of: fileURL.path, under: backupPath) else { continue }

            let firstComponent = relativePath.components(separatedBy: "/").first ?? ""
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

            let sourceFile = (sourcePath as NSString).appendingPathComponent(relativePath)
            if !itemExists(atPath: sourceFile) {
                orphaned.append(relativePath)
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

            let firstComponent = relativePath.components(separatedBy: "/").first ?? ""
            if OrphanScanner.skipPaths.contains(firstComponent) {
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

    /// True if a file, directory, or symlink (even dangling) exists at path.
    private func itemExists(atPath path: String) -> Bool {
        if fileManager.fileExists(atPath: path) {
            return true
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
