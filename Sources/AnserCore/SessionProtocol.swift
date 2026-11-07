import Foundation

/// How Anser talks to `anser-session`, the small helper that keeps shells
/// running while Anser itself quits, restarts or updates.
///
/// Each terminal pane runs `anser-session attach`, which connects to the
/// helper over a Unix socket (only your user can open it) and passes bytes
/// both ways. Messages are framed: one type byte, a 4-byte big-endian length,
/// then the payload.
public enum SessionProtocol {
    public static let version = 1

    public enum Kind: UInt8, Sendable {
        /// Client → helper: JSON hello (attach or control request).
        case hello = 0x48        // H
        /// Client → helper: keyboard input for the shell.
        case input = 0x49        // I
        /// Client → helper: window size, 2 bytes columns + 2 bytes rows.
        case resize = 0x57       // W
        /// Helper → client: terminal output.
        case output = 0x4F       // O
        /// Helper → client: the shell exited; 4-byte status.
        case exit = 0x58         // X
        /// Helper → client: JSON reply to a control request.
        case reply = 0x52        // R
        /// Helper → client: a message to show, then the client stops.
        case error = 0x45        // E
    }

    public static func frame(_ kind: Kind, _ payload: Data) -> Data {
        var d = Data([kind.rawValue])
        var n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    public static func frame(_ kind: Kind, json: [String: Any]) -> Data {
        frame(kind, (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8))
    }

    public static func resizePayload(cols: Int, rows: Int) -> Data {
        var c = UInt16(clamping: cols).bigEndian, r = UInt16(clamping: rows).bigEndian
        var d = Data()
        withUnsafeBytes(of: &c) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &r) { d.append(contentsOf: $0) }
        return d
    }

    public static func parseResize(_ d: Data) -> (cols: Int, rows: Int)? {
        guard d.count == 4 else { return nil }
        let b = [UInt8](d)
        return (Int(b[0]) << 8 | Int(b[1]), Int(b[2]) << 8 | Int(b[3]))
    }

    public static func exitPayload(_ status: Int32) -> Data {
        var s = status.bigEndian
        return withUnsafeBytes(of: &s) { Data($0) }
    }

    public static func parseExit(_ d: Data) -> Int32 {
        guard d.count == 4 else { return 1 }
        let b = [UInt8](d)
        return Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    }

    /// Collects bytes and hands out complete frames.
    public struct Decoder: Sendable {
        private var buffer = Data()
        /// Frames larger than this mean a broken peer; decoding stops.
        public static let maxFrame = 16 << 20
        public private(set) var broken = false

        public init() {}

        public mutating func append(_ d: Data) -> [(Kind, Data)] {
            guard !broken else { return [] }
            buffer.append(d)
            var out: [(Kind, Data)] = []
            while buffer.count >= 5 {
                let b = buffer.startIndex
                let len = Int(buffer[b + 1]) << 24 | Int(buffer[b + 2]) << 16 | Int(buffer[b + 3]) << 8 | Int(buffer[b + 4])
                guard len <= Self.maxFrame, let kind = Kind(rawValue: buffer[b]) else { broken = true; return out }
                guard buffer.count >= 5 + len else { break }
                out.append((kind, buffer.subdata(in: (b + 5)..<(b + 5 + len))))
                buffer.removeSubrange(b..<(b + 5 + len))
            }
            return out
        }
    }

    // MARK: Paths

    /// Where kept sessions live: the helper's socket, each shell's event pipe and saved state.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Anser/sessions")
    }

    /// A session id is used in file names; only safe characters.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
    }
}

/// The most recent output of a kept shell, replayed when Anser re-attaches,
/// and whether a full-screen program (vim, htop…) is showing.
public struct ReplayBuffer: Sendable {
    public let limit: Int
    public private(set) var data = Data()
    /// The alternate screen (used by full-screen programs) is active.
    public private(set) var alternateScreen = false
    private var tail = Data()

    public init(limit: Int = 2 << 20) { self.limit = limit }

    public mutating func append(_ d: Data) {
        data.append(d)
        // Track the alternate screen, including sequences split across reads:
        // whichever of "on" / "off" came last wins.
        let scan = tail + d
        var lastOn: Int?, lastOff: Int?
        for (on, seq) in Self.altSequences {
            guard let r = scan.range(of: seq, options: .backwards) else { continue }
            let at = r.lowerBound - scan.startIndex
            if on { lastOn = max(lastOn ?? -1, at) } else { lastOff = max(lastOff ?? -1, at) }
        }
        if lastOn != nil || lastOff != nil { alternateScreen = (lastOn ?? -1) > (lastOff ?? -1) }
        tail = scan.suffix(16)
        if data.count > limit {
            // Drop the oldest part, starting again at a line break so the
            // replay never begins halfway through an escape sequence.
            var cut = data.count - limit
            let start = data.startIndex + cut
            if let nl = data[start...].firstIndex(of: 0x0A) { cut = nl - data.startIndex + 1 }
            data.removeSubrange(data.startIndex..<(data.startIndex + min(cut, data.count)))
        }
    }

    static let altSequences: [(on: Bool, seq: Data)] = [
        (true, Data("\u{1b}[?1049h".utf8)), (false, Data("\u{1b}[?1049l".utf8)),
        (true, Data("\u{1b}[?1047h".utf8)), (false, Data("\u{1b}[?1047l".utf8)),
        (true, Data("\u{1b}[?47h".utf8)), (false, Data("\u{1b}[?47l".utf8)),
    ]
}
