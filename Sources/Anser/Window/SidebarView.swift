import AppKit
import AnserCore

/// Optional left sidebar (⌃⌘S): the focused pane's git changes, recent
/// folders, your notebook and workflows. Everything is one click away.
final class SidebarView: NSView {
    weak var controller: TerminalWindowController?
    private let scroll = NSScrollView()
    private let stack = FlippedStack()
    private var loadTask: Task<Void, Never>?
    private(set) var rowCount = 0
    private weak var lastPane: PaneView?
    private var lastChanges: [GitChange] = []
    /// Section titles you've folded away (remembered across launches).
    private(set) var collapsedSections: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sidebarCollapsed") ?? [])
    /// Header titles as drawn, for tests ("GIT · 6").
    private(set) var sectionTitles: [String] = []

    final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }

    /// Where each section starts in the stack while building (title, index), and sections you hid.
    private var sectionStarts: [(title: String, index: Int)] = []
    private var hiddenNow: [String] = []
    /// Section titles in the order shown (for tests and moving).
    private(set) var orderedSections: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 12, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = true
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
        ])
        setAccessibilityLabel("Sidebar")
        NotificationCenter.default.addObserver(forName: .anserNotebookChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.refreshSidebar() }
        }
        NotificationCenter.default.addObserver(forName: .anserPluginsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.refreshSidebar() }
        }
        NotificationCenter.default.addObserver(forName: ServerMonitor.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller?.refreshSidebar() }
        }
        for name in [ContainerMonitor.changed, TunnelManager.changed, OutputWatchManager.changed] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller?.refreshSidebar() }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The list is sized by hand: as wide as the sidebar, as tall as its rows.
    override func layout() {
        super.layout()
        let w = scroll.contentSize.width
        guard w > 0 else { return }
        stack.frame.size.width = w
        stack.layoutSubtreeIfNeeded()
        let h = max(stack.fittingSize.height, scroll.contentSize.height)
        stack.frame = NSRect(x: 0, y: 0, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = GhosttyRuntime.shared.theme
        t.barBackground.setFill()
        bounds.fill()
        t.foreground.withAlphaComponent(0.08).setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    /// Rebuilds the sidebar for a pane (git status is loaded in the background).
    func refresh(for pane: PaneView?) {
        loadTask?.cancel()
        guard let pane else { return }
        let session = pane.session
        loadTask = Task { @MainActor [weak self] in
            let changes = session.gitBranch != nil && !session.gitRisky ? await Generators.gitChanges(cwd: session.cwd, env: session.env) : []
            guard let self, !Task.isCancelled else { return }
            self.build(pane: pane, changes: changes)
        }
    }

    func toggleSection(_ title: String) {
        if collapsedSections.contains(title) { collapsedSections.remove(title) } else { collapsedSections.insert(title) }
        UserDefaults.standard.set(Array(collapsedSections), forKey: "sidebarCollapsed")
        if let p = lastPane { build(pane: p, changes: lastChanges) }
    }

    private func build(pane: PaneView, changes: [GitChange]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowCount = 0
        sectionTitles = []
        sectionStarts = []
        hiddenNow = []
        lastPane = pane
        lastChanges = changes
        defer { arrangeSections(); needsLayout = true }
        let t = GhosttyRuntime.shared.theme
        let s = pane.session
        let fm = FileManager.default

        if let branch = s.gitBranch, section("Git", count: changes.isEmpty ? nil : changes.count) {
            row(symbol: "arrow.triangle.branch", text: branch, detail: "switch…", color: t.foreground) { [weak self] in
                self?.controller?.showBranchSwitcher(for: pane)
            }
            if changes.isEmpty {
                row(symbol: "checkmark.circle", text: "No changes", detail: nil, color: t.dim, action: nil)
            }
            func run(_ cmd: String) { if s.atPrompt { pane.run(cmd) } else { NSSound.beep() } }
            for c in changes.prefix(40) {
                var isDir: ObjCBool = false
                let full = (s.cwd as NSString).appendingPathComponent(c.path)
                let folder = c.path.hasSuffix("/") || (fm.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue)
                let name = ((c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) as NSString).lastPathComponent
                let deleted = c.code.contains("D")
                let color: NSColor = c.untracked ? t.green : (deleted ? t.red : t.yellow)
                let symbol = folder ? "folder.badge.plus" : (c.untracked ? "plus.square" : (deleted ? "minus.square" : "pencil"))
                let f = ShellLexer.escape(c.path)
                var actions: [SidebarRow.Action] = []
                if !c.staged || c.untracked {
                    actions.append(.init(symbol: "plus.circle", tip: "Stage (git add)") { run("git add -- \(f)") })
                } else {
                    actions.append(.init(symbol: "minus.circle", tip: "Unstage (git restore --staged)") { run("git restore --staged -- \(f)") })
                }
                if !c.untracked, !c.staged {
                    actions.append(.init(symbol: "arrow.uturn.backward.circle", tip: "Discard changes…") { [weak self] in
                        self?.confirmDiscard(c.path) { run("git restore -- \(f)") }
                    })
                }
                row(symbol: symbol, text: name + (folder ? "/" : ""), detail: folder ? "new folder" : c.summary, color: color,
                    tooltip: c.path + (folder ? "" : "\nClick to see the diff"), actions: actions) {
                    if folder { run("ls -la -- \(f)") }
                    else { run(c.untracked ? "cat -- \(f)" : (c.staged ? "git diff --cached -- \(f)" : "git diff -- \(f)")) }
                }
            }
            if changes.count > 40 {
                row(symbol: "ellipsis", text: "\(changes.count - 40) more…", detail: nil, color: t.dim) { [weak self] in
                    self?.controller?.showChanges(for: pane)
                }
            }
        }

        // Failed tests from the last test run: open one, re-run just it.
        if let (report, cmd, cwd) = pane.testReport, !report.failures.isEmpty, section("Failed tests", count: report.failures.count) {
            for f in report.failures.prefix(20) {
                let re = TestFailures.rerunCommand(f, runner: report.runner, original: cmd)
                var actions: [SidebarRow.Action] = []
                if let re { actions.append(.init(symbol: "play.circle", tip: "Re-run this test") { pane.rerunTests([f], command: re, cwd: cwd) }) }
                row(symbol: "xmark.circle", text: f.name, detail: f.location.map { ($0 as NSString).lastPathComponent }, color: t.red,
                    tooltip: [f.name, f.location, f.message].compactMap { $0 }.joined(separator: "\n") + "\nClick to open · ▶ re-runs it",
                    actions: actions, wraps: true) {
                    pane.openTestLocation(f, cwd: cwd)
                }
            }
            if let all = TestFailures.rerunCommand(report.failures, runner: report.runner, original: cmd) {
                row(symbol: "arrow.clockwise", text: "Re-run all failed", detail: report.runner.displayName, color: t.dim, tooltip: all) {
                    pane.rerunTests(report.failures, command: all, cwd: cwd)
                }
            }
        }

        // Servers your tabs started, in every window.
        let servers = ServerMonitor.shared.all
        if !servers.isEmpty, section("Servers", count: servers.count) {
            for (p, srv) in servers {
                let tab = p.windowController.flatMap { wc in wc.tab(for: p).map { wc.title(of: $0) } } ?? ""
                row(symbol: "server.rack", text: ":\(srv.port)  \(srv.process)", detail: tab, color: t.green,
                    tooltip: "\(srv.url)\nClick to open · right-click to copy or stop",
                    actions: [.init(symbol: "stop.circle", tip: "Stop \(srv.process)") { ServerMonitor.stop(pid: srv.pid) }],
                    menu: { ServerMonitor.menu(for: srv, pane: p) }) {
                    if let u = URL(string: srv.url) { NSWorkspace.shared.open(u) }
                }
            }
        }

        // One-click project tasks: npm scripts, Make targets, just recipes…
        if !s.isRemote, let project = ProjectTasks.find(from: s.cwd), section("Tasks", count: project.tasks.count) {
            let name = (project.root as NSString).lastPathComponent
            func runTask(_ task: ProjectTasks.Task) {
                let cmd = project.root == s.cwd ? task.command : "cd \(ShellLexer.escape(project.root)) && \(task.command)"
                if s.atPrompt { pane.run(cmd) } else { AppDelegate.shared.openTab(cwd: project.root, run: task.command) }
            }
            for task in project.tasks.prefix(30) {
                let symbol = ["dev", "start", "run", "serve", "watch"].contains(task.name) ? "play.circle" : (task.name.contains("test") ? "checkmark.circle" : "hammer")
                row(symbol: symbol, text: task.name, detail: task.group, color: t.foreground,
                    tooltip: task.command + (task.detail.map { "\n" + $0 } ?? "") + "\nClick to run in \(name) · right-click for more",
                    actions: [.init(symbol: "plus.square.on.square", tip: "Run in a new tab") { AppDelegate.shared.openTab(cwd: project.root, run: task.command) }],
                    menu: {
                        let m = NSMenu()
                        m.addItem(ClosureMenuItem(title: "Run") { runTask(task) })
                        m.addItem(ClosureMenuItem(title: "Run in New Tab") { AppDelegate.shared.openTab(cwd: project.root, run: task.command) })
                        m.addItem(ClosureMenuItem(title: "Put in Editor") { pane.insertIntoEditor(task.command) })
                        m.addItem(ClosureMenuItem(title: "Copy Command") { TerminalWindowController.copy(task.command) })
                        return m
                    }) { runTask(task) }
            }
            if project.tasks.count > 30 {
                row(symbol: "ellipsis", text: "\(project.tasks.count - 30) more", detail: nil, color: t.dim, action: nil)
            }
        }

        // Sections from plugins.
        for (title, rows) in PluginHost.shared.sections(for: pane) where section(title, count: rows.count) {
            for r in rows {
                row(symbol: r.run != nil ? "play.circle" : (r.open != nil ? "arrow.up.forward.square" : "puzzlepiece.extension"), text: r.text, detail: r.detail,
                    color: TabBarView.color(r.color) ?? t.foreground, tooltip: r.text + (r.run.map { "\nClick to run: \($0)" } ?? "")) {
                    if let cmd = r.run {
                        if s.atPrompt { pane.submitFromEditor(cmd) } else { AppDelegate.shared.openTab(cwd: s.cwd, run: cmd) }
                    } else if let o = r.open, let url = PluginOutput.safeToOpen(o) {
                        PluginHost.open(url)
                    }
                }
            }
        }

        // Docker containers (when Docker is running) and Kubernetes pods (when you ask).
        let cm = ContainerMonitor.shared
        cm.refreshDocker(env: s.env)
        if cm.dockerAvailable, !cm.containers.isEmpty, section("Containers", count: cm.containers.filter(\.isRunning).count) {
            for c in cm.containers {
                let env = s.env
                let menu: () -> NSMenu? = {
                    let m = NSMenu()
                    m.addItem(ClosureMenuItem(title: "Follow Logs") { AppDelegate.shared.openTab(cwd: nil, run: Containers.logs(c)) })
                    if c.isRunning {
                        m.addItem(ClosureMenuItem(title: "Open a Shell Inside") { AppDelegate.shared.openTab(cwd: nil, run: Containers.shell(c)) })
                        if let port = c.hostPort {
                            m.addItem(ClosureMenuItem(title: "Open http://localhost:\(port)") { if let u = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(u) } })
                        }
                        m.addItem(ClosureMenuItem(title: "Restart") { cm.docker(["restart", c.name], env: env) { _ in pane.flash("Restarted \(c.name)") } })
                        m.addItem(ClosureMenuItem(title: "Stop") { cm.docker(["stop", c.name], env: env) { _ in pane.flash("Stopped \(c.name)") } })
                    } else {
                        m.addItem(ClosureMenuItem(title: "Start") { cm.docker(["start", c.name], env: env) { _ in pane.flash("Started \(c.name)") } })
                    }
                    m.addItem(.separator())
                    m.addItem(ClosureMenuItem(title: "Copy Name") { TerminalWindowController.copy(c.name) })
                    return m
                }
                row(symbol: c.isRunning ? "shippingbox.fill" : "shippingbox", text: c.name, detail: c.isRunning ? (c.hostPort.map { ":\($0)" } ?? c.image) : "stopped",
                    color: c.isRunning ? t.foreground : t.dim, tooltip: "\(c.image)\n\(c.status)\(c.ports.isEmpty ? "" : "\n" + c.ports)\nClick for logs · right-click for more",
                    actions: c.isRunning ? [.init(symbol: "terminal", tip: "Open a shell inside") { AppDelegate.shared.openTab(cwd: nil, run: Containers.shell(c)) }] : [],
                    menu: menu) {
                    AppDelegate.shared.openTab(cwd: nil, run: Containers.logs(c))
                }
            }
        }
        let kube = CloudContext.current(vars: s.cloudVars).kube
        if !s.isRemote, let ctx = kube, CommandIndex.shared.contains("kubectl", env: s.env), section("Pods", count: cm.pods[ctx]?.pods.count) {
            var extra: [String: String] = [:]
            if let k = s.cloudVars.kubeconfig { extra["KUBECONFIG"] = k }
            if let list = cm.pods[ctx] {
                if let err = list.error {
                    row(symbol: "exclamationmark.triangle", text: "Couldn't list pods", detail: nil, color: t.yellow, tooltip: err, wraps: true, action: nil)
                }
                for p in list.pods.prefix(30) {
                    let menu: () -> NSMenu? = {
                        let m = NSMenu()
                        m.addItem(ClosureMenuItem(title: "Follow Logs") { AppDelegate.shared.openTab(cwd: nil, run: Containers.logs(p)) })
                        m.addItem(ClosureMenuItem(title: "Open a Shell Inside") { AppDelegate.shared.openTab(cwd: nil, run: Containers.shell(p)) })
                        m.addItem(ClosureMenuItem(title: "Describe") { if s.atPrompt { pane.run(Containers.describe(p)) } else { AppDelegate.shared.openTab(cwd: nil, run: Containers.describe(p)) } })
                        m.addItem(ClosureMenuItem(title: "Copy Name") { TerminalWindowController.copy(p.name) })
                        return m
                    }
                    row(symbol: p.isHealthy ? "circle.fill" : "exclamationmark.circle", text: p.name, detail: p.statusText,
                        color: p.isHealthy ? t.foreground : (p.phase == "Pending" ? t.yellow : t.red),
                        tooltip: "\(p.namespace)/\(p.name)\n\(p.statusText)\nClick for logs · right-click for more", menu: menu) {
                        AppDelegate.shared.openTab(cwd: nil, run: Containers.logs(p))
                    }
                }
                row(symbol: "arrow.clockwise", text: cm.isLoadingPods(ctx) ? "Loading…" : "Refresh", detail: ctx, color: t.dim, tooltip: "kubectl get pods in \(ctx)") {
                    cm.loadPods(context: ctx, env: s.env, extra: extra)
                }
            } else {
                row(symbol: "arrow.down.circle", text: cm.isLoadingPods(ctx) ? "Loading pods…" : "Load pods", detail: ctx, color: t.dim,
                    tooltip: "Lists pods with kubectl in context \(ctx). Only when you click, since the cluster may be far away.") {
                    cm.loadPods(context: ctx, env: s.env, extra: extra)
                }
            }
        }

        // Commands watched in the background.
        let watches = OutputWatchManager.shared.watches
        if !watches.isEmpty, section("Watching", count: watches.count) {
            for w in watches {
                let failing = (w.lastExit ?? 0) != 0 && w.lastRun != nil
                let every = w.intervalMinutes >= 60 ? "\(Int(w.intervalMinutes / 60))h" : "\(Int(w.intervalMinutes))m"
                let detail = w.lastRun == nil ? "running…" : (failing ? "failing" : (w.lastChange.map { "changed " + RelativeTime.format($0) } ?? "every \(every)"))
                row(symbol: failing ? "exclamationmark.circle" : (w.changes > 0 ? "eye.trianglebadge.exclamationmark" : "eye"), text: w.command, detail: detail,
                    color: failing ? t.red : (w.changes > 0 ? t.yellow : t.foreground),
                    tooltip: "\(w.command)\nEvery \(every) in \(PathDisplay.short(w.cwd)) · \(w.runs) runs, \(w.changes) changes\nClick to see the output · right-click for more",
                    menu: { [weak self] in OutputWatchManager.shared.menu(for: w, window: self?.window) }) { [weak self] in
                    OutputWatchManager.shared.showChange(w, over: self?.window)
                }
            }
        }

        // SSH tunnels kept open in the background.
        let tunnels = Services.shared.config.tunnels
        if !tunnels.isEmpty, section("Tunnels", count: tunnels.filter { TunnelManager.shared.isOn($0) }.count) {
            let tm = TunnelManager.shared
            for tn in tunnels {
                let state = tm.state(tn)
                let (symbol, color, detail): (String, NSColor, String) = {
                    switch state {
                    case .stopped: return ("circle", t.dim, "off")
                    case .starting: return ("circle.dotted", t.yellow, "opening…")
                    case .up: return ("circle.fill", t.green, ":\(tn.localPort)")
                    case .retrying: return ("arrow.clockwise.circle", t.yellow, "reconnecting")
                    case .failed: return ("exclamationmark.circle", t.red, "failed")
                    }
                }()
                var tip = tn.summary
                if case let .failed(why) = state { tip += "\n" + why }
                if case let .retrying(_, why) = state { tip += "\n" + why }
                row(symbol: symbol, text: tn.name.isEmpty ? tn.host : tn.name, detail: detail, color: color,
                    tooltip: tip + "\nClick to open or close · right-click for more", menu: { tm.menu(for: tn, pane: pane) }) {
                    tm.toggle(tn)
                }
            }
            row(symbol: "plus", text: "Add tunnel…", detail: nil, color: t.dim) { [weak self] in tm.edit(nil, over: self?.window) }
        }

        if section("Recent folders") {
        // Where you are, highlighted, then recent folders with their parent folder
        // in gray so look-alike names ("src", "app") can be told apart.
        func parent(_ path: String) -> String {
            path == "/" ? "" : PathDisplay.short((path as NSString).deletingLastPathComponent, max: 20)
        }
        if !s.isRemote {
            row(symbol: "folder.fill", text: (s.cwd as NSString).lastPathComponent.isEmpty ? "/" : (s.cwd as NSString).lastPathComponent,
                detail: parent(s.cwd), color: t.foreground, tooltip: s.cwd + "\nYou're here · right-click for options", highlighted: true,
                menu: { FileActions.folderMenu(s.cwd, pane: pane) }, action: nil)
        }
        for d in Services.shared.history.recentDirectories(limit: 30).filter({ fm.fileExists(atPath: $0.path) && $0.path != s.cwd }).prefix(8) {
            row(symbol: "folder", text: (d.path as NSString).lastPathComponent, detail: parent(d.path), color: t.foreground,
                tooltip: d.path + "\nClick to cd · right-click for options", menu: { FileActions.folderMenu(d.path, pane: pane) }) {
                if s.atPrompt { pane.run("cd " + ShellLexer.escape(d.path)) } else { NSSound.beep() }
            }
        }
        row(symbol: "magnifyingglass", text: "More folders…", detail: "⌘J", color: t.dim) { [weak self] in
            self?.controller?.showFolderJumper(for: pane)
        }
        }

        // SSH hosts from ~/.ssh/config: click opens a tab connected to it, with its profile's color.
        let hosts = SSHConfig.load()
        if !hosts.isEmpty, section("SSH hosts", count: hosts.count) {
            let profiles = Services.shared.config.profiles
            for h in hosts.prefix(25) {
                let profile = Profile.resolve(profiles, host: h.alias, cwd: "~") ?? h.hostName.flatMap { Profile.resolve(profiles, host: $0, cwd: "~") }
                let color = TabBarView.color(profile?.tabColor) ?? t.foreground
                row(symbol: "network", text: h.alias, detail: profile?.badge ?? h.detail, color: color,
                    tooltip: "ssh \(h.alias)" + (h.detail.map { "\n" + $0 } ?? "") + "\nClick to connect in a new tab") {
                    AppDelegate.shared.openTab(cwd: nil, run: "ssh " + ShellLexer.escape(h.alias))
                }
            }
        }

        // Saved things (Notebook, workflows, runbooks) live in the panel on the right;
        // the sidebar keeps to where you are and what's running. See addSavedRow().
    }

    // MARK: Customizing

    /// Puts sections in your order, and adds a row for the ones you hid.
    private func arrangeSections() {
        let views = stack.arrangedSubviews
        guard !sectionStarts.isEmpty else { addHiddenRow(); addSavedRow(); return }
        var chunks: [(title: String, views: [NSView], original: Int)] = []
        for (i, start) in sectionStarts.enumerated() {
            let end = i + 1 < sectionStarts.count ? sectionStarts[i + 1].index : views.count
            chunks.append((start.title, Array(views[start.index..<max(start.index, end)]), i))
        }
        let order = SidebarPrefs.order
        let ranked = chunks.sorted { a, b in
            let ra = order.firstIndex(of: a.title) ?? (1000 + a.original), rb = order.firstIndex(of: b.title) ?? (1000 + b.original)
            return ra < rb
        }
        orderedSections = ranked.map(\.title)
        if ranked.map(\.title) != chunks.map(\.title) {
            for v in views { stack.removeArrangedSubview(v) }
            for (ci, c) in ranked.enumerated() {
                for v in c.views { stack.addArrangedSubview(v) }
                if ci > 0, let prevLast = ranked[ci - 1].views.last { stack.setCustomSpacing(12, after: prevLast) }
                if let header = c.views.first { stack.setCustomSpacing(4, after: header) }
            }
            sectionTitles = ranked.compactMap { c in (c.views.first as? SidebarHeader)?.titleText }
        }
        addHiddenRow()
        addSavedRow()
    }

    /// One link to the Saved panel when it's closed, so saved commands are a click away without repeating them here.
    private(set) var savedRowText: String?
    private func addSavedRow() {
        savedRowText = nil
        guard let pane = lastPane, controller?.notebookPanelVisible != true else { return }
        let t = GhosttyRuntime.shared.theme
        let s = pane.session
        let notebook = (try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook()
        let flows = s.isRemote ? 0 : WorkflowStore.load(cwd: s.cwd).count
        let books = s.isRemote ? 0 : Runbook.load(cwd: s.cwd).count
        let total = notebook.entryCount + flows + books
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(12, after: last) }
        let text = total == 0 ? "Saved commands" : "Saved commands · \(total)"
        savedRowText = text
        row(symbol: "book.closed", text: text, detail: "⌥⌘N", color: t.dim,
            tooltip: "Your Notebook (workflows included) and runbooks, in the panel on the right") { [weak self] in
            self?.controller?.toggleNotebookPanel()
        }
    }

    private func addHiddenRow() {
        guard !hiddenNow.isEmpty, let pane = lastPane else { return }
        let t = GhosttyRuntime.shared.theme
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(12, after: last) }
        let names = hiddenNow
        row(symbol: "eye.slash", text: "\(names.count) hidden section\(names.count == 1 ? "" : "s")", detail: nil, color: t.dim,
            tooltip: names.joined(separator: ", ") + "\nClick to show one again", menu: { [weak self] in self?.hiddenMenu(names) }) { [weak self] in
            guard let self, let m = self.hiddenMenu(names) else { return }
            m.popUp(positioning: nil, at: NSPoint(x: 20, y: 0), in: self.stack.arrangedSubviews.last ?? self)
        }
        _ = pane
    }

    private func hiddenMenu(_ names: [String]) -> NSMenu? {
        let m = NSMenu()
        for n in names { m.addItem(ClosureMenuItem(title: "Show “\(n)”") { [weak self] in SidebarPrefs.setHidden(n, false); self?.rebuildNow() }) }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Show All") { [weak self] in SidebarPrefs.hidden = []; self?.rebuildNow() })
        return m
    }

    private func headerMenu(_ title: String) -> NSMenu {
        let m = NSMenu()
        let i = orderedSections.firstIndex(of: title) ?? 0
        let top = ClosureMenuItem(title: "Move to Top") { [weak self] in self?.move(title, to: 0) }
        top.isEnabled = i > 0
        let up = ClosureMenuItem(title: "Move Up") { [weak self] in self?.move(title, to: i - 1) }
        up.isEnabled = i > 0
        let down = ClosureMenuItem(title: "Move Down") { [weak self] in self?.move(title, to: i + 1) }
        down.isEnabled = i < orderedSections.count - 1
        for item in [top, up, down] { m.addItem(item) }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Hide “\(title)”") { [weak self] in SidebarPrefs.setHidden(title, true); self?.rebuildNow() })
        m.addItem(ClosureMenuItem(title: "Reset Sidebar") { [weak self] in SidebarPrefs.order = []; SidebarPrefs.hidden = []; self?.rebuildNow() })
        return m
    }

    /// Moves a section and remembers the whole order.
    func move(_ title: String, to index: Int) {
        var order = orderedSections
        guard let from = order.firstIndex(of: title) else { return }
        order.remove(at: from)
        order.insert(title, at: max(0, min(order.count, index)))
        // Keep sections that aren't showing right now (no servers, say) in their saved place too.
        let rest = SidebarPrefs.order.filter { !order.contains($0) }
        SidebarPrefs.order = order + rest
        rebuildNow()
    }

    func rebuildNow() { if let p = lastPane { build(pane: p, changes: lastChanges) } }

    private func confirmDiscard(_ path: String, then go: @escaping () -> Void) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Discard your changes to \((path as NSString).lastPathComponent)?"
        a.informativeText = "This runs `git restore` and can't be undone."
        a.addButton(withTitle: "Discard")
        a.addButton(withTitle: "Cancel")
        guard let window else { if a.runModal() == .alertFirstButtonReturn { go() }; return }
        a.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { go() } }
    }

    /// Adds a section header; returns false when the section is folded.
    @discardableResult
    private func section(_ title: String, count: Int? = nil) -> Bool {
        // Hidden sections aren't built at all.
        if SidebarPrefs.hidden.contains(title) { hiddenNow.append(title); return false }
        sectionStarts.append((title, stack.arrangedSubviews.count))
        let folded = collapsedSections.contains(title)
        let text = title.uppercased() + (count.map { " · \($0)" } ?? "")
        sectionTitles.append(text)
        let h = SidebarHeader(title: text, folded: folded) { [weak self] in self?.toggleSection(title) }
        h.menuProvider = { [weak self] in self?.headerMenu(title) }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(12, after: last) }
        stack.addArrangedSubview(h)
        h.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        stack.setCustomSpacing(4, after: h)
        return !folded
    }

    private func row(symbol: String, text: String, detail: String?, color: NSColor, tooltip: String? = nil,
                     actions: [SidebarRow.Action] = [], wraps: Bool = false, highlighted: Bool = false,
                     menu: (() -> NSMenu?)? = nil, action: (() -> Void)?) {
        let r = SidebarRow(symbol: symbol, text: text, detail: detail, color: color, actions: actions, wraps: wraps, action: action)
        r.highlighted = highlighted
        r.menuProvider = menu
        r.toolTip = tooltip ?? text
        stack.addArrangedSubview(r)
        r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        rowCount += 1
    }
}

