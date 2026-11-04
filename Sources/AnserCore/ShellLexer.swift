import Foundation

/// A token in a shell command line. Ranges are UTF-16 offsets so they map
/// directly onto NSTextView / NSString ranges.
public struct ShellToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case word        // a command, argument or option
        case op          // | || && ; & ( ) and redirections
        case comment
    }

    public var kind: Kind
    /// The raw source text, quotes and escapes included.
    public var raw: String
    /// The word with quotes and escapes removed.
    public var value: String
    public var range: Range<Int>
    /// True if any part of the word was quoted.
    public var quoted: Bool
    /// Quote character still open at the end of the input, if any.
    public var openQuote: Character?

    public var nsRange: NSRange { NSRange(location: range.lowerBound, length: range.count) }

    public init(kind: Kind, raw: String, value: String, range: Range<Int>, quoted: Bool, openQuote: Character?) {
        self.kind = kind; self.raw = raw; self.value = value; self.range = range; self.quoted = quoted; self.openQuote = openQuote
    }
}

public enum ShellLexer {
    public static let controlOps: Set<String> = ["|", "||", "&&", ";", "&", "(", ")", "|&", ";;"]
    public static let redirectOps: Set<String> = [">", ">>", "<", "<<", "<<<", "&>", ">&", "2>", "2>>", "&>>", "2>&1", ">|"]

    /// Splits a command line into tokens. Never fails: unterminated quotes
    /// simply run to the end of the input.
    public static func tokenize(_ line: String) -> [ShellToken] {
        let chars = Array(line.utf16)
        var tokens: [ShellToken] = []
        var i = 0
        let n = chars.count

        func ch(_ k: Int) -> Character? {
            guard k < n, let s = Unicode.Scalar(chars[k]) else { return nil }
            return Character(s)
        }

        while i < n {
            let c = ch(i)
            // Skip unescaped whitespace.
            if c == " " || c == "\t" || c == "\n" {
                // A newline acts like ';'
                if c == "\n" {
                    tokens.append(ShellToken(kind: .op, raw: "\n", value: ";", range: i..<(i + 1), quoted: false, openQuote: nil))
                }
                i += 1
                continue
            }
            // Comments only start at the beginning of a word.
            if c == "#" {
                let start = i
                while i < n, ch(i) != "\n" { i += 1 }
                let raw = String(utf16CodeUnits: Array(chars[start..<i]), count: i - start)
                tokens.append(ShellToken(kind: .comment, raw: raw, value: raw, range: start..<i, quoted: false, openQuote: nil))
                continue
            }
            // Operators: try the longest match first.
            if let c, "|&;()<>".contains(c) || (c == "2" && (ch(i + 1) == ">")) {
                var matched: String?
                for len in stride(from: 4, through: 1, by: -1) where i + len <= n {
                    let cand = String(utf16CodeUnits: Array(chars[i..<(i + len)]), count: len)
                    if controlOps.contains(cand) || redirectOps.contains(cand) { matched = cand; break }
                }
                if let op = matched {
                    let len = op.utf16.count
                    tokens.append(ShellToken(kind: .op, raw: op, value: op, range: i..<(i + len), quoted: false, openQuote: nil))
                    i += len
                    continue
                }
            }
            // A word.
            let start = i
            var value = ""
            var quoted = false
            var openQuote: Character?
            wordLoop: while i < n {
                guard let c = ch(i) else { i += 1; continue }
                switch c {
                case " ", "\t", "\n", "|", "&", ";", "(", ")", "<", ">":
                    break wordLoop
                case "\\":
                    if let next = ch(i + 1) { value.append(next); i += 2 } else { i += 1 }
                case "'":
                    quoted = true
                    i += 1
                    var closed = false
                    while i < n {
                        if ch(i) == "'" { closed = true; i += 1; break }
                        if let x = ch(i) { value.append(x) }
                        i += 1
                    }
                    if !closed { openQuote = "'" }
                case "\"":
                    quoted = true
                    i += 1
                    var closed = false
                    while i < n {
                        let x = ch(i)
                        if x == "\"" { closed = true; i += 1; break }
                        if x == "\\", let next = ch(i + 1), "\"\\$`".contains(next) { value.append(next); i += 2; continue }
                        if let x { value.append(x) }
                        i += 1
                    }
                    if !closed { openQuote = "\"" }
                default:
                    // Surrogate pairs: decode properly.
                    if UTF16.isLeadSurrogate(chars[i]), i + 1 < n {
                        let s = String(utf16CodeUnits: [chars[i], chars[i + 1]], count: 2)
                        value += s
                        i += 2
                    } else {
                        value.append(c)
                        i += 1
                    }
                }
            }
            let raw = String(utf16CodeUnits: Array(chars[start..<i]), count: i - start)
            tokens.append(ShellToken(kind: .word, raw: raw, value: value, range: start..<i, quoted: quoted, openQuote: openQuote))
        }
        return tokens
    }

    /// Commands that run another command, so the word after them is a command too.
    public static let precommands: Set<String> = [
        "sudo", "time", "nohup", "exec", "command", "builtin", "nice", "env", "xargs",
        "watch", "caffeinate", "noglob", "doas", "then", "do", "else", "if", "while", "until", "!",
    ]

