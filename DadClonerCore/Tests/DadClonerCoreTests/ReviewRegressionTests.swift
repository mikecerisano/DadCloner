import XCTest
@testable import DadClonerCore

/// Regressions for data-safety issues found in review.
final class ReviewRegressionTests: TempDirTestCase {
    var source: URL!
    var backup: URL!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        source = root.appendingPathComponent("source")
        backup = root.appendingPathComponent("backup")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore permissions so cleanup can delete everything
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("Locked").path)
        try super.tearDownWithError()
    }

    /// A folder on the source we can't read must not make its backed-up
    /// files look deleted.
    func testUnreadableSourceFolderIsNotOrphaned() throws {
        try write("Locked/song.wav", under: source)
        try write("Locked/song.wav", under: backup)
        try write("Gone.wav", under: backup)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.appendingPathComponent("Locked").path)

        let result = try OrphanScanner().scan(backupPath: backup.path, sourcePath: source.path)
        XCTAssertEqual(result.orphaned, ["Gone.wav"])
    }

    /// "X" archived earlier as a file, now "X/y" is orphaned: archive it
    /// under a sibling root instead of failing the whole sync.
    func testFileWhereFolderIsNeededUsesSiblingRoot() throws {
        let day = root.appendingPathComponent("archive/2026-01-01").path
        try write("X", under: URL(fileURLWithPath: day), contents: "old file")
        try write("X/y.txt", under: backup, contents: "y")

        let result = ArchiveMover().archive(relativePaths: ["X/y.txt"], backupRoot: backup.path, dayFolder: day, now: now)

        XCTAssertEqual(result.archived, ["X/y.txt"])
        XCTAssertTrue(result.failures.isEmpty)
        let renamed = try XCTUnwrap(result.renamed["X/y.txt"])
        XCTAssertTrue(renamed.hasPrefix("2026-01-01 "))
        let moved = root.appendingPathComponent("archive").appendingPathComponent(renamed).path
        XCTAssertEqual(try String(contentsOfFile: moved), "y")
        XCTAssertEqual(try String(contentsOfFile: (day as NSString).appendingPathComponent("X")), "old file")
    }

    /// An archived symlink named "X" pointing at a real folder must never
    /// let "X/y" be moved through the link to outside the archive.
    func testNeverMovesThroughArchivedSymlink() throws {
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let day = root.appendingPathComponent("archive/2026-01-01")
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: day.appendingPathComponent("X"), withDestinationURL: outside)
        try write("X/y.txt", under: backup, contents: "y")

        let result = ArchiveMover().archive(relativePaths: ["X/y.txt"], backupRoot: backup.path, dayFolder: day.path, now: now)

        XCTAssertEqual(result.archived, ["X/y.txt"])
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("y.txt").path))
        let renamed = try XCTUnwrap(result.renamed["X/y.txt"])
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("archive").appendingPathComponent(renamed).path))
    }
}