/// A clickable section title with a fold arrow.
private final class SidebarHeader: NSView {
    private let action: () -> Void
    let titleText: String
    /// Right-click: move or hide the section.
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    init(title: String, folded: Bool, action: @escaping () -> Void) {
        self.action = action
        titleText = title
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 18))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        let t = GhosttyRuntime.shared.theme
        let chevron = NSImageView(image: NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: nil) ?? NSImage())
        chevron.contentTintColor = t.dim
        chevron.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = t.dim
        for v in [chevron, l] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            l.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 5),
            l.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = folded ? "Show section" : "Hide section"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title + (folded ? ", collapsed" : ", expanded"))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { action() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

final class SidebarRow: NSView {
    struct Action {
        let symbol: String
        let tip: String
        let run: () -> Void
    }
    private let action: (() -> Void)?
    /// The right-click menu (folders: cd, new tab, Finder…).
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() ?? super.menu(for: event) }
    private var hovering = false { didSet { needsDisplay = true; updateHover() } }
    private var tracking: NSTrackingArea?
    private var actionButtons: [NSButton] = []
    private let actions: [Action]
    private var detailLabel: NSTextField?

    init(symbol: String, text: String, detail: String?, color: NSColor, actions: [Action] = [], wraps: Bool = false, action: (() -> Void)?) {
        self.action = action
        self.actions = actions
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        // Hug 24pt; a wrapped label can push it taller.
        let h = heightAnchor.constraint(equalToConstant: 24)
        h.priority = wraps ? .defaultLow : .required
        h.isActive = true
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color.withAlphaComponent(0.8)
        icon.imageScaling = .scaleProportionallyDown
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = color.withAlphaComponent(0.9)
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingMiddle
        if wraps {
            label.maximumNumberOfLines = 3
            label.preferredMaxLayoutWidth = 180
            label.cell?.wraps = true
        }
        let d = NSTextField(labelWithString: detail ?? "")
        detailLabel = d
        d.font = .systemFont(ofSize: 10.5)
        d.textColor = GhosttyRuntime.shared.theme.dim
        d.alignment = .right
        for v in [icon, label, d] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        d.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            d.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            d.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            d.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // Shown on hover, in place of the detail text.
        var x: CGFloat = -6
        for a in actions.reversed() {
            let b = ClosureButton(symbol: a.symbol, tip: a.tip, run: a.run)
            b.contentTintColor = GhosttyRuntime.shared.theme.foreground.withAlphaComponent(0.7)
            b.isHidden = true
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            NSLayoutConstraint.activate([
                b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: x),
                b.centerYAnchor.constraint(equalTo: centerYAnchor),
                b.widthAnchor.constraint(equalToConstant: 16), b.heightAnchor.constraint(equalToConstant: 16),
            ])
            x -= 20
            actionButtons.append(b)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(action == nil ? .staticText : .button)
        setAccessibilityLabel(text + (detail.map { ", " + $0 } ?? ""))
        if !actions.isEmpty {
            setAccessibilityCustomActions(actions.map { a in NSAccessibilityCustomAction(name: a.tip) { a.run(); return true } })
        }
    }

    var actionTips: [String] { actions.map(\.tip) }

    private func updateHover() {
        guard !actions.isEmpty else { return }
        actionButtons.forEach { $0.isHidden = !hovering }
        detailLabel?.isHidden = hovering
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The row for where you are now (drawn with a tinted background).
    var highlighted = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let t = GhosttyRuntime.shared.theme
        if highlighted {
            t.blue.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            return
        }
        guard hovering, action != nil else { return }
        t.foreground.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { if action != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseDown(with event: NSEvent) { action?() }
    override func accessibilityPerformPress() -> Bool { action?(); return action != nil }
}

/// A small borderless symbol button that runs a closure.
final class ClosureButton: NSButton {
    private let run: () -> Void
    init(symbol: String, tip: String, run: @escaping () -> Void) {
        self.run = run
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        isBordered = false
        imageScaling = .scaleProportionallyDown
        toolTip = tip
        setAccessibilityLabel(tip)
        target = self
        action = #selector(fire)
    }
    /// A small push button with a text title.
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 11)
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// Your sidebar order and hidden sections.
enum SidebarPrefs {
    /// Tests keep these in their own store.
    static var defaults: UserDefaults = .standard

    static var order: [String] {
        get { defaults.stringArray(forKey: "sidebarOrder") ?? [] }
        set { defaults.set(newValue, forKey: "sidebarOrder") }
    }

    static var hidden: Set<String> {
        get { Set(defaults.stringArray(forKey: "sidebarHidden") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "sidebarHidden") }
    }

    static func setHidden(_ title: String, _ on: Bool) {
        var h = hidden
        if on { h.insert(title) } else { h.remove(title) }
        hidden = h
    }
}
