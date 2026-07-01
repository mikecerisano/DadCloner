// DadClonerCore/Tests/DadClonerCoreTests/LogRotatorTests.swift
import XCTest
@testable import DadClonerCore

final class LogRotatorTests: XCTestCase {

    var path: String!
    let fm = FileManager.default

    override func setUp() {
        path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("LogRotatorTests-\(UUID().uuidString).txt")
    }

    override func tearDown() {
        try? fm.removeItem(atPath: path)
    }

    func size() throws -> Int {
        (try fm.attributesOfItem(atPath: path)[.size] as! NSNumber).intValue
    }

    func testSmallFileIsUntouched() throws {
        try "short log\n".write(toFile: path, atomically: true, encoding: .utf8)
        try LogRotator.rotate(fileAtPath: path, maxBytes: 1000, keepBytes: 500)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "short log\n")
    }

    func testMissingFileIsANoOp() throws {
        XCTAssertNoThrow(try LogRotator.rotate(fileAtPath: path, maxBytes: 1000, keepBytes: 500))
        XCTAssertFalse(fm.fileExists(atPath: path))
    }

    func testOversizedFileIsTrimmedToTail() throws {
        let lines = (0..<200).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try lines.write(toFile: path, atomically: true, encoding: .utf8)
        try LogRotator.rotate(fileAtPath: path, maxBytes: 500, keepBytes: 300)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertLessThanOrEqual(try size(), 300 + 100) // tail + truncation header
        XCTAssertTrue(content.hasPrefix("[log truncated]"))
        XCTAssertTrue(content.hasSuffix("line 199\n"))   // newest entries kept
    }

    func testTrimStartsAtLineBoundary() throws {
        let lines = (0..<200).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try lines.write(toFile: path, atomically: true, encoding: .utf8)
        try LogRotator.rotate(fileAtPath: path, maxBytes: 500, keepBytes: 300)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        // Second line of output (after the truncation header) must be a
        // complete "line N" entry, not a partial one.
        let secondLine = content.components(separatedBy: "\n")[1]
        XCTAssertTrue(secondLine.hasPrefix("line "), "got partial line: \(secondLine)")
    }
}
