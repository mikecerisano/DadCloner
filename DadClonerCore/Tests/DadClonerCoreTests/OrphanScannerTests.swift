import XCTest
@testable import DadClonerCore

final class OrphanScannerTests: XCTestCase {

    var root: URL!
    var source: URL!
    var backup: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        // NSTemporaryDirectory() on macOS lives under /var, which is itself
        // a symlink to /private/var. URL.resolvingSymlinksInPath() only
        // resolves the final path component if it's a symlink, so it does
        // NOT canonicalize this path; the .canonicalPathKey resource value
        // does a full realpath()-style resolution and is what we need so
        // paths built under `root` match what FileManager's enumerator
        // reports back.
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        let canonicalPath = (try? tempRoot.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? nil
        root = URL(fileURLWithPath: canonicalPath ?? tempRoot.path)
            .appendingPathComponent("OrphanScannerTests-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        backup = root.appendingPathComponent("backup")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func write(_ relative: String, under base: URL) throws {
        let url = base.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
    }

    func testFileInBothIsNotOrphaned() throws {
        try write("a/keep.txt", under: source)
        try write("a/keep.txt", under: backup)
        let orphans = try OrphanScanner().findOrphanedFiles(
            backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(orphans, [])
    }

    func testFileOnlyInBackupIsOrphaned() throws {
        try write("a/deleted.txt", under: backup)
        let orphans = try OrphanScanner().findOrphanedFiles(
            backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(orphans, ["a/deleted.txt"])
    }

    func testHiddenUserFileIsOrphaned() throws {
        try write(".config-gone", under: backup)
        let orphans = try OrphanScanner().findOrphanedFiles(
            backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(orphans, [".config-gone"])
    }

    func testArchiveDirAndMarkerAreSkipped() throws {
        try write("DadCloner_Archive/2026-01-01/old.txt", under: backup)
        try write(".dadcloner_backup", under: backup)
        try write(".DS_Store", under: backup)
        let orphans = try OrphanScanner().findOrphanedFiles(
            backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(orphans, [])
    }

    func testDanglingSymlinkInSourceCountsAsExisting() throws {
        // rsync copies symlinks as symlinks; a dangling symlink in source
        // still means the entry exists and must NOT be archived.
        try write("link-target-gone", under: backup)
        try fm.createSymbolicLink(
            atPath: source.appendingPathComponent("link-target-gone").path,
            withDestinationPath: "/nonexistent/target")
        let orphans = try OrphanScanner().findOrphanedFiles(
            backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(orphans, [])
    }

    func testRemoveEmptyOrphanedDirectoriesRemovesOnlyEmptyOrphans() throws {
        // "emptied" exists only in backup and is empty -> removed.
        // "occupied" exists only in backup but still has a file -> kept.
        // "shared" exists in source too -> kept even though empty.
        try fm.createDirectory(at: backup.appendingPathComponent("emptied"), withIntermediateDirectories: true)
        try write("occupied/still-here.txt", under: backup)
        try fm.createDirectory(at: backup.appendingPathComponent("shared"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("shared"), withIntermediateDirectories: true)

        let result = OrphanScanner().removeEmptyOrphanedDirectories(
            backupPath: backup.path, sourcePath: source.path)

        XCTAssertEqual(result.removed, [backup.appendingPathComponent("emptied").path])
        XCTAssertTrue(fm.fileExists(atPath: backup.appendingPathComponent("occupied").path))
        XCTAssertTrue(fm.fileExists(atPath: backup.appendingPathComponent("shared").path))
    }

    func testNestedEmptyOrphanedDirectoriesRemovedDeepestFirst() throws {
        try fm.createDirectory(
            at: backup.appendingPathComponent("outer/inner"),
            withIntermediateDirectories: true)
        let result = OrphanScanner().removeEmptyOrphanedDirectories(
            backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(Set(result.removed), [
            backup.appendingPathComponent("outer/inner").path,
            backup.appendingPathComponent("outer").path,
        ])
    }
}
