import XCTest
@testable import DadClonerCore

final class RsyncOutputTests: XCTestCase {

    // MARK: progressPercent

    func testProgressPercentParsesInfoProgress2Line() {
        let line = "  1,234,567  42%   10.5MB/s    0:00:12"
        XCTAssertEqual(RsyncOutput.progressPercent(from: line), 0.42)
    }

    func testProgressPercentReturnsNilForFileLine() {
        XCTAssertNil(RsyncOutput.progressPercent(from: ">f+++++++++ Music/song.aif"))
    }

    func testProgressPercentReturnsNilForEmptyLine() {
        XCTAssertNil(RsyncOutput.progressPercent(from: "   "))
    }

    func testProgressPercentIgnoresPercentInFilename() {
        // A file line whose name contains '%' must not be read as progress
        XCTAssertNil(RsyncOutput.progressPercent(from: ">f+++++++++ mixes/100% done.wav"))
    }

    // MARK: isFileLine / filename

    func testIsFileLineMatchesItemizedPrefixes() {
        XCTAssertTrue(RsyncOutput.isFileLine(">f+++++++++ a.txt"))
        XCTAssertTrue(RsyncOutput.isFileLine("<f.st...... b.txt"))
        XCTAssertTrue(RsyncOutput.isFileLine("cf+++++++++ c.txt"))
        XCTAssertFalse(RsyncOutput.isFileLine("cd+++++++++ somedir/"))
        XCTAssertFalse(RsyncOutput.isFileLine("total size is 1,000"))
    }

    func testFilenameExtractsPathAfterFlags() {
        XCTAssertEqual(RsyncOutput.filename(from: ">f+++++++++ Music/song.aif"), "Music/song.aif")
    }

    func testFilenameReturnsWholeLineWithoutSpace() {
        XCTAssertEqual(RsyncOutput.filename(from: "oddline"), "oddline")
    }

    // MARK: transferredFileSize

    func testTransferredFileSizeParsesStatsBlock() {
        let stats = """
        Number of files: 120 (reg: 100, dir: 20)
        Total transferred file size: 1,234,567 bytes
        Literal data: 0 bytes
        """
        XCTAssertEqual(RsyncOutput.transferredFileSize(fromStats: stats), 1_234_567)
    }

    func testTransferredFileSizeNilWhenAbsent() {
        XCTAssertNil(RsyncOutput.transferredFileSize(fromStats: "no stats here"))
    }

    // MARK: fileCount

    func testFileCountCountsOnlyFileLines() {
        let output = """
        cd+++++++++ dir/
        >f+++++++++ dir/a.txt
        <f.st...... dir/b.txt
        cf+++++++++ dir/c.txt
        total size is 12345
        """
        XCTAssertEqual(RsyncOutput.fileCount(fromItemized: output), 3)
    }
}
