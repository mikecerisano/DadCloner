import XCTest
@testable import DadClonerCore

final class RsyncCommandTests: XCTestCase {
    let args = RsyncCommand.arguments(source: "/Users/dad", destination: "/Volumes/Backup", replacedDir: "/Volumes/Backup/DadCloner_Archive/r")

    func testContainsRequiredFlags() {
        for flag in ["-a", "-X", "--crtimes", "--one-file-system", "--backup",
                     "--backup-dir=/Volumes/Backup/DadCloner_Archive/r"] {
            XCTAssertTrue(args.contains(flag), flag)
        }
    }

    func testExcludesEveryLayoutName() {
        for name in BackupLayout.excludedNames {
            let i = args.firstIndex(of: name)
            XCTAssertNotNil(i, name)
            if let i { XCTAssertEqual(args[i - 1], "--exclude", name) }
        }
    }

    func testNeverDeletes() {
        XCTAssertFalse(args.contains { $0.lowercased().contains("delete") }
                       && !args.contains { $0.hasPrefix("--backup-dir=") })
        // --backup-dir value may legitimately not contain "delete"; check strictly:
        XCTAssertFalse(args.contains { $0.contains("delete") })
        let dry = RsyncCommand.dryRunArguments(source: "/a", destination: "/b", replacedDir: "/r")
        XCTAssertFalse(dry.contains { $0.contains("delete") })
    }

    func testSourceAndDestinationGetTrailingSlashesAndAreLast() {
        XCTAssertEqual(Array(args.suffix(2)), ["/Users/dad/", "/Volumes/Backup/"])
        let already = RsyncCommand.arguments(source: "/a/", destination: "/b/", replacedDir: "/r")
        XCTAssertEqual(Array(already.suffix(2)), ["/a/", "/b/"])
    }

    func testDryRunArguments() {
        let dry = RsyncCommand.dryRunArguments(source: "/a", destination: "/b", replacedDir: "/r")
        XCTAssertEqual(Array(dry.prefix(2)), ["--dry-run", "--stats"])
        XCTAssertEqual(Array(dry.suffix(2)), ["/a/", "/b/"])
        XCTAssertTrue(dry.contains("--backup"))
    }

    func testReplacedFolderFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_773_172_800 + 3 * 3600 + 4 * 60 + 5) // 2026-03-10 23:04:05 UTC
        XCTAssertEqual(
            RsyncCommand.replacedFolder(archiveRoot: "/arch", now: date, calendar: cal),
            "/arch/2026-03-10 replaced 23.04.05")
    }

    func testOutcome() {
        XCTAssertEqual(RsyncOutcome(exitCode: 0), .success)
        XCTAssertEqual(RsyncOutcome(exitCode: 23), .partial)
        XCTAssertEqual(RsyncOutcome(exitCode: 24), .partial)
        for code: Int32 in [1, 2, 12, 30, 255, -1] {
            XCTAssertEqual(RsyncOutcome(exitCode: code), .failure, "\(code)")
        }
    }
}
