import Foundation
import Security
import AnserCore

protocol ShellSessionDelegate: AnyObject {
    func sessionDidShowPrompt(_ session: ShellSession)
    func sessionDidStartCommand(_ session: ShellSession, command: String)
    func sessionDidUpdateInfo(_ session: ShellSession)
    /// Whether you can see this shell right now (app in front, its tab showing).
    var sessionIsVisible: Bool { get }
}

/// One shell's side channel. The shell hooks write events into a private
/// FIFO; this reads them and tracks prompt/command state and history.
final class ShellSession {
    struct Block {
        let id = UUID()
        var command: String
        var cwd: String
        var started: Date
        var duration: Double?
        var exitCode: Int?
        var historyID: Int64
        /// The command's output, saved when it finished (nil = not captured).
        var output: String?
    }

    /// Deep Clean: forget this tab's finished commands and their output. Returns their history ids.
    @discardableResult
    func forgetBlocks() -> [Int64] {
        let ids = blocks.map(\.historyID)
        blocks = []
        lastExit = nil
        return ids
    }

    /// How much output this tab keeps in memory (MemoryManager tightens it when macOS is short).
    var outputBudget: OutputBudget = .standard

    func setOutput(_ text: String, forBlockAt i: Int) {
        guard blocks.indices.contains(i) else { return }
        blocks[i].output = text.utf8.count > outputBudget.newest ? OutputBudget.tail(text, bytes: outputBudget.newest) : text
        applyOutputBudget()
    }

    /// Shrinks older outputs to their last part, and drops them past the tab's total.
    func applyOutputBudget(_ budget: OutputBudget? = nil) {
        let plan = (budget ?? outputBudget).plan(blocks.map { $0.output?.utf8.count })
        for i in blocks.indices {
            guard let out = blocks[i].output else { continue }
            if let keep = plan[i] {
                if out.utf8.count > keep { blocks[i].output = OutputBudget.tail(out, bytes: keep) }
            } else {
                blocks[i].output = nil
            }
        }
    }

    /// Bytes of output this tab holds (for problem reports and tests).
    var outputBytes: Int { blocks.reduce(0) { $0 + ($1.output?.utf8.count ?? 0) } }

    let id: String
    /// Held by anser-session, so it survives Anser quitting (see SessionHost).
    let persistent: Bool
    /// Secret that events from Anser's ssh hooks must carry. They arrive as
    /// terminal titles, which any output can print, so without it a file you
    /// `cat` could fake commands into history or switch the pane to "remote".
    private(set) var remoteToken: String = ShellSession.makeToken()

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private(set) var rejectedRemoteEvents = 0
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
    /// This repo's config could make git run programs, so Anser's own
    /// automatic git checks are switched off here.
    private(set) var gitRisky = false

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
    /// AWS_PROFILE, KUBECONFIG… from the shell, for the cloud context chip.
    private(set) var cloudVars = CloudContext.Vars()
    /// The command that finished most recently (even when it's kept out of order, like an ssh session's).
    private(set) var lastFinished: Block?
    /// Commands Anser rewrote before running (secrets filled in): what ran → what to keep in history.
    var historyAliases: [String: String] = [:]
    /// What this shell's hooks support ("load": Anser can load a project environment silently).
    private(set) var capabilities: Set<String> = []
    /// The ssh command this shell is connected through, while in an ssh session.
    var remoteCommand: String? { remoteHost != nil ? outerBlock?.command : nil }

