import Foundation

public enum HighlightRole: Sendable, Equatable {
    case command, unknownCommand, builtin, alias, option, string, variable, op, comment, path, argument, placeholder
}

public enum Highlighter {
    /// Returns styled ranges (UTF-16) for a command line.
    public static func highlight(_ line: String, cwd: String, env: ShellEnvironment, checkPaths: Bool = true) -> [(NSRange, HighlightRole)] {
        let tokens = ShellLexer.tokenize(line)
        let cmdPos = ShellLexer.commandPositions(tokens)
        var out: [(NSRange, HighlightRole)] = []
        let fm = FileManager.default
        for (i, t) in tokens.enumerated() {
            switch t.kind {
            case .comment: out.append((t.nsRange, .comment))
            case .op: out.append((t.nsRange, .op))
            case .word:
                if cmdPos.contains(i) {
                    let name = t.value
                    let role: HighlightRole
                    if env.aliases[name] != nil { role = .alias }
                    else if ShellBuiltins.all[name] != nil || env.functions.contains(name) { role = .builtin }
                    else if env.isRemote || CommandIndex.shared.exists(name, env: env) { role = .command }
                    else { role = .unknownCommand }
                    out.append((t.nsRange, role))
                } else if t.raw.hasPrefix("-") {
                    out.append((t.nsRange, .option))
                } else if t.quoted {
                    out.append((t.nsRange, .string))
                } else if t.raw.hasPrefix("$") {
                    out.append((t.nsRange, .variable))
                } else {
                    var p = t.value
                    if p.hasPrefix("~") { p = env.home + p.dropFirst() }
                    if !p.hasPrefix("/") { p = (cwd as NSString).appendingPathComponent(p) }
                    out.append((t.nsRange, checkPaths && !env.isRemote && !t.value.isEmpty && fm.fileExists(atPath: p) ? .path : .argument))
                }
            }
        }
        // {{placeholders}} from snippets
        if line.contains("{{") {
            let re = try! NSRegularExpression(pattern: #"\{\{[^}]*\}\}"#)
            for m in re.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                out.append((m.range, .placeholder))
            }
        }
        return out
    }

    /// Next `{{placeholder}}` at or after `location` (wrapping around).
    public static func nextPlaceholder(in line: String, after location: Int) -> NSRange? {
        let re = try! NSRegularExpression(pattern: #"\{\{[^}]*\}\}"#)
        let all = re.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)).map(\.range)
        return all.first { $0.location >= location } ?? all.first
    }
}
