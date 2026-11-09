import Foundation

/// An alias you made in Anser's alias manager.
public struct AnserAlias: Codable, Sendable, Equatable {
    public var name: String
    public var command: String
    /// A heading to keep related aliases together ("git", "docker").
    public var group: String?
    public init(name: String, command: String, group: String? = nil) {
        self.name = name; self.command = command
        let g = group?.trimmingCharacters(in: .whitespaces)
        self.group = (g?.isEmpty ?? true) ? nil : g
    }
}

/// Aliases you manage in Anser (Tools → Aliases…). Kept in
/// ~/.config/anser/aliases.json, with generated aliases.sh / aliases.fish that
/// every new shell loads; open tabs get changes right away.
public struct AliasBook: Codable, Sendable, Equatable {
    public var aliases: [AnserAlias] = []
    /// Suggested commands you said no to.
    public var dismissed: [String] = []

    public init(aliases: [AnserAlias] = [], dismissed: [String] = []) { self.aliases = aliases; self.dismissed = dismissed }

    public subscript(name: String) -> AnserAlias? { aliases.first { $0.name == name } }

    /// Adds or replaces (by name). `replacing` renames an existing one.
    public mutating func set(_ a: AnserAlias, replacing old: String? = nil) {
        if let old, old != a.name { aliases.removeAll { $0.name == old } }
        if let i = aliases.firstIndex(where: { $0.name == a.name }) { aliases[i] = a } else { aliases.append(a) }
        aliases.sort { $0.name.lowercased() < $1.name.lowercased() }
    }

    public mutating func remove(_ name: String) { aliases.removeAll { $0.name == name } }

    /// Group names in use, sorted.
    public var groups: [String] { Array(Set(aliases.compactMap(\.group))).sorted { $0.lowercased() < $1.lowercased() } }

    /// Adds shell aliases you don't have here yet (same name already here is skipped). Returns how many were added.
    @discardableResult
    public mutating func importAliases(_ shell: [String: String], group: String? = "Imported") -> Int {
        var n = 0
        for (name, value) in shell.sorted(by: { $0.key < $1.key }) where self[name] == nil && AliasStore.problem(name: name, command: value) == nil {
            set(AnserAlias(name: name, command: value, group: group))
            n += 1
        }
        return n
    }

    /// Aliases grouped for display: ungrouped first, then each group.
    public var grouped: [(group: String?, aliases: [AnserAlias])] {
        var out: [(String?, [AnserAlias])] = []
        let none = aliases.filter { $0.group == nil }
        if !none.isEmpty { out.append((nil, none)) }
        for g in groups { out.append((g, aliases.filter { $0.group == g })) }
        return out
    }
}

public enum AliasStore {
    public static var directory: URL { AnserConfig.directory }
    public static var fileURL: URL { directory.appendingPathComponent("aliases.json") }
    public static var posixFile: URL { directory.appendingPathComponent("aliases.sh") }
    public static var fishFile: URL { directory.appendingPathComponent("aliases.fish") }

    public static func load(from url: URL = fileURL) -> AliasBook {
        guard let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(AliasBook.self, from: d) else { return AliasBook() }
        return b
    }

    /// Saves the book and the shell files generated from it.
    public static func save(_ book: AliasBook, to url: URL = fileURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(book).write(to: url, options: .atomic)
        let header = "# Made by Anser's alias manager (Tools → Aliases…). Edits here are overwritten; change aliases there.\n"
        try (header + script(book.aliases, shell: .posix)).write(to: dir.appendingPathComponent("aliases.sh"), atomically: true, encoding: .utf8)
        try (header + script(book.aliases, shell: .fish)).write(to: dir.appendingPathComponent("aliases.fish"), atomically: true, encoding: .utf8)
    }

