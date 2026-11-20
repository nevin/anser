import AppKit
import AnserCore

/// What your tabs are running: each tab's processes (with CPU, memory and
/// ports), processes left behind by tabs that closed, and other programs
/// listening on ports. Samples every few seconds while something runs in a
/// tab or the sidebar's Running section is showing, and stops otherwise.
final class ProcessMonitor {
    static let shared = ProcessMonitor()
    /// Processes or ports came or went (rebuild the list).
    static let changed = Notification.Name("AnserProcessesChanged")
    /// New CPU and memory numbers for the same processes (update in place).
    static let sampled = Notification.Name("AnserProcessesSampled")

    struct Item: Equatable {
        var pid: pid_t
        var name: String
        /// 1 = started by the shell; deeper for what that started.
        var depth: Int
        var started: Date
        var ports: [ServerPorts.Listener]
        /// Percent of one core, averaged since the last sample.
        var cpu: Double
        var memory: UInt64
        var runaway: RunawayTracker.Kind?
        /// Not the program in front of the terminal (`cmd &`, nohup, left over).
        var background: Bool
        var commandLine: String?
        var folder: String?
        var isSystem = false
        var app: String?

        /// What decides whether the list must be rebuilt.
        var shape: String { "\(pid):\(ports.map(\.port)):\(runaway?.rawValue ?? ""):\(depth)" }

        var usageText: String {
            let mem = memory > 0 ? ProcessScan.formatMemory(memory) : ""
            let busy = cpu >= 1 ? "\(Int(cpu.rounded()))%" : ""
            return [busy, mem].filter { !$0.isEmpty }.joined(separator: " · ")
        }

        var title: String {
            let p = ports.prefix(2).map { ":\($0.port)" }.joined(separator: " ")
            return p.isEmpty ? name : "\(name)  \(p)"
        }

        var tooltip: String {
            var lines: [String] = []
            if let c = commandLine, !c.isEmpty { lines.append(String(c.prefix(300))) }
            var facts = ["process \(pid)"]
            if started > .distantPast { facts.append("running for " + ProcessMonitor.age(started)) }
            facts.append(usageText)
            lines.append(facts.joined(separator: " · "))
            if let f = folder { lines.append(PathDisplay.short(f)) }
            for p in ports { lines.append(p.url) }
            switch runaway {
            case .cpu?: lines.append("Has kept a whole CPU core busy for over \(Int(ProcessMonitor.shared.cpuSeconds / 60)) minutes")
            case .memory?: lines.append("Is using a lot of memory")
            case nil: break
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Session id → its processes, parents before children.
    private(set) var byTab: [String: [Item]] = [:]
    /// Left behind by tabs that have closed.
    private(set) var leftovers: [Item] = []
    /// Programs listening on a port that no tab started (system ones flagged).
    private(set) var otherPorts: [Item] = []

    func items(for pane: PaneView) -> [Item] { byTab[pane.session.id] ?? [] }

    /// How long a process must keep a core busy to count as running away (self-test shortens it).
    var cpuSeconds: TimeInterval = 120 {
        didSet { queue.async { [cpuSeconds] in self.tracker.cpuSeconds = cpuSeconds } }
    }

    private var timer: Timer?
    private var scanning = false
    private var lastShape: [String] = []
    private var sidebars = NSHashTable<SidebarView>.weakObjects()

    // Only touched on `queue`.
    private let queue = DispatchQueue(label: "anser.processes", qos: .utility)
    private var lastUsage: [pid_t: (usage: ProcessScan.Usage, at: Date)] = [:]
    private var tracker = RunawayTracker()
    /// pid + start time → (command line, folder): a process's arguments don't change.
    private var argsCache: [String: (line: String, folder: String?)] = [:]
    /// Shells of tabs Anser has had open (pid → when it started), so what they leave behind can be
    /// recognized after the tab closes. Kept across launches (not by the self-test).
    private lazy var knownShells: [pid_t: Date] = Self.loadKnownShells()
    private static let knownShellsKey = "AnserKnownShells"

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.wake()
        }
    }

    // MARK: When to look

    /// A sidebar showing the Running section asks for the full picture (left over, other ports).
    func sidebar(_ s: SidebarView, showsRunning: Bool) {
        if showsRunning {
            let was = wantsDetail
            sidebars.add(s)
            if !was { wake(soon: true) }
        } else {
            sidebars.remove(s)
        }
    }

