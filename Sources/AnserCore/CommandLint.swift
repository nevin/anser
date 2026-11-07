import Foundation

/// Checks a command line as you type: commands that don't exist, quotes and
/// brackets left open, and commands that can do serious damage. Ranges are
/// UTF-16 offsets (NSString), like the editor's.
public enum CommandLint {
    public enum Severity: Int, Sendable, Comparable {
        /// A mistake (red underline): unknown command, unclosed quote or bracket.
        case error = 1
        /// Worth a second look (orange): force push, reset --hard, curl | sh…
        case warning = 2
        /// Can destroy a lot (red, and Anser asks before running it).
        case danger = 3
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Issue: Equatable, Sendable {
        public var range: NSRange
        public var severity: Severity
        public var message: String
        public init(range: NSRange, severity: Severity, message: String) {
            self.range = range; self.severity = severity; self.message = message
        }
    }

    /// All issues in `line`. `isKnown` says whether a command name exists;
    /// `suggest` offers a likely intended name for an unknown one.
    public static func check(_ line: String, isKnown: (String) -> Bool, suggest: (String) -> String? = { _ in nil }) -> [Issue] {
        guard !line.isEmpty, (line as NSString).length <= 20_000 else { return [] }
        var out: [Issue] = []
        let tokens = ShellLexer.tokenize(line)
        let cmdPos = ShellLexer.commandPositions(tokens)
        for (i, t) in tokens.enumerated() where t.kind == .word {
            if cmdPos.contains(i) {
                let name = t.value
                // Assignments (FOO=bar), substitutions and placeholders aren't commands.
                if name.isEmpty || name.contains("=") || name.contains("$") || name.contains("{{") || t.raw.hasPrefix("(") { continue }
                if !isKnown(name) {
                    var msg = "“\(name)” isn't a command here."
                    if let s = suggest(name), s != name { msg += " Did you mean “\(s)”?" }
                    out.append(Issue(range: t.nsRange, severity: .error, message: msg))
                }
            }
            if let q = t.openQuote {
                let raw = t.raw as NSString
                let qi = raw.range(of: String(q), options: .backwards)
                let start = t.range.lowerBound + (qi.location == NSNotFound ? 0 : qi.location)
                out.append(Issue(range: NSRange(location: start, length: t.range.upperBound - start), severity: .error,
                                 message: "This \(q) quote isn't closed."))
            }
        }
        out += unbalancedBrackets(line)
        out += risky(line)
        return out
    }

    // MARK: Brackets

