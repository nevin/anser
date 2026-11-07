import Foundation

/// Saved commands, grouped, for reuse (Tools → Command Notebook).
/// Stored as plain JSON in `~/.config/anser/notebook.json` so it can be
/// edited by hand, synced or committed.
public struct Notebook: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        public var command: String
        public var note: String

        public init(id: UUID = UUID(), title: String, command: String, note: String = "") {
            self.id = id; self.title = title; self.command = command; self.note = note
        }

        /// The title, or the command's first line when it has none.
        public var displayTitle: String {
            let t = title.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
            return command.split(separator: "\n").first.map(String.init) ?? "Untitled"
        }
    }

    public struct Group: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var entries: [Entry]

        public init(id: UUID = UUID(), name: String, entries: [Entry] = []) {
            self.id = id; self.name = name; self.entries = entries
        }
    }

    public var groups: [Group]
    /// Set once the old config.json "snippets" have been copied in.
    public var importedSnippets: Bool?

    public init(groups: [Group] = [Group(name: "General")]) { self.groups = groups }

    /// What a brand-new notebook starts with: a few useful examples.
    public static var starter: Notebook {
        var nb = Notebook(groups: [Group(name: "General"), Group(name: "Examples")])
        let ex = nb.groups[1].id
        nb.add(Entry(title: "Kill process on port", command: "lsof -ti tcp:{{port}} | xargs kill", note: "Run asks for the port"), to: ex)
        nb.add(Entry(title: "Find files by name", command: "find . -name '{{pattern}}' -not -path '*/node_modules/*'"), to: ex)
        nb.add(Entry(title: "Undo last commit (keep changes)", command: "git reset --soft HEAD~1"), to: ex)
        nb.add(Entry(title: "New branch from main", command: "git switch main && git pull && git switch -c {{branch}}"), to: ex)
        nb.importedSnippets = true
        return nb
    }

    /// Copies config.json snippets in (once), into a "Snippets" group, skipping commands already here.
    /// Returns true when the notebook changed.
    @discardableResult
    public mutating func importSnippets(_ snippets: [AnserConfig.Snippet]) -> Bool {
        guard importedSnippets != true else { return false }
        importedSnippets = true
        let have = Set(groups.flatMap(\.entries).map(\.command))
        let new = snippets.filter { !have.contains($0.command) }
        guard !new.isEmpty else { return true }
        let g = groups.first { $0.name == "Snippets" }?.id ?? addGroup(named: "Snippets")
        for sn in new { add(Entry(title: sn.name, command: sn.command, note: sn.description ?? ""), to: g) }
        return true
    }

    /// Every entry, in order.
    public var allEntries: [Entry] { groups.flatMap(\.entries) }

    /// The entry with this title (case-insensitive), for `snippet:<name>` keybindings.
    public func entry(titled title: String) -> Entry? {
        allEntries.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    /// This notebook plus anything only `other` has (same group names are merged; entries matched by id).
    public func merged(with other: Notebook) -> Notebook {
        var out = self
        let ids = Set(allEntries.map(\.id))
        for g in other.groups {
            let fresh = g.entries.filter { !ids.contains($0.id) }
            if let i = out.groups.firstIndex(where: { $0.id == g.id || $0.name == g.name }) {
                out.groups[i].entries += fresh
            } else if !fresh.isEmpty || g.entries.isEmpty {
                out.groups.append(Group(id: g.id, name: g.name, entries: fresh))
            }
        }
        if other.importedSnippets == true { out.importedSnippets = true }
        return out
    }

    public var entryCount: Int { groups.reduce(0) { $0 + $1.entries.count } }

    // MARK: Storage

    public static var defaultURL: URL { AnserConfig.directory.appendingPathComponent("notebook.json") }

    /// Loads the notebook; a missing file gives an empty one with a "General" group.
    public static func load(from url: URL = defaultURL) throws -> Notebook {
        guard FileManager.default.fileExists(atPath: url.path) else { return Notebook() }
        let nb = try JSONDecoder().decode(Notebook.self, from: Data(contentsOf: url))
        return nb.groups.isEmpty ? Notebook() : nb
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Editing

    public func groupIndex(_ id: UUID) -> Int? { groups.firstIndex { $0.id == id } }

    /// Where an entry is: (group index, entry index).
    public func locate(_ entryID: UUID) -> (Int, Int)? {
        for (g, group) in groups.enumerated() {
            if let e = group.entries.firstIndex(where: { $0.id == entryID }) { return (g, e) }
        }
        return nil
    }

    public func entry(_ id: UUID) -> Entry? { locate(id).map { groups[$0.0].entries[$0.1] } }

    @discardableResult
    public mutating func addGroup(named name: String) -> UUID {
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? "New group" : name
        var unique = base, n = 2
        while groups.contains(where: { $0.name == unique }) { unique = "\(base) \(n)"; n += 1 }
        let g = Group(name: unique)
        groups.append(g)
        return g.id
    }

    /// Adds an entry to a group (the first group when `group` is nil or unknown).
    @discardableResult
    public mutating func add(_ entry: Entry, to group: UUID? = nil) -> UUID {
        if groups.isEmpty { groups = [Group(name: "General")] }
        let g = group.flatMap(groupIndex) ?? 0
        groups[g].entries.append(entry)
        return entry.id
    }

    public mutating func update(_ entry: Entry) {
        guard let (g, e) = locate(entry.id) else { return }
        groups[g].entries[e] = entry
    }

    public mutating func move(_ entryID: UUID, to group: UUID) {
        guard let (g, e) = locate(entryID), let target = groupIndex(group), target != g else { return }
        let entry = groups[g].entries.remove(at: e)
        groups[target].entries.append(entry)
    }

    public mutating func removeEntry(_ id: UUID) {
        guard let (g, e) = locate(id) else { return }
        groups[g].entries.remove(at: e)
    }

    /// Removes a group; its commands move to the first remaining group so nothing is lost.
    public mutating func removeGroup(_ id: UUID) {
        guard let g = groupIndex(id) else { return }
        let orphans = groups.remove(at: g).entries
        if groups.isEmpty { groups = [Group(name: "General")] }
        groups[0].entries += orphans
    }

    public mutating func renameGroup(_ id: UUID, to name: String) {
        guard let g = groupIndex(id), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        groups[g].name = name
    }

    /// Groups with only the entries matching `query` (title, command or note); empty query keeps all.
    public func filtered(_ query: String) -> [Group] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { g in
            if g.name.lowercased().contains(q) { return g }
            let hits = g.entries.filter {
                $0.title.lowercased().contains(q) || $0.command.lowercased().contains(q) || $0.note.lowercased().contains(q)
            }
            return hits.isEmpty ? nil : Group(id: g.id, name: g.name, entries: hits)
        }
    }
}
