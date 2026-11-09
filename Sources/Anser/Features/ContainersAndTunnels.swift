import AppKit
import AnserCore

/// Docker containers (checked when the sidebar refreshes, at most every few
/// seconds) and Kubernetes pods (only when you ask: a cluster may be remote).
final class ContainerMonitor {
    static let shared = ContainerMonitor()
    static let changed = Notification.Name("AnserContainersChanged")

    private(set) var containers: [Containers.Container] = []
    private(set) var dockerAvailable = false
    private var lastDocker = Date.distantPast
    private var dockerBusy = false

    struct PodList { var context: String; var pods: [Containers.Pod]; var error: String?; var at: Date }
    /// Pods per kube context, once you've loaded them.
    private(set) var pods: [String: PodList] = [:]
    private var podsBusy: Set<String> = []
    /// Tests fill these instead of running docker/kubectl.
    var testContainers: [Containers.Container]?

    func refreshDocker(env: ShellEnvironment, force: Bool = false) {
        if let t = testContainers { containers = t; dockerAvailable = true; return }
        guard !dockerBusy, force || Date().timeIntervalSince(lastDocker) > 8 else { return }
        guard CommandIndex.shared.contains("docker", env: env) else { dockerAvailable = false; containers = []; return }
        dockerBusy = true
        lastDocker = Date()
        Task { @MainActor in
            let out = await ScriptRunner.shared.run(argv: Containers.dockerListCommand, cwd: NSHomeDirectory(), env: env, timeout: 3) ?? ""
            self.dockerBusy = false
            // A stopped Docker daemon prints an error, not JSON.
            let list = Containers.parseDocker(out)
            let available = out.contains("{") || out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard list != self.containers || available != self.dockerAvailable else { return }
            self.containers = list
            self.dockerAvailable = available
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    func loadPods(context: String, env: ShellEnvironment, extra: [String: String]) {
        guard !podsBusy.contains(context) else { return }
        podsBusy.insert(context)
        Task { @MainActor in
            let out = await ScriptRunner.shared.run(argv: ["kubectl", "get", "pods", "-o", "json", "--request-timeout=8s"], cwd: NSHomeDirectory(), env: env, extra: extra, timeout: 10) ?? ""
            self.podsBusy.remove(context)
            if let list = Containers.parsePods(out) {
                self.pods[context] = PodList(context: context, pods: list, error: nil, at: Date())
            } else {
                let err = out.split(separator: "\n").last.map(String.init) ?? "kubectl didn't answer"
                self.pods[context] = PodList(context: context, pods: [], error: String(err.prefix(140)), at: Date())
            }
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    func isLoadingPods(_ context: String) -> Bool { podsBusy.contains(context) }
    func forgetPods(_ context: String) { pods[context] = nil }

    /// Runs a quick docker command (restart, stop) in the background, then refreshes.
    func docker(_ args: [String], env: ShellEnvironment, done: @escaping (String) -> Void) {
        Task { @MainActor in
            let out = await ScriptRunner.shared.run(argv: ["docker"] + args, cwd: NSHomeDirectory(), env: env, timeout: 30) ?? ""
            done(out.trimmingCharacters(in: .whitespacesAndNewlines))
            self.refreshDocker(env: env, force: true)
        }
    }
}

/// Keeps ssh tunnels (Settings → tunnels in config.json) open in the background, reconnecting when they drop.
final class TunnelManager {
    static let shared = TunnelManager()
    static let changed = Notification.Name("AnserTunnelsChanged")

    enum State: Equatable { case stopped, starting, up(Date), retrying(Date, String), failed(String) }

    private final class Running {
        let tunnel: SSHTunnel
        var process: Process?
        var wanted = true
        var attempts = 0
        var state: State = .starting
        var lastOutput = ""
        var timer: Timer?
        init(_ t: SSHTunnel) { tunnel = t }
    }

    private var running: [String: Running] = [:]

    var tunnels: [SSHTunnel] { Services.shared.config.tunnels }

    func state(_ t: SSHTunnel) -> State { running[t.id]?.state ?? .stopped }

    func isOn(_ t: SSHTunnel) -> Bool { running[t.id]?.wanted == true }

    func startAutomatic() {
        for t in tunnels where t.autoStart == true && t.problem == nil { start(t) }
    }

    func toggle(_ t: SSHTunnel) { isOn(t) ? stop(t) : start(t) }

    func start(_ t: SSHTunnel) {
        guard t.problem == nil else { return }
        let r = running[t.id] ?? Running(t)
        r.wanted = true
        r.attempts = 0
        running[t.id] = r
        launch(r)
    }

    func stop(_ t: SSHTunnel) {
        guard let r = running[t.id] else { return }
        r.wanted = false
        r.timer?.invalidate()
        r.process?.terminate()
        running[t.id] = nil
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func stopAll() {
        for r in running.values { r.wanted = false; r.timer?.invalidate(); r.process?.terminate() }
        running = [:]
    }

    private func launch(_ r: Running) {
        r.state = .starting
        NotificationCenter.default.post(name: Self.changed, object: nil)
        let argv = r.tunnel.argv()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { r.lastOutput = String((r.lastOutput + s).suffix(600)) }
        }
        let started = Date()
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.ended(r, status: proc.terminationStatus, after: Date().timeIntervalSince(started))
            }
        }
        do {
            try p.run()
            r.process = p
            Diagnostics.shared.log("tunnel start: :\(r.tunnel.localPort)")
            // Still running after a moment: the forward is up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard r.process === p, p.isRunning else { return }
                r.state = .up(Date())
                r.attempts = 0
                self.map { _ in NotificationCenter.default.post(name: Self.changed, object: nil) }
            }
        } catch {
            r.state = .failed(error.localizedDescription)
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    private func ended(_ r: Running, status: Int32, after seconds: TimeInterval) {
        guard r.wanted, running[r.tunnel.id] === r else { return }
        let last = r.lastOutput.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ssh exited (\(status))"
        Diagnostics.shared.log("tunnel ended: :\(r.tunnel.localPort) status=\(status)")
        // Fails straight away twice (wrong host, no key, port taken): stop and say why.
        if seconds < 3 { r.attempts += 1 }
        let needsLogin = last.contains("Permission denied") || last.contains("Host key verification failed")
        if needsLogin || r.attempts >= 3 {
            r.state = .failed(needsLogin ? "ssh needs a key or ssh-agent for background tunnels (\(last))" : last)
            r.wanted = false
            NotificationCenter.default.post(name: Self.changed, object: nil)
            return
        }
        let delay = min(30, pow(2, Double(max(1, r.attempts))))
        r.state = .retrying(Date().addingTimeInterval(delay), last)
        NotificationCenter.default.post(name: Self.changed, object: nil)
        r.timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard r.wanted else { return }
            self?.launch(r)
        }
    }

    // MARK: Editing

    func save(_ list: [SSHTunnel]) {
        let enc = JSONEncoder()
        let arr = list.compactMap { t -> Any? in (try? enc.encode(t)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
        SettingsWindowController.setValue(["tunnels"], arr.isEmpty ? nil : arr)
    }

    /// A form to add (or change) a tunnel, checked as you type.
    func form(_ existing: SSHTunnel?) -> FormSheet {
        let f = FormSheet(title: existing == nil ? "Add an SSH tunnel" : "Edit tunnel",
                          message: "Forwards a port on this Mac to a host the server can reach, and keeps it open. It runs in the background, so the server must accept your key or ssh-agent.",
                          fields: [
                            .init("name", "Name", .text(placeholder: "e.g. Staging database", mono: false), value: existing?.name ?? ""),
                            .init("host", "SSH host", .combo(options: SSHConfig.load().map(\.alias), placeholder: "from ~/.ssh/config, or user@host"), value: existing?.host ?? ""),
                            .init("local", "Local port", .text(placeholder: "e.g. 5433", mono: true), value: existing.map { String($0.localPort) } ?? ""),
                            .init("remoteHost", "Remote host", .text(placeholder: "as the server sees it", mono: true), value: existing?.remoteHost ?? "localhost"),
                            .init("remotePort", "Remote port", .text(placeholder: "e.g. 5432", mono: true), value: existing.map { String($0.remotePort) } ?? ""),
                            .init("auto", "", .check(title: "Open when Anser starts"), value: existing?.autoStart == true ? "1" : ""),
                          ], ok: existing == nil ? "Add" : "Save")
        func tunnel(_ v: [String: String]) -> SSHTunnel {
            SSHTunnel(name: v["name", default: ""].trimmingCharacters(in: .whitespaces), host: v["host", default: ""].trimmingCharacters(in: .whitespaces),
                      localPort: Int(v["local", default: ""].trimmingCharacters(in: .whitespaces)) ?? 0,
                      remoteHost: v["remoteHost", default: ""].trimmingCharacters(in: .whitespaces),
                      remotePort: Int(v["remotePort", default: ""].trimmingCharacters(in: .whitespaces)) ?? 0,
                      autoStart: v["auto"] == "1" ? true : nil)
        }
        f.validate = { v in
            let t = tunnel(v)
            if let p = t.problem { return p }
            if t.id != existing?.id, self.tunnels.contains(where: { $0.localPort == t.localPort }) { return "Another tunnel already uses local port \(t.localPort)." }
            return nil
        }
        f.warn = { v in
            let t = tunnel(v)
            guard t.localPort > 0, t.id != existing?.id, !PaneView.isFree(t.localPort) else { return nil }
            return "Something on this Mac already listens on port \(t.localPort)."
        }
        f.preview = { v in
            let t = tunnel(v)
            guard t.problem == nil else { return nil }
            return "localhost:\(t.localPort) → \(t.remoteHost):\(t.remotePort) through \(t.host)\n" + t.argv(ssh: "ssh").joined(separator: " ")
        }
        return f
    }

    func edit(_ existing: SSHTunnel?, over window: NSWindow?) {
        let f = form(existing)
        f.present(over: window, focus: existing == nil ? "host" : "name") { [weak self] v in
            guard let self, let v else { return }
            let t = SSHTunnel(name: v["name", default: ""].trimmingCharacters(in: .whitespaces), host: v["host", default: ""].trimmingCharacters(in: .whitespaces),
                              localPort: Int(v["local", default: ""].trimmingCharacters(in: .whitespaces)) ?? 0,
                              remoteHost: v["remoteHost", default: ""].trimmingCharacters(in: .whitespaces),
                              remotePort: Int(v["remotePort", default: ""].trimmingCharacters(in: .whitespaces)) ?? 0,
                              autoStart: v["auto"] == "1" ? true : nil)
            guard t.problem == nil else { return }
            var list = self.tunnels
            if let existing, let i = list.firstIndex(of: existing) { self.stop(existing); list[i] = t } else { list.append(t) }
            self.save(list)
            Services.shared.record("tunnel.add")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.start(t) }
        }
    }

    func remove(_ t: SSHTunnel) {
        stop(t)
        save(tunnels.filter { $0 != t })
    }

    func menu(for t: SSHTunnel, pane: PaneView?) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: isOn(t) ? "Close Tunnel" : "Open Tunnel") { [weak self] in self?.toggle(t) })
        m.addItem(ClosureMenuItem(title: "Open in Terminal (can ask for a password)") {
            AppDelegate.shared.openTab(cwd: nil, run: t.argv(ssh: "ssh", interactive: true).map { ShellLexer.escape($0) }.joined(separator: " "))
        })
        m.addItem(ClosureMenuItem(title: "Copy localhost:\(t.localPort)") { TerminalWindowController.copy("localhost:\(t.localPort)") })
        m.addItem(ClosureMenuItem(title: "Open http://localhost:\(t.localPort)") {
            if let u = URL(string: "http://localhost:\(t.localPort)") { NSWorkspace.shared.open(u) }
        })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Edit…") { [weak self] in self?.edit(t, over: pane?.window) })
        m.addItem(ClosureMenuItem(title: "Remove") { [weak self] in self?.remove(t) })
        return m
    }
}