    private static let openers: [UInt16: UInt16] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]   // ( [ {
    private static let closers: [UInt16: UInt16] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]

    /// Bracket positions outside quotes and comments, paired up.
    /// Returns (pairs, unmatched positions).
    static func scanBrackets(_ line: String) -> (pairs: [(Int, Int)], unmatched: [Int]) {
        let u = Array(line.utf16)
        var stack: [Int] = [], pairs: [(Int, Int)] = [], unmatched: [Int] = []
        var i = 0
        var quote: UInt16? = nil
        while i < u.count {
            let c = u[i]
            if let q = quote {
                if c == 0x5C, q == 0x22 { i += 2; continue }        // \ inside "…"
                if c == q { quote = nil }
                i += 1; continue
            }
            switch c {
            case 0x5C: i += 2; continue                             // \x
            case 0x27, 0x22, 0x60: quote = c                        // ' " `
            case 0x23 where i == 0 || u[i - 1] == 0x20 || u[i - 1] == 0x0A:   // # comment to end of line
                while i < u.count, u[i] != 0x0A { i += 1 }
                continue
            default:
                if openers[c] != nil { stack.append(i) }
                else if let o = closers[c] {
                    if let top = stack.last, u[top] == o { stack.removeLast(); pairs.append((top, i)) } else { unmatched.append(i) }
                }
            }
            i += 1
        }
        return (pairs, unmatched + stack)
    }

    static func unbalancedBrackets(_ line: String) -> [Issue] {
        let u = Array(line.utf16)
        return scanBrackets(line).unmatched.map { i in
            let isOpen = openers[u[i]] != nil
            let ch = String(utf16CodeUnits: [u[i]], count: 1)
            return Issue(range: NSRange(location: i, length: 1), severity: .error,
                         message: isOpen ? "This \(ch) is never closed." : "This \(ch) has no matching opening bracket.")
        }
    }

    /// The bracket matching the one just before or at `index`, for highlighting both.
    public static func matchingBracket(in line: String, at index: Int) -> (Int, Int)? {
        let pairs = scanBrackets(line).pairs
        for candidate in [index - 1, index] {
            if let p = pairs.first(where: { $0.0 == candidate || $0.1 == candidate }) { return p }
        }
        return nil
    }

    // MARK: Risky commands

    struct Rule {
        let pattern: NSRegularExpression
        let severity: Severity
        let message: String
        init(_ p: String, _ s: Severity, _ m: String) {
            pattern = try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
            severity = s; message = m
        }
    }

    nonisolated(unsafe) static let rules: [Rule] = [
        Rule(#"\brm\s+(?:-[a-z]*\s+)*-[a-z]*[rR][a-z]*\s+(?:-[a-z]+\s+)*(?:"?(?:/|/\*|~/?|~/\*|\$HOME/?|/Users/?|/System|/Library|/Applications)"?)(?=\s|$|;|&|\|)"#,
             .danger, "This deletes everything in a top-level folder (or your whole home folder)."),
        Rule(#":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, .danger, "This is a fork bomb: it freezes the Mac until it restarts."),
        Rule(#"\bdd\b[^;&|]*\bof=/dev/(?:r?disk|sd|nvme|hd)"#, .danger, "This writes straight onto a disk, erasing what's on it."),
        Rule(#"\b(?:mkfs(?:\.\w+)?|newfs_\w+)\b"#, .danger, "This formats a disk, erasing it."),
        Rule(#"\bdiskutil\s+(?:erase\w*|partitionDisk|zeroDisk|randomDisk|secureErase)\b"#, .danger, "This erases a disk."),
        Rule(#">\s*/dev/(?:r?disk|sd|nvme)\w*"#, .danger, "This writes straight onto a disk, erasing what's on it."),
        Rule(#"\bchmod\s+-R\s+0?777\s+/(?:\s|$)"#, .danger, "This makes every file on the Mac writable by anyone."),
        Rule(#"\bgit\s+push\b(?=[^;&|]*\s(?:--force(?!-with-lease)|-f\b|-[a-z]*f[a-z]*\b|\+\S))"#, .warning,
             "Force push replaces the remote branch, including others' commits. --force-with-lease is safer."),
        Rule(#"\bgit\s+reset\s+(?:\S+\s+)*--hard\b"#, .warning, "reset --hard throws away uncommitted changes."),
        Rule(#"\bgit\s+clean\s+(?:\S+\s+)*-[a-z]*f"#, .warning, "git clean -f deletes untracked files for good."),
        Rule(#"\bgit\s+(?:checkout\s+--\s+\.|restore\s+(?:--\S+\s+)*\.)(?:\s|$)"#, .warning, "This discards all your uncommitted changes."),
        Rule(#"\b(?:curl|wget)\b[^|;&]*\|\s*(?:sudo\s+)?(?:ba|z|da|k)?sh\b"#, .warning,
             "This runs a script straight from the internet without letting you read it first."),
        Rule(#"\bchmod\s+(?:-R\s+)?0?777\b"#, .warning, "777 lets anyone change or run these files."),
        Rule(#"\bkubectl\s+delete\b[^;&|]*(?:--all\b|\bnamespace\b|\bns\b)"#, .warning, "This deletes many Kubernetes resources at once."),
        Rule(#"\b(?:drop\s+(?:table|database|schema)|truncate\s+table)\b"#, .warning, "This deletes data permanently."),
    ]

    static func risky(_ line: String) -> [Issue] {
        let ns = line as NSString
        var out: [Issue] = []
        for r in rules {
            for m in r.pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                // Rules don't fire inside a comment.
                let before = ns.substring(to: m.range.location)
                if before.range(of: #"(^|\s)#"#, options: .regularExpression) != nil, !before.contains("\n") { continue }
                out.append(Issue(range: m.range, severity: r.severity, message: r.message))
            }
        }
        // The worst first; one issue per spot.
        return out.sorted { $0.severity > $1.severity }.reduce(into: []) { acc, i in
            if !acc.contains(where: { NSIntersectionRange($0.range, i.range).length > 0 }) { acc.append(i) }
        }
    }
}
