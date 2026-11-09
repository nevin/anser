import Foundation

/// Spots history entries worth deleting: typos, commands that were never
/// found, one-off failures, and trivial commands that only add clutter.
public enum HistoryCleanup {
    public enum Issue: Sendable, Equatable {
        /// The program doesn't exist, and looks like a typo of this one.
        case typo(of: String)
        /// The shell said "command not found" (exit 127).
        case notFound
        /// Ran once and failed.
        case failedOnce(exit: Int)
        /// A trivial command (ls, pwd, clear…) that suggestions don't need.
        case trivial

        public var label: String {
            switch self {
            case .typo(let of): "typo of \(of)?"
            case .notFound: "command not found"
            case .failedOnce(let e): "failed once (exit \(e))"
            case .trivial: "basic command"
            }
        }

        /// Mistakes (selected by “Select Mistakes”); trivial commands are separate.
        public var isMistake: Bool { self != .trivial }
    }

    static let trivialCommands: Set<String> = ["ls", "l", "ll", "la", "pwd", "clear", "cls", "exit", "history", "whoami", "date", "cd", "cd ..",
                                               "cd ~", "cd -", "..", "...", "ls -l", "ls -la", "ls -al", "ls -a", "ls -lh", "ls -lah",
                                               "q", ":q", "reset", "true", "false", "fg", "jobs", "top", "htop", "logout"]

    /// Why `c` could go, or nil when it looks like a command worth keeping.
    /// `isKnown`: whether a program name exists (in PATH, an alias, function or builtin).
    /// `closest`: a known program a misspelt name probably meant.
    public static func issue(for c: HistoryCommand, isKnown: (String) -> Bool, closest: (String) -> String?) -> Issue? {
        let cmd = c.command.trimmingCharacters(in: .whitespaces)
        if trivialCommands.contains(cmd) || cmd.count <= 2 && !cmd.isEmpty && cmd.allSatisfy(\.isLetter) && isKnown(cmd) { return .trivial }
        // A program that ran (any exit but 127, "command not found") wasn't misspelt,
        // even if it isn't installed here (npm run biuld is a typo in the script name, not in npm).
        let programRan = c.lastExit.map { $0 != 127 } ?? false
        if !programRan, let prog = HistoryStore.programName(cmd), !prog.contains("/"), !isKnown(prog), !shellKeywords.contains(prog),
           let near = closest(prog), near != prog, distance(prog, near) <= 2 {
            return .typo(of: near)
        }
        // Exit 127 with a program that exists here (a fixed typo keeps its old exit code) isn't "not found".
        if c.lastExit == 127, !(HistoryStore.programName(cmd).map(isKnown) ?? false) { return .notFound }
        if c.count == 1, let e = c.lastExit, e != 0, e != 127, e != 130, e != 143 { return .failedOnce(exit: e) }
        return nil
    }

    static let shellKeywords: Set<String> = ["if", "for", "while", "until", "case", "function", "time", "[[", "[", "{", "(", "!", "export", "source",
                                             ".", "eval", "exec", "alias", "unalias", "set", "unset", "builtin", "command", "noglob", "nocorrect"]

    /// Edit distance with transpositions (gti → git is 1).
    public static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }

    /// The nearest name in `names` (only when it's close), preferring commands you use often.
    public static func closest(to name: String, in names: [String], frequency: [String: Int] = [:]) -> String? {
        guard name.count >= 2 else { return nil }
        var best: (String, Int, Int)?
        for n in names where abs(n.count - name.count) <= 2 && n != name {
            let d = distance(name, n)
            guard d <= (name.count <= 3 ? 1 : 2) else { continue }
            let f = frequency[n] ?? 0
            if best == nil || d < best!.1 || (d == best!.1 && f > best!.2) { best = (n, d, f) }
        }
        return best?.0
    }
}
