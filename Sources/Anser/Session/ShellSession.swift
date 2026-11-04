import Foundation
import AnserCore

protocol ShellSessionDelegate: AnyObject {
    func sessionDidShowPrompt(_ session: ShellSession)
    func sessionDidStartCommand(_ session: ShellSession, command: String)
    func sessionDidUpdateInfo(_ session: ShellSession)
}

/// One shell's side channel. The shell hooks write events into a private
/// FIFO; this reads them and tracks prompt/command state and history.
final class ShellSession {
    struct Block {
        var command: String
        var cwd: String
        var started: Date
        var duration: Double?
        var exitCode: Int?
        var historyID: Int64
        /// The command's output, saved when it finished (nil = not captured).
        var output: String?
    }

    func setOutput(_ text: String, forBlockAt i: Int) {
        guard blocks.indices.contains(i) else { return }
        blocks[i].output = text.count > 1_000_000 ? String(text.suffix(1_000_000)) : text
    }

    let id = UUID().uuidString
    let fifoPath: String
    weak var delegate: ShellSessionDelegate?

    private var fd: Int32 = -1
    private var lines = LineBuffer()
    /// Set when the pane closes; the reader thread exits on its next wake-up.
    private let stopFlag = StopFlag()

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private(set) var env = ShellEnvironment()
    private(set) var cwd: String
    /// True once the shell hooks have checked in.
    private(set) var integrated = false
    private(set) var atPrompt = false
    private(set) var running: Block?
    /// Finished commands in this shell, oldest first.
    private(set) var blocks: [Block] = []
    private(set) var gitBranch: String?
    private(set) var gitDirty = false
    /// Number of changed (including untracked) files in the repo.
    private(set) var gitChangeCount = 0

    // ssh: while a remote shell with Anser's hooks is active, the ssh command
    // itself is kept aside and the remote prompt/commands drive the editor.
    private(set) var remoteHost: String?
    private(set) var remoteCwd: String?
    private var outerBlock: Block?
    private var outerIndex = 0
    /// Where the ssh command's block goes when it finishes (see leaveRemote).
    private var insertFinishedAt: Int?

    /// The latest finished command in the current context (remote commands
    /// only while in an ssh session), for the status row.
    var lastBlockInContext: Block? {
        if isRemote, blocks.count <= outerIndex { return nil }
        return blocks.last
    }
    var isRemote: Bool { remoteHost != nil }
    /// The folder shown in the UI ("host:/path" when remote).
    var displayCwd: String { remoteHost.map { "\($0):\(remoteCwd ?? "~")" } ?? cwd }
    private(set) var lastExit: Int?
    /// The shell's process id, from its first check-in.
    private(set) var shellPID: Int32 = 0
    /// Don't save this tab's commands to history.
    var historyPaused = false

    init(cwd: String?) {
        self.cwd = cwd ?? NSHomeDirectory()
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("anser")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fifoPath = (dir as NSString).appendingPathComponent("s-\(id.prefix(8))")
        unlink(fifoPath)
        if mkfifo(fifoPath, 0o600) == 0 {
            // O_RDWR keeps the FIFO open (no EOF) even when no shell is writing.
            fd = open(fifoPath, O_RDWR)
        }
        if fd >= 0 { startReader() }
        refreshGit()
    }

    func close() {
        guard fd >= 0, !stopFlag.isSet else { return }
        stopFlag.set()
        // Wake the reader thread; it closes the descriptor on its way out.
        var nl: UInt8 = 0x0A
        _ = write(fd, &nl, 1)
        fd = -1
        unlink(fifoPath)
    }

    deinit { close() }

    /// Environment variables for the shell so it loads Anser's hooks.
    func shellEnvironment() -> [String: String] {
        guard let res = Bundle.main.resourceURL?.path else { return [:] }
        let shellDir = res + "/shell"
        var env: [String: String] = [
            "ANSER_FIFO": fifoPath,
            "ANSER_SHELL_DIR": shellDir,
            "TERM_PROGRAM": "Anser",
            "GHOSTTY_SHELL_FEATURES": "cursor,title,sudo",
        ]
        env["ANSER_PROMPT_MODE"] = Services.shared.config.shellPrompt
        if let gh = GhosttyRuntime.shared.resourcesDir {
            env["GHOSTTY_RESOURCES_DIR"] = gh
            env["ANSER_GHOSTTY_INTEGRATION"] = gh + "/shell-integration"
        }
        let shell = Self.userShell
        if shell.hasSuffix("zsh") {
            // Our .zshenv restores the user's ZDOTDIR, then loads the hooks.
            if let z = ProcessInfo.processInfo.environment["ZDOTDIR"] { env["ANSER_ORIG_ZDOTDIR"] = z }
            env["ZDOTDIR"] = shellDir + "/zsh"
        }
        if let boot = RemoteBootstrap.path { env["ANSER_SSH_BOOTSTRAP"] = boot }
        return env
    }

