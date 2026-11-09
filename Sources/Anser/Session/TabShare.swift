import AppKit
import Network
import AnserCore

/// Shares one tab, read-only, with people on your network: Shell → Share This
/// Tab. Anser serves a small web page at a link with a long random secret; it
/// shows what's on the tab's screen, live. Viewers can't type anything. Sharing
/// stops when you stop it, close the tab, quit, or after two hours.
final class TabShare {
    static private(set) var active: [String: TabShare] = [:]
    /// Shares waiting for their port (held here so they aren't released meanwhile).
    static private var starting: [String: TabShare] = [:]
    static let maxViewers = 20
    static let maxDuration: TimeInterval = 2 * 3600

    let token: String
    /// A 4-digit code viewers must type (nil = the link alone is enough).
    let code: String?
    /// Wrong codes so far; sharing stops after too many (someone is guessing).
    private(set) var wrongCodes = 0
    static let maxWrongCodes = 10
    private weak var pane: PaneView?
    private let sessionID: String
    private var listener: NWListener?
    private var viewers: [NWConnection] = []
    private var timer: Timer?
    private var lastText = ""
    private var lastPing = Date()
    private let started = Date()
    private(set) var port: UInt16 = 0
    var viewerCount: Int { viewers.count }

    static func share(for pane: PaneView) -> TabShare? { active[pane.session.id] }

    private init(pane: PaneView, requireCode: Bool) {
        self.pane = pane
        code = requireCode ? String(format: "%04d", Int.random(in: 0...9999)) : nil
        sessionID = pane.session.id
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// Starts sharing; `ready` gets the share once its port is known (nil if it couldn't start).
    static func start(for pane: PaneView, requireCode: Bool = false, ready: @escaping (TabShare?) -> Void) {
        if let s = active[pane.session.id] { ready(s); return }
        let share = TabShare(pane: pane, requireCode: requireCode)
        starting[share.sessionID] = share
        do {
            let l = try NWListener(using: .tcp, on: .any)
            share.listener = l
            l.newConnectionHandler = { [weak share] c in share?.accept(c) }
            l.stateUpdateHandler = { [weak share] state in
                guard let share else { return }
                switch state {
                case .ready:
                    share.port = l.port?.rawValue ?? 0
                    starting[share.sessionID] = nil
                    active[share.sessionID] = share
                    share.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak share] _ in share?.tick() }
                    share.timer?.tolerance = 0.15
                    Services.shared.record("share.start")
                    ready(share)
                    pane.refreshChrome()
                case .failed:
                    starting[share.sessionID] = nil
                    ready(nil)
                default: break
                }
            }
            l.start(queue: .main)
        } catch {
            starting[share.sessionID] = nil
            ready(nil)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        listener?.cancel()
        viewers.forEach { $0.cancel() }
        viewers = []
        Self.active[sessionID] = nil
        pane?.refreshChrome()
    }

    /// The link to send: this Mac's network address (or localhost when there is none).
    var link: String { "http://\(Self.lanAddress() ?? "localhost"):\(port)/s/\(token)" }
    var localLink: String { "http://127.0.0.1:\(port)/s/\(token)" }