    /// The self-test gathers the full picture without a sidebar on screen.
    var forceDetail = false

    private var wantsDetail: Bool {
        forceDetail || sidebars.allObjects.contains { $0.window?.isVisible == true && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// Commands started or finished: look again shortly.
    func wake(soon: Bool = false) {
        schedule(after: soon ? 0.2 : 1.5)
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.scan() }
        timer?.tolerance = seconds * 0.2
    }

    /// Looks now and calls `done` with the result (self-test, after stopping something).
    func scan(done: (() -> Void)? = nil) {
        guard !scanning else {
            if let done { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.scan(done: done) } }
            return
        }
        let panes = AppDelegate.shared.allPanes.filter { !$0.session.isRemote && $0.session.shellPID > 1 }
        var shellToSession: [pid_t: String] = [:]
        for p in panes where shellToSession[p.session.shellPID] == nil { shellToSession[p.session.shellPID] = p.session.id }
        let detail = wantsDetail
        let busy = panes.contains { $0.session.running != nil }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.collect(shells: shellToSession, detail: detail)
            DispatchQueue.main.async {
                self.scanning = false
                self.byTab = result.byTab
                self.leftovers = result.leftovers
                if detail { self.otherPorts = result.other } else if !self.otherPorts.isEmpty { self.otherPorts = [] }
                let shape = (result.byTab.sorted { $0.key < $1.key }.flatMap { k, v in [k] + v.map(\.shape) })
                    + result.leftovers.map(\.shape) + (detail ? result.other.map(\.shape) : [])
                if shape != self.lastShape {
                    self.lastShape = shape
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                } else {
                    NotificationCenter.default.post(name: Self.sampled, object: nil)
                }
                done?()
                // Keep looking while there's something to watch.
                let active = NSApp.isActive
                if detail { self.schedule(after: active ? 3 : 30) }
                else if busy || !result.byTab.isEmpty { self.schedule(after: active ? 5 : 30) }
                else { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    // MARK: Reading the processes (on `queue`)

    private struct Result {
        var byTab: [String: [Item]] = [:]
        var leftovers: [Item] = []
        var other: [Item] = []
    }

    private func collect(shells: [pid_t: String], detail: Bool) -> Result {
        let procs = ProcessScan.all()
        let me = getuid()
        let now = Date()
        let own = getpid()
        var shown = Set<pid_t>(shells.keys)
        shown.insert(own)
        var result = Result()

        rememberShells(shells, procs: procs)
        let foreground: [pid_t: pid_t] = Dictionary(uniqueKeysWithValues: shells.keys.map { ($0, ForegroundJob.of(shellPID: $0)?.pgid ?? 0) })

        func item(_ n: ProcessScan.Node, background: Bool, needArgs: Bool) -> Item {
            let pid = n.proc.pid
            let u = ProcessScan.usage(pid)
            var cpu = 0.0
            if let u, let prev = lastUsage[pid] { cpu = ProcessScan.cpuPercent(from: prev.usage, to: u, seconds: now.timeIntervalSince(prev.at)) }
            if let u { lastUsage[pid] = (u, now) }
            tracker.record(pid: pid, cpu: background ? cpu : 0, memory: u?.memory ?? 0, at: now)
            var it = Item(pid: pid, name: ProcessScan.name(pid) ?? n.proc.name, depth: n.depth, started: n.proc.started,
                          ports: ProcessScan.ports(pid), cpu: cpu, memory: u?.memory ?? 0, runaway: tracker.kind(pid, at: now), background: background)
            if needArgs || detail {
                let a = args(n.proc)
                it.commandLine = a.line
                it.folder = a.folder
            }
            return it
        }

        // Each tab's processes.
        let trees = ProcessScan.trees(under: Array(shells.keys), in: procs)
        let byPID = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for (shell, nodes) in trees {
            guard let session = shells[shell] else { continue }
            let front = foreground[shell] ?? 0
            // The shell's own helpers (a prompt's git status, a subshell for the title) share its
            // process group; commands and jobs get groups of their own.
            let jobs = byPID[shell].map { ProcessScan.jobs(of: $0, nodes) } ?? nodes
            for n in nodes { shown.insert(n.proc.pid) }
            if !jobs.isEmpty {
                result.byTab[session] = jobs.map { n in item(n, background: front == 0 || n.proc.pgid != front, needArgs: false) }
            }
        }

        if detail {
            let sessionDaemons = Set(procs.filter { $0.name == "anser-session" }.map(\.pid))
            shown.formUnion(sessionDaemons)
            // On their own now (`nohup … &`, a double fork, or their tab closed), but still in the
            // terminal session of an Anser shell: a process keeps its session id after the shell is gone.
            for p in procs where p.ppid == 1 && p.uid == me && !shown.contains(p.pid) {
                let sid = getsid(p.pid)
                guard sid > 1 else { continue }
                let tab = shells[sid]
                guard tab != nil || knownShells[sid].map({ p.started >= $0 }) == true else { continue }
                // Not one of the shell's own helpers (same group as the shell, or on another terminal).
                guard p.pgid != sid, now.timeIntervalSince(p.started) >= 1.5, !ProcessScan.isShellHelper(p.name) else { continue }
                if tab != nil, let shell = byPID[sid], p.tty != -1, p.tty != shell.tty { continue }
                guard ProcessScan.appName(path: ProcessScan.path(p.pid)) == nil else { continue }
                let subtree = [ProcessScan.Node(proc: p, depth: 1)]
                    + (ProcessScan.trees(under: [p.pid], in: procs)[p.pid] ?? []).map { ProcessScan.Node(proc: $0.proc, depth: $0.depth + 1) }
                let items = subtree.map { n -> Item in shown.insert(n.proc.pid); return item(n, background: true, needArgs: true) }
                if let tab { result.byTab[tab, default: []].append(contentsOf: items) } else { result.leftovers.append(contentsOf: items) }
            }
            // Everything else of yours that listens on a port.
            for p in procs where p.uid == me && !shown.contains(p.pid) {
                let ports = ProcessScan.ports(p.pid)
                guard !ports.isEmpty else { continue }
                let path = ProcessScan.path(p.pid)
                let u = ProcessScan.usage(p.pid)
                var it = Item(pid: p.pid, name: ProcessScan.name(p.pid) ?? p.name, depth: 1, started: p.started, ports: ports,
                              cpu: 0, memory: u?.memory ?? 0, runaway: nil, background: true)
                it.isSystem = ProcessScan.isSystem(path: path)
                it.app = ProcessScan.appName(path: path)
                it.commandLine = it.isSystem ? path : args(p).line
                result.other.append(it)
            }
            // Servers with several worker processes (httpd, nginx) share one port: list it once.
            var seenPorts = Set<String>()
            result.other = result.other.sorted { $0.pid < $1.pid }.filter { seenPorts.insert("\($0.name):\($0.ports.map(\.port))").inserted }
            result.other.sort { ($0.ports.first?.port ?? 0) < ($1.ports.first?.port ?? 0) }
        }

        // Forget processes that are gone.
        let alive = Set(procs.map(\.pid))
        lastUsage = lastUsage.filter { alive.contains($0.key) }
        tracker.keepOnly(alive)
        if argsCache.count > 2000 { argsCache = [:] }
        return result
    }

    /// Whether a shell is remembered (for tests).
    func remembers(shell pid: pid_t) -> Bool { queue.sync { knownShells[pid] != nil } }

    private func rememberShells(_ shells: [pid_t: String], procs: [ProcessScan.Proc]) {
        var changed = false
        for p in procs where shells[p.pid] != nil && knownShells[p.pid] != p.started {
            knownShells[p.pid] = p.started
            changed = true
        }
        guard changed else { return }
        // A shell is forgotten a week after it started, and only the newest 300 are kept.
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        knownShells = Dictionary(uniqueKeysWithValues: knownShells.filter { $0.value > cutoff }.sorted { $0.value > $1.value }.prefix(300).map { ($0.key, $0.value) })
        guard !Services.isSelfTest else { return }
        let plain = knownShells.map { [Double($0.key), $0.value.timeIntervalSince1970] }
        UserDefaults.standard.set(plain, forKey: Self.knownShellsKey)
    }

    private static func loadKnownShells() -> [pid_t: Date] {
        guard !Services.isSelfTest, let rows = UserDefaults.standard.array(forKey: knownShellsKey) as? [[Double]] else { return [:] }
        var out: [pid_t: Date] = [:]
        for r in rows where r.count == 2 { out[pid_t(r[0])] = Date(timeIntervalSince1970: r[1]) }
        return out
    }

    private func args(_ p: ProcessScan.Proc) -> (line: String, folder: String?) {
        let key = "\(p.pid)@\(p.started.timeIntervalSince1970)"
        if let c = argsCache[key] { return c }
        let a = ProcessScan.arguments(p.pid)
        let v = (a?.commandLine ?? p.name, ProcessScan.cwd(p.pid))
        argsCache[key] = v
        return v
    }

    // MARK: Stopping

    /// Whether Anser will stop this process: yours, not part of macOS, not Anser or its shells.
    static func canStop(_ pid: pid_t) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        if AppDelegate.shared.allPanes.contains(where: { $0.session.shellPID == pid }) { return false }
        if ProcessScan.name(pid) == "anser-session" { return false }
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size, info.pbsi_uid == getuid() else { return false }
        return !ProcessScan.isSystem(path: ProcessScan.path(pid))
    }

    /// Asks each process to quit (SIGTERM), forces the ones still there after 3 seconds,
    /// then calls `then` once they're gone.
    static func stop(_ pids: [pid_t], then: (() -> Void)? = nil) {
        let list = pids.filter(canStop)
        for pid in list { kill(pid, SIGTERM) }
        let start = Date()
        func poll() {
            let left = list.filter { kill($0, 0) == 0 && !isZombie($0) }
            if left.isEmpty || Date().timeIntervalSince(start) > 4.5 {
                ServerMonitor.shared.check()
                shared.scan { then?() }
                return
            }
            if Date().timeIntervalSince(start) >= 3 { for pid in left { kill(pid, SIGKILL) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: poll)
    }

    private static func isZombie(_ pid: pid_t) -> Bool {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return true }
        return info.pbsi_status == UInt32(SZOMB)
    }

    /// Everything a tab is running (not its shell).
    static func stopAll(in pane: PaneView, then: (() -> Void)? = nil) {
        let pids = shared.items(for: pane).map(\.pid)
        guard !pids.isEmpty else { then?(); return }
        stop(pids, then: then)
    }

    // MARK: Menus

    /// Right-click menu for one process.
    static func menu(for it: Item, pane: PaneView?, over window: NSWindow?) -> NSMenu {
        let m = NSMenu()
        if let pane {
            m.addItem(ClosureMenuItem(title: "Show Its Tab") { _ = AppDelegate.shared.reveal(sessionID: pane.session.id) })
        }
        for p in it.ports {
            m.addItem(ClosureMenuItem(title: "Open \(p.url)") { if let u = URL(string: p.url) { NSWorkspace.shared.open(u) } })
        }
        if let first = it.ports.first {
            m.addItem(ClosureMenuItem(title: "Copy Link") { TerminalWindowController.copy(first.url) })
        }
        if let c = it.commandLine, !c.isEmpty {
            m.addItem(ClosureMenuItem(title: "Copy Command Line") { TerminalWindowController.copy(c) })
        }
        m.addItem(ClosureMenuItem(title: "Copy Process ID (\(it.pid))") { TerminalWindowController.copy(String(it.pid)) })
        if let f = it.folder {
            m.addItem(ClosureMenuItem(title: "Show Folder in Finder") { FileActions.reveal(f) })
        }
        guard canStop(it.pid) else { return m }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Stop \(it.name)") { confirmStop(it, fromTab: pane != nil, over: window) })
        m.addItem(ClosureMenuItem(title: "Force Quit \(it.name)") { kill(it.pid, SIGKILL); shared.wake(soon: true) })
        if let pane, shared.items(for: pane).count > 1 {
            m.addItem(ClosureMenuItem(title: "Stop Everything in This Tab") { stopAll(in: pane) })
        }
        return m
    }

    /// What a tab started stops right away; anything else asks first.
    static func confirmStop(_ it: Item, fromTab: Bool, over window: NSWindow?) {
        guard canStop(it.pid) else { NSSound.beep(); return }
        if fromTab { stop([it.pid]); return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Stop \(it.app ?? it.name)?"
        var info = it.ports.isEmpty ? "" : "It's listening on " + it.ports.map { ":\($0.port)" }.joined(separator: ", ") + ". "
        info += it.app != nil ? "It's part of \(it.app!), so the app may stop working or start it again." : "Anser didn't start it."
        a.informativeText = info
        a.addButton(withTitle: "Stop It")
        a.addButton(withTitle: "Cancel")
        let go: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { stop([it.pid]) } }
        if let window { a.beginSheetModal(for: window, completionHandler: go) } else { go(a.runModal()) }
    }

    /// "3m", "2h 5m", "4d".
    static func age(_ since: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d"
    }
}
