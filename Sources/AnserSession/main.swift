import Foundation
import Darwin
import AnserCore
import AnserPTY
import MachO

// anser-session: keeps Anser's shells running while Anser quits, restarts or
// updates.
//
//   anser-session attach   run by each terminal pane; connects the pane to its
//                          shell, starting the shell (and the helper) if needed
//   anser-session daemon   the helper itself; started on demand, exits when it
//                          has no shells left
//
// Only your user can reach the helper: its socket is in a folder only you can
// read, and connections from other users are refused.

signal(SIGPIPE, SIG_IGN)

let environment = ProcessInfo.processInfo.environment
let socketPath = environment["ANSER_SESSION_SOCKET"]
    ?? SessionProtocol.defaultDirectory.appendingPathComponent("d.sock").path

// MARK: - Small POSIX helpers

func setNonBlocking(_ fd: Int32) { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
func setCloseOnExec(_ fd: Int32) { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

func unixAddress(_ path: String) -> sockaddr_un? {
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

func connectSocket(_ path: String) -> Int32? {
    guard var addr = unixAddress(path) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    setCloseOnExec(fd)
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if ok != 0 { close(fd); return nil }
    return fd
}

@discardableResult
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        while offset < data.count {
            let n = write(fd, base + offset, data.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 1000)
                    continue
                }
                return false
            }
            offset += n
        }
        return true
    }
}

func cStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
    strings.map { strdup($0) } + [nil]
}

// MARK: - Helper (daemon)

final class Daemon {
    final class Session {
        let id: String
        let master: Int32
        let pid: pid_t
        var replay = ReplayBuffer()
        var client: Int32?
        var toShell = Data()
        var killRequested: Date?
        var masterOpen = true
        init(id: String, master: Int32, pid: pid_t) { self.id = id; self.master = master; self.pid = pid }
    }

    struct Client {
        var decoder = SessionProtocol.Decoder()
        var out = Data()
        /// Bytes of `out` already written (compacted now and then, not on every write).
        var sent = 0
        var pending: Int { out.count - sent }
        var session: String?
        var closeAfterFlush = false
    }

    let path: String
    var listenFD: Int32 = -1
    var clients: [Int32: Client] = [:]
    var sessions: [String: Session] = [:]
    var idleSince = Date()

    init(path: String) { self.path = path }

    func run() -> Never {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        // One helper at a time.
        let lock = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
        setCloseOnExec(lock)
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0, var addr = unixAddress(path) else { exit(1) }
        setCloseOnExec(listenFD)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { exit(1) }
        chmod(path, 0o600)
        listen(listenFD, 32)
        setNonBlocking(listenFD)
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        while true {
            loopOnce()
            if sessions.isEmpty && clients.isEmpty {
                if Date().timeIntervalSince(idleSince) > 30 { unlink(path); exit(0) }
            } else {
                idleSince = Date()
            }
        }
    }

