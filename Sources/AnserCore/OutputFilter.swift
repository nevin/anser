import Foundation

/// Filters a running command's output: lines matching a search, errors and
/// warnings only, and runs of near-identical lines (progress bars, repeated
/// log lines) folded into one.
public enum OutputFilter {
    public enum Level: Int, Sendable, Comparable {
        case normal = 0, warning = 1, error = 2
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Line: Sendable, Equatable {
        public var text: String
        public var level: Level
        /// How many lines this one stands for (more than 1 when folded).
        public var count: Int
        /// Line number in the original output (1-based, first of the run).
        public var number: Int
    }

    public struct Options: Sendable, Equatable {
        public var query: String
        public var minimumLevel: Level
        public var fold: Bool
        /// Treat the query as a regular expression.
        public var regex: Bool
        public init(query: String = "", minimumLevel: Level = .normal, fold: Bool = true, regex: Bool = false) {
            self.query = query; self.minimumLevel = minimumLevel; self.fold = fold; self.regex = regex
        }
    }

    public static func level(of line: String) -> Level {
        let l = line.lowercased()
        let ns = l as NSString
        let r = NSRange(location: 0, length: ns.length)
        if errorRE.firstMatch(in: l, range: r) != nil, okRE.firstMatch(in: l, range: r) == nil { return .error }
        if warnRE.firstMatch(in: l, range: r) != nil { return .warning }
        return .normal
    }

    nonisolated(unsafe) static let errorRE = try! NSRegularExpression(
        pattern: #"\b(error|errors|err!|fatal|failed|failure|panic|exception|traceback|segmentation fault|denied|refused|cannot|can't|could not|not found|undefined|uncaught)\b|✗|✘|❌"#)
    nonisolated(unsafe) static let okRE = try! NSRegularExpression(
        pattern: #"\b0 (errors?|failures?|failed)\b|\bno errors?\b|\berror(s)?: 0\b"#)
    nonisolated(unsafe) static let warnRE = try! NSRegularExpression(
        pattern: #"\b(warn|warning|warnings|deprecated|deprecation)\b|⚠"#)

    /// The shape of a line with numbers, hex and times taken out, for folding.
    static func shape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasDigit = false
        for ch in s {
            if ch.isNumber || ch.isHexDigit && lastWasDigit {
                if !lastWasDigit { out.append("#") }
                lastWasDigit = true
            } else {
                out.append(ch)
                lastWasDigit = false
            }
        }
        return out
    }

    public static func apply(_ text: String, _ o: Options) -> [Line] {
        let raw = text.split(separator: "\n", omittingEmptySubsequences: false)
        var matcher: ((String) -> Bool)?
        let q = o.query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            if o.regex, let re = try? NSRegularExpression(pattern: q, options: [.caseInsensitive]) {
                matcher = { re.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
            } else {
                // Every word must appear (in any order).
                let words = q.lowercased().split(separator: " ").map(String.init)
                matcher = { line in let l = line.lowercased(); return words.allSatisfy { l.contains($0) } }
            }
        }
        var out: [Line] = []
        var lastShape: String?
        for (i, sub) in raw.enumerated() {
            let s = String(sub)
            if s.trimmingCharacters(in: .whitespaces).isEmpty, matcher != nil || o.minimumLevel > .normal { continue }
            let lv = level(of: s)
            if lv < o.minimumLevel { continue }
            if let m = matcher, !m(s) { continue }
            if o.fold {
                let sh = shape(s)
                if sh == lastShape, !out.isEmpty, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    out[out.count - 1].count += 1
                    out[out.count - 1].text = s        // show the newest of the run
                    out[out.count - 1].level = max(out[out.count - 1].level, lv)
                    continue
                }
                lastShape = sh
            }
            out.append(Line(text: s, level: lv, count: 1, number: i + 1))
        }
        while let l = out.last, l.text.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        return out
    }

    /// Counts by level, for the filter bar ("3 errors · 12 warnings").
    public static func counts(_ text: String) -> (errors: Int, warnings: Int) {
        var e = 0, w = 0
        for sub in text.split(separator: "\n") {
            switch level(of: String(sub)) {
            case .error: e += 1
            case .warning: w += 1
            case .normal: break
            }
        }
        return (e, w)
    }
}
