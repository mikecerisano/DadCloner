import XCTest
@testable import DadClonerCore

final class LineSplitterTests: XCTestCase {
    func testSplitsOnNewlineAndCarriageReturnSkippingEmpty() {
        var s = LineSplitter()
        let lines = s.append(Data("a\nb\rc\r\n\n\rd\n".utf8))
        XCTAssertEqual(lines, ["a", "b", "c", "d"])
        XCTAssertEqual(s.finish(), [])
    }

    func testPartialLineWaitsForTerminator() {
        var s = LineSplitter()
        XCTAssertEqual(s.append(Data("hel".utf8)), [])
        XCTAssertEqual(s.append(Data("lo\nwor".utf8)), ["hello"])
        XCTAssertEqual(s.append(Data("ld\n".utf8)), ["world"])
    }

    func testMultibyteCharacterSplitAcrossAppends() {
        for text in ["caf\u{00E9}", "hi \u{1F600}!"] {
            let bytes = Array((text + "\n").utf8)
            for cut in 1..<bytes.count {
                var s = LineSplitter()
                var out = s.append(Data(bytes[..<cut]))
                out += s.append(Data(bytes[cut...]))
                XCTAssertEqual(out, [text], "cut at \(cut)")
            }
        }
    }

    func testFinishReturnsTrailingPartialAndResets() {
        var s = LineSplitter()
        XCTAssertEqual(s.append(Data("one\ntwo".utf8)), ["one"])
        XCTAssertEqual(s.finish(), ["two"])
        XCTAssertEqual(s.finish(), [])
        XCTAssertEqual(s.append(Data("x\n".utf8)), ["x"])
    }
}