    private func loopOnce() {
        var fds: [pollfd] = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)]
        for (fd, c) in clients { fds.append(pollfd(fd: fd, events: Int16(POLLIN) | (c.pending == 0 ? 0 : Int16(POLLOUT)), revents: 0)) }
        for s in sessions.values where s.masterOpen {
            // Backpressure, like a real terminal: while the pane is behind on
            // drawing, stop reading, so the program waits instead of output piling up.
            let behind = s.client.map { (clients[$0]?.pending ?? 0) > Self.maxBehind } ?? false
            let events = (behind ? 0 : Int16(POLLIN)) | (s.toShell.isEmpty ? 0 : Int16(POLLOUT))
            if events != 0 { fds.append(pollfd(fd: s.master, events: events, revents: 0)) }
        }
        let n = poll(&fds, nfds_t(fds.count), 500)
        if n > 0 {
            for p in fds where p.revents != 0 {
                if p.fd == listenFD { acceptClients(); continue }
                if clients[p.fd] != nil { serviceClient(p.fd, p.revents); continue }
                if let s = sessions.values.first(where: { $0.master == p.fd }) { serviceShell(s, p.revents) }
            }
        }
        reap()
    }

    private func acceptClients() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            setNonBlocking(fd)
            setCloseOnExec(fd)
            clients[fd] = Client()
        }
    }

    static let maxBehind = 1 << 20

    private func send(_ fd: Int32, _ frame: Data) {
        guard clients[fd] != nil else { return }
        clients[fd]!.out.append(frame)
    }

    private func drop(_ fd: Int32) {
        if let id = clients[fd]?.session, sessions[id]?.client == fd { sessions[id]?.client = nil }
        clients[fd] = nil
        close(fd)
    }

    private func serviceClient(_ fd: Int32, _ ev: Int16) {
        if ev & Int16(POLLOUT) != 0, var c = clients[fd], c.pending > 0 {
            let start = c.sent
            let n = c.out.withUnsafeBytes { write(fd, $0.baseAddress! + start, c.out.count - start) }
            if n > 0 {
                c.sent += n
                if c.sent == c.out.count { c.out.removeAll(keepingCapacity: true); c.sent = 0 }
                else if c.sent > 256 << 10 { c.out.removeFirst(c.sent); c.sent = 0 }
            } else if n < 0, errno != EAGAIN, errno != EINTR { drop(fd); return }
            clients[fd] = c
            if c.pending == 0 && c.closeAfterFlush { drop(fd); return }
        }
        if ev & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &buf, buf.count)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { drop(fd); return }
            guard n > 0, var c = clients[fd] else { return }
            let frames = c.decoder.append(Data(buf[0..<n]))
            let broken = c.decoder.broken
            clients[fd] = c
            for (kind, payload) in frames { handle(fd, kind, payload) }
            if broken { drop(fd) }
        }
    }

    private func handle(_ fd: Int32, _ kind: SessionProtocol.Kind, _ payload: Data) {
        switch kind {
        case .hello:
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { fail(fd, "bad request"); return }
            if (json["mode"] as? String) == "control" { control(fd, json) } else { attach(fd, json) }
        case .input:
            if let id = clients[fd]?.session, let s = sessions[id] { s.toShell.append(payload) }
        case .resize:
            if let id = clients[fd]?.session, let s = sessions[id], let size = SessionProtocol.parseResize(payload) {
                var ws = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.cols), ws_xpixel: 0, ws_ypixel: 0)
                _ = ioctl(s.master, TIOCSWINSZ, &ws)
            }
        default:
            break
        }
    }

    private func fail(_ fd: Int32, _ message: String) {
        send(fd, SessionProtocol.frame(.error, Data(message.utf8)))
        clients[fd]?.closeAfterFlush = true
    }

    private func attach(_ fd: Int32, _ json: [String: Any]) {
        guard (json["v"] as? Int) == SessionProtocol.version else { fail(fd, "Anser and its session helper are different versions"); return }
        guard let id = json["id"] as? String, SessionProtocol.isValidID(id) else { fail(fd, "bad session id"); return }
        let cols = json["cols"] as? Int ?? 80, rows = json["rows"] as? Int ?? 24
        let session: Session
        if let existing = sessions[id], existing.masterOpen {
            session = existing
            if let other = session.client, other != fd {
                send(other, SessionProtocol.frame(.error, Data("This shell is now open in another Anser window.".utf8)))
                clients[other]?.session = nil
                clients[other]?.closeAfterFlush = true
            }
        } else {
            guard (json["create"] as? Bool) == true, let s = spawn(id: id, json: json, cols: cols, rows: rows) else {
                fail(fd, "This shell has ended.")
                return
            }
            session = s
            sessions[id] = s
        }
        session.client = fd
        clients[fd]?.session = id
        // Bring the terminal back to how it looked: the recent output, then a
        // size change so full-screen programs (vim, htop…) redraw themselves.
        if !session.replay.data.isEmpty { send(fd, SessionProtocol.frame(.output, session.replay.data)) }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        if session.replay.alternateScreen, rows > 2 {
            var smaller = ws
            smaller.ws_row -= 1
            _ = ioctl(session.master, TIOCSWINSZ, &smaller)
        }
        _ = ioctl(session.master, TIOCSWINSZ, &ws)
    }

    private func spawn(id: String, json: [String: Any], cols: Int, rows: Int) -> Session? {
        let env = (json["env"] as? [String: String]) ?? [:]
        let command = (json["command"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let cwd = json["cwd"] as? String
        var path: String
        var argv: [String]
        if command.isEmpty {
            // A login shell, like Terminal and Ghostty start.
            path = env["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? Self.userShell
            argv = ["-" + (path as NSString).lastPathComponent]
        } else {
            path = "/bin/sh"
            argv = ["sh", "-c", "exec " + command]
        }
        if !FileManager.default.isExecutableFile(atPath: path) { path = "/bin/zsh"; argv = ["-zsh"] }
        let cArgv = cStringArray(argv)
        let cEnv = cStringArray(env.map { "\($0.key)=\($0.value)" })
        defer { cArgv.forEach { free($0) }; cEnv.forEach { free($0) } }
        var master: Int32 = -1
        let pid = cArgv.withUnsafeBufferPointer { a in
            cEnv.withUnsafeBufferPointer { e in
                anser_spawn_pty(path, a.baseAddress, e.baseAddress, cwd, UInt16(clamping: rows), UInt16(clamping: cols), &master)
            }
        }
        guard pid > 0, master >= 0 else { return nil }
        setNonBlocking(master)
        return Session(id: id, master: master, pid: pid)
    }

    static var userShell: String {
        if let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell { return String(cString: s) }
        return "/bin/zsh"
    }

    private func control(_ fd: Int32, _ json: [String: Any]) {
        var reply: [String: Any] = ["v": SessionProtocol.version]
        switch json["cmd"] as? String {
        case "list":
            reply["ids"] = sessions.values.filter(\.masterOpen).map(\.id)
        case "kill":
            if let id = json["id"] as? String, let s = sessions[id] { end(s) }
            reply["ok"] = true
        case "keep":
            // Ends every shell that isn't listed and isn't open in a window.
            let keep = Set(json["ids"] as? [String] ?? [])
            var ended: [String] = []
            for s in sessions.values where !keep.contains(s.id) && s.client == nil { end(s); ended.append(s.id) }
            reply["ended"] = ended
        case "busy":
            if let id = json["id"] as? String, let s = sessions[id] {
                let fg = tcgetpgrp(s.master)
                reply["busy"] = fg > 0 && fg != s.pid
            } else {
                reply["busy"] = false
            }
        case "clearReplay":
            // After Clear / Deep Clean, a restart shouldn't bring the old output back.
            if let id = json["id"] as? String, let s = sessions[id] { s.replay = ReplayBuffer() }
            reply["ok"] = true
        case "replaySize":
            reply["bytes"] = (json["id"] as? String).flatMap { sessions[$0]?.replay.data.count } ?? 0
        case "endAll":
            sessions.values.forEach(end)
            reply["ok"] = true
        default:
            reply["pid"] = Int(getpid())
        }
        send(fd, SessionProtocol.frame(.reply, json: reply))
    }

    /// Hangs up on a shell, like closing a terminal window; forced after 3 seconds.
    private func end(_ s: Session) {
        guard s.killRequested == nil else { return }
        s.killRequested = Date()
        kill(-s.pid, SIGHUP)
        kill(s.pid, SIGHUP)
    }

    private func serviceShell(_ s: Session, _ ev: Int16) {
        if ev & Int16(POLLOUT) != 0, !s.toShell.isEmpty {
            let n = s.toShell.withUnsafeBytes { write(s.master, $0.baseAddress!, s.toShell.count) }
            if n > 0 { s.toShell.removeFirst(n) }
        }
        if ev & Int16(POLLIN | POLLHUP | POLLERR) != 0 { readShell(s) }
    }

    private func readShell(_ s: Session) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            if let c = s.client, (clients[c]?.pending ?? 0) > Self.maxBehind { return }
            let n = read(s.master, &buf, buf.count)
            if n > 0 {
                let d = Data(buf[0..<n])
                s.replay.append(d)
                if let c = s.client { send(c, SessionProtocol.frame(.output, d)) }
                continue
            }
            if n < 0, errno == EAGAIN || errno == EINTR { return }
            // EOF or EIO: nothing holds the terminal open any more.
            s.masterOpen = false
            return
        }
    }

    private func reap() {
        for s in Array(sessions.values) {
            var status: Int32 = 0
            let r = waitpid(s.pid, &status, WNOHANG)
            if r == 0 {
                if let k = s.killRequested, Date().timeIntervalSince(k) > 3 { kill(-s.pid, SIGKILL); kill(s.pid, SIGKILL) }
                if !s.masterOpen { /* background jobs may still hold it; keep waiting */ }
                continue
            }
            if s.masterOpen { readShell(s) }
            let code: Int32 = r < 0 ? 1 : (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            if let c = s.client {
                send(c, SessionProtocol.frame(.exit, SessionProtocol.exitPayload(code)))
                clients[c]?.closeAfterFlush = true
                clients[c]?.session = nil
            }
            close(s.master)
            sessions[s.id] = nil
        }
    }
}

// MARK: - attach (one per pane)

var winchWrite: Int32 = -1

func startHelper() -> Int32? {
    if let fd = connectSocket(socketPath) { return fd }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
    // This program's own path (argv[0] can be "-…" when started as a login command).
    var size: UInt32 = 4096
    var pathBuf = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&pathBuf, &size) == 0 else { return nil }
    let exe = String(cString: pathBuf)
    let argv = cStringArray(["anser-session", "daemon"])
    let env = cStringArray(["ANSER_SESSION_SOCKET=\(socketPath)", "HOME=\(NSHomeDirectory())", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
    var pid: pid_t = 0
    let rc = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in posix_spawn(&pid, exe, &actions, &attr, a.baseAddress, e.baseAddress) } }
    argv.forEach { free($0) }; env.forEach { free($0) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    guard rc == 0 else { return nil }
    for _ in 0..<60 {
        if let fd = connectSocket(socketPath) { return fd }
        usleep(50_000)
    }
    return nil
}

/// Without the helper the pane still gets a shell: run it directly.
func runShellDirectly(_ command: String, _ env: [String: String]) -> Never {
    var envp = cStringArray(env.map { "\($0.key)=\($0.value)" })
    let shell = env["SHELL"] ?? Daemon.userShell
    let argv = command.isEmpty ? cStringArray(["-" + (shell as NSString).lastPathComponent]) : cStringArray(["sh", "-c", "exec " + command])
    let path = command.isEmpty ? shell : "/bin/sh"
    argv.withUnsafeBufferPointer { a in envp.withUnsafeMutableBufferPointer { e in _ = execve(path, a.baseAddress, e.baseAddress) } }
    exit(127)
}

func attachMain() -> Never {
    var env = environment
    let id = env.removeValue(forKey: "ANSER_SESSION_ID") ?? ""
    let command = env.removeValue(forKey: "ANSER_SESSION_COMMAND") ?? ""
    env.removeValue(forKey: "ANSER_SESSION_SOCKET")
    guard SessionProtocol.isValidID(id), let sock = startHelper() else { runShellDirectly(command, env) }

    var ws = winsize()
    _ = ioctl(0, TIOCGWINSZ, &ws)
    var original = termios()
    let isTTY = tcgetattr(0, &original) == 0
    if isTTY {
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
    }
    func finish(_ code: Int32, _ message: String? = nil) -> Never {
        if isTTY { var o = original; tcsetattr(0, TCSANOW, &o) }
        if let message { FileHandle.standardOutput.write(Data("\r\n[\(message)]\r\n".utf8)) }
        exit(code)
    }

    let hello: [String: Any] = ["v": SessionProtocol.version, "mode": "attach", "id": id, "create": true,
                                "cols": Int(ws.ws_col), "rows": Int(ws.ws_row),
                                "cwd": FileManager.default.currentDirectoryPath, "env": env, "command": command]
    guard writeAll(sock, SessionProtocol.frame(.hello, json: hello)) else { finish(1, "Anser couldn't reach its session helper") }

    var pipeFDs: [Int32] = [-1, -1]
    pipe(&pipeFDs)
    winchWrite = pipeFDs[1]
    signal(SIGWINCH) { _ in var b: UInt8 = 1; _ = write(winchWrite, &b, 1) }

    var decoder = SessionProtocol.Decoder()
    // iTerm2-style pictures become kitty ones, which the terminal shows.
    var images = InlineImageFilter()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        var fds = [pollfd(fd: 0, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: sock, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: pipeFDs[0], events: Int16(POLLIN), revents: 0)]
        if poll(&fds, 3, -1) < 0 { if errno == EINTR { continue }; finish(1) }
        if fds[2].revents != 0 {
            _ = read(pipeFDs[0], &buf, buf.count)
            _ = ioctl(0, TIOCGWINSZ, &ws)
            writeAll(sock, SessionProtocol.frame(.resize, SessionProtocol.resizePayload(cols: Int(ws.ws_col), rows: Int(ws.ws_row))))
        }
        if fds[0].revents != 0 {
            let n = read(0, &buf, buf.count)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; finish(0) }   // the window went away: detach
            writeAll(sock, SessionProtocol.frame(.input, Data(buf[0..<n])))
        }
        if fds[1].revents != 0 {
            let n = read(sock, &buf, buf.count)
            if n <= 0 { if n < 0 && errno == EINTR { continue }; finish(1, "Anser's session helper stopped; this shell has ended") }
            for (kind, payload) in decoder.append(Data(buf[0..<n])) {
                switch kind {
                case .output: writeAll(1, images.feed(payload))
                case .exit: finish(SessionProtocol.parseExit(payload))
                case .error: finish(1, String(decoding: payload, as: UTF8.self))
                default: break
                }
            }
        }
    }
}

/// `anser-session imgcat FILE…`: shows pictures in the terminal (kitty graphics).
func imgcatMain(_ files: [String]) -> Never {
    var failed = false
    for f in files {
        guard let data = FileManager.default.contents(atPath: f), let png = InlineImageFilter.pngData(data) else {
            FileHandle.standardError.write(Data("imgcat: can't show \(f) (not an image?)\n".utf8))
            failed = true
            continue
        }
        FileHandle.standardOutput.write(InlineImageFilter.kittySequence(png: png))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    if files.isEmpty { FileHandle.standardError.write(Data("usage: imgcat FILE…\n".utf8)) }
    exit(failed || files.isEmpty ? 1 : 0)
}

if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "imgcat" { imgcatMain(Array(CommandLine.arguments.dropFirst(2))) }

switch CommandLine.arguments.last {
case "daemon": Daemon(path: socketPath).run()
case "attach": attachMain()
default:
    FileHandle.standardError.write(Data("usage: anser-session attach | daemon\n".utf8))
    exit(2)
}