    /// Why `name` can't be an alias, or nil when it's fine.
    public static func problem(name: String, command: String) -> String? {
        if name.isEmpty { return "Give the alias a name." }
        guard let first = name.unicodeScalars.first, CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first),
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-")).contains($0) && $0.isASCII }) else {
            return "Names use letters, digits, “_”, “.” and “-”, and start with a letter."
        }
        if reserved.contains(name) { return "“\(name)” is part of the shell itself; pick another name." }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the command it stands for." }
        if command.contains("\n") { return "An alias is one line. For several commands, use && or save a workflow." }
        return nil
    }

    static let reserved: Set<String> = ["alias", "unalias", "builtin", "command", "exec", "export", "function", "if", "then", "else", "fi", "for", "do",
                                        "done", "while", "case", "esac", "return", "set", "source", "unset", "eval", "end", "begin", "and", "or", "not"]

    public static func script(_ aliases: [AnserAlias], shell: ProjectEnv.Shell) -> String {
        aliases.map { a in
            shell == .fish ? "alias \(a.name) \(ProjectEnv.q(a.command, .fish))" : "alias \(a.name)=\(ProjectEnv.q(a.command, .posix))"
        }.joined(separator: "\n") + "\n"
    }

    /// Shell code that turns `old` into `new` in a running shell.
    public static func changes(from old: [AnserAlias], to new: [AnserAlias], shell: ProjectEnv.Shell) -> String {
        let newNames = Set(new.map(\.name))
        var lines: [String] = []
        for a in old where !newNames.contains(a.name) {
            lines.append(shell == .fish ? "functions -e \(a.name) 2>/dev/null" : "unalias \(a.name) 2>/dev/null")
        }
        let changed = new.filter { !old.contains($0) }
        if !changed.isEmpty { lines.append(script(changed, shell: shell).trimmingCharacters(in: .newlines)) }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

/// Long commands you keep typing, with a short alias name for each.
public enum HabitSuggestions {
    public struct Suggestion: Sendable, Equatable {
        public var command: String
        public var count: Int
        public var name: String
        /// Characters you'd skip each time.
        public var saves: Int { max(0, command.count - name.count) }
    }

    public static let minCount = 4
    public static let minLength = 16

    /// Whether a command is worth an alias: long, repeated, works, and has nothing secret in it.
    public static func qualifies(_ c: HistoryCommand, aliasValues: Set<String>, dismissed: Set<String>) -> Bool {
        let cmd = c.command.trimmingCharacters(in: .whitespaces)
        guard c.count >= minCount, cmd.count >= minLength, cmd.count <= 300, !cmd.contains("\n"), !c.command.hasPrefix(" ") else { return false }
        guard (c.lastExit ?? 0) == 0, !aliasValues.contains(cmd), !dismissed.contains(cmd) else { return false }
        if AIHelp.redact(cmd) != cmd || cmd.contains("{{") || cmd.contains("anser-selftest") { return false }
        // `cd` to a folder is better served by ⌘J; one-word commands can't get much shorter.
        if cmd.hasPrefix("cd ") || !cmd.contains(" ") { return false }
        return true
    }

    public static func suggest(_ history: [HistoryCommand], aliases: [String: String], dismissed: Set<String>,
                               isTaken: (String) -> Bool, limit: Int = 12) -> [Suggestion] {
        let values = Set(aliases.values.map { $0.trimmingCharacters(in: .whitespaces) })
        var used = Set(aliases.keys)
        let picked = history.filter { qualifies($0, aliasValues: values, dismissed: dismissed) }
            .sorted { $0.count * $0.command.count > $1.count * $1.command.count }
            .prefix(limit)
        return picked.map { c in
            let n = name(for: c.command, isTaken: { used.contains($0) || isTaken($0) })
            used.insert(n)
            return Suggestion(command: c.command.trimmingCharacters(in: .whitespaces), count: c.count, name: n)
        }
    }

    /// A short name from the command's words: "git log --oneline --graph" → "glog".
    public static func name(for command: String, isTaken: (String) -> Bool) -> String {
        var words = command.split(separator: " ").map(String.init)
        while let w = words.first, w.contains("=") || w == "sudo" || w == "env" { words.removeFirst() }
        guard let program = words.first.map({ ($0 as NSString).lastPathComponent.lowercased() }) else { return "a" }
        let rest = words.dropFirst()
        let letters = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        var base = String(letters(program).prefix(1))
        let plain = rest.filter { !$0.hasPrefix("-") }
        // The first plain word (often a subcommand) stays whole when it's short: git log → glog.
        if let sub = plain.first, letters(sub).count <= 4, !letters(sub).isEmpty {
            base += letters(sub)
            for w in plain.dropFirst() { if let c = letters(w).first { base.append(c) } }
        } else {
            for w in plain { if let c = letters(w).first { base.append(c) } }
        }
        // Flags only when the words alone are too short to tell apart.
        if base.count < 3 { for w in rest where w.hasPrefix("-") { if let c = letters(w).first { base.append(c) } } }
        base = String(base.prefix(6))
        if base.count < 2 { base = String(letters(program).prefix(3)) }
        if let f = base.first, !f.isLetter { base = "a" + base }
        var candidate = base, n = 2
        while isTaken(candidate) || AliasStore.reserved.contains(candidate) { candidate = base + String(n); n += 1 }
        return candidate
    }
}

extension HistoryStore {
    /// Commands run at least `minCount` times (for alias suggestions).
    public func frequentCommands(minCount: Int = HabitSuggestions.minCount) -> [HistoryCommand] {
        allCommands().filter { $0.count >= minCount }
    }
}
