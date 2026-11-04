import Foundation
import SQLite3

public struct HistoryEntry: Sendable, Hashable {
    public var id: Int64
    public var command: String
    public var cwd: String?
    public var session: String?
    public var started: Date
    public var duration: Double?
    public var exitCode: Int?
    public var branch: String?
}

/// One distinct command with usage stats, used for ranking.
public struct HistoryCommand: Sendable, Hashable {
    public var command: String
    public var count: Int
    public var lastUsed: Date
    public var lastCwd: String?
    public var lastExit: Int?
    public var cwds: Set<String>

    /// Frequency weighted by recency (a "frecency" score).
    public func frecency(now: Date = Date(), cwd: String? = nil) -> Double {
        let ageHours = max(0, now.timeIntervalSince(lastUsed) / 3600)
        var s = sqrt(Double(count)) * (1.0 / (1.0 + ageHours / 48.0))
        if let cwd, cwds.contains(cwd) { s *= 2.5 }
        if let e = lastExit, e != 0 { s *= 0.6 }
        return s
    }
}

public enum HistoryScope: Int, Sendable, CaseIterable {
    case all, directory, session, failed
    public var title: String {
        switch self {
        case .all: "All"
        case .directory: "This folder"
        case .session: "This tab"
        case .failed: "Failed"
        }
    }
}

