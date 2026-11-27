import AppKit
import AnserCore
import GhosttyKit

/// A kept shell's own terminal, handed to its tab by `anser-session`, so Ghostty reads the
/// shell directly instead of through `anser-session attach` and a second terminal (heavy
/// output streams about twice as fast). The helper still holds the terminal, so the shell
/// outlives Anser; the socket stays open so the helper can say when the shell exits or
/// opens in another window, and so the tab can hand its history back when it lets go.
final class DirectTerminal {
    /// Anser's copy of the shell's terminal (Ghostty keeps its own).
    let fd: Int32
    let shellPID: pid_t
    /// The output the helper kept, shown before anything new.
    let replay: [UInt8]
    private let socket: Int32
    private let opened = Date()
    private var decoder: SessionProtocol.Decoder
    /// Frames that came in with the handoff, delivered once watching starts.
    private var early: [(SessionProtocol.Kind, Data)]
    private var source: DispatchSourceRead?
    private var exitWatch: DispatchSourceProcess?
    /// Main thread only.
    private(set) var closed = false
    /// `queue` only: every write to the socket goes through the queue, so none lands after
    /// the socket closed (when the helper goes away first, say).
    private var socketOpen = true
    private static let queue = DispatchQueue(label: "anser.direct-terminal")

    /// The tab's surface, whose recent output is snapshotted to the helper (main thread).
    var surface: (() -> ghostty_surface_t?)?
    /// Output total at the last snapshot, so unchanged tabs send nothing.
    private var snapshotTotal: UInt64 = 0
    private static let live = NSHashTable<DirectTerminal>.weakObjects()
    private static var snapshotTimer: Timer?
    /// The pid of a helper that didn't hand the terminal over (main thread).
    private static var helperWithoutHandoff: Int?
    /// How often open tabs send their history to the helper, so a crash loses at most this much.
    static var snapshotInterval: TimeInterval = 5

    private init(socket: Int32, fd: Int32, pid: pid_t, replay: [UInt8], decoder: SessionProtocol.Decoder, early: [(SessionProtocol.Kind, Data)]) {
        self.socket = socket; self.fd = fd; self.shellPID = pid; self.replay = replay
        self.decoder = decoder; self.early = early
    }

    /// How long the tab has had the shell, for Ghostty's "exited too quickly" check.
    var runtimeMS: UInt64 { UInt64(max(0, Date().timeIntervalSince(opened) * 1000)) }

    /// A program other than the shell is in front (a build, ssh, vim…).
    var busy: Bool {
        let fg = tcgetpgrp(fd)
        return fg > 0 && shellPID > 0 && fg != shellPID
    }

