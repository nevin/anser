import AppKit
import Network
import Security
import SystemConfiguration
import UserNotifications
import AnserCore

// MARK: Servers

/// Finds servers your tabs started: anything listening on a TCP port whose
/// process runs under a tab's shell. Checks every few seconds while a command
/// is running somewhere, and stops checking when nothing is.
final class ServerMonitor {
    static let shared = ServerMonitor()
    /// Shell session id → its servers.
    private(set) var bySession: [String: [ServerPorts.Listener]] = [:]
    private var timer: Timer?
    private var checking = false
    static let changed = Notification.Name("AnserServersChanged")

    var all: [(pane: PaneView, server: ServerPorts.Listener)] {
        AppDelegate.shared.allPanes.flatMap { p in (bySession[p.session.id] ?? []).map { (p, $0) } }
    }

    func servers(for pane: PaneView) -> [ServerPorts.Listener] { bySession[pane.session.id] ?? [] }

    /// Called when commands start or finish.
    func wake() {
        guard Services.shared.config.serverChips else { stop(); return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.check() }
            timer?.tolerance = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.check() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if !bySession.isEmpty { bySession = [:]; NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    func check() {
        guard !checking else { return }
        let panes = AppDelegate.shared.allPanes.filter { !$0.session.isRemote && $0.session.shellPID > 1 }
        // Nothing running anywhere: servers have stopped too (their shell is at a prompt).
        let busy = panes.filter { $0.session.running != nil }
        if busy.isEmpty && bySession.isEmpty { timer?.invalidate(); timer = nil; return }
        let shells = Dictionary(panes.map { ($0.session.id, $0.session.shellPID) }, uniquingKeysWith: { a, _ in a })
        checking = true
        Task.detached(priority: .utility) { [weak self] in
            let env = ShellEnvironment()
            let lsof = await ScriptRunner.shared.run(argv: ["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], cwd: "/", env: env, timeout: 3) ?? ""
            let ps = await ScriptRunner.shared.run(argv: ["/bin/ps", "-axo", "pid=,ppid="], cwd: "/", env: env, timeout: 3) ?? ""
            let listeners = ServerPorts.parseLsof(lsof)
            let parents = ServerPorts.parseParents(ps)
            var found: [String: [ServerPorts.Listener]] = [:]
            for l in listeners {
                if let (sid, _) = shells.first(where: { ServerPorts.descends(l.pid, from: $0.value, parents: parents) }) {
                    found[sid, default: []].append(l)
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.checking = false
                if found != self.bySession {
                    self.bySession = found
                    NotificationCenter.default.post(name: Self.changed, object: nil)
                }
                if busy.isEmpty, found.isEmpty { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    /// Stops a server: SIGTERM, then SIGKILL if it's still there after 3 seconds.
    static func stop(pid: Int32, then: (() -> Void)? = nil) {
        kill(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            ServerMonitor.shared.check()
            then?()
        }
    }

    /// The menu for one server: open, copy link, stop.
    static func menu(for s: ServerPorts.Listener, pane: PaneView?) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "Open \(s.url)") { if let u = URL(string: s.url) { NSWorkspace.shared.open(u) } })
        m.addItem(ClosureMenuItem(title: "Copy Link") { TerminalWindowController.copy(s.url) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Stop \(s.process) (port \(s.port))") { [weak pane] in
            stop(pid: s.pid) { pane?.flash("Stopped \(s.process) on port \(s.port)") }
        })
        return m
    }

    /// Kill Process on Port…: asks for the port, shows what's there, asks again, then stops it.
    static func promptKillPort(in window: NSWindow?, pane: PaneView?) {
        let a = NSAlert()
        a.messageText = "Free a port"
        a.informativeText = "Which port? Anser shows what's using it before stopping anything."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "3000"
        a.accessoryView = field
        a.addButton(withTitle: "Find")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            guard let port = ServerPorts.parsePort(field.stringValue) else { pane?.flash("That isn't a port number"); return }
            Task { @MainActor in
                let out = await ScriptRunner.shared.run(argv: ["/usr/sbin/lsof", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"], cwd: "/",
                                                        env: ShellEnvironment(), timeout: 3) ?? ""
                let hits = ServerPorts.parseLsof(out)
                guard !hits.isEmpty else { pane?.flash("Nothing is listening on port \(port)"); return }
                let c = NSAlert()
                c.alertStyle = .warning
                c.messageText = "Stop what's on port \(port)?"
                c.informativeText = hits.map { "\($0.process) (process \($0.pid))" }.joined(separator: "\n")
                c.addButton(withTitle: "Stop It")
                c.addButton(withTitle: "Cancel")
                let go: (NSApplication.ModalResponse) -> Void = { r in
                    guard r == .alertFirstButtonReturn else { return }
                    for h in hits { stop(pid: h.pid) }
                    pane?.flash("Stopping \(hits.map(\.process).joined(separator: ", ")) on port \(port)")
                }
                if let w = window { c.beginSheetModal(for: w, completionHandler: go) } else { go(c.runModal()) }
            }
        }
        if let w = window { a.beginSheetModal(for: w, completionHandler: handle) } else { handle(a.runModal()) }
    }
}

// MARK: Network

/// Whether the Mac is online, for reconnecting ssh only once the network is back.
final class NetworkWatch {
    static let shared = NetworkWatch()
    private let monitor = NWPathMonitor()
    private(set) var online = true
    private var waiters: [() -> Void] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.online = path.status == .satisfied
                if self.online { let w = self.waiters; self.waiters = []; w.forEach { $0() } }
            }
        }
        monitor.start(queue: DispatchQueue(label: "anser.network"))
    }

    /// Runs `f` now if online, else when the network comes back.
    func whenOnline(_ f: @escaping () -> Void) {
        if online { f() } else { waiters.append(f) }
    }
}

// MARK: Secrets

/// Secrets for `{{secret:name}}`, kept in your login Keychain.
enum SecretStore {
    static let service = "app.anser.terminal.secret"

    static func names() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    static func get(_ name: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: name, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func set(_ name: String, _ value: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "Anser secret: \(name)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ name: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name] as CFDictionary)
    }
}

/// Hands a secret to one command without writing it anywhere: a one-time pipe
/// the command reads with `$(cat …)`. The pipe is gone after one read, or after
/// two minutes if nothing reads it.
enum SecretBroker {
    static var directory: String {
        let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("anser-secrets")
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(d, 0o700)
        return d
    }

    /// Shell code that produces the value, or nil if there's no such secret.
    static func code(for name: String) -> String? {
        guard let value = get(name) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let path = (directory as NSString).appendingPathComponent(bytes.map { String(format: "%02x", $0) }.joined())
        guard mkfifo(path, 0o600) == 0 else { return nil }
        DispatchQueue.global(qos: .userInitiated).async {
            // Opening for writing succeeds only once the command opens it for reading.
            let deadline = Date().addingTimeInterval(120)
            var fd: Int32 = -1
            while Date() < deadline {
                fd = open(path, O_WRONLY | O_NONBLOCK)
                if fd >= 0 { break }
                usleep(50_000)
            }
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL)
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                var data = Array(value.utf8)
                _ = write(fd, &data, data.count)
                close(fd)
            }
            unlink(path)
        }
        return "\"$(cat \(ShellLexer.escape(path)))\""
    }

    /// Tests read secrets from here instead of the Keychain.
    static var testValues: [String: String]?
    static func get(_ name: String) -> String? { testValues.map { $0[name] } ?? SecretStore.get(name) }
}

// MARK: History sync

/// Shares history between your Macs (Settings → Privacy & History). Runs at launch,
/// every 5 minutes, and when Anser quits.
final class HistorySyncService {
    static let shared = HistorySyncService()
    private var timer: Timer?
    private var running = false
    private(set) var last: HistorySync.Result?
    private(set) var lastRun: Date?

    var folder: String {
        let cfg = Services.shared.config
        if let f = cfg.syncFolder?.trimmingCharacters(in: .whitespaces), !f.isEmpty { return (f as NSString).expandingTildeInPath }
        if let loc = cfg.notebookLocation, !loc.isEmpty { return Services.notebookURL(for: loc).deletingLastPathComponent().path }
        return Services.iCloudFolder.path
    }

    /// This Mac's name in the folder ("Sneha-s-MacBook-Pro-3f2a").
    static var machine: String {
        let key = "historySyncMachine"
        if let m = UserDefaults.standard.string(forKey: key) { return m }
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
        let m = HistorySync.fileName(machine: name + "-" + UUID().uuidString.prefix(4)).dropFirst("history-".count).dropLast(".jsonl".count)
        UserDefaults.standard.set(String(m), forKey: key)
        return String(m)
    }

    func configure() {
        timer?.invalidate()
        timer = nil
        guard Services.shared.config.syncHistory, !Services.isSelfTest else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.syncNow() }
        timer?.tolerance = 30
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.syncNow() }
    }

    func syncNow(wait: Bool = false, done: ((HistorySync.Result) -> Void)? = nil) {
        guard !running else { return }
        running = true
        let folder = self.folder, machine = Self.machine, store = Services.shared.history
        let work = {
            let r = HistorySync.run(folder: folder, machine: machine, store: store)
            DispatchQueue.main.async {
                self.running = false
                self.last = r
                self.lastRun = Date()
                if r.received > 0 { Diagnostics.shared.log("history sync: +\(r.received) from \(r.otherMacs.joined(separator: ", "))") }
                done?(r)
            }
        }
        if wait { work() } else { DispatchQueue.global(qos: .utility).async(execute: work) }
    }
}

// MARK: Waiting notifications

extension Services {
    func notifyWaiting(_ wait: InputWait.Wait, tab: String, sessionID: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = wait.title
        content.body = "\(tab)\n\(String(wait.line.prefix(160)))"
        content.userInfo = ["session": sessionID]
        content.sound = .default
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            if ok { center.add(UNNotificationRequest(identifier: "wait-" + sessionID, content: content, trigger: nil)) }
        }
    }
}