    /// The command to start, or nil to let Ghostty start the login shell.
    var shellCommand: String? {
        let shell = Self.userShell
        if shell.hasSuffix("bash"), let res = Bundle.main.resourceURL?.path {
            return "\(shell) --rcfile '\(res)/shell/anser.bash' -i"
        }
        if shell.hasSuffix("fish"), let res = Bundle.main.resourceURL?.path {
            return "\(shell) -l -C \"source '\(res)/shell/anser.fish'\""
        }
        return nil
    }

    static var userShell: String {
        if let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell { return String(cString: s) }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    // MARK: Reading events

    /// Reads on a background thread with blocking reads. (A kqueue/dispatch
    /// read source on a FIFO stops firing after the first chunk on macOS, which
    /// stalls large messages.)
    private func startReader() {
        let fd = self.fd
        let stop = stopFlag
        let thread = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            while !stop.isSet {
                let n = read(fd, &buf, buf.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 || stop.isSet { break }
                let data = Data(buf[0..<n])
                DispatchQueue.main.async { self?.received(data) }
            }
            Darwin.close(fd)
        }
        thread.name = "Anser shell events"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func received(_ data: Data) {
        for line in lines.append(data) {
            if let ev = ShellEvent.parse(line) { handle(ev) }
        }
    }

    private static let debug = ProcessInfo.processInfo.environment["ANSER_DEBUG"] != nil

    private func handle(_ ev: ShellEvent) {
        if Self.debug { NSLog("Anser event: %@", String(String(describing: ev).prefix(120))) }
        switch ev {
        case let .hello(shell, pid, path):
            integrated = true
            if pid > 0 { shellPID = pid }
            env.shell = shell
            if !path.isEmpty { env.path = path.split(separator: ":").map(String.init) }
            delegate?.sessionDidUpdateInfo(self)

        case let .aliases(file):
            if let text = try? String(contentsOfFile: file, encoding: .utf8) { env.aliases = ShellEnvironment.parseAliases(text) }
            unlink(file)

        case let .functions(names):
            env.functions = Set(names)

        case let .prompt(exitCode, newCwd):
            integrated = true
            leaveRemote()
            if !newCwd.isEmpty, newCwd != cwd { cwd = newCwd }
            lastExit = exitCode
            if var b = running {
                b.exitCode = exitCode
                b.duration = Date().timeIntervalSince(b.started)
                Services.shared.history.recordFinish(id: b.historyID, exitCode: exitCode, duration: b.duration)
                if let at = insertFinishedAt, at <= blocks.count { blocks.insert(b, at: at) } else { blocks.append(b) }
                if blocks.count > 500 { blocks.removeFirst(blocks.count - 500) }
                running = nil
                let threshold = Services.shared.config.notifyAfterSeconds
                if threshold > 0, let d = b.duration, d >= threshold, !AppDelegate.shared.isActive {
                    Services.shared.notifyCommandFinished(b.command, exitCode: exitCode, duration: d)
                }
            }
            insertFinishedAt = nil
            atPrompt = true
            refreshGit()
            delegate?.sessionDidShowPrompt(self)

        case let .preexec(command, newCwd):
            if !newCwd.isEmpty { cwd = newCwd }
            atPrompt = false
            let skip = historyPaused || Services.shared.config.shouldIgnoreInHistory(command)
            let id = skip ? -1 : Services.shared.history.recordStart(command: command, cwd: cwd, session: id, branch: gitBranch)
            running = Block(command: command, cwd: cwd, started: Date(), historyID: id)
            delegate?.sessionDidStartCommand(self, command: command)

        case .buffer:
            break
        }
    }

    // MARK: Remote (ssh) events, delivered in-band through the terminal

    /// Fields from an in-band event: ["hello", shell, host] / ["prompt", exit, host, cwd] / ["preexec", command, cwd].
    func handleRemote(_ f: [String]) {
        guard let kind = f.first else { return }
        func field(_ i: Int) -> String { i < f.count ? f[i] : "" }
        enterRemote(host: kind == "hello" ? field(2) : (kind == "prompt" ? field(2) : remoteHost ?? "remote"))
        switch kind {
        case "hello":
            env.shell = field(1)
            delegate?.sessionDidUpdateInfo(self)
        case "prompt":
            let ec = Int(field(1)) ?? 0
            remoteCwd = field(3)
            lastExit = ec
            if var b = running {
                b.exitCode = ec
                b.duration = Date().timeIntervalSince(b.started)
                Services.shared.history.recordFinish(id: b.historyID, exitCode: ec, duration: b.duration)
                blocks.append(b)
                running = nil
            }
            atPrompt = true
            delegate?.sessionDidShowPrompt(self)
        case "preexec":
            let command = field(1)
            if !field(2).isEmpty { remoteCwd = field(2) }
            atPrompt = false
            let where_ = "ssh://\(remoteHost ?? "?")\(remoteCwd ?? "")"
            let skip = command.isEmpty || historyPaused || Services.shared.config.shouldIgnoreInHistory(command)
            let id = skip ? -1 : Services.shared.history.recordStart(command: command, cwd: where_, session: self.id)
            running = Block(command: command, cwd: displayCwd, started: Date(), historyID: id)
            delegate?.sessionDidStartCommand(self, command: command)
        default:
            break
        }
    }

    private func enterRemote(host: String) {
        guard remoteHost == nil else {
            if !host.isEmpty, host != "remote" { remoteHost = host; env.remoteHost = host }
            return
        }
        remoteHost = host.isEmpty ? "remote" : host
        env.remoteHost = remoteHost
        // The ssh command keeps running underneath; set it aside.
        outerBlock = running
        outerIndex = blocks.count
        running = nil
        Diagnostics.shared.log("remote session started")
    }

    /// The local shell is back (ssh ended): restore the ssh command as the running one.
    private func leaveRemote() {
        guard remoteHost != nil else { return }
        if var r = running {   // a remote command was cut off
            r.duration = Date().timeIntervalSince(r.started)
            blocks.append(r)
        }
        running = outerBlock
        outerBlock = nil
        insertFinishedAt = outerIndex
        remoteHost = nil
        remoteCwd = nil
        env.remoteHost = nil
        Diagnostics.shared.log("remote session ended")
    }

    func setCwd(_ path: String) {
        guard path != cwd else { return }
        cwd = path
        refreshGit()
    }

    // MARK: Git

    /// Reads the branch straight from .git (no process), then checks
    /// dirtiness in the background.
    private func refreshGit() {
        let dir = cwd
        var d = dir
        var head: String?
        var gitDir: String?
        while true {
            let g = (d as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: g, isDirectory: &isDir) {
                if isDir.boolValue {
                    gitDir = g
                } else if let txt = try? String(contentsOfFile: g, encoding: .utf8), txt.hasPrefix("gitdir: ") {
                    // worktrees and submodules
                    var p = txt.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !p.hasPrefix("/") { p = (d as NSString).appendingPathComponent(p) }
                    gitDir = p
                }
                break
            }
            if d == "/" || d.isEmpty { break }
            d = (d as NSString).deletingLastPathComponent
        }
        if let gitDir, let h = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) {
            let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
            head = t.hasPrefix("ref: refs/heads/") ? String(t.dropFirst(16)) : String(t.prefix(7))
        }
        gitBranch = head
        guard head != nil else { gitDirty = false; gitChangeCount = 0; delegate?.sessionDidUpdateInfo(self); return }
        let env = self.env
        Task { @MainActor [weak self] in
            let out = await ScriptRunner.shared.run("git status --porcelain 2>/dev/null | head -5000 | wc -l", cwd: dir, env: env, timeout: 2)
            guard let self, self.cwd == dir else { return }
            self.gitChangeCount = Int((out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            self.gitDirty = self.gitChangeCount > 0
            self.delegate?.sessionDidUpdateInfo(self)
        }
        delegate?.sessionDidUpdateInfo(self)
    }
}
