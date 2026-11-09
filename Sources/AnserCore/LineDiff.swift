import Foundation

/// Line-by-line differences between two outputs (Myers' algorithm), for
/// "Compare with Previous Run".
public enum LineDiff {
    public enum Kind: Sendable, Equatable { case same, removed, added }

    public struct Line: Sendable, Equatable {
        public var kind: Kind
        public var text: String
        public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
    }

    public struct Summary: Sendable, Equatable {
        public var added = 0
        public var removed = 0
        public init() {}
        public var identical: Bool { added == 0 && removed == 0 }
    }

    /// `ignoreNumbers`: lines that differ only in numbers (times, counts, ids) count as the same.
    public static func diff(_ old: String, _ new: String, ignoreNumbers: Bool = false, maxLines: Int = 20_000) -> [Line] {
        let a = Array(old.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines)).map(String.init)
        let b = Array(new.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines)).map(String.init)
        let ka = ignoreNumbers ? a.map(OutputFilter.shape) : a
        let kb = ignoreNumbers ? b.map(OutputFilter.shape) : b
        return diff(a, b, keysA: ka, keysB: kb)
    }

    static func diff(_ a: [String], _ b: [String], keysA: [String], keysB: [String]) -> [Line] {
        // Common start and end first: usually most of it.
        var pre = 0
        while pre < keysA.count, pre < keysB.count, keysA[pre] == keysB[pre] { pre += 1 }
        var suf = 0
        while suf < keysA.count - pre, suf < keysB.count - pre, keysA[keysA.count - 1 - suf] == keysB[keysB.count - 1 - suf] { suf += 1 }
        var out = (0..<pre).map { Line(.same, b[$0]) }
        let ma = Array(keysA[pre..<(keysA.count - suf)]), mb = Array(keysB[pre..<(keysB.count - suf)])
        let ta = Array(a[pre..<(a.count - suf)]), tb = Array(b[pre..<(b.count - suf)])
        out += myers(ma, mb, ta, tb)
        out += (0..<suf).map { Line(.same, b[b.count - suf + $0]) }
        return out
    }

    static func myers(_ a: [String], _ b: [String], _ ta: [String], _ tb: [String]) -> [Line] {
        let n = a.count, m = b.count
        if n == 0 { return tb.map { Line(.added, $0) } }
        if m == 0 { return ta.map { Line(.removed, $0) } }
        let maxD = min(n + m, 4000)
        let off = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...maxD {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) { x = v[off + k + 1] } else { x = v[off + k - 1] + 1 }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[off + k] = x
                if x >= n, y >= m { found = true; trace.append(v); break outer }
                k += 2
            }
        }
        // Too different to line up: show it all as removed then added.
        guard found else { return ta.map { Line(.removed, $0) } + tb.map { Line(.added, $0) } }
        var out: [Line] = []
        var x = n, y = m
        for d in stride(from: trace.count - 2, through: 0, by: -1) {
            let vv = trace[d]
            let k = x - y
            let prevK = (k == -d || (k != d && vv[off + k - 1] < vv[off + k + 1])) ? k + 1 : k - 1
            let px = vv[off + prevK], py = px - prevK
            while x > px, y > py { out.append(Line(.same, tb[y - 1])); x -= 1; y -= 1 }
            if d > 0 {
                if x == px { out.append(Line(.added, tb[y - 1])); y -= 1 } else { out.append(Line(.removed, ta[x - 1])); x -= 1 }
            }
        }
        return out.reversed()
    }

    public static func summary(_ lines: [Line]) -> Summary {
        var s = Summary()
        for l in lines {
            if l.kind == .added { s.added += 1 } else if l.kind == .removed { s.removed += 1 }
        }
        return s
    }
}
