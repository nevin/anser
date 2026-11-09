import AppKit
import AnserCore

extension PaneView {
    // MARK: "Last time this failed, you ran…"

    /// After a failure, looks for what you ran last time this exact command failed and then worked.
    func checkFixHint(_ b: ShellSession.Block) {
        guard (b.exitCode ?? 0) != 0, (b.exitCode ?? 0) != 130, !b.command.isEmpty, session.running == nil else { return }
        let cmd = b.command
        let id = b.historyID
        let history = Services.shared.history
        Task { @MainActor [weak self] in
            let steps = await Task.detached(priority: .utility) { history.fixAfterFailure(of: cmd, excludingID: id) }.value
            guard let self, let steps, self.session.atPrompt, self.session.lastFinished?.id == b.id else { return }
            self.fixHint = (cmd, steps)
            Services.shared.record("fixhint.shown")
            self.refreshBar()
        }
    }

    func refreshFixAndForwardChips() {
        let t = theme
        let dim = t.foreground.withAlphaComponent(0.55)
        if let h = fixHint, session.atPrompt {
            hintChip.filled = ChipRole.suggestion.color(t)
            let first = h.steps.first ?? ""
            hintChip.set(symbol: "clock.arrow.circlepath", text: "Last time: " + String(first.prefix(36)) + (h.steps.count > 1 ? " +\(h.steps.count - 1)" : ""),
                         color: t.green, tooltip: "The last time “\(h.command)” failed, you fixed it with:\n" + h.steps.map { "  " + $0 }.joined(separator: "\n") + "\nClick to run or edit")
        } else {
            hintChip.filled = nil
            hintChip.set(symbol: nil, text: "", color: dim)
        }
        // Forwards end with the ssh session.
        if !session.isRemote, !forwardedPorts.isEmpty || !remotePortsSeen.isEmpty { stopForwards(); remotePortsSeen = []; dismissedRemotePorts = [] }
        let offered = remotePortsSeen.filter { forwardedPorts[$0] == nil && !dismissedRemotePorts.contains($0) }
        if let p = offered.first, session.isRemote {
            forwardChip.filled = ChipRole.suggestion.color(t)
            forwardChip.set(symbol: "arrow.down.left.circle", text: "Open :\(p) on this Mac", color: ChipRole.suggestion.color(t),
                            tooltip: "A program on \(session.remoteHost ?? "the server") is listening on port \(p).\nClick to forward it through ssh and open it here.")
        } else if !forwardedPorts.isEmpty {
            let list = forwardedPorts.sorted { $0.key < $1.key }
            forwardChip.filled = nil
            forwardChip.set(symbol: "arrow.down.left.circle.fill", text: list.map { "localhost:\($0.value.localPort)" }.joined(separator: ", "), color: ChipRole.info.color(t),
                            tooltip: list.map { "localhost:\($0.value.localPort) → port \($0.key) on \(session.remoteHost ?? "the server")" }.joined(separator: "\n") + "\nClick to open, copy or stop")
        } else {
            forwardChip.filled = nil
            forwardChip.set(symbol: nil, text: "", color: dim)
        }
    }

