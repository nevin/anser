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

    public init(command: String, count: Int, lastUsed: Date, lastCwd: String?, lastExit: Int?, cwds: Set<String>) {
        self.command = command; self.count = count; self.lastUsed = lastUsed; self.lastCwd = lastCwd; self.lastExit = lastExit; self.cwds = cwds
    }

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
    case all, directory, session, failed, output
    public var title: String {
        switch self {
        case .all: "All"
        case .directory: "This folder"
        case .session: "This tab"
        case .failed: "Failed"
        case .output: "Output"
        }
    }
}

/// Persistent command history in SQLite, with an in-memory index of distinct
/// commands for instant suggestions.
/// Thread-safe by convention, not by the compiler: every public method takes
/// `lock` before touching `db` or the in-memory index, and private helpers are
/// only called with it held. Keep it that way when adding methods.
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
        // Saved command output (the end of it, secrets removed), for searching.
        exec("CREATE TABLE IF NOT EXISTS output(history_id INTEGER PRIMARY KEY, text TEXT NOT NULL)")
        // Commands deleted in the History Editor, kept 7 days so they can be restored.
        exec("""
        CREATE TABLE IF NOT EXISTS trash(
            id INTEGER PRIMARY KEY, command TEXT NOT NULL, cwd TEXT, session TEXT, started REAL NOT NULL,
            duration REAL, exit_code INTEGER, branch TEXT, source TEXT, deleted_at REAL NOT NULL)
        """)
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
    /// Removes specific runs (and their saved output), e.g. one tab's commands after Deep Clean.
    /// A command stays in suggestions while other runs of it remain.
    public func delete(ids: [Int64]) {
        let ids = ids.filter { $0 > 0 }
        guard !ids.isEmpty else { return }
        var commandsTouched: Set<String> = []
        lock.lock()
        for id in ids { if let c = commandFor(id: id) { commandsTouched.insert(c) } }
        let list = ids.map(String.init).joined(separator: ",")
        exec("DELETE FROM history WHERE id IN (\(list))")
        exec("DELETE FROM output WHERE history_id IN (\(list))")
        lock.unlock()
        // Commands with no runs left disappear from suggestions too.
        for c in commandsTouched where !hasRuns(of: c) { delete(command: c) }
    }

    private func hasRuns(of command: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM history WHERE command=? LIMIT 1", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, command)
        return sqlite3_step(st) == SQLITE_ROW
    }

    public func delete(command: String) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM history WHERE command=?", -1, &st, nil) == SQLITE_OK {
            bindText(st, 1, command)
            sqlite3_step(st)
        }
        sqlite3_finalize(st)
        exec("DELETE FROM output WHERE history_id NOT IN (SELECT id FROM history)")
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
            guard cmd.count > prefix.count, let c = commands[cmd], !Self.isMistake(c) else { return }
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

    /// The exit code of the last run of `command`, if known.
    public func lastExit(for command: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return commands[command]?.lastExit
    }

    /// Whether `command` failed the only time it ran, or wasn't found: likely a typo.
    public func isLikelyMistake(_ command: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return commands[command].map(Self.isMistake) ?? false
    }

    static func isMistake(_ c: HistoryCommand) -> Bool {
        guard let e = c.lastExit, e != 0 else { return false }
        return e == 127 || c.count == 1
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
        case .output:
            // Searched with searchOutput (matches the output, not the command).
            return []
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

    // MARK: Timing

    public struct Timing: Sendable, Equatable {
        /// Median of recent successful runs.
        public var typical: Double
        public var runs: Int
        public var fastest: Double
        public var slowest: Double
    }

    /// How long this exact command usually takes (its last 10 successful runs).
    /// nil until it has run successfully at least twice.
    public func timing(for command: String) -> Timing? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "SELECT duration FROM history WHERE command=? AND exit_code=0 AND duration IS NOT NULL ORDER BY started DESC LIMIT 10"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, cmd)
        var d: [Double] = []
        while sqlite3_step(st) == SQLITE_ROW { d.append(sqlite3_column_double(st, 0)) }
        guard d.count >= 2 else { return nil }
        let sorted = d.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return Timing(typical: median, runs: d.count, fastest: sorted.first!, slowest: sorted.last!)
    }

    // MARK: Output

    /// The most kept per command (its last part) and the number of commands kept.
    public static let maxOutputCharacters = 32_000
    public static let maxOutputs = 3_000
    private var outputSaves = 0

    /// Keeps a finished command's output so it can be searched later. Callers
    /// remove secrets first; this keeps only the end of long output.
    public func saveOutput(_ text: String, forHistoryID id: Int64) {
        guard id > 0 else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        if trimmed.isEmpty {
            guard sqlite3_prepare_v2(db, "DELETE FROM output WHERE history_id=?", -1, &st, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(st, 1, id)
        } else {
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO output(history_id, text) VALUES(?,?)", -1, &st, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(st, 1, id)
            bindText(st, 2, String(trimmed.suffix(Self.maxOutputCharacters)))
        }
        sqlite3_step(st)
        sqlite3_finalize(st)
        outputSaves += 1
        if outputSaves % 50 == 1 {
            exec("DELETE FROM output WHERE history_id NOT IN (SELECT history_id FROM output ORDER BY history_id DESC LIMIT \(Self.maxOutputs))")
        }
    }

    public func output(forHistoryID id: Int64) -> String? {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT text FROM output WHERE history_id=?", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, id)
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return nil }
        return String(cString: c)
    }

    public struct OutputHit: Sendable, Equatable {
        public var entry: HistoryEntry
        /// The matching line (or the first line for an empty search).
        public var line: String
    }

    /// Commands whose saved output contains `query` (case-insensitive), newest first.
    /// An empty query lists the latest outputs.
    public func searchOutput(_ query: String, limit: Int = 150) -> [OutputHit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = """
        SELECT h.id, h.command, h.cwd, h.session, h.started, h.duration, h.exit_code, h.branch, o.text
        FROM output o JOIN history h ON h.id = o.history_id
        \(q.isEmpty ? "" : "WHERE instr(lower(o.text), lower(?)) > 0")
        ORDER BY h.id DESC LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        var i: Int32 = 1
        if !q.isEmpty { bindText(st, i, q); i += 1 }
        sqlite3_bind_int(st, i, Int32(limit))
        var out: [OutputHit] = []
        let lq = q.lowercased()
        while sqlite3_step(st) == SQLITE_ROW {
            let entry = readEntry(st)
            let text = sqlite3_column_text(st, 8).map { String(cString: $0) } ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let line = (lq.isEmpty ? lines.first : lines.first { $0.lowercased().contains(lq) }) ?? lines.first ?? ""
            out.append(OutputHit(entry: entry, line: String(line.trimmingCharacters(in: .whitespaces).prefix(300))))
        }
        return out
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

    /// One command's stats, if it was ever run.
    public func stats(for command: String) -> HistoryCommand? {
        lock.lock(); defer { lock.unlock() }
        return commands[command] ?? commands[command.trimmingCharacters(in: .whitespaces)]
    }

    /// Every distinct command with its count (a copy).
    public func allCommands() -> [HistoryCommand] {
        lock.lock(); defer { lock.unlock() }
        return Array(commands.values)
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

    /// The run of `command` before `beforeID` that has saved output (for "Compare with Previous Run").
    public func previousRun(of command: String, beforeID: Int64) -> (entry: HistoryEntry, output: String)? {
        lock.lock(); defer { lock.unlock() }
        let sql = """
        SELECT h.id, h.command, h.cwd, h.session, h.started, h.duration, h.exit_code, h.branch, o.text
        FROM history h JOIN output o ON o.history_id = h.id
        WHERE h.command = ? AND (? <= 0 OR h.id < ?) ORDER BY h.id DESC LIMIT 1
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, command.trimmingCharacters(in: .whitespacesAndNewlines))
        sqlite3_bind_int64(st, 2, beforeID)
        sqlite3_bind_int64(st, 3, beforeID)
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        let e = readEntry(st)
        let text = sqlite3_column_text(st, 8).map { String(cString: $0) } ?? ""
        return (e, text)
    }

    // MARK: Sync between Macs

    /// Commands run on this Mac after `afterID`, finished (or started over 6 hours ago), oldest first.
    public func localEntriesForSync(afterID: Int64, limit: Int = 5000) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        let sql = "SELECT id, command, cwd, session, started, duration, exit_code, branch FROM history WHERE id > ? AND source = 'anser' ORDER BY id ASC LIMIT ?"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, afterID)
        sqlite3_bind_int(st, 2, Int32(limit))
        var out: [HistoryEntry] = []
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        while sqlite3_step(st) == SQLITE_ROW {
            let e = readEntry(st)
            // Stop at a command still running, so it's sent once it has finished.
            if e.exitCode == nil, e.started > cutoff { break }
            out.append(e)
        }
        return out
    }

    /// Adds commands run on another Mac (marked with its name, so they're never sent back).
    public func importSynced(_ entries: [HistoryEntry], machine: String) {
        guard !entries.isEmpty else { return }
        lock.lock()
        exec("BEGIN")
        for e in entries {
            insert(command: e.command, cwd: e.cwd, session: nil, started: e.started, duration: e.duration, exit: e.exitCode, branch: e.branch, source: "sync:" + machine)
            bump(e.command, date: e.started, cwd: e.cwd, exit: e.exitCode)
        }
        exec("COMMIT")
        orderDirty = true
        lock.unlock()
    }

    public func syncValue(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return metaValue("sync." + key)
    }

    public func setSyncValue(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        setMeta("sync." + key, value)
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

// MARK: Cleaning up (History Editor)

extension HistoryStore {
    public struct CompactOptions: Sendable, Equatable {
        /// Keep only the newest N runs of each command (counts for suggestions shrink to N).
        public var keepRunsPerCommand: Int?
        /// Forget commands not used for this many days.
        public var unusedForDays: Int?
        /// Drop saved output of runs older than this many days.
        public var outputOlderThanDays: Int?
        /// Also delete these commands (e.g. the mistakes found).
        public var removeCommands: [String] = []
        public init(keepRunsPerCommand: Int? = nil, unusedForDays: Int? = nil, outputOlderThanDays: Int? = nil, removeCommands: [String] = []) {
            self.keepRunsPerCommand = keepRunsPerCommand; self.unusedForDays = unusedForDays
            self.outputOlderThanDays = outputOlderThanDays; self.removeCommands = removeCommands
        }
    }

    public struct CompactResult: Sendable, Equatable {
        public var runsRemoved = 0
        public var commandsRemoved = 0
        public var outputsRemoved = 0
        public var bytesBefore: Int64 = 0
        public var bytesAfter: Int64 = 0
    }

    /// The database's size on disk, with its write-ahead log.
    public var sizeOnDisk: Int64 {
        let fm = FileManager.default
        return [path, path + "-wal", path + "-shm"].reduce(Int64(0)) { sum, p in
            sum + ((try? fm.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0)
        }
    }

    /// Total runs stored (every time a command ran).
    public var runCount: Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM history", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }

    /// Deletes many commands at once (every run of each, and their output).
    /// Unless `permanently`, the runs go to Recently Deleted for 7 days.
    public func delete(commands list: [String], permanently: Bool = true, now: Date = Date()) {
        guard !list.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN")
        for c in list {
            if !permanently { moveToTrash(command: c, now: now) }
            delete(command: c)
        }
        exec("COMMIT")
    }

    private func moveToTrash(command: String, now: Date) {
        var st: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO trash SELECT id, command, cwd, session, started, duration, exit_code, branch, source, ? FROM history WHERE command=?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, now.timeIntervalSince1970)
        bindText(st, 2, command)
        sqlite3_step(st)
    }

    public struct Trashed: Sendable, Equatable {
        public var command: String
        public var runs: Int
        public var deleted: Date
        public var lastUsed: Date
    }

    /// Recently deleted commands, newest deletion first.
    public func trashed() -> [Trashed] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT command, COUNT(*), MAX(deleted_at), MAX(started) FROM trash GROUP BY command ORDER BY MAX(deleted_at) DESC", -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [Trashed] = []
        while sqlite3_step(st) == SQLITE_ROW {
            guard let c = sqlite3_column_text(st, 0) else { continue }
            out.append(Trashed(command: String(cString: c), runs: Int(sqlite3_column_int(st, 1)),
                               deleted: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)), lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(st, 3))))
        }
        return out
    }

    /// Puts deleted commands back (their saved output is gone).
    public func restore(commands list: [String]) {
        guard !list.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN")
        for c in list {
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO history(id, command, cwd, session, started, duration, exit_code, branch, source) SELECT id, command, cwd, session, started, duration, exit_code, branch, source FROM trash WHERE command=?", -1, &st, nil) == SQLITE_OK {
                bindText(st, 1, c); sqlite3_step(st)
            }
            sqlite3_finalize(st)
            if sqlite3_prepare_v2(db, "DELETE FROM trash WHERE command=?", -1, &st, nil) == SQLITE_OK { bindText(st, 1, c); sqlite3_step(st) }
            sqlite3_finalize(st)
        }
        exec("COMMIT")
        loadIndex()
    }

    /// Removes from Recently Deleted for good: these commands, or everything deleted before `olderThan`.
    @discardableResult
    public func purgeTrash(commands list: [String]? = nil, olderThan: Date? = nil) -> Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        var n = 0
        if let list {
            for c in list {
                if sqlite3_prepare_v2(db, "DELETE FROM trash WHERE command=?", -1, &st, nil) == SQLITE_OK { bindText(st, 1, c); sqlite3_step(st); n += Int(sqlite3_changes(db)) }
                sqlite3_finalize(st)
            }
        }
        if let olderThan {
            if sqlite3_prepare_v2(db, "DELETE FROM trash WHERE deleted_at < ?", -1, &st, nil) == SQLITE_OK {
                sqlite3_bind_double(st, 1, olderThan.timeIntervalSince1970); sqlite3_step(st); n += Int(sqlite3_changes(db))
            }
            sqlite3_finalize(st)
        }
        return n
    }

    /// What you ran to fix it the last time this exact command failed: the commands
    /// between that failure and its next successful run in the same tab.
    public func fixAfterFailure(of command: String, excludingID: Int64 = 0) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let failSQL = "SELECT id, session FROM history WHERE command=? AND exit_code IS NOT NULL AND exit_code != 0 AND id != ? AND session IS NOT NULL ORDER BY id DESC LIMIT 5"
        guard sqlite3_prepare_v2(db, failSQL, -1, &st, nil) == SQLITE_OK else { return nil }
        bindText(st, 1, command)
        sqlite3_bind_int64(st, 2, excludingID)
        var failures: [(Int64, String)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            if let sess = sqlite3_column_text(st, 1) { failures.append((sqlite3_column_int64(st, 0), String(cString: sess))) }
        }
        sqlite3_finalize(st)
        let noise: Set<String> = ["ls", "ll", "la", "pwd", "clear", "history", "git status", "git diff", "cat", "less"]
        for (fid, sess) in failures {
            var q: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT command, exit_code FROM history WHERE session=? AND id > ? AND id != ? ORDER BY id LIMIT 15", -1, &q, nil) == SQLITE_OK else { continue }
            bindText(q, 1, sess)
            sqlite3_bind_int64(q, 2, fid)
            sqlite3_bind_int64(q, 3, excludingID)
            var steps: [String] = []
            var fixed = false
            while sqlite3_step(q) == SQLITE_ROW {
                guard let c = sqlite3_column_text(q, 0) else { continue }
                let cmd = String(cString: c)
                let ok = sqlite3_column_type(q, 1) != SQLITE_NULL && sqlite3_column_int(q, 1) == 0
                if cmd == command { fixed = ok; break }
                // Only commands that worked count as part of the fix.
                if ok, !noise.contains(cmd), !(HistoryStore.programName(cmd).map { ["cat", "less", "ls", "man", "echo"].contains($0) } ?? false),
                   !steps.contains(cmd) { steps.append(cmd) }
            }
            sqlite3_finalize(q)
            if fixed, !steps.isEmpty { return Array(steps.suffix(3)) }
        }
        return nil
    }

    /// Shrinks history: removes old runs, unused commands and old output, then reclaims the space.
    @discardableResult
    public func compact(_ o: CompactOptions, now: Date = Date()) -> CompactResult {
        lock.lock(); defer { lock.unlock() }
        var r = CompactResult()
        r.bytesBefore = sizeOnDisk
        let commandsBefore = commands.count
        func run(_ sql: String, _ bind: ((OpaquePointer?) -> Void)? = nil) -> Int {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(st) }
            bind?(st)
            sqlite3_step(st)
            return Int(sqlite3_changes(db))
        }
        exec("BEGIN")
        for c in o.removeCommands {
            moveToTrash(command: c, now: now)
            r.runsRemoved += run("DELETE FROM history WHERE command=?") { self.bindText($0, 1, c) }
        }
        if let days = o.unusedForDays, days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            r.runsRemoved += run("DELETE FROM history WHERE command IN (SELECT command FROM history GROUP BY command HAVING MAX(started) < ?)") {
                sqlite3_bind_double($0, 1, cutoff)
            }
        }
        if let keep = o.keepRunsPerCommand, keep > 0 {
            r.runsRemoved += run("""
                DELETE FROM history WHERE id IN (
                  SELECT id FROM (SELECT id, ROW_NUMBER() OVER (PARTITION BY command ORDER BY started DESC, id DESC) AS rn FROM history) WHERE rn > ?)
                """) { sqlite3_bind_int($0, 1, Int32(keep)) }
        }
        if let days = o.outputOlderThanDays, days >= 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            r.outputsRemoved += run("DELETE FROM output WHERE history_id IN (SELECT id FROM history WHERE started < ?)") { sqlite3_bind_double($0, 1, cutoff) }
        }
        r.outputsRemoved += run("DELETE FROM output WHERE history_id NOT IN (SELECT id FROM history)")
        exec("COMMIT")
        exec("PRAGMA wal_checkpoint(TRUNCATE)")
        exec("VACUUM")
        loadIndex()
        r.commandsRemoved = max(0, commandsBefore - commands.count)
        r.bytesAfter = sizeOnDisk
        return r
    }
}