    // MARK: Serving

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8),
                  let first = req.split(separator: "\r\n").first else { c.cancel(); return }
            let parts = first.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else { self.send(c, status: "405 Method Not Allowed", body: "read-only"); return }
            let target = String(parts[1])
            let path = String(target.split(separator: "?").first ?? "")
            let given = URLComponents(string: target)?.queryItems?.first { $0.name == "code" }?.value
            let codeOK = self.code == nil || given == self.code
            switch path {
            case "/s/\(self.token)":
                self.send(c, status: "200 OK", type: "text/html; charset=utf-8", body: Self.page.replacingOccurrences(of: "@@NEEDCODE@@", with: self.code == nil ? "false" : "true"))
            case "/s/\(self.token)/check":
                if codeOK { self.send(c, status: "200 OK", body: "ok"); return }
                self.wrongCode()
                self.send(c, status: "403 Forbidden", body: "wrong code")
            case "/s/\(self.token)/events" where !codeOK:
                self.wrongCode()
                self.send(c, status: "403 Forbidden", body: "wrong code")
            case "/s/\(self.token)/events":
                guard self.viewers.count < Self.maxViewers else { self.send(c, status: "503 Service Unavailable", body: "Too many viewers"); return }
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n"
                c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                self.viewers.append(c)
                c.stateUpdateHandler = { [weak self, weak c] state in
                    if case .cancelled = state { self?.dropViewer(c) }
                    if case .failed = state { self?.dropViewer(c) }
                }
                self.push(self.currentText(), to: [c])
                self.pane?.refreshChrome()
            default:
                self.send(c, status: "404 Not Found", body: "Not found")
            }
        }
    }

    private func wrongCode() {
        wrongCodes += 1
        if wrongCodes >= Self.maxWrongCodes {
            pane?.flash("Stopped sharing: too many wrong codes")
            stop()
        }
    }

    private func dropViewer(_ c: NWConnection?) {
        guard let c else { return }
        viewers.removeAll { $0 === c }
        pane?.refreshChrome()
    }

    private func send(_ c: NWConnection, status: String, type: String = "text/plain; charset=utf-8", body: String) {
        let b = Data(body.utf8)
        // The page can't be framed elsewhere and can only talk back to this server.
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(b.count)\r\nCache-Control: no-store\r\n"
            + "X-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n"
            + "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'\r\n"
            + "Connection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + b, completion: .contentProcessed { _ in c.cancel() })
    }

    private func currentText() -> String { pane?.surfaceView.viewportText() ?? "" }

    private func push(_ text: String, to targets: [NWConnection]) {
        guard let json = try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed) else { return }
        let frame = Data("data: ".utf8) + json + Data("\n\n".utf8)
        for c in targets { c.send(content: frame, completion: .contentProcessed { _ in }) }
    }

    private func tick() {
        guard pane != nil, Date().timeIntervalSince(started) < Self.maxDuration else { stop(); return }
        guard !viewers.isEmpty else { return }
        let text = currentText()
        if text != lastText {
            lastText = text
            push(text, to: viewers)
        } else if Date().timeIntervalSince(lastPing) > 15 {
            lastPing = Date()
            for c in viewers { c.send(content: Data(":\n\n".utf8), completion: .contentProcessed { _ in }) }
        }
    }

    /// This Mac's IPv4 address on Wi-Fi or Ethernet.
    static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var found: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (a.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (a.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found = String(cString: host)
                if name == "en0" { break }
            }
        }
        return found
    }

    static let page = """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Anser · shared tab</title>
    <style>
    :root { color-scheme: dark light; }
    body { margin: 0; background: #1e1f24; color: #e6e6e6; font: 13px -apple-system, system-ui, sans-serif; }
    header { padding: 10px 16px; display: flex; gap: 10px; align-items: center; border-bottom: 1px solid #333; }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: #4caf50; }
    .off .dot { background: #888; }
    form { padding: 16px; } input { font: 16px ui-monospace, Menlo, monospace; padding: 4px 6px; }
    pre { margin: 0; padding: 12px 16px; font: 13px/1.35 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre; overflow: auto; }
    </style></head>
    <body><header><span class="dot"></span><span id="s">Live · read-only · shared from Anser</span></header><pre id="t">Connecting…</pre>
    <form id="f" hidden><label>Code from the person sharing: <input id="c" inputmode="numeric" maxlength="4" size="5" autofocus></label> <button>Watch</button> <span id="m"></span></form>
    <script>
    const t = document.getElementById('t'), s = document.getElementById('s'), f = document.getElementById('f');
    function watch(code) {
      const q = code ? '?code=' + encodeURIComponent(code) : '';
      const es = new EventSource(location.pathname + '/events' + q);
      es.onmessage = e => { t.textContent = JSON.parse(e.data); s.textContent = 'Live · read-only · shared from Anser'; document.body.className = ''; };
      es.onerror = () => { s.textContent = 'Not connected: sharing may have stopped'; document.body.className = 'off'; };
    }
    if (@@NEEDCODE@@) {
      f.hidden = false; t.textContent = '';
      f.onsubmit = async ev => {
        ev.preventDefault();
        const code = document.getElementById('c').value.trim();
        const r = await fetch(location.pathname + '/check?code=' + encodeURIComponent(code)).catch(() => null);
        if (r && r.ok) { f.hidden = true; t.textContent = 'Connecting…'; watch(code); }
        else { document.getElementById('m').textContent = 'That code is not right.'; }
      };
    } else { watch(''); }
    </script></body></html>
    """
}

extension PaneView {
    /// Shell → Share This Tab: asks first, then copies the link.
    func shareTab() {
        if let s = TabShare.share(for: self) { showShareMenu(s); return }
        let a = NSAlert()
        a.messageText = "Share this tab, read-only?"
        a.informativeText = "Anyone on your network who has the link can watch this tab's screen live, including anything it shows. They can't type. "
            + "The link has a long secret, works only on your network (not encrypted), and stops when you stop sharing, close the tab, quit, or after 2 hours."
        a.addButton(withTitle: "Share and Copy Link")
        a.addButton(withTitle: "Cancel")
        let codeBox = NSButton(checkboxWithTitle: "Viewers must also type a 4-digit code I tell them", target: nil, action: nil)
        codeBox.state = .on
        a.accessoryView = codeBox
        guard let w = window else { return }
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            TabShare.start(for: self, requireCode: codeBox.state == .on) { [weak self] share in
                guard let share else { self?.flash("Couldn't start sharing"); return }
                TerminalWindowController.copy(share.link)
                self?.flash("Link copied: \(share.link)" + (share.code.map { " · code \($0)" } ?? ""))
            }
        }
    }

    func showShareMenu(_ s: TabShare) {
        shareMenu(s).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func shareMenu(_ s: TabShare) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "Copy Link") { TerminalWindowController.copy(s.link) })
        if let code = s.code { m.addItem(ClosureMenuItem(title: "Copy Code (\(code))") { TerminalWindowController.copy(code) }) }
        m.addItem(ClosureMenuItem(title: "Open in Browser") { if let u = URL(string: s.link) { NSWorkspace.shared.open(u) } })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Stop Sharing") { [weak self] in s.stop(); self?.flash("Stopped sharing") })
        return m
    }
}
