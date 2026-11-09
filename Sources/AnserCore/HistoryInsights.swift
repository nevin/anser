import Foundation

/// Numbers behind the History Editor's side panel: activity per day, most-used
/// commands and folders, and one command's track record.
public enum HistoryInsights {
    public struct Count: Sendable, Equatable {
        public var name: String
        public var count: Int
        public init(_ name: String, _ count: Int) { self.name = name; self.count = count }
    }

    /// One command's track record, from its runs (newest first or any order).
    public struct Summary: Sendable, Equatable {
        public var runs = 0
        public var failed = 0
        /// Runs whose result is known (finished with an exit code).
        public var finished = 0
        public var first: Date?
        public var last: Date?
        public var typical: Double?
        public var folders: [Count] = []
        public var branches: [Count] = []
        /// Share of finished runs that worked, 0...1.
        public var successRate: Double? { finished == 0 ? nil : Double(finished - failed) / Double(finished) }
        public init() {}
    }

    public static func summary(of runs: [HistoryEntry]) -> Summary {
        var s = Summary()
        s.runs = runs.count
        s.finished = runs.filter { $0.exitCode != nil }.count
        s.failed = runs.filter { ($0.exitCode ?? 0) != 0 }.count
        s.first = runs.map(\.started).min()
        s.last = runs.map(\.started).max()
        let durations = runs.compactMap(\.duration).sorted()
        if !durations.isEmpty { s.typical = durations[durations.count / 2] }
        s.folders = ranked(runs.compactMap { $0.cwd.flatMap { $0.isEmpty ? nil : $0 } })
        s.branches = ranked(runs.compactMap { $0.branch.flatMap { $0.isEmpty ? nil : $0 } })
        return s
    }

    /// Commands with the most runs.
    public static func topCommands(_ commands: [HistoryCommand], limit: Int = 6) -> [Count] {
        commands.sorted { $0.count == $1.count ? $0.lastUsed > $1.lastUsed : $0.count > $1.count }
            .prefix(limit).map { Count($0.command, $0.count) }
    }

    /// Values by how often they appear, most first (ties by name).
    public static func ranked(_ values: [String], limit: Int = 5) -> [Count] {
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { Count($0.key, $0.value) }
    }

    /// Runs per day for the last `days` days, oldest first; today is the last value.
    public static func perDay(_ dates: [Date], days: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> [Int] {
        guard days > 0 else { return [] }
        var out = [Int](repeating: 0, count: days)
        let today = calendar.startOfDay(for: now)
        for d in dates {
            guard let ago = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: today).day,
                  ago >= 0, ago < days else { continue }
            out[days - 1 - ago] += 1
        }
        return out
    }
}
