import Foundation

/// Short, friendly "how long ago": just now, 5 min ago, 3 hr ago, yesterday,
/// 4 days ago, 2 wk ago, Mar 14, Mar 2024.
public enum RelativeTime {
    public static func format(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) hr ago" }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? Int(s / 86400)
        if days <= 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 35 { return "\(days / 7) wk ago" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: now) ? "MMM d" : "MMM yyyy"
        return f.string(from: date)
    }

    /// From a Unix timestamp string, as git prints with `%ct` or `:unix`.
    public static func format(unix: String, now: Date = Date()) -> String? {
        guard let t = Double(unix.trimmingCharacters(in: .whitespaces)) else { return nil }
        return format(Date(timeIntervalSince1970: t), now: now)
    }
}