/// Persistent command history in SQLite, with an in-memory index of distinct
/// commands for instant suggestions.
public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var commands: [String: HistoryCommand] = [:]
    /// Distinct commands, most recent first.
    private var recentOrder: [String] = []
    /// How often each program (first word) was run.
    private var nameFrequency: [String: Int] = [:]
    /// Distinct commands in sorted order, for fast prefix lookups.
    private var sortedCommands: [String] = []
    private var sortedReady = false
    private var orderDirty = true

    public let path: String

    public init(path: String) {
        self.path = path
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            db = nil
        }
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS history(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            command TEXT NOT NULL,
            cwd TEXT, session TEXT,
            started REAL NOT NULL,
            duration REAL, exit_code INTEGER, branch TEXT, source TEXT)
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_history_started ON history(started)")
        exec("CREATE INDEX IF NOT EXISTS idx_history_command ON history(command)")
        exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)")
        loadIndex()
    }

    deinit { sqlite3_close(db) }

    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Anser/history.sqlite").path
    }

    // MARK: Writing

    /// Records that a command started. Returns its row id.
    @discardableResult
    public func recordStart(command: String, cwd: String?, session: String?, branch: String? = nil, at date: Date = Date()) -> Int64 {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return -1 }
        lock.lock(); defer { lock.unlock() }
        let id = insert(command: cmd, cwd: cwd, session: session, started: date, duration: nil, exit: nil, branch: branch, source: "anser")
        bump(cmd, date: date, cwd: cwd, exit: nil)
        return id
    }

    public func recordFinish(id: Int64, exitCode: Int?, duration: Double?) {
        guard id > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let sql = "UPDATE history SET exit_code=?, duration=? WHERE id=?"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        if let e = exitCode { sqlite3_bind_int(st, 1, Int32(e)) } else { sqlite3_bind_null(st, 1) }
        if let d = duration { sqlite3_bind_double(st, 2, d) } else { sqlite3_bind_null(st, 2) }
        sqlite3_bind_int64(st, 3, id)
        sqlite3_step(st)
        // Update the in-memory exit status.
        if let cmd = commandFor(id: id), var c = commands[cmd] { c.lastExit = exitCode; commands[cmd] = c }
    }

    /// Deletes every occurrence of a command (for removing secrets or typos).
    public func delete(command: String) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM history WHERE command=?", -1, &st, nil) == SQLITE_OK {
            bindText(st, 1, command)
            sqlite3_step(st)
        }
        sqlite3_finalize(st)
        if let c = commands[command], let name = Self.programName(command) {
            nameFrequency[name, default: 0] -= c.count
            if nameFrequency[name, default: 0] <= 0 { nameFrequency[name] = nil }
        }
        commands[command] = nil
        sortedReady = false
        orderDirty = true
    }

    // MARK: Reading

    /// The best whole-line completion for what the user has typed (ghost text).
    public func suggestion(forPrefix prefix: String, cwd: String?) -> String? {
        guard prefix.count >= 1, !prefix.hasPrefix(" ") else { return nil }
        lock.lock(); defer { lock.unlock() }
        refreshSorted()
        let now = Date()
        var best: (String, Double)?
        func consider(_ cmd: String) {
            guard cmd.count > prefix.count, let c = commands[cmd] else { return }
            let s = c.frecency(now: now, cwd: cwd)
            if best == nil || s > best!.1 { best = (cmd, s) }
        }
        // Commands sharing a prefix sit next to each other in sorted order.
        let lo = lowerBound(prefix)
        var hi = lo
        while hi < sortedCommands.count, sortedCommands[hi].hasPrefix(prefix) { hi += 1 }
        if hi - lo <= 3000 {
            for i in lo..<hi { consider(sortedCommands[i]) }
        } else {
            // Very common prefix ("g"): the best match is almost always recent,
            // so rank the 400 most recent matches instead of all of them.
            refreshOrder()
            var seen = 0
            for cmd in recentOrder where cmd.hasPrefix(prefix) {
                consider(cmd)
                seen += 1
                if seen >= 400 { break }
            }
        }
        return best?.0
    }

    private func refreshSorted() {
        guard !sortedReady else { return }
        sortedCommands = commands.keys.sorted()
        sortedReady = true
    }

    private func lowerBound(_ key: String) -> Int {
        var lo = 0, hi = sortedCommands.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedCommands[mid] < key { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Distinct commands starting with `prefix`, most recent first (for Up/Down).
    public func recentCommands(withPrefix prefix: String, limit: Int = 500) -> [String] {
        lock.lock(); defer { lock.unlock() }
        refreshOrder()
        var out: [String] = []
        for c in recentOrder where prefix.isEmpty || (c.hasPrefix(prefix) && c != prefix) {
            out.append(c)
            if out.count >= limit { break }
        }
        return out
    }

    /// Fuzzy search over distinct commands, ranked by match quality and frecency.
    public func search(_ query: String, scope: HistoryScope = .all, cwd: String? = nil, session: String? = nil, limit: Int = 200) -> [(HistoryCommand, Fuzzy.Match)] {
        lock.lock()
        var pool = Array(commands.values)
        lock.unlock()

        switch scope {
        case .all: break
        case .directory: pool = pool.filter { c in cwd.map { c.cwds.contains($0) } ?? true }
        case .failed: pool = pool.filter { ($0.lastExit ?? 0) != 0 }
        case .session:
            let set = Set(entries(session: session, limit: 5000).map(\.command))
            pool = pool.filter { set.contains($0.command) }
        }
        let now = Date()
        var scored: [(HistoryCommand, Fuzzy.Match, Double)] = []
        scored.reserveCapacity(pool.count)
        for c in pool {
            guard let m = Fuzzy.match(query, c.command) else { continue }
            let rank = query.isEmpty ? c.frecency(now: now, cwd: cwd) * 100 : Double(m.score) + c.frecency(now: now, cwd: cwd) * 40
            scored.append((c, m, rank))
        }
        if query.isEmpty {
            scored.sort { $0.0.lastUsed > $1.0.lastUsed }
        } else {
            scored.sort { $0.2 > $1.2 }
        }
        return scored.prefix(limit).map { ($0.0, $0.1) }
    }

    /// Raw entries for one session, newest first.
    public func entries(session: String?, limit: Int = 200) -> [HistoryEntry] {
        guard let session else { return [] }
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "SELECT id, command, cwd, session, started, duration, exit_code, branch FROM history WHERE session=? ORDER BY started DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, session)
        sqlite3_bind_int(st, 2, Int32(limit))
        var out: [HistoryEntry] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(readEntry(st)) }
        return out
    }

    /// Folders you've run commands in, best first (frequency × recency).
    public func recentDirectories(limit: Int = 300) -> [(path: String, count: Int, last: Date)] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "SELECT cwd, COUNT(*), MAX(started) FROM history WHERE cwd IS NOT NULL AND cwd != '' GROUP BY cwd"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [(String, Int, Date, Double)] = []
        let now = Date()
        while sqlite3_step(st) == SQLITE_ROW {
            guard let c = sqlite3_column_text(st, 0) else { continue }
            let count = Int(sqlite3_column_int(st, 1))
            let last = Date(timeIntervalSince1970: sqlite3_column_double(st, 2))
            let age = max(0, now.timeIntervalSince(last) / 3600)
            out.append((String(cString: c), count, last, sqrt(Double(count)) / (1 + age / 72)))
        }
        return out.sorted { $0.3 > $1.3 }.prefix(limit).map { ($0.0, $0.1, $0.2) }
    }

    public var commandCount: Int { lock.lock(); defer { lock.unlock() }; return commands.count }

    /// How often each program (first word) was run. Kept up to date incrementally.
    public func commandNameFrequency() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return nameFrequency
    }

    /// The program a command line runs, skipping `FOO=bar` and `sudo`.
    public static func programName(_ cmd: String) -> String? {
        for word in cmd.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            if word.contains("=") || word == "sudo" || word == "time" || word == "nohup" { continue }
            return String(word)
        }
        return nil
    }

    // MARK: Import

    /// Imports ~/.zsh_history and ~/.bash_history once.
    public func importShellHistoryIfNeeded(home: String = NSHomeDirectory()) {
        lock.lock(); defer { lock.unlock() }
        if metaValue("imported_shell_history") != nil { return }
        exec("BEGIN")
        var imported = 0
        let zsh = ProcessInfo.processInfo.environment["HISTFILE"] ?? (home + "/.zsh_history")
        if let data = FileManager.default.contents(atPath: zsh) {
            for (cmd, date) in Self.parseZshHistory(data) {
                insert(command: cmd, cwd: nil, session: nil, started: date ?? Date(timeIntervalSince1970: 0), duration: nil, exit: nil, branch: nil, source: "zsh")
                imported += 1
            }
        }
        if let text = try? String(contentsOfFile: home + "/.bash_history", encoding: .utf8) {
            var stamp: Date?
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("#"), let t = Double(line.dropFirst()) { stamp = Date(timeIntervalSince1970: t); continue }
                insert(command: String(line), cwd: nil, session: nil, started: stamp ?? Date(timeIntervalSince1970: 0), duration: nil, exit: nil, branch: nil, source: "bash")
                imported += 1
            }
        }
        setMeta("imported_shell_history", "\(imported)")
        exec("COMMIT")
        loadIndex()
    }

    /// Parses zsh history, including EXTENDED_HISTORY timestamps, multi-line
    /// commands and zsh's "metafied" byte encoding.
    public static func parseZshHistory(_ data: Data) -> [(String, Date?)] {
        // Unmetafy: 0x83 means "next byte XOR 32".
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count)
        var meta = false
        for b in data {
            if meta { bytes.append(b ^ 32); meta = false } else if b == 0x83 { meta = true } else { bytes.append(b) }
        }
        let text = String(decoding: bytes, as: UTF8.self)
        var out: [(String, Date?)] = []
        var pending: String?
        var pendingDate: Date?
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            if pending == nil {
                pendingDate = nil
                if line.hasPrefix(": "), let semi = line.firstIndex(of: ";") {
                    let header = line[line.index(line.startIndex, offsetBy: 2)..<semi]
                    if let ts = header.split(separator: ":").first, let t = Double(ts) { pendingDate = Date(timeIntervalSince1970: t) }
                    line = String(line[line.index(after: semi)...])
                }
            }
            if line.hasSuffix("\\") {
                pending = (pending.map { $0 + "\n" } ?? "") + line.dropLast()
                continue
            }
            let full = (pending.map { $0 + "\n" } ?? "") + line
            pending = nil
            let trimmed = full.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { out.append((trimmed, pendingDate)) }
        }
        return out
    }

    // MARK: Internals

    private func loadIndex() {
        lock.lock(); defer { lock.unlock() }
        commands.removeAll(keepingCapacity: true)
        nameFrequency.removeAll(keepingCapacity: true)
        sortedReady = false
        var st: OpaquePointer?
        let sql = "SELECT command, started, cwd, exit_code FROM history ORDER BY started ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            guard let c = sqlite3_column_text(st, 0) else { continue }
            let cmd = String(cString: c)
            let date = Date(timeIntervalSince1970: sqlite3_column_double(st, 1))
            let cwd = sqlite3_column_text(st, 2).map { String(cString: $0) }
            let exit: Int? = sqlite3_column_type(st, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(st, 3))
            bump(cmd, date: date, cwd: cwd, exit: exit)
        }
        orderDirty = true
    }

    private func bump(_ cmd: String, date: Date, cwd: String?, exit: Int?) {
        if let name = Self.programName(cmd) { nameFrequency[name, default: 0] += 1 }
        if commands[cmd] == nil, sortedReady {
            sortedCommands.insert(cmd, at: lowerBound(cmd))
        }
        if var c = commands[cmd] {
            c.count += 1
            if date >= c.lastUsed { c.lastUsed = date; c.lastCwd = cwd ?? c.lastCwd; c.lastExit = exit }
            if let cwd { c.cwds.insert(cwd) }
            commands[cmd] = c
        } else {
            commands[cmd] = HistoryCommand(command: cmd, count: 1, lastUsed: date, lastCwd: cwd, lastExit: exit, cwds: cwd.map { [$0] } ?? [])
        }
        orderDirty = true
    }

    private func refreshOrder() {
        guard orderDirty else { return }
        recentOrder = commands.values.sorted { $0.lastUsed > $1.lastUsed }.map(\.command)
        orderDirty = false
    }

    private func commandFor(id: Int64) -> String? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT command FROM history WHERE id=?", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, id)
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: c)
    }

    @discardableResult
    private func insert(command: String, cwd: String?, session: String?, started: Date, duration: Double?, exit: Int?, branch: String?, source: String) -> Int64 {
        let sql = "INSERT INTO history(command, cwd, session, started, duration, exit_code, branch, source) VALUES(?,?,?,?,?,?,?,?)"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, command)
        bindText(st, 2, cwd)
        bindText(st, 3, session)
        sqlite3_bind_double(st, 4, started.timeIntervalSince1970)
        if let d = duration { sqlite3_bind_double(st, 5, d) } else { sqlite3_bind_null(st, 5) }
        if let e = exit { sqlite3_bind_int(st, 6, Int32(e)) } else { sqlite3_bind_null(st, 6) }
        bindText(st, 7, branch)
        bindText(st, 8, source)
        guard sqlite3_step(st) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    private func readEntry(_ st: OpaquePointer?) -> HistoryEntry {
        func text(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
        return HistoryEntry(
            id: sqlite3_column_int64(st, 0),
            command: text(1) ?? "",
            cwd: text(2), session: text(3),
            started: Date(timeIntervalSince1970: sqlite3_column_double(st, 4)),
            duration: sqlite3_column_type(st, 5) == SQLITE_NULL ? nil : sqlite3_column_double(st, 5),
            exitCode: sqlite3_column_type(st, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(st, 6)),
            branch: text(7))
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private func bindText(_ st: OpaquePointer?, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(st, i, s, -1, Self.transient) } else { sqlite3_bind_null(st, i) }
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func metaValue(_ key: String) -> String? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key=?", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, key)
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: c)
    }

    private func setMeta(_ key: String, _ value: String) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta(key, value) VALUES(?,?)", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, key)
        bindText(st, 2, value)
        sqlite3_step(st)
    }
}