// MARK: Copying files over ssh

extension PaneView {
    /// The scp options and target for this ssh tab.
    var sshCopyTarget: (options: [String], target: String)? {
        guard session.isRemote, let cmd = session.remoteCommand ?? sshTarget.map({ "ssh " + $0 }) else { return nil }
        return SSHCopy.options(fromSSH: cmd)
    }

    /// Dropping files on an ssh tab: upload them to the remote folder, or paste their paths.
    func offerUpload(_ files: [String]) -> Bool {
        guard session.isRemote, sshCopyTarget != nil, let w = window, !files.isEmpty else { return false }
        let a = NSAlert()
        let dir = session.remoteCwd ?? "~"
        a.messageText = files.count == 1 ? "Upload \((files[0] as NSString).lastPathComponent) to the server?" : "Upload \(files.count) items to the server?"
        a.informativeText = "Copies to \(session.remoteHost ?? "the server"):\(dir) with scp."
        a.addButton(withTitle: "Upload")
        a.addButton(withTitle: "Paste Paths")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard let self else { return }
            switch r {
            case .alertFirstButtonReturn: self.upload(files, to: dir)
            case .alertSecondButtonReturn: self.surfaceView.sendText(files.map { ShellLexer.escape($0) }.joined(separator: " "))
            default: break
            }
        }
        return true
    }

    func upload(_ files: [String], to dir: String) {
        guard let (opts, target) = sshCopyTarget else { flash("Uploads work in ssh tabs"); return }
        Services.shared.record("ssh.upload")
        flash("Uploading \(files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) items")…")
        let argv = SSHCopy.uploadArgv(files: files, to: dir, options: opts, target: target)
        copyInBackground(argv, interactive: SSHCopy.uploadArgv(files: files, to: dir, options: opts, target: target, batch: false), success: "Uploaded to \(dir)")
    }

    func promptUpload() {
        guard session.isRemote, sshCopyTarget != nil, let w = window else { flash("Uploads work in ssh tabs: connect with ssh first"); return }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Upload"
        p.message = "Copies to \(session.remoteHost ?? "the server"):\(session.remoteCwd ?? "~")"
        p.beginSheetModal(for: w) { [weak self] r in
            guard let self, r == .OK, !p.urls.isEmpty else { return }
            self.upload(p.urls.map(\.path), to: self.session.remoteCwd ?? "~")
        }
    }

    func promptDownload() {
        guard session.isRemote, sshCopyTarget != nil, let w = window else { flash("Downloads work in ssh tabs: connect with ssh first"); return }
        let a = NSAlert()
        a.messageText = "Download from \(session.remoteHost ?? "the server")"
        a.informativeText = "Path on the server (relative paths are in \(session.remoteCwd ?? "~")). It goes to your Downloads folder."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        f.placeholderString = "e.g. logs/app.log"
        f.stringValue = surfaceView.selectionText()?.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
        a.accessoryView = f
        a.window.initialFirstResponder = f
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn, let (opts, target) = self.sshCopyTarget else { return }
            let path = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !path.hasPrefix("-") else { return }
            let remote = SSHCopy.remotePath(path, remoteCwd: self.session.remoteCwd)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
            Services.shared.record("ssh.download")
            self.flash("Downloading \((path as NSString).lastPathComponent)…")
            let local = (downloads as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            self.copyInBackground(SSHCopy.downloadArgv(remote: remote, to: downloads, options: opts, target: target),
                                  interactive: SSHCopy.downloadArgv(remote: remote, to: downloads, options: opts, target: target, batch: false),
                                  success: "Saved to Downloads", reveal: local)
        }
    }

    /// Runs scp without a terminal; when it needs a password, offers a tab where it can ask.
    private func copyInBackground(_ argv: [String], interactive: [String], success: String, reveal: String? = nil) {
        let env = session.env
        Task { @MainActor [weak self] in
            let (out, status) = await ScriptRunner.shared.runWithStatus(argv: argv, cwd: NSHomeDirectory(), env: env, timeout: 600)
            guard let self else { return }
            if status == 0 {
                self.flash(success)
                if let reveal { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reveal)]) }
                return
            }
            let reason = out.split(whereSeparator: \.isNewline).last.map(String.init) ?? "scp failed"
            let a = NSAlert()
            a.messageText = "The copy didn't finish"
            a.informativeText = reason + "\n\nIf the server asks for a password, run it in a new tab where you can type it."
            a.addButton(withTitle: "Run in New Tab")
            a.addButton(withTitle: "Close")
            guard let w = self.window else { return }
            a.beginSheetModal(for: w) { r in
                if r == .alertFirstButtonReturn {
                    AppDelegate.shared.openTab(cwd: nil, run: interactive.map { ShellLexer.escape($0) }.joined(separator: " "))
                }
            }
        }
    }
}
