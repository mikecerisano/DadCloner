import Foundation

/// Keeps an append-only text log bounded: when the file exceeds
/// `maxBytes`, it is rewritten as a truncation header plus the last
/// `keepBytes` of content, trimmed forward to the next line boundary
/// so no partial line survives.
public enum LogRotator {

    public static func rotate(
        fileAtPath path: String,
        maxBytes: Int,
        keepBytes: Int,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard let sizeNumber = attributes[.size] as? NSNumber,
              sizeNumber.intValue > maxBytes else {
            return
        }

        guard let data = fileManager.contents(atPath: path) else {
            return
        }
        var tail = data.suffix(keepBytes)

        // Drop the (likely partial) first line of the tail.
        if let newlineIndex = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newlineIndex)...]
        } else {
            // If the tail contains no newline at all, no complete line survives.
            // Drop the tail entirely to honor the "no partial line" guarantee.
            tail = Data()
        }

        var output = Data("[log truncated] older entries removed to keep this file small\n".utf8)
        output.append(tail)
        try output.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
