import Foundation

/// The dim "   you@mac · 14:02:11" line the shell prints after each command (Anser
/// draws the line or dots around it). Older ones look like "── you@mac · 14:02:11 ──".
/// It sits between a command's output and the next prompt, so Ghostty counts it as
/// output; this takes it back off.
public enum CommandSeparator {
    static let pattern = try! NSRegularExpression(
        pattern: #"^(\s*(─{2}|┄{2}) \S+ · \d{2}:\d{2}:\d{2} [─┄]+|   \S+@\S+ · \d{2}:\d{2}:\d{2})\s*$"#)

    public static func isSeparator(_ line: String) -> Bool {
        pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// `text` without a separator line (and the blank lines around it) at its end.
    public static func strip(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var end = lines.count
        while end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        guard end > 0, isSeparator(lines[end - 1]) else { return text }
        lines.removeSubrange((end - 1)...)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}
