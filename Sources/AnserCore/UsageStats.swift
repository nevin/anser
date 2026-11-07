import Foundation

/// Counts of which features you use, per day, kept only on this Mac
/// (~/Library/Application Support/Anser/usage.json). Nothing is sent
/// anywhere; you can read it in Help → Your Feature Usage and choose to
/// include it in a problem report. Off unless `usageStats` is on.
public struct UsageStats: Codable, Sendable, Equatable {
    /// "2026-11-04" → feature → count.
    public var days: [String: [String: Int]] = [:]

    public init() {}

    static func dayKey(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public mutating func record(_ feature: String, at date: Date = Date()) {
        days[Self.dayKey(date), default: [:]][feature, default: 0] += 1
    }

    /// Drops days older than `keep` days.
    public mutating func prune(keep: Int = 90, now: Date = Date()) {
        let cutoff = Self.dayKey(now.addingTimeInterval(-Double(keep) * 86_400))
        days = days.filter { $0.key >= cutoff }
    }

    public struct Line: Equatable, Sendable {
        public let feature: String
        public let count: Int
        public let daysUsed: Int
    }

    /// Totals over the last `days` days, most used first.
    public func summary(days n: Int = 30, now: Date = Date()) -> [Line] {
        let cutoff = Self.dayKey(now.addingTimeInterval(-Double(n) * 86_400))
        var count: [String: Int] = [:], used: [String: Int] = [:]
        for (day, features) in days where day >= cutoff {
            for (f, c) in features { count[f, default: 0] += c; used[f, default: 0] += 1 }
        }
        return count.map { Line(feature: $0.key, count: $0.value, daysUsed: used[$0.key] ?? 0) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.feature < $1.feature }
    }

    /// Plain text for Help → Your Feature Usage and problem reports.
    public func report(days n: Int = 30, now: Date = Date()) -> String {
        let lines = summary(days: n, now: now)
        guard !lines.isEmpty else { return "No usage recorded in the last \(n) days." }
        return "Feature usage, last \(n) days (count · days used):\n" + lines.map { "  \($0.feature): \($0.count) · \($0.daysUsed)d" }.joined(separator: "\n")
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Anser/usage.json")
    }

    public static func load(from url: URL = defaultURL) -> UsageStats {
        (try? JSONDecoder().decode(UsageStats.self, from: Data(contentsOf: url))) ?? UsageStats()
    }

    public func save(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
