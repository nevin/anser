import Foundation

/// Finds folders for "Jump to folder": ones you've used, ones from `cd`
/// commands in your shell history, and a quick scan of the disk.
public enum FolderIndex {
    /// Folders never worth descending into (huge or generated).
    public static let skipNames: Set<String> = [
        "node_modules", "Library", "Applications", "DerivedData", "Pods", "build", "dist", "target",
        "__pycache__", "venv", ".venv", "vendor", "bower_components", "coverage", "tmp", "Caches",
    ]

    /// Directories under each root, breadth-first, up to `depth` levels,
    /// stopping at `limit` results or when `deadline` passes.
    public static func scan(roots: [(path: String, depth: Int)], limit: Int = 8000, deadline: Date = Date().addingTimeInterval(1.0)) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        var seen = Set<String>()
        for (root, maxDepth) in roots {
            var queue: [(String, Int)] = [(root, 0)]
            var qi = 0
            while qi < queue.count {
                let (dir, level) = queue[qi]
                qi += 1
                if out.count >= limit || Date() > deadline { return out }
                guard level < maxDepth, let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for name in names.sorted() where !name.hasPrefix(".") {
                    let path = (dir as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                          !name.hasSuffix(".app"), !name.hasSuffix(".xcodeproj"), !name.hasSuffix(".bundle"),
                          seen.insert(path).inserted else { continue }
                    out.append(path)
                    if !skipNames.contains(name) { queue.append((path, level + 1)) }
                }
            }
        }
        return out
    }

    /// Absolute folders named in `cd` / `pushd` commands (relative ones are
    /// ambiguous without knowing where they ran, so they're left out).
    public static func cdTargets(from commands: [String], home: String = NSHomeDirectory()) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for cmd in commands {
            let toks = ShellLexer.tokenize(cmd).filter { $0.kind == .word }
            for (i, t) in toks.enumerated() where (t.value == "cd" || t.value == "pushd") && i + 1 < toks.count {
                var p = toks[i + 1].value
                if p.hasPrefix("~") { p = home + p.dropFirst() }
                guard p.hasPrefix("/") else { continue }
                p = (p as NSString).standardizingPath
                if seen.insert(p).inserted { out.append(p) }
            }
        }
        return out
    }

    public struct Candidate: Sendable {
        public var path: String
        /// Recency/frequency bonus (folders you've actually used rank higher).
        public var boost: Double
        public var note: String?
        public init(path: String, boost: Double = 0, note: String? = nil) { self.path = path; self.boost = boost; self.note = note }
    }

    /// Fuzzy-ranks folders. A match on the folder's own name counts more than
    /// a match spread across the whole path.
    public static func rank(_ query: String, _ candidates: [Candidate], home: String = NSHomeDirectory(), limit: Int = 200) -> [(Candidate, Fuzzy.Match, String)] {
        var out: [(Candidate, Fuzzy.Match, String, Double)] = []
        let q = query.trimmingCharacters(in: .whitespaces)
        for c in candidates {
            let shown = c.path.hasPrefix(home) ? "~" + c.path.dropFirst(home.count) : c.path
            if q.isEmpty {
                out.append((c, Fuzzy.Match(score: 0, positions: []), shown, c.boost))
                continue
            }
            let name = (shown as NSString).lastPathComponent
            let offset = shown.count - name.count
            var best: (Fuzzy.Match, Double)?
            if let m = Fuzzy.match(q, name) {
                best = (Fuzzy.Match(score: m.score, positions: m.positions.map { $0 + offset }), Double(m.score) * 1.5)
            }
            if let m = Fuzzy.match(q, shown), best == nil || Double(m.score) > best!.1 {
                best = (m, Double(m.score))
            }
            guard let (m, s) = best else { continue }
            // Shorter paths win ties; used folders get their boost.
            out.append((c, m, shown, s + c.boost * 40 - Double(shown.count) * 0.5))
        }
        // Prefer matches where the typed text appears in one piece (prefix or
        // substring scores); letters scattered across a path are noise unless
        // nothing better exists.
        if q.count >= 2 {
            let solid = out.filter { $0.1.score >= 300 }
            if !solid.isEmpty { out = solid }
        }
        return out.sorted { $0.3 > $1.3 }.prefix(limit).map { ($0.0, $0.1, $0.2) }
    }
}
