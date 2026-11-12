import AppKit
import AnserCore

/// A dropped ssh session Anser is reconnecting (or offering to).
final class ReconnectState {
    let command: String
    let auto: Bool
    var attempt = 0
    var timer: Timer?
    var fireAt: Date?
    /// Anser just ran the reconnect command and is waiting to see if it holds.
    var attemptRunning = false
    var gaveUp = false
    init(command: String, auto: Bool) { self.command = command; self.auto = auto }
}

extension PaneView {
    // MARK: Chips

    func setUpLiveChips() {
        waitChip.onClick = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.surfaceView)
            self.flash("Type your answer in the terminal")
        }
        serverChip.onClick = { [weak self] in self?.showServerMenu() }
        contextChip.onClick = { [weak self] in self?.showContextMenu() }
        reconnectChip.onClick = { [weak self] in self?.showReconnectMenu() }
        setUpRunToolChips()
        NotificationCenter.default.addObserver(forName: ServerMonitor.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBar() }
        }
    }

    func refreshLiveChips() {
        let t = theme
        let dim = t.foreground.withAlphaComponent(0.55)
        if let w = waitState {
            waitChip.filled = NSColor.systemOrange
            let label: String
            switch w.kind {
            case .confirm: label = "waiting for y/n"
            case .password: label = "waiting for password"
            case .agent: label = "agent needs approval"
            case .keypress: label = "press a key"
            case .question: label = "waiting for you"
            }
            waitChip.set(symbol: "hand.raised.fill", text: label, color: .systemOrange,
                         tooltip: w.title + ":\n" + w.line + "\nClick to type your answer in the terminal.")
        } else {
            waitChip.filled = nil
            waitChip.set(symbol: nil, text: "", color: dim)
        }
        let servers = Services.shared.config.serverChips ? ServerMonitor.shared.servers(for: self) : []
        if let first = servers.first {
            let more = servers.count > 1 ? " +\(servers.count - 1)" : ""
            serverChip.set(symbol: "server.rack", text: ":\(first.port)\(more)", color: ChipRole.info.color(t),
                           tooltip: servers.map { "\($0.process) on port \($0.port)" }.joined(separator: "\n") + "\nClick to open, copy the link or stop it")
        } else {
            serverChip.set(symbol: nil, text: "", color: dim)
        }
        if let r = reconnect {
            reconnectChip.filled = NSColor.systemOrange
            let text: String
            if r.attemptRunning { text = "reconnecting…" }
            else if r.gaveUp || !r.auto || r.fireAt == nil { text = "connection lost · Reconnect" }
            else { text = "reconnecting in \(max(0, Int(ceil(r.fireAt!.timeIntervalSinceNow))))s" }
            reconnectChip.set(symbol: "arrow.clockwise", text: text, color: .systemOrange,
                              tooltip: "The ssh connection dropped.\n\(r.command)\nClick for options")
        } else {
            reconnectChip.filled = nil
            reconnectChip.set(symbol: nil, text: "", color: dim)
        }
        refreshContextChip(layout: false)
        refreshRunToolChips()
        refreshPluginChips()
    }

    // MARK: Waiting for you

    /// Every second while a command runs: once the screen has stopped
    /// changing, does the last line ask for something?
    func checkWaiting() {
        guard Services.shared.config.waitAlerts, session.running != nil else { return }
        let screen = surfaceView.viewportText() ?? ""
        if screen != waitScreen {
            waitScreen = screen
            waitScreenChangedAt = Date()
            waitScreenChecked = false
            if waitState != nil, InputWait.detect(screen: screen) == nil { clearWaiting() }
            return
        }
        let quiet = Date().timeIntervalSince(waitScreenChangedAt)
        guard waitState == nil, quiet >= 1.5, !waitScreenChecked else { return }
        // After 4 quiet seconds the answer for this screen can't change: don't look again until it does.
        if quiet >= 4 { waitScreenChecked = true }
        guard let w = InputWait.detect(screen: screen) else { return }
        // Plain questions need a longer pause; full-screen programs only count for clear prompts.
        if w.kind == .question, quiet < 4 || fullscreenProgram { return }
        if fullscreenProgram, w.kind == .keypress { return }
        waitState = w
        Services.shared.record("wait." + w.kind.rawValue)
        Diagnostics.shared.log("waiting for input: \(w.kind.rawValue)")
        windowController?.paneActivityChanged(self, finished: false, failed: false)
        refreshBar()
        if !sessionIsVisible {
            let tab = windowController.flatMap { wc in wc.tab(for: self).map { wc.title(of: $0) } } ?? "Anser"
            Services.shared.notifyWaiting(w, tab: tab, sessionID: session.id)
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    func clearWaiting() {
        guard waitState != nil else { return }
        waitState = nil
        windowController?.paneActivityChanged(self, finished: false, failed: false)
        refreshBar()
    }

    // MARK: Servers

    func showServerMenu() {
        let servers = ServerMonitor.shared.servers(for: self)
        guard !servers.isEmpty else { return }
        let m: NSMenu
        if servers.count == 1 {
            m = ServerMonitor.menu(for: servers[0], pane: self)
        } else {
            m = NSMenu()
            for s in servers {
                let i = NSMenuItem(title: "\(s.process) · port \(s.port)", action: nil, keyEquivalent: "")
                i.submenu = ServerMonitor.menu(for: s, pane: self)
                m.addItem(i)
            }
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Kill Process on Port…") { [weak self] in ServerMonitor.promptKillPort(in: self?.window, pane: self) })
        m.popUp(positioning: nil, at: NSPoint(x: serverChip.bounds.minX, y: serverChip.bounds.maxY + 4), in: serverChip)
    }

    // MARK: Cloud context

    func cloudContext() -> CloudContext {
        let vars = session.cloudVars
        if let c = cloudCache, c.vars == vars, Date().timeIntervalSince(c.at) < 3 { return c.ctx }
        let ctx = CloudContext.current(vars: vars)
        cloudCache = (Date(), vars, ctx)
        return ctx
    }

    /// The profile for the current cloud context, when `command` uses that service.
    func contextProfile(for command: String) -> Profile? {
        let cfg = Services.shared.config
        guard !session.isRemote, cfg.profiles.contains(where: { $0.kubeContext != nil || $0.awsProfile != nil }) else { return nil }
        let tools = CloudContext.tools(in: command)
        guard let p = Profile.resolve(cfg.profiles, context: cloudContext()) else { return nil }
        if p.kubeContext != nil, tools.contains("kube") { return p }
        if p.awsProfile != nil, tools.contains("aws") { return p }
        return nil
    }

    func refreshContextChip(layout: Bool = true) {
        let cfg = Services.shared.config
        let t = theme
        func hide() {
            guard !contextChip.text.isEmpty else { return }
            contextChip.filled = nil
            contextChip.set(symbol: nil, text: "", color: t.dim)
            if layout { needsLayout = true }
        }
        guard cfg.showCloudContext != "off", !session.isRemote else { hide(); return }
        let typed = editor.string
        var show = CloudContext.tools(in: typed)
        if show.isEmpty, typed.isEmpty, let last = session.running?.command ?? session.lastBlockInContext?.command { show = CloudContext.tools(in: last) }
        if cfg.showCloudContext == "always" { show = ["kube", "aws", "gcloud", "docker"] }
        // Without a reason to look, skip reading kubeconfig at all.
        let hasContextProfiles = cfg.profiles.contains { $0.kubeContext != nil || $0.awsProfile != nil }
        guard !show.isEmpty || hasContextProfiles else { hide(); return }
        let ctx = cloudContext()
        guard !ctx.isEmpty else { hide(); return }
        let matched = Profile.resolve(cfg.profiles, context: ctx)
        if let m = matched {
            if m.kubeContext != nil { show.insert("kube") }
            if m.awsProfile != nil { show.insert("aws") }
        }
        let text = ctx.summary(showing: show)
        guard !text.isEmpty else { hide(); return }
        let before = contextChip.text
        if let m = matched {
            let c = TabBarView.color(m.tabColor) ?? t.red
            contextChip.filled = c
            contextChip.set(symbol: "exclamationmark.icloud", text: (m.badge.map { $0 + " · " } ?? "") + text, color: c,
                            tooltip: "Commands here talk to \(text)\(m.name.map { " (profile “\($0)”)" } ?? "").\nClick to switch")
        } else {
            contextChip.filled = nil
            contextChip.set(symbol: "cloud", text: text, color: t.cyan.withAlphaComponent(0.9),
                            tooltip: "Commands here talk to \(text).\nClick to switch")
        }
        if layout, before != contextChip.text { needsLayout = true }
    }

    func showContextMenu() {
        let m = NSMenu()
        let ctx = cloudContext()
        let vars = session.cloudVars
        func runOrInsert(_ cmd: String) {
            if session.atPrompt { run(cmd) } else { flash("Wait for the running command to finish") }
            cloudCache = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.cloudCache = nil; self?.refreshBar() }
        }
        let kube = CloudContext.kubeContextNames(vars: vars)
        if !kube.isEmpty {
            let i = NSMenuItem(title: "Kubernetes Context", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for k in kube {
                let item = ClosureMenuItem(title: k) { runOrInsert("kubectl config use-context \(ShellLexer.escape(k))") }
                item.state = k == ctx.kube ? .on : .off
                sub.addItem(item)
            }
            i.submenu = sub
            m.addItem(i)
        }
        let aws = CloudContext.awsProfiles()
        if !aws.isEmpty {
            let i = NSMenuItem(title: "AWS Profile", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for a in aws {
                let item = ClosureMenuItem(title: a) { runOrInsert("export AWS_PROFILE=\(ShellLexer.escape(a))") }
                item.state = a == ctx.aws ? .on : .off
                sub.addItem(item)
            }
            if ctx.aws != nil {
                sub.addItem(.separator())
                sub.addItem(ClosureMenuItem(title: "Use the Default Profile") { runOrInsert("unset AWS_PROFILE") })
            }
            i.submenu = sub
            m.addItem(i)
        }
        if m.items.count > 0 { m.addItem(.separator()) }
        m.addItem(ClosureMenuItem(title: "Copy “\(ctx.summary(showing: ["kube", "aws", "gcloud", "docker"]))”") {
            TerminalWindowController.copy(ctx.summary(showing: ["kube", "aws", "gcloud", "docker"]))
        })
        m.addItem(ClosureMenuItem(title: "Profiles for Contexts…") { SettingsWindowController.shared.show(section: "Profiles") })
        m.popUp(positioning: nil, at: NSPoint(x: contextChip.bounds.minX, y: contextChip.bounds.maxY + 4), in: contextChip)
    }

    // MARK: ssh reconnect

    func commandStartedForReconnect(_ command: String) {
        guard let r = reconnect else { return }
        if r.attemptRunning { refreshBar(); return }
        // You ran something else: stop trying.
        r.timer?.invalidate()
        reconnect = nil
    }

    func handleCommandFinishedForReconnect() {
        guard session.running == nil, let last = session.lastFinished, !session.isRemote else { return }
        if let r = reconnect, r.attemptRunning {
            r.attemptRunning = false
            if last.exitCode == 255, (last.duration ?? 0) < 8 {
                // Still can't connect.
                if r.attempt >= SSHReconnect.maxAttempts || !r.auto { r.gaveUp = true; r.fireAt = nil } else { scheduleReconnect() }
                refreshBar()
                return
            }
            if SSHReconnect.shouldOffer(command: r.command, exitCode: last.exitCode, duration: last.duration) {
                r.attempt = 0
                r.gaveUp = false
                if r.auto { scheduleReconnect() }
            } else {
                reconnect = nil
            }
            refreshBar()
            return
        }
        guard SSHReconnect.shouldOffer(command: last.command, exitCode: last.exitCode, duration: last.duration) else { return }
        let r = ReconnectState(command: last.command, auto: Services.shared.config.sshAutoReconnect)
        reconnect = r
        Services.shared.record("ssh.dropped")
        if r.auto { scheduleReconnect() }
        refreshBar()
    }

    func scheduleReconnect() {
        guard let r = reconnect else { return }
        r.attempt += 1
        r.gaveUp = false
        r.fireAt = Date().addingTimeInterval(SSHReconnect.delay(attempt: r.attempt))
        r.timer?.invalidate()
        r.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak r] tm in
            guard let self, let r, let at = r.fireAt else { tm.invalidate(); return }
            if Date() >= at { tm.invalidate(); self.reconnectNow() } else { self.refreshBar() }
        }
        r.timer?.tolerance = 0.2
    }

    func reconnectNow() {
        guard let r = reconnect else { return }
        r.timer?.invalidate()
        r.fireAt = nil
        NetworkWatch.shared.whenOnline { [weak self, weak r] in
            guard let self, let r, self.reconnect === r else { return }
            guard self.session.atPrompt, self.session.running == nil else { return }
            let cmd = SSHReconnect.reconnectCommand(r.command)
            if cmd != r.command { self.session.historyAliases[cmd] = r.command }
            r.attemptRunning = true
            Services.shared.record("ssh.reconnect")
            self.run(cmd)
            self.refreshBar()
        }
        if !NetworkWatch.shared.online { flash("Waiting for the network to come back…") }
        refreshBar()
    }

    func showReconnectMenu() {
        guard let r = reconnect else { return }
        if r.gaveUp || !r.auto, !r.attemptRunning { reconnectNow(); return }
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "Reconnect Now") { [weak self] in self?.reconnectNow() })
        m.addItem(ClosureMenuItem(title: "Stop Reconnecting") { [weak self] in
            self?.reconnect?.timer?.invalidate()
            self?.reconnect = nil
            self?.refreshBar()
        })
        m.popUp(positioning: nil, at: NSPoint(x: reconnectChip.bounds.minX, y: reconnectChip.bounds.maxY + 4), in: reconnectChip)
    }

    // MARK: Secrets

    /// Fills in `{{secret:…}}` and `{{op://…}}` just before running. Returns nil
    /// (and runs nothing yet) when a secret has to be added first.
    func fillSecrets(_ command: String) -> String? {
        let names = SecretRefs.keychainNames(command)
        if session.isRemote, !names.isEmpty {
            flash("Keychain secrets work in local shells; on servers use {{op://…}} with 1Password's op tool")
            editor.setCommand(command)
            return nil
        }
        if let missing = names.first(where: { SecretBroker.get($0) == nil }) {
            promptForSecret(missing) { [weak self] ok in
                guard let self else { return }
                if ok { self.run(command) } else { self.editor.setCommand(command); self.focus() }
            }
            return nil
        }
        guard let filled = SecretRefs.rewrite(command, keychainCode: SecretBroker.code(for:)) else {
            flash("Couldn't read a secret from the Keychain")
            return nil
        }
        session.historyAliases[filled] = command
        Services.shared.record("secret.use")
        return filled
    }

    func promptForSecret(_ name: String, done: @escaping (Bool) -> Void) {
        SecretsWindowController.askForValue(name: name, in: window, done: done)
    }
}
