import Foundation

/// Splits a byte stream into lines. Buffers raw bytes so a multibyte UTF-8
/// character split across reads is never lost, and treats `\r` as a line
/// break too because rsync's `--info=progress2` redraws its progress line
/// with carriage returns.
public struct LineSplitter {
    private var buffer = Data()

    public init() {}

    /// Append bytes and return every complete line now available.
    public mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer = Data(buffer[buffer.index(after: index)...])
            if !lineData.isEmpty {
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
        }
        return lines
    }

    /// Return any trailing partial line and reset.
    public mutating func finish() -> [String] {
        defer { buffer = Data() }
        guard !buffer.isEmpty else { return [] }
        return [String(decoding: buffer, as: UTF8.self)]
    }
}
