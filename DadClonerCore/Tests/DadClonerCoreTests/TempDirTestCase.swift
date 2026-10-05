import XCTest

/// Base class giving each test a canonical temp directory, removed in tearDown.
class TempDirTestCase: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        let canonicalPath = (try? tempRoot.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? nil
        root = URL(fileURLWithPath: canonicalPath ?? tempRoot.path)
            .appendingPathComponent("DadClonerTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func write(_ relative: String, under base: URL, contents: String = "x") throws {
        let url = base.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