    /// Asks the helper for shell `id` (starting the shell, or the helper, if needed) and waits
    /// for its terminal. Nil when that doesn't happen within `timeout` (an older helper still
    /// running from before an update, say): the tab then starts through `attach` as before.
    static func open(id: String, cwd: String?, command: String?, env: [String: String], timeout: TimeInterval = 1) -> DirectTerminal? {
        // A helper that didn't hand over before (one from an older Anser, still running after an
        // update) won't now either: skip the wait while it's the one running.
        if let pid = helperWithoutHandoff {
            if SessionHost.shared.request([:], timeout: 0.5)?["pid"] as? Int == pid { return nil }
            helperWithoutHandoff = nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        guard let sock = SessionHost.shared.openConnection(startingBy: deadline) else { return nil }
        var handed: Int32?
        var done = false
        defer {
            if !done {
                Darwin.close(sock)
                if let handed { Darwin.close(handed) }
            }
        }
        let dir = cwd ?? NSHomeDirectory()
        let hello: [String: Any] = ["v": SessionProtocol.version, "mode": "attach", "id": id, "create": true,
                                    "cols": 80, "rows": 24, "cwd": dir, "env": environment(env, cwd: dir),
                                    "command": command ?? "", "direct": true]
        guard writeAll(sock, SessionProtocol.frame(.hello, json: hello)) else { return nil }

        var decoder = SessionProtocol.Decoder()
        var replay: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 65536)
        func timedOut() -> DirectTerminal? {
            helperWithoutHandoff = SessionHost.shared.request([:], timeout: 0.5)?["pid"] as? Int
            return nil
        }
        while true {
            let left = Int32(deadline.timeIntervalSinceNow * 1000)
            guard left > 0 else { return timedOut() }
            var p = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, left)
            if r < 0 && errno == EINTR { continue }
            guard r > 0 else { return timedOut() }
            var got: Int32?
            let n = buf.withUnsafeMutableBytes { DescriptorPassing.receive(sock, $0.baseAddress!, $0.count, &got) }
            if let got { if handed == nil { handed = got } else { Darwin.close(got) } }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            let frames = decoder.append(Data(buf[0..<n]))
            for (i, (kind, payload)) in frames.enumerated() {
                switch kind {
                case .output:
                    replay.append(contentsOf: payload)
                case .handoff:
                    guard let fd = handed else { return nil }
                    let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
                    let pid = pid_t(json?["pid"] as? Int ?? 0)
                    done = true
                    return DirectTerminal(socket: sock, fd: fd, pid: pid, replay: replay, decoder: decoder,
                                          early: Array(frames[(i + 1)...]))
                default:
                    // An error ("this shell has ended") or an exit before the handoff: let
                    // the `attach` path show it as it always has.
                    return nil
                }
            }
        }
    }

    /// Starts listening to the helper. `onExit` gets the shell's exit status, `onElsewhere`
    /// the helper's message when the shell opened in another window. Both run on the main thread.
    func watch(onExit: @escaping (Int32) -> Void, onElsewhere: @escaping (String) -> Void) {
        guard source == nil, !closed else { return }
        let deliver: ([(SessionProtocol.Kind, Data)]) -> Void = { [weak self] frames in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                for (kind, payload) in frames {
                    switch kind {
                    case .exit: onExit(SessionProtocol.parseExit(payload)); return
                    case .error: onElsewhere(String(decoding: payload, as: UTF8.self)); return
                    default: break
                    }
                }
            }
        }
        if !early.isEmpty { deliver(early); early = [] }
        let s = DispatchSource.makeReadSource(fileDescriptor: socket, queue: Self.queue)
        var buf = [UInt8](repeating: 0, count: 65536)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let n = read(self.socket, &buf, buf.count)
            if n < 0 && (errno == EINTR || errno == EAGAIN) { return }
            guard n > 0 else {
                // The helper went away (it crashed or was killed). The shell keeps running on the
                // terminal Ghostty holds; notice its exit directly instead.
                self.source?.cancel()
                DispatchQueue.main.async { self.watchProcess(onExit) }
                return
            }
            let frames = self.decoder.append(Data(buf[0..<n]))
            if !frames.isEmpty { deliver(frames) }
        }
        let sock = socket
        s.setCancelHandler { [weak self] in self?.socketOpen = false; Darwin.close(sock) }
        source = s
        s.resume()
        Self.live.add(self)
        Self.startSnapshots()
    }

    // MARK: Snapshots

    private static func startSnapshots() {
        guard snapshotTimer == nil else { return }
        let t = Timer(timeInterval: snapshotInterval, repeats: true) { _ in snapshotAll() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        snapshotTimer = t
    }

    /// Sends each open tab's recent output to the helper, if it changed since the last time.
    /// The copy is taken here (the surface lives on the main thread); sending happens on `queue`.
    static func snapshotAll() {
        for d in live.allObjects where !d.closed { d.snapshot() }
    }

    func snapshot() {
        guard !closed, let s = surface?() else { return }
        let total = ghostty_surface_recent_output_total(s)
        guard total != snapshotTotal else { return }
        snapshotTotal = total
        var buf = [UInt8](repeating: 0, count: 2 << 20)
        let n = ghostty_surface_recent_output(s, &buf, buf.count)
        guard n > 0 else { return }
        let frame = SessionProtocol.frame(.replay, Data(buf[0..<n]))
        Self.queue.async { [weak self] in
            guard let self, self.socketOpen else { return }
            _ = Self.writeAll(self.socket, frame)
        }
    }

    private func watchProcess(_ onExit: @escaping (Int32) -> Void) {
        guard !closed, exitWatch == nil, shellPID > 0 else { return }
        let w = DispatchSource.makeProcessSource(identifier: shellPID, eventMask: .exit, queue: .main)
        w.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            self.exitWatch?.cancel()
            onExit(0)
        }
        exitWatch = w
        w.resume()
        // Already gone before the watch started.
        if kill(shellPID, 0) != 0 && errno == ESRCH { w.cancel(); onExit(0) }
    }

    /// Lets go of the shell. `history`: what the tab showed, for the helper to replay next time
    /// (when the shell is kept); without it the helper keeps what it had before the handoff.
    func close(handingBack history: [UInt8]? = nil) {
        guard !closed else { return }
        closed = true
        Self.live.remove(self)
        if let history, !history.isEmpty {
            let frame = SessionProtocol.frame(.replay, Data(history))
            Self.queue.sync { if socketOpen { _ = Self.writeAll(socket, frame) } }
        }
        exitWatch?.cancel()
        if let source { source.cancel() } else { Darwin.close(socket) }
        Darwin.close(fd)
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                off += n
            }
            return true
        }
    }

    // MARK: Environment

    /// The environment Ghostty gives a shell it starts (its own variables added to Anser's),
    /// since the helper starts this one instead. `overrides` are the tab's own variables.
    static func environment(_ overrides: [String: String], cwd: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if env["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil {
            for k in ["__XCODE_BUILT_PRODUCTS_DIR_PATHS", "__XPC_DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_INSERT_LIBRARIES",
                      "DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "SECURITYSESSIONID", "XPC_SERVICE_NAME"] { env[k] = nil }
        }
        env["GHOSTTY_MAC_LAUNCH_SOURCE"] = nil
        if getppid() == 1 { env["LANGUAGE"] = nil }
        func append(_ list: String?, _ item: String) -> String {
            guard let list, !list.isEmpty else { return item }
            return list + ":" + item
        }
        if let res = GhosttyRuntime.shared.resourcesDir {
            env["GHOSTTY_RESOURCES_DIR"] = res
            env["TERM"] = configuredTerm ?? "xterm-ghostty"
            env["COLORTERM"] = "truecolor"
            env["TERMINFO"] = (res as NSString).deletingLastPathComponent + "/terminfo"
            env["XDG_DATA_DIRS"] = append(env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share", res + "/..")
            env["MANPATH"] = (env["MANPATH"] ?? "") + ":" + res + "/../man"
        } else {
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
        }
        if let exe = Bundle.main.executablePath {
            let dir = (exe as NSString).deletingLastPathComponent
            env["GHOSTTY_BIN_DIR"] = dir
            if !(env["PATH"] ?? "").split(separator: ":").contains(Substring(dir)) { env["PATH"] = append(env["PATH"], dir) }
        }
        env["TERM_PROGRAM"] = "ghostty"
        let info = ghostty_info()
        env["TERM_PROGRAM_VERSION"] = String(decoding: UnsafeRawBufferPointer(start: info.version, count: Int(info.version_len)), as: UTF8.self)
        env["VTE_VERSION"] = nil
        for (k, v) in overrides { env[k] = v }
        env["PWD"] = cwd
        return env
    }

    /// `term` from the Ghostty config, when set.
    private static var configuredTerm: String? {
        guard let cfg = GhosttyRuntime.shared.config else { return nil }
        var p: UnsafePointer<CChar>?
        guard ghostty_config_get(cfg, &p, "term", 4), let p else { return nil }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }
}

extension SessionHost {
    /// A connection to the helper, starting it if it isn't running. Nil past `deadline`.
    func openConnection(startingBy deadline: Date) -> Int32? {
        if let fd = connectOnce() { return fd }
        guard let helper = helperPath else { return nil }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        let args = ["anser-session", "daemon"]
        var envs = ["ANSER_SESSION_SOCKET=\(socketPath)", "HOME=\(NSHomeDirectory())", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        // The fallback test's stand-in for an older helper.
        if Services.isSelfTest, let v = ProcessInfo.processInfo.environment["ANSER_SESSION_IGNORE_DIRECT"] { envs.append("ANSER_SESSION_IGNORE_DIRECT=\(v)") }
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = envs.map { strdup($0) } + [nil]
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, helper, &actions, &attr, &argv, &envp)
        argv.forEach { free($0) }; envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        guard rc == 0 else { return nil }
        // It runs in its own session, but it's still Anser's child: reap it when it ends
        // (at once, when another helper already holds the lock).
        let reaper = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        reaper.setEventHandler { var st: Int32 = 0; waitpid(pid, &st, WNOHANG); reaper.cancel() }
        reaper.resume()
        while Date() < deadline {
            if let fd = connectOnce() { return fd }
            usleep(20_000)
        }
        return nil
    }

    private func connectOnce() -> Int32? {
        guard var addr = Self.address(socketPath) else { return nil }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Darwin.close(fd); return nil }
        return fd
    }
}