    /// Where Anser leaves files for the shell to load (ESC [9990~). Private to you.
    static var loadDirectory: String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("anser-load")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// `persistentID`: a shell kept by anser-session (the same id comes back
    /// after a restart). `restored`: what this shell looked like when Anser
    /// quit, when re-attaching to a shell that is still running.
    init(cwd: String?, persistentID: String? = nil, restored: SavedState? = nil) {
        id = persistentID ?? UUID().uuidString
        persistent = persistentID != nil
        self.cwd = restored?.cwd ?? cwd ?? NSHomeDirectory()
        if persistent {
            // A fixed place, so a restarted Anser finds the same channel the shell still writes to.
            fifoPath = SessionHost.shared.fifoPath(id)
            var st = stat()
            let isFIFO = stat(fifoPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFIFO
            if !isFIFO { unlink(fifoPath); mkfifo(fifoPath, 0o600) }
        } else {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("anser")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            fifoPath = (dir as NSString).appendingPathComponent("s-\(id.prefix(8))")
            unlink(fifoPath)
            mkfifo(fifoPath, 0o600)
        }
        // O_RDWR keeps the FIFO open (no EOF) even when no shell is writing.
        fd = open(fifoPath, O_RDWR)
        if let r = restored { apply(r) }
        if fd >= 0 { startReader() }
        refreshGit()
    }

    /// `keepShell`: Anser is quitting and the shell lives on in anser-session;
    /// leave its channel in place for the next launch.
    func close(keepShell: Bool = false) {
        guard fd >= 0, !stopFlag.isSet else { return }
        stopFlag.set()
        // Wake the reader thread; it closes the descriptor on its way out.
        var nl: UInt8 = 0x0A
        _ = write(fd, &nl, 1)
        fd = -1
        if !(keepShell && persistent) { unlink(fifoPath) }
    }

    // MARK: Saved state (kept shells)

    struct SavedBlock: Codable {
        var command: String, cwd: String, started: Date, duration: Double?, exitCode: Int?, historyID: Int64
    }

    struct SavedState: Codable {
        var cwd: String
        var integrated: Bool
        var atPrompt: Bool
        var running: SavedBlock?
        var blocks: [SavedBlock]
        var lastExit: Int?
        var shellPID: Int32
        var shell: String
        var path: [String]
        var aliases: [String: String]
        var functions: [String]
        var historyPaused: Bool
        var remoteToken: String
        var capabilities: [String]?
    }

    func savedState() -> SavedState {
        func saved(_ b: Block) -> SavedBlock {
            SavedBlock(command: b.command, cwd: b.cwd, started: b.started, duration: b.duration, exitCode: b.exitCode, historyID: b.historyID)
        }
        return SavedState(cwd: cwd, integrated: integrated, atPrompt: atPrompt, running: running.map(saved),
                          blocks: blocks.suffix(200).map(saved), lastExit: lastExit, shellPID: shellPID, shell: env.shell,
                          path: env.path, aliases: env.aliases, functions: Array(env.functions), historyPaused: historyPaused,
                          remoteToken: remoteToken, capabilities: Array(capabilities))
    }

    private func apply(_ r: SavedState) {
        func block(_ b: SavedBlock) -> Block {
            Block(command: b.command, cwd: b.cwd, started: b.started, duration: b.duration, exitCode: b.exitCode, historyID: b.historyID, output: nil)
        }
        integrated = r.integrated
        atPrompt = r.atPrompt
        running = r.running.map(block)
        blocks = r.blocks.map(block)
        lastExit = r.lastExit
        shellPID = r.shellPID
        env.shell = r.shell
        env.path = r.path
        env.aliases = r.aliases
        env.functions = Set(r.functions)
        historyPaused = r.historyPaused
        remoteToken = r.remoteToken
        capabilities = Set(r.capabilities ?? [])
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
        // The self-test's shells keep their own history file, never the user's.
        if Services.isSelfTest {
            env["ANSER_PRIVATE_HISTFILE"] = NSTemporaryDirectory() + "anser-selftest-shell-history"
            env["HISTFILE"] = env["ANSER_PRIVATE_HISTFILE"]
        }
        // Gives the shell an `imgcat` (when it has none) that shows pictures.
        if let helper = SessionHost.shared.helperPath { env["ANSER_HELPER"] = helper }
        if !Services.shared.config.showLoginMessage { env["ANSER_HIDE_LOGIN"] = "1" }
        env["ANSER_SEPARATOR"] = Services.shared.config.commandSeparator
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
        // A matching folder profile can add environment (e.g. AWS_PROFILE) to new tabs.
        if let extra = Profile.resolve(Services.shared.config.profiles, host: nil, cwd: cwd)?.env {
            for (k, v) in extra where !k.hasPrefix("ANSER_") && !["ZDOTDIR", "TERM_PROGRAM"].contains(k) { env[k] = v }
        }
        env["ANSER_LOAD_DIR"] = Self.loadDirectory
        // Aliases from Tools → Aliases…, loaded by the hooks.
        env["ANSER_ALIASES"] = (Self.userShell.hasSuffix("fish") ? AliasStore.fishFile : AliasStore.posixFile).path
        if let boot = RemoteBootstrap.path {
            env["ANSER_SSH_BOOTSTRAP"] = boot
            env["ANSER_REMOTE_TOKEN"] = remoteToken
        }
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
                lastFinished = b
                if let at = insertFinishedAt, at <= blocks.count { blocks.insert(b, at: at) } else { blocks.append(b) }
                if blocks.count > 500 { blocks.removeFirst(blocks.count - 500) }
                running = nil
                let threshold = Services.shared.config.notifyAfterSeconds
                if threshold > 0, let d = b.duration, d >= threshold, !(delegate?.sessionIsVisible ?? false) {
                    Services.shared.notifyCommandFinished(b.command, exitCode: exitCode, duration: d, sessionID: id)
                }
            }
            insertFinishedAt = nil
            atPrompt = true
            refreshGit()
            delegate?.sessionDidShowPrompt(self)

        case let .preexec(ran, newCwd):
            // History keeps `{{secret:name}}`, not the code that fetched it.
            let command = historyAliases.removeValue(forKey: ran) ?? historyAliases.removeValue(forKey: ran.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ran
            if !newCwd.isEmpty { cwd = newCwd }
            atPrompt = false
            let skip = historyPaused || Services.shared.config.shouldIgnoreInHistory(command)
            let id = skip ? -1 : Services.shared.history.recordStart(command: command, cwd: cwd, session: id, branch: gitBranch)
            running = Block(command: command, cwd: cwd, started: Date(), historyID: id)
            delegate?.sessionDidStartCommand(self, command: command)

        case .buffer:
            break

        case let .capabilities(caps):
            capabilities = Set(caps)

        case let .context(vars):
            guard vars != cloudVars else { break }
            cloudVars = vars
            delegate?.sessionDidUpdateInfo(self)
        }
    }

