import XCTest
@testable import DadClonerCore

final class OrphanScannerDepthTests: TempDirTestCase {
    var source: URL!
    var backup: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        source = root.appendingPathComponent("source")
        backup = root.appendingPathComponent("backup")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
    }

    func testNestedDSStoreIsNotOrphaned() throws {
        try write("Projects/.DS_Store", under: backup)
        let result = try OrphanScanner().scan(backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(result.orphaned, [])
        XCTAssertEqual(result.scannedFileCount, 0)
    }

    func testNestedArchiveDirectoryIsSkippedWithContents() throws {
        try write("Projects/\(BackupLayout.archiveDirectoryName)/old.txt", under: backup)
        try write("Projects/real.txt", under: backup)
        let result = try OrphanScanner().scan(backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(result.orphaned, ["Projects/real.txt"])
        XCTAssertEqual(result.scannedFileCount, 1)
    }

    func testTopLevelArchiveAndMarkerSkipped() throws {
        try write("\(BackupLayout.archiveDirectoryName)/2026-01-01/a.txt", under: backup)
        try write(BackupLayout.backupMarkerFilename, under: backup)
        let result = try OrphanScanner().scan(backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(result.orphaned, [])
        XCTAssertEqual(result.scannedFileCount, 0)
    }

    func testScanCountsFilesAndSymlinksAndReportsOrphans() throws {
        try write("keep.txt", under: source)
        try write("keep.txt", under: backup)
        try write("gone.txt", under: backup)
        try write("sub/gone2.txt", under: backup)
        try fm.createSymbolicLink(atPath: backup.appendingPathComponent("link").path,
                                  withDestinationPath: "/nonexistent/target")
        let result = try OrphanScanner().scan(backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(result.scannedFileCount, 4)
        XCTAssertEqual(Set(result.orphaned), ["gone.txt", "sub/gone2.txt", "link"])
    }

    func testScanOfEmptyBackup() throws {
        let result = try OrphanScanner().scan(backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(result.scannedFileCount, 0)
        XCTAssertEqual(result.orphaned, [])
    }

    func testDirectoryWithOnlyDSStoreIsRemoved() throws {
        try write("old/.DS_Store", under: backup)
        let (removed, warnings) = OrphanScanner().removeEmptyOrphanedDirectories(
            backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(removed, [backup.appendingPathComponent("old").path])
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: backup.appendingPathComponent("old").path))
    }

    func testDirectoryWithRealFileIsKept() throws {
        try write("old/file.txt", under: backup)
        try write("old/.DS_Store", under: backup)
        let (removed, _) = OrphanScanner().removeEmptyOrphanedDirectories(
            backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(removed, [])
        XCTAssertTrue(fm.fileExists(atPath: backup.appendingPathComponent("old/file.txt").path))
    }

    func testDirectoryStillInSourceIsKept() throws {
        try fm.createDirectory(at: source.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try fm.createDirectory(at: backup.appendingPathComponent("dir"), withIntermediateDirectories: true)
        let (removed, _) = OrphanScanner().removeEmptyOrphanedDirectories(
            backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(removed, [])
    }

    func testEmptyArchiveDirectoryIsNotRemoved() throws {
        try fm.createDirectory(
            at: backup.appendingPathComponent(BackupLayout.archiveDirectoryName),
            withIntermediateDirectories: true)
        let (removed, _) = OrphanScanner().removeEmptyOrphanedDirectories(
            backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(removed, [])
    }
}
