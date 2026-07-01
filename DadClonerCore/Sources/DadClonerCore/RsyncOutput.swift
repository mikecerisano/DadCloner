import Foundation

/// Parsers for the output of `rsync -av --itemize-changes --info=progress2`
/// and `rsync --dry-run --stats`. Pure functions; no I/O.
public enum RsyncOutput {

    /// Overall progress from an --info=progress2 line, as 0.0...1.0.
    /// Returns nil for anything that isn't a progress line (including
    /// itemized file lines, whose names may contain '%').
    public static func progressPercent(from line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isFileLine(trimmed) { return nil }
        for token in trimmed.split(separator: " ") {
            if token.hasSuffix("%"), let value = Double(token.dropLast()) {
                return value / 100.0
            }
        }
        return nil
    }

    /// Whether an --itemize-changes line describes a transferred file.
    public static func isFileLine(_ line: String) -> Bool {
        line.hasPrefix(">f") || line.hasPrefix("<f") || line.hasPrefix("cf")
    }

    /// The file path portion of an itemized change line.
    public static func filename(from line: String) -> String {
        guard let spaceIndex = line.firstIndex(of: " ") else { return line }
        return line[line.index(after: spaceIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Total transferred file size" from `rsync --dry-run --stats` output.
    public static func transferredFileSize(fromStats output: String) -> Int64? {
        for line in output.components(separatedBy: .newlines) {
            guard line.lowercased().contains("total transferred file size:") else { continue }
            guard let valuePart = line.split(separator: ":", maxSplits: 1).last else { return nil }
            return Int64(valuePart.filter { $0.isNumber })
        }
        return nil
    }

    /// Number of files a dry run reports it would transfer.
    public static func fileCount(fromItemized output: String) -> Int {
        output.components(separatedBy: "\n").filter { isFileLine($0) }.count
    }
}