extension HistoryStore {
    /// Every run of one command, newest first (for the History Editor's details).
    public func runs(of command: String, limit: Int = 50) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "SELECT id, command, cwd, session, started, duration, exit_code, branch FROM history WHERE command=? ORDER BY started DESC, id DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        bindText(st, 1, command)
        sqlite3_bind_int(st, 2, Int32(limit))
        var out: [HistoryEntry] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(readEntry(st)) }
        return out
    }

    /// Changes a command's text in every run (fixing a typo, removing a secret). Merges into `to` when that already exists.
    public func rename(command: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != command else { return }
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE history SET command=? WHERE command=?", -1, &st, nil) == SQLITE_OK {
            bindText(st, 1, n)
            bindText(st, 2, command)
            sqlite3_step(st)
        }
        sqlite3_finalize(st)
        loadIndex()
    }
}

extension HistoryStore {
    /// When runs started since `since` (one command, or all of them), for activity charts.
    public func runDates(command: String? = nil, since: Date) -> [Date] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = command == nil ? "SELECT started FROM history WHERE started >= ?"
                                 : "SELECT started FROM history WHERE started >= ? AND command=?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, since.timeIntervalSince1970)
        if let command { bindText(st, 2, command) }
        var out: [Date] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(Date(timeIntervalSince1970: sqlite3_column_double(st, 0))) }
        return out
    }
}
