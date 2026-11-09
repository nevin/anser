import Foundation

/// Local servers (anything listening on a TCP port) and which shell started them.
public enum ServerPorts {
    public struct Listener: Sendable, Equatable, Hashable {
        public var pid: Int32
        public var process: String
        public var port: Int
        /// The address it listens on ("*", "127.0.0.1", "[::1]"…).
        public var address: String
        public init(pid: Int32, process: String, port: Int, address: String) {
            self.pid = pid; self.process = process; self.port = port; self.address = address
        }
        /// A link to open it in the browser.
        public var url: String { "http://localhost:\(port)" }
    }

    /// Parses `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` (fields: p=pid, c=command, n=address:port).
    public static func parseLsof(_ text: String) -> [Listener] {
        var out: [Listener] = []
        var seen = Set<String>()
        var pid: Int32 = 0, cmd = ""
        for raw in text.split(separator: "\n") {
            guard let tag = raw.first else { continue }
            let v = String(raw.dropFirst())
            switch tag {
            case "p": pid = Int32(v) ?? 0; cmd = ""
            case "c": cmd = v
            case "n":
                guard let colon = v.lastIndex(of: ":"), let port = Int(v[v.index(after: colon)...]), pid > 0 else { continue }
                let addr = String(v[..<colon])
                // One row per process and port (IPv4 and IPv6 both listen).
                if seen.insert("\(pid):\(port)").inserted {
                    out.append(Listener(pid: pid, process: cmd, port: port, address: addr))
                }
            default: break
            }
        }
        return out.sorted { $0.port < $1.port }
    }

    /// Parses `ps -axo pid=,ppid=` into child → parent.
    public static func parseParents(_ text: String) -> [Int32: Int32] {
        var m: [Int32: Int32] = [:]
        for line in text.split(separator: "\n") {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            if p.count >= 2, let a = Int32(p[0]), let b = Int32(p[1]) { m[a] = b }
        }
        return m
    }

    /// Whether `pid` is `ancestor` or runs under it.
    public static func descends(_ pid: Int32, from ancestor: Int32, parents: [Int32: Int32]) -> Bool {
        guard ancestor > 1 else { return false }
        var p = pid
        var steps = 0
        while p > 1, steps < 64 {
            if p == ancestor { return true }
            guard let next = parents[p], next != p else { return false }
            p = next
            steps += 1
        }
        return false
    }

    /// Ports a program announced in its output ("Local: http://localhost:5173/",
    /// "listening on port 3000", "Running on http://127.0.0.1:8000").
    public static func announcedPorts(in text: String) -> [Int] {
        let ns = text as NSString
        var out: [Int] = []
        for re in [urlRE, phraseRE] {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                if let p = Int(ns.substring(with: m.range(at: 1))), (1...65535).contains(p), !out.contains(p) { out.append(p) }
            }
        }
        return out
    }

    nonisolated(unsafe) static let urlRE = try! NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|\[::\]):(\d{2,5})"#, options: [.caseInsensitive])
    nonisolated(unsafe) static let phraseRE = try! NSRegularExpression(
        pattern: #"(?:listening|running|serving|started|server)\b[^\n]{0,30}?\bport\s+(\d{2,5})\b"#, options: [.caseInsensitive])

    /// Port from what the user typed ("3000", ":3000", "localhost:3000").
    public static func parsePort(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let digits = t.split(separator: ":").last.map(String.init) ?? t
        guard let p = Int(digits), (1...65535).contains(p) else { return nil }
        return p
    }
}
