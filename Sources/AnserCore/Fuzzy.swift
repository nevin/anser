import Foundation

/// Small, fast fuzzy matcher. Prefix matches beat word-boundary matches,
/// which beat scattered subsequence matches.
public enum Fuzzy {
    public struct Match: Sendable {
        public var score: Int
        /// Character offsets (in the candidate) that matched, for highlighting.
        public var positions: [Int]
    }

    public static func match(_ query: String, _ candidate: String) -> Match? {
        if query.isEmpty { return Match(score: 0, positions: []) }
        // Fast path for plain ASCII (almost every command): works on the
        // string's bytes in place, without copying or lowercasing it.
        var q = Array(query.utf8)
        if q.allSatisfy({ $0 < 128 }) {
            for i in q.indices { q[i] = lower(q[i]) }
            let qExact = Array(query.utf8)
            if let r = candidate.utf8.withContiguousStorageIfAvailable({ buf -> Match?? in
                for b in buf where b >= 128 { return .none }   // not ASCII: use the general path
                return .some(asciiMatch(q, qExact, buf))
            }), let result = r {
                return result
            }
        }
        return generalMatch(query, candidate)
    }

    @inline(__always) static func lower(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c | 0x20 : c }
    @inline(__always) static func isBoundaryByte(_ c: UInt8) -> Bool {
        c == 32 || c == 45 || c == 95 || c == 47 || c == 46 || c == 58 || c == 61   // space - _ / . : =
    }

    /// Same scoring as `generalMatch`, on ASCII bytes.
    static func asciiMatch(_ q: [UInt8], _ qExact: [UInt8], _ c: UnsafeBufferPointer<UInt8>) -> Match? {
        let n = c.count, m = q.count
        guard m <= n else { return nil }
        // Quick reject: every query letter must appear in order.
        var qi = 0
        for b in c where qi < m && lower(b) == q[qi] { qi += 1 }
        guard qi == m else { return nil }
        // Prefix.
        var isPrefix = true, exactCase = true
        for i in 0..<m {
            if lower(c[i]) != q[i] { isPrefix = false; break }
            if c[i] != qExact[i] { exactCase = false }
        }
        if isPrefix { return Match(score: 1000 - (n - m) + (exactCase ? 50 : 0), positions: Array(0..<m)) }
        // Substring.
        if m <= n {
            var start = 0
            while start + m <= n {
                var ok = true
                for j in 0..<m where lower(c[start + j]) != q[j] { ok = false; break }
                if ok {
                    let boundary = start > 0 && isBoundaryByte(c[start - 1])
                    return Match(score: (boundary ? 700 : 500) - start - (n - m) / 4, positions: Array(start..<(start + m)))
                }
                start += 1
            }
        }
        // Scattered subsequence with bonuses.
        var positions: [Int] = []
        positions.reserveCapacity(m)
        var score = 0, lastMatch = -2
        qi = 0
        for ci in 0..<n where qi < m {
            if lower(c[ci]) == q[qi] {
                var s = 10
                if ci == 0 || isBoundaryByte(c[ci - 1]) { s += 25 }
                if lastMatch == ci - 1 { s += 15 }
                if ci > 0, c[ci] >= 65, c[ci] <= 90, c[ci - 1] >= 97, c[ci - 1] <= 122 { s += 20 }
                score += s
                positions.append(ci)
                lastMatch = ci
                qi += 1
            }
        }
        let spread = (positions.last ?? 0) - (positions.first ?? 0)
        return Match(score: score - spread - n / 8, positions: positions)
    }

    static func generalMatch(_ query: String, _ candidate: String) -> Match? {
        let q = Array(query.lowercased())
        let cOrig = Array(candidate)
        let c = Array(candidate.lowercased())
        guard q.count <= c.count else { return nil }

        // Exact / prefix fast paths.
        if c.starts(with: q) {
            let exactCase = cOrig.starts(with: Array(query))
            return Match(score: 1000 - (c.count - q.count) + (exactCase ? 50 : 0), positions: Array(0..<q.count))
        }
        // Substring.
        if let r = candidate.lowercased().range(of: query.lowercased()) {
            let start = candidate.lowercased().distance(from: candidate.lowercased().startIndex, to: r.lowerBound)
            let boundary = start > 0 && isBoundary(c[start - 1])
            return Match(score: (boundary ? 700 : 500) - start - (c.count - q.count) / 4, positions: Array(start..<(start + q.count)))
        }
        // Subsequence with bonuses for word boundaries and runs.
        var positions: [Int] = []
        var score = 0
        var qi = 0
        var lastMatch = -2
        for (ci, ch) in c.enumerated() where qi < q.count {
            if ch == q[qi] {
                var s = 10
                if ci == 0 || isBoundary(c[ci - 1]) { s += 25 }
                if lastMatch == ci - 1 { s += 15 }
                if ci > 0, cOrig[ci].isUppercase, cOrig[ci - 1].isLowercase { s += 20 }
                score += s
                positions.append(ci)
                lastMatch = ci
                qi += 1
            }
        }
        guard qi == q.count else { return nil }
        let spread = (positions.last ?? 0) - (positions.first ?? 0)
        return Match(score: score - spread - c.count / 8, positions: positions)
    }

    @inline(__always) static func isBoundary(_ ch: Character) -> Bool {
        ch == " " || ch == "-" || ch == "_" || ch == "/" || ch == "." || ch == ":" || ch == "="
    }
}
