import Foundation

/// Recognizes output that is really data — JSON, CSV/TSV, or a table with a
/// header row like `kubectl get pods`, `docker ps` or `ps aux` — so it can be
/// shown in a sortable, filterable viewer.
public enum StructuredOutput {
    public indirect enum JSON: Sendable, Equatable {
        case object([(String, JSON)])
        case array([JSON])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        public static func == (l: JSON, r: JSON) -> Bool {
            switch (l, r) {
            case let (.object(a), .object(b)): return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            case let (.array(a), .array(b)): return a == b
            case let (.string(a), .string(b)): return a == b
            case let (.number(a), .number(b)): return a == b
            case let (.bool(a), .bool(b)): return a == b
            case (.null, .null): return true
            default: return false
            }
        }

        init(_ any: Any) {
            switch any {
            case let d as [String: Any]: self = .object(d.keys.sorted().map { ($0, JSON(d[$0]!)) })
            case let a as [Any]: self = .array(a.map(JSON.init))
            case let s as String: self = .string(s)
            case let n as NSNumber:
                if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
            default: self = .null
            }
        }

        /// One-line text for a value (objects and arrays as a count).
        public var preview: String {
            switch self {
            case .object(let o): return "{ \(o.count) field\(o.count == 1 ? "" : "s") }"
            case .array(let a): return "[ \(a.count) item\(a.count == 1 ? "" : "s") ]"
            case .string(let s): return s
            case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            case .bool(let b): return b ? "true" : "false"
            case .null: return "null"
            }
        }

        public var children: [(String, JSON)] {
            switch self {
            case .object(let o): return o
            case .array(let a): return a.enumerated().map { ("[\($0.offset)]", $0.element) }
            default: return []
            }
        }
    }

    public struct Table: Sendable, Equatable {
        public var headers: [String]
        public var rows: [[String]]
        public init(headers: [String], rows: [[String]]) { self.headers = headers; self.rows = rows }
    }

    public enum Kind: Sendable, Equatable {
        case json(JSON)
        case table(Table, source: String)    // source: "csv", "tsv", "columns", "json"
    }

    public static func detect(_ text: String) -> Kind? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.utf8.count <= 32 << 20 else { return nil }
        if let j = json(t) { return .json(j) }
        if let ndjson = ndjsonTable(t) { return .table(ndjson, source: "json") }
        if let c = delimited(t, separator: "\t") { return .table(c, source: "tsv") }
        if let c = delimited(t, separator: ",") { return .table(c, source: "csv") }
        if let c = columns(t) { return .table(c, source: "columns") }
        return nil
    }

    static func json(_ t: String) -> JSON? {
        guard let f = t.first, f == "{" || f == "[" else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed]) else { return nil }
        return JSON(obj)
    }

    /// A JSON array of objects, or one object per line, as a table.
    public static func table(from j: JSON) -> Table? {
        guard case .array(let items) = j, !items.isEmpty else { return nil }
        var keys: [String] = []
        var rows: [[String: String]] = []
        for it in items {
            guard case .object(let o) = it else { return nil }
            var r: [String: String] = [:]
            for (k, v) in o {
                if !keys.contains(k) { keys.append(k) }
                r[k] = v.preview
            }
            rows.append(r)
        }
        return Table(headers: keys, rows: rows.map { r in keys.map { r[$0] ?? "" } })
    }

    static func ndjsonTable(_ t: String) -> Table? {
        let lines = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2, lines.allSatisfy({ $0.hasPrefix("{") && $0.hasSuffix("}") }) else { return nil }
        let items = lines.compactMap { json($0) }
        guard items.count == lines.count else { return nil }
        return table(from: .array(items))
    }

    /// CSV/TSV with quotes. Needs a header and at least one row, all with the same number of fields.
    static func delimited(_ t: String, separator: Character) -> Table? {
        let lines = t.split(separator: "\n", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard lines.count >= 2 else { return nil }
        let rows = lines.map { splitDelimited($0, separator) }
        let n = rows[0].count
        guard n >= 2, rows.allSatisfy({ $0.count == n }) else { return nil }
        // Prose with commas isn't a table: header fields are short.
        guard rows[0].allSatisfy({ $0.count <= 60 && !$0.isEmpty }) else { return nil }
        return Table(headers: rows[0], rows: Array(rows.dropFirst()))
    }

    static func splitDelimited(_ line: String, _ sep: Character) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        let it = Array(line)
        var i = 0
        while i < it.count {
            let c = it[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < it.count, it[i + 1] == "\"" { cur.append("\""); i += 1 } else { quoted = false }
                } else { cur.append(c) }
            } else if c == "\"" && cur.isEmpty {
                quoted = true
            } else if c == sep {
                out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else {
                cur.append(c)
            }
            i += 1
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// A header row of capitalized names over aligned columns.
    static func columns(_ t: String) -> Table? {
        let lines = t.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2, let header = lines.first else { return nil }
        let letters = header.filter(\.isLetter)
        guard letters.count >= 3, letters.filter(\.isUppercase).count * 10 >= letters.count * 8 else { return nil }
        let chars = Array(header)
        // Column starts: after 2+ spaces (or 1, when the header has no wide gaps).
        let wide = header.contains("  ")
        var starts: [Int] = []
        for i in chars.indices where chars[i] != " " {
            let gap = wide ? 2 : 1
            if i == 0 || (i >= gap && chars[(i - gap)..<i].allSatisfy { $0 == " " }) { starts.append(i) }
        }
        guard starts.count >= 2 else { return nil }
        let headers = starts.enumerated().map { idx, s -> String in
            let e = idx + 1 < starts.count ? starts[idx + 1] : chars.count
            return String(chars[s..<min(e, chars.count)]).trimmingCharacters(in: .whitespaces)
        }
        var rows: [[String]] = []
        for line in lines.dropFirst() {
            if wide {
                let lc = Array(line)
                var row: [String] = []
                for (idx, s) in starts.enumerated() {
                    // Move a start left to the beginning of the word it lands in.
                    var a = min(s, lc.count)
                    while a > 0, a < lc.count, lc[a - 1] != " " { a -= 1 }
                    var e = idx + 1 < starts.count ? min(starts[idx + 1], lc.count) : lc.count
                    while e > 0, e < lc.count, lc[e - 1] != " " { e -= 1 }
                    row.append(a < e ? String(lc[a..<e]).trimmingCharacters(in: .whitespaces) : "")
                }
                rows.append(row)
            } else {
                let parts = line.split(separator: " ", maxSplits: headers.count - 1, omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= headers.count - 1 else { return nil }
                rows.append(parts + Array(repeating: "", count: max(0, headers.count - parts.count)))
            }
        }
        return Table(headers: headers, rows: rows)
    }
}