    // MARK: Remote (ssh) events, delivered in-band through the terminal

    /// Fields from an in-band event: ["hello", shell, host] / ["prompt", exit, host, cwd] / ["preexec", command, cwd].
    /// Fields after the token; events with a missing or wrong token are dropped.
    func handleRemote(token: String, _ f: [String]) {
        guard token.utf8.count == remoteToken.utf8.count,
              zip(token.utf8, remoteToken.utf8).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            rejectedRemoteEvents += 1
            if rejectedRemoteEvents <= 3 { Diagnostics.shared.log("ignored a fake ssh event printed by a program") }
            return
        }
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
                lastFinished = b
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
        guard head != nil else { gitDirty = false; gitChangeCount = 0; gitRisky = false; delegate?.sessionDidUpdateInfo(self); return }
        gitRisky = GitSafety.isRisky(cwd: dir)
        if gitRisky {
            gitDirty = false; gitChangeCount = 0
            Diagnostics.shared.log("git checks off: repo config can run programs")
            delegate?.sessionDidUpdateInfo(self)
            return
        }
        countGitChanges()
        delegate?.sessionDidUpdateInfo(self)
    }

    /// One `git status` per session at a time. Requests that arrive while one is
    /// running are merged into a single follow-up run for the latest folder.
    private var gitCountRunning = false
    private var gitCountAgain = false

    private func countGitChanges() {
        if gitCountRunning { gitCountAgain = true; return }
        gitCountRunning = true
        let dir = cwd, env = self.env
        Task { @MainActor [weak self] in
            let out = await ScriptRunner.shared.run("git status --porcelain 2>/dev/null | head -5000 | wc -l", cwd: dir, env: env, timeout: 2)
            guard let self else { return }
            self.gitCountRunning = false
            if self.gitCountAgain {
                self.gitCountAgain = false
                if self.gitBranch != nil, !self.gitRisky { self.countGitChanges() }
                if self.cwd != dir { return }
            }
            guard self.cwd == dir else { return }
            self.gitChangeCount = Int((out ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            self.gitDirty = self.gitChangeCount > 0
            self.delegate?.sessionDidUpdateInfo(self)
        }
    }
}