    func showFixHintMenu() {
        guard let h = fixHint else { return }
        let m = NSMenu()
        let all = h.steps.joined(separator: " && ")
        if h.steps.count == 1 {
            m.addItem(ClosureMenuItem(title: "Run “\(h.steps[0].prefix(50))”") { [weak self] in self?.runFixHint(h.steps[0]) })
        } else {
            m.addItem(ClosureMenuItem(title: "Run Them All, Then Retry") { [weak self] in self?.runFixHint(all + " && " + h.command) })
            for s in h.steps { m.addItem(ClosureMenuItem(title: "Run “\(s.prefix(50))”") { [weak self] in self?.runFixHint(s) }) }
        }
        m.addItem(ClosureMenuItem(title: "Put in Editor") { [weak self] in self?.insertIntoEditor(all); self?.fixHint = nil; self?.refreshBar() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Hide") { [weak self] in self?.fixHint = nil; self?.refreshBar() })
        m.popUp(positioning: nil, at: NSPoint(x: hintChip.frame.minX, y: hintChip.frame.maxY + 2), in: bar)
    }

    private func runFixHint(_ cmd: String) {
        guard session.atPrompt else { NSSound.beep(); return }
        Services.shared.record("fixhint.run")
        fixHint = nil
        submitFromEditor(cmd)
    }

    // MARK: Forwarding a server port from an ssh tab

    /// While something runs in an ssh tab: did it announce a port (http://localhost:3000, "listening on 8080")?
    func checkRemotePorts() {
        guard session.isRemote, session.running != nil, sshCopyTarget != nil, let screen = surfaceView.viewportText() else { return }
        let ports = ServerPorts.announcedPorts(in: screen).filter { $0 >= 1024 && !remotePortsSeen.contains($0) }
        guard !ports.isEmpty else { return }
        remotePortsSeen += ports
        Services.shared.record("forward.offered")
        refreshBar()
    }

    func showForwardMenu() {
        let m = NSMenu()
        for p in remotePortsSeen where forwardedPorts[p] == nil && !dismissedRemotePorts.contains(p) {
            m.addItem(ClosureMenuItem(title: "Forward Port \(p) and Open It") { [weak self] in self?.forward(remotePort: p, open: true) })
            m.addItem(ClosureMenuItem(title: "Not Port \(p)") { [weak self] in self?.dismissedRemotePorts.insert(p); self?.refreshBar() })
        }
        for (p, t) in forwardedPorts.sorted(by: { $0.key < $1.key }) {
            if m.numberOfItems > 0 { m.addItem(.separator()) }
            m.addItem(ClosureMenuItem(title: "Open http://localhost:\(t.localPort)") { if let u = URL(string: "http://localhost:\(t.localPort)") { NSWorkspace.shared.open(u) } })
            m.addItem(ClosureMenuItem(title: "Copy localhost:\(t.localPort)") { TerminalWindowController.copy("localhost:\(t.localPort)") })
            m.addItem(ClosureMenuItem(title: "Stop Forwarding Port \(p)") { [weak self] in
                TunnelManager.shared.stop(t)
                self?.forwardedPorts[p] = nil
                self?.refreshBar()
            })
        }
        guard m.numberOfItems > 0 else { return }
        m.popUp(positioning: nil, at: NSPoint(x: forwardChip.frame.minX, y: forwardChip.frame.maxY + 2), in: bar)
    }

    /// Shell → Open a Server Port on This Mac…
    func promptForwardPort() {
        guard session.isRemote, sshCopyTarget != nil, let w = window else { flash("Connect with ssh first: this forwards a port from the server you're on"); return }
        let a = NSAlert()
        a.messageText = "Open a port from \(session.remoteHost ?? "the server") on this Mac"
        a.informativeText = "Forwards it through ssh, so http://localhost:PORT here reaches it there."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        f.placeholderString = "e.g. 3000"
        f.stringValue = remotePortsSeen.first.map(String.init) ?? ""
        a.accessoryView = f
        a.window.initialFirstResponder = f
        a.addButton(withTitle: "Forward")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let p = Int(f.stringValue.trimmingCharacters(in: .whitespaces)), (1...65535).contains(p) else { return }
            self?.forward(remotePort: p, open: true)
        }
    }

    func forward(remotePort p: Int, open: Bool) {
        guard let (opts, target) = sshCopyTarget else { return }
        guard let local = Self.freeLocalPort(near: p) else { flash("No free port on this Mac near \(p)"); return }
        let t = SSHTunnel(name: "\(session.remoteHost ?? target):\(p)", host: target, localPort: local, remoteHost: "localhost", remotePort: p, options: opts)
        TunnelManager.shared.start(t)
        forwardedPorts[p] = t
        Services.shared.record("forward.start")
        refreshBar()
        guard open else { return }
        flash("Forwarding port \(p) to localhost:\(local)…")
        // Open once the tunnel is up (or say why not).
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                switch TunnelManager.shared.state(t) {
                case .up:
                    if !Services.isSelfTest, let u = URL(string: "http://localhost:\(local)") { NSWorkspace.shared.open(u) }
                    return
                case .failed(let why), .retrying(_, let why):
                    self?.flash("Couldn't forward port \(p): \(why.prefix(90))")
                    return
                default: continue
                }
            }
        }
    }

    func stopForwards() {
        for t in forwardedPorts.values { TunnelManager.shared.stop(t) }
        forwardedPorts = [:]
    }

    /// `port` if nothing on this Mac uses it, else the next free one.
    static func freeLocalPort(near port: Int) -> Int? {
        for p in port..<min(65535, port + 50) where isFree(p) { return p }
        return nil
    }

    static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}
