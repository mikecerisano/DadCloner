import XCTest
@testable import DadClonerCore

final class ArchiveMoverTests: TempDirTestCase {
    var backup: URL!
    var day: String!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        backup = root.appendingPathComponent("backup")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        day = root.appendingPathComponent("archive/2026-01-01").path
    }

    /// Same formatting the mover uses (current time zone).
    var stamp: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss"
        return f.string(from: now)
    }

    func path(_ rel: String) -> String { (day as NSString).appendingPathComponent(rel) }

    func testMovesFilesPreservingRelativePaths() throws {
        try write("a/b/one.txt", under: backup, contents: "1")
        try write("two.txt", under: backup, contents: "2")
        let result = ArchiveMover().archive(
            relativePaths: ["a/b/one.txt", "two.txt"], backupRoot: backup.path, dayFolder: day, now: now)
        XCTAssertEqual(result.archived, ["a/b/one.txt", "two.txt"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(result.renamed.isEmpty)
        XCTAssertEqual(try String(contentsOfFile: path("a/b/one.txt")), "1")
        XCTAssertEqual(try String(contentsOfFile: path("two.txt")), "2")
        XCTAssertFalse(fm.fileExists(atPath: backup.appendingPathComponent("a/b/one.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: backup.appendingPathComponent("two.txt").path))
    }

    func testCollisionAddsTimestampBeforeExtension() throws {
        try write("doc.txt", under: backup, contents: "new")
        try fm.createDirectory(atPath: day, withIntermediateDirectories: true)
        try "old".write(toFile: path("doc.txt"), atomically: true, encoding: .utf8)
        let result = ArchiveMover().archive(
            relativePaths: ["doc.txt"], backupRoot: backup.path, dayFolder: day, now: now)
        XCTAssertEqual(result.archived, ["doc.txt"])
        XCTAssertEqual(result.renamed["doc.txt"], "doc_\(stamp).txt")
        XCTAssertEqual(try String(contentsOfFile: path("doc.txt")), "old")
        XCTAssertEqual(try String(contentsOfFile: path("doc_\(stamp).txt")), "new")
    }

    func testSecondCollisionInSameSecondGetsDashOne() throws {
        try fm.createDirectory(atPath: day, withIntermediateDirectories: true)
        try "old".write(toFile: path("doc.txt"), atomically: true, encoding: .utf8)
        try write("doc.txt", under: backup, contents: "second")
        _ = ArchiveMover().archive(relativePaths: ["doc.txt"], backupRoot: backup.path, dayFolder: day, now: now)
        try write("doc.txt", under: backup, contents: "third")
        let result = ArchiveMover().archive(
            relativePaths: ["doc.txt"], backupRoot: backup.path, dayFolder: day, now: now)
        XCTAssertEqual(result.renamed["doc.txt"], "doc_\(stamp)-1.txt")
        XCTAssertEqual(try String(contentsOfFile: path("doc_\(stamp)-1.txt")), "third")
        XCTAssertEqual(try String(contentsOfFile: path("doc_\(stamp).txt")), "second")
        XCTAssertEqual(try String(contentsOfFile: path("doc.txt")), "old")
    }

    func testCollisionInSubfolderStaysInSubfolder() throws {
        try fm.createDirectory(atPath: path("sub"), withIntermediateDirectories: true)
        try "old".write(toFile: path("sub/doc.txt"), atomically: true, encoding: .utf8)
        try write("sub/doc.txt", under: backup, contents: "new")
        let result = ArchiveMover().archive(
            relativePaths: ["sub/doc.txt"], backupRoot: backup.path, dayFolder: day, now: now)
        XCTAssertTrue(fm.fileExists(atPath: path("sub/doc_\(stamp).txt")))
        XCTAssertEqual(result.archived, ["sub/doc.txt"])
    }

    func testCollisionWithoutExtensionAppendsSuffix() throws {
        try fm.createDirectory(atPath: day, withIntermediateDirectories: true)
        try "old".write(toFile: path("Makefile"), atomically: true, encoding: .utf8)
        try write("Makefile", under: backup, contents: "new")
        let result = ArchiveMover().archive(
            relativePaths: ["Makefile"], backupRoot: backup.path, dayFolder: day, now: now)
        XCTAssertEqual(result.renamed["Makefile"], "Makefile_\(stamp)")
        XCTAssertEqual(try String(contentsOfFile: path("Makefile_\(stamp)")), "new")
    }

    func testMissingSourceFileIsFailureNotThrow() throws {
        try write("real.txt", under: backup)
        let result = ArchiveMover().archive(
            relativePaths: ["missing.txt", "real.txt"], backupRoot: backup.path, dayFolder: day, now: now)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.relativePath, "missing.txt")
        XCTAssertFalse(result.failures.first?.reason.isEmpty ?? true)
        XCTAssertEqual(result.archived, ["real.txt"])
    }

    func testMovesSymlinksIncludingDanglingAsLinks() throws {
        try write("target.txt", under: backup)
        try fm.createSymbolicLink(atPath: backup.appendingPathComponent("good").path,
                                  withDestinationPath: "target.txt")
        try fm.createSymbolicLink(atPath: backup.appendingPathComponent("dangling").path,
                                  withDestinationPath: "/no/such/place")
        let result = ArchiveMover().archive(
            relativePaths: ["good", "dangling"], backupRoot: backup.path, dayFolder: day, now: now)
        XCTAssertEqual(result.archived, ["good", "dangling"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: path("good")), "target.txt")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: path("dangling")), "/no/such/place")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: backup.appendingPathComponent("dangling").path))
        // target untouched
        XCTAssertTrue(fm.fileExists(atPath: backup.appendingPathComponent("target.txt").path))
    }

    func testDayFolderUsesCalendarTimeZone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // 2026-03-10 20:00 UTC == 2026-03-11 05:00 Tokyo
        let date = Date(timeIntervalSince1970: 1_773_172_800)
        XCTAssertEqual(ArchiveMover.dayFolder(archiveRoot: "/arch", now: date, calendar: utc), "/arch/2026-03-10")
        XCTAssertEqual(ArchiveMover.dayFolder(archiveRoot: "/arch", now: date, calendar: tokyo), "/arch/2026-03-11")
    }
}