    /// Returns the indices of words that are in command position (the program
    /// being run), taking pipes, `&&`, `sudo`, and `FOO=bar` prefixes into account.
    public static func commandPositions(_ tokens: [ShellToken]) -> Set<Int> {
        var result: Set<Int> = []
        var expectCommand = true
        var afterRedirect = false
        for (idx, t) in tokens.enumerated() {
            switch t.kind {
            case .comment: continue
            case .op:
                if redirectOps.contains(t.value) { afterRedirect = true } else { expectCommand = true }
            case .word:
                if afterRedirect { afterRedirect = false; continue }
                if expectCommand {
                    if isAssignment(t.raw) { continue }
                    result.insert(idx)
                    expectCommand = precommands.contains(t.value)
                    // sudo -u user cmd: keep expecting while we see options
                } else if let prev = result.max(), prev == idx - 1, precommands.contains(tokens[prev].value), t.value.hasPrefix("-") {
                    expectCommand = true
                }
            }
        }
        return result
    }

    public static func isAssignment(_ raw: String) -> Bool {
        guard let eq = raw.firstIndex(of: "="), eq != raw.startIndex else { return false }
        return raw[raw.startIndex..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Quotes a value for safe insertion into a command line.
    public static func escape(_ s: String, insideQuote: Character? = nil) -> String {
        if let q = insideQuote {
            if q == "'" { return s.replacingOccurrences(of: "'", with: "'\\''") }
            var out = ""
            for c in s { if "\"\\$`".contains(c) { out.append("\\") }; out.append(c) }
            return out
        }
        let special = Set(" \t\n'\"\\$`!&|;()<>*?[]{}#~")
        var out = ""
        for (i, c) in s.enumerated() {
            // A leading ~ is meaningful; keep it unescaped.
            if c == "~" && i == 0 { out.append(c); continue }
            if special.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

/// The part of the command line the cursor is in, ready for completion.
public struct CompletionContext: Sendable {
    public var line: String
    public var cursor: Int
    public var cwd: String
    /// Words of the current command before the word being completed, unquoted.
    /// The first one is the command name (with any sudo/env prefix removed).
    public var words: [String]
    /// The unquoted text typed so far in the current word.
    public var prefix: String
    /// UTF-16 range in `line` that a completion replaces.
    public var replaceRange: Range<Int>
    public var openQuote: Character?
    /// True when the current word is the command itself.
    public var isCommandPosition: Bool
    /// True right after a redirection like `>` (expect a file).
    public var afterRedirect: Bool

    public init(line: String, cursor: Int, cwd: String) {
        self.line = line
        self.cursor = cursor
        self.cwd = cwd
        let before = String(utf16CodeUnits: Array(line.utf16.prefix(cursor)), count: min(cursor, line.utf16.count))
        let tokens = ShellLexer.tokenize(before)
        let cmdPos = ShellLexer.commandPositions(tokens)

        // Is the cursor touching a word, or after whitespace?
        let endsWithSpace = before.last.map { $0 == " " || $0 == "\t" } ?? true
        var current: ShellToken?
        var currentIndex = tokens.count
        if let last = tokens.last, last.kind == .word, !endsWithSpace || last.openQuote != nil, last.range.upperBound == before.utf16.count {
            current = last
            currentIndex = tokens.count - 1
        }

        // Find where the current command segment starts.
        var segStart = 0
        for (i, t) in tokens.enumerated() where i < currentIndex {
            if t.kind == .op, !ShellLexer.redirectOps.contains(t.value) { segStart = i + 1 }
        }
        var words: [String] = []
        var sawCommand = false
        for i in segStart..<currentIndex {
            let t = tokens[i]
            guard t.kind == .word else { continue }
            if cmdPos.contains(i) {
                // Restart at each command word so `sudo git` gives ["git"].
                words = [t.value]
                sawCommand = true
            } else if sawCommand {
                words.append(t.value)
            }
        }
        if !sawCommand { words = [] }
        self.words = words

        let prevTok = currentIndex > 0 ? tokens[currentIndex - 1] : nil
        afterRedirect = prevTok.map { $0.kind == .op && ShellLexer.redirectOps.contains($0.value) } ?? false

        if let cur = current {
            prefix = cur.value
            replaceRange = cur.range
            openQuote = cur.openQuote
            isCommandPosition = cmdPos.contains(currentIndex) || (!sawCommand && !afterRedirect)
        } else {
            prefix = ""
            let c = before.utf16.count
            replaceRange = c..<c
            openQuote = nil
            isCommandPosition = !sawCommand && !afterRedirect
            if let last = words.last, sawCommand, ShellLexer.precommands.contains(last), words.count == 1 { isCommandPosition = true }
        }
        // The word being typed may extend past the cursor (e.g. editing the middle of a word).
        let after = Array(line.utf16.dropFirst(cursor))
        var extra = 0
        for u in after {
            if let s = Unicode.Scalar(u), " \t\n|&;()<>".contains(Character(s)) { break }
            extra += 1
        }
        replaceRange = replaceRange.lowerBound..<(replaceRange.upperBound + extra)
    }
}
