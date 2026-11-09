import AppKit
import AnserCore

/// Anser's side of `anser-session`, the helper that keeps shells running
/// while Anser quits, restarts or updates (Settings → Sessions & Windows). Each pane's
/// terminal runs `anser-session attach`; this talks to the helper for
/// everything else: which shells are alive, ending one when its pane closes,
/// and cleaning up shells nobody will come back to.
final class SessionHost {
    static let shared = SessionHost()

    /// Self-tests use their own helper, never the one holding your real shells.
    let directory: URL = Services.isSelfTest
        ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("anser-st-sessions")
        : SessionProtocol.defaultDirectory

    var socketPath: String { directory.appendingPathComponent("d.sock").path }

    var helperPath: String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/anser-session").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// New panes start through the helper.
    var enabled: Bool { helperPath != nil && Services.shared.config.keepShellsRunning }

    /// Shells stay running when Anser quits (they need session restore to come back).
    var keepOnQuit: Bool { enabled && Services.shared.config.restoreSession }

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
    }

    func fifoPath(_ id: String) -> String { directory.appendingPathComponent(id + ".fifo").path }
    func stateURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }

    // MARK: Requests

    /// One control request; nil when the helper isn't running.
    @discardableResult
    func request(_ body: [String: Any], timeout: TimeInterval = 1.5) -> [String: Any]? {
        guard var addr = Self.address(socketPath) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        var json = body
        json["v"] = SessionProtocol.version
        json["mode"] = "control"
        let frame = SessionProtocol.frame(.hello, json: json)
        guard frame.withUnsafeBytes({ write(fd, $0.baseAddress!, frame.count) }) == frame.count else { return nil }
        var decoder = SessionProtocol.Decoder()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return nil }
            for (kind, payload) in decoder.append(Data(buf[0..<n])) where kind == .reply {
                return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            }
        }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Shells the helper is holding right now.
    func liveIDs() -> Set<String> { Set(request(["cmd": "list"])?["ids"] as? [String] ?? []) }

    /// Read once at launch, for restoring panes.
    private(set) lazy var liveAtLaunch: Set<String> = liveIDs()
    /// Tests: read it again (as a fresh launch would).
    func refreshLive() { liveAtLaunch = liveIDs() }

    func end(_ id: String) {
        try? FileManager.default.removeItem(at: stateURL(id))
        DispatchQueue.global(qos: .utility).async { [self] in request(["cmd": "kill", "id": id]) }
    }

    /// A program other than the shell is in the foreground (for "close while running?").
    func busy(_ id: String) -> Bool { (request(["cmd": "busy", "id": id], timeout: 0.5)?["busy"] as? Bool) ?? false }

    /// Ends shells not in `ids` (and not open in a window), and removes their leftover files.
    func keepOnly(_ ids: Set<String>) {
        DispatchQueue.global(qos: .utility).async { [self] in
            request(["cmd": "keep", "ids": Array(ids)])
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for f in files where f.hasSuffix(".json") || f.hasSuffix(".fifo") {
                let id = (f as NSString).deletingPathExtension
                if !ids.contains(id) { unlink(directory.appendingPathComponent(f).path) }
            }
        }
    }

    // MARK: Saved state

    /// What was last written per shell, so unchanged state isn't rewritten every autosave.
    private var lastSaved: [String: Data] = [:]

    func save(_ session: ShellSession) {
        guard session.persistent, let data = try? JSONEncoder().encode(session.savedState()) else { return }
        guard lastSaved[session.id] != data else { return }
        lastSaved[session.id] = data
        let url = stateURL(session.id)
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    func loadState(_ id: String) -> ShellSession.SavedState? {
        guard SessionProtocol.isValidID(id), let d = try? Data(contentsOf: stateURL(id)) else { return nil }
        return try? JSONDecoder().decode(ShellSession.SavedState.self, from: d)
    }
}
