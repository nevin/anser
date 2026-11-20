import AppKit
import AnserCore

/// A command failed because its port was taken, and what holds the port.
struct PortBusy {
    let port: Int
    let command: String
    /// What's listening there (nil when Anser can't see it: another user's or the system's).
    var owner: ServerPorts.Listener?
    /// The tab that started it, if one did.
    weak var ownerPane: PaneView?
}

extension PaneView {
    func setUpProcessChips() {
        footer.addSubview(portChip)
        footer.addSubview(heavyChip)
        portChip.onClick = { [weak self] in self?.showPortBusyMenu() }
        heavyChip.onClick = { [weak self] in self?.showHeavyMenu() }
        NotificationCenter.default.addObserver(forName: ProcessMonitor.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBar() }
        }
    }

    /// The process of this tab that's running away, unless you said to leave it.
    var heavyProcess: ProcessMonitor.Item? {
        ProcessMonitor.shared.items(for: self).first { $0.runaway != nil && !heavyIgnored.contains($0.pid) }
    }

    func refreshProcessChips() {
        let t = theme
        let dim = t.foreground.withAlphaComponent(0.55)
        if let b = portBusy {
            let who = b.owner.map { " by \($0.process)" } ?? ""
            portChip.set(role: .problem, symbol: "exclamationmark.triangle", text: ":\(b.port) is taken\(who)",
                         tooltip: b.owner.map { "Port \(b.port) is used by \($0.process) (process \($0.pid))" + (b.ownerPane.map { _ in ", started in another tab" } ?? "") + ".\nClick to stop it and run your command again." }
                            ?? "Port \(b.port) is in use, by something Anser can't see (another user's or the system's).\nClick for options.",
                         filled: true, theme: t)
        } else {
            portChip.filled = nil
            portChip.set(symbol: nil, text: "", color: dim)
        }
        if let h = heavyProcess {
            let what = h.runaway == .memory ? ProcessScan.formatMemory(h.memory) : "\(Int(h.cpu.rounded()))% CPU"
            heavyChip.set(role: .waiting, symbol: "flame", text: "\(h.name) · \(what)",
                          tooltip: h.tooltip + "\nClick to stop it or leave it be", filled: false, theme: t)
        } else {
            heavyChip.filled = nil
            heavyChip.set(symbol: nil, text: "", color: dim)
        }
    }

    // MARK: Port already in use

    /// After a failed command: did it fail because its port was taken? Then find what has it.
    func checkPortInUse(_ b: ShellSession.Block, output: String) {
        guard (b.exitCode ?? 0) != 0, !session.isRemote, let port = PortConflict.port(output: String(output.suffix(20_000)), command: b.command) else { return }
        let command = b.command
        Task { @MainActor [weak self] in
            let out = await ScriptRunner.shared.run(argv: ["/usr/sbin/lsof", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"], cwd: "/",
                                                    env: ShellEnvironment(), timeout: 3) ?? ""
            guard let self, self.session.lastFinished?.id == b.id else { return }
            let owner = ServerPorts.parseLsof(out).first { $0.port == port }
            let ownerPane = owner.flatMap { o in
                AppDelegate.shared.allPanes.first { p in ProcessMonitor.shared.items(for: p).contains { $0.pid == o.pid } }
            }
            self.portBusy = PortBusy(port: port, command: command, owner: owner, ownerPane: ownerPane)
            Services.shared.record("port.busy")
            self.refreshBar()
        }
    }

    func showPortBusyMenu() {
        guard let b = portBusy else { return }
        let m = NSMenu()
        if let o = b.owner, ProcessMonitor.canStop(o.pid) {
            m.addItem(ClosureMenuItem(title: "Stop \(o.process) and Run Again") { [weak self] in self?.freePortAndRetry(b, rerun: true) })
            m.addItem(ClosureMenuItem(title: "Stop \(o.process)") { [weak self] in self?.freePortAndRetry(b, rerun: false) })
        } else if let o = b.owner {
            let i = NSMenuItem(title: "\(o.process) isn't yours to stop", action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        if let p = b.ownerPane, p !== self {
            m.addItem(ClosureMenuItem(title: "Show the Tab Running It") { _ = AppDelegate.shared.reveal(sessionID: p.session.id) })
        }
        if let o = b.owner {
            m.addItem(ClosureMenuItem(title: "Open \(o.url)") { if let u = URL(string: o.url) { NSWorkspace.shared.open(u) } })
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Dismiss") { [weak self] in self?.portBusy = nil; self?.refreshBar() })
        m.popUp(positioning: nil, at: NSPoint(x: portChip.frame.minX, y: portChip.frame.maxY + 2), in: footer)
    }

    /// Stops what holds the port; then runs the command again once the port is free.
    func freePortAndRetry(_ b: PortBusy, rerun: Bool) {
        guard let o = b.owner else { return }
        portBusy = nil
        refreshBar()
        flash("Stopping \(o.process) on port \(b.port)…")
        ProcessMonitor.stop([o.pid]) { [weak self] in
            guard let self else { return }
            Services.shared.record(rerun ? "port.retry" : "port.stop")
            guard rerun else { self.flash("Port \(b.port) is free"); return }
            guard self.session.atPrompt else { self.flash("Port \(b.port) is free. Run your command when this tab is at a prompt."); return }
            self.submitFromEditor(b.command)
        }
    }

    // MARK: Runaway processes

    func showHeavyMenu() {
        guard let h = heavyProcess else { return }
        let m = ProcessMonitor.menu(for: h, pane: nil, over: window)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Leave It Running") { [weak self] in
            self?.heavyIgnored.insert(h.pid)
            self?.refreshBar()
        })
        m.popUp(positioning: nil, at: NSPoint(x: heavyChip.frame.minX, y: heavyChip.frame.maxY + 2), in: footer)
    }
}
