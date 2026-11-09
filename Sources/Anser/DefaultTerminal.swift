import AppKit
import UniformTypeIdentifiers
import AnserCore

/// Anser as the default terminal: it opens scripts double-clicked in Finder,
/// ssh:// and x-man-page:// links, and folders dropped on the Dock icon.
extension AppDelegate {
    static let shellScriptTypes = ["com.apple.terminal.shell-script", "public.unix-executable"]
    static let terminalSchemes = ["ssh", "x-man-page"]
    static let appleTerminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    // MARK: Opening

    func application(_ application: NSApplication, open urls: [URL]) {
        // Launched by opening something: wait until the first window exists.
        guard didFinishLaunching else { pendingOpenURLs += urls; return }
        for url in urls { handleOpen(url) }
    }

    func openPendingURLs() {
        let urls = pendingOpenURLs
        pendingOpenURLs = []
        for url in urls { handleOpen(url) }
    }

    func handleOpen(_ url: URL) {
        Services.shared.record("open." + (url.isFileURL ? "file" : (url.scheme ?? "?")))
        if url.isFileURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { NSSound.beep(); return }
            if isDir.boolValue { openTab(cwd: url.path, run: nil); return }
            let path = url.path
            let run = { self.openTab(cwd: url.deletingLastPathComponent().path, run: OpenRequests.scriptCommand(path: path)) }
            if Self.isQuarantined(path) { confirmDownloadedScript(path, then: run) } else { run() }
            return
        }
        switch url.scheme?.lowercased() {
        case "ssh":
            guard let cmd = OpenRequests.sshCommand(url) else { refuseLink(url); return }
            openTab(cwd: nil, run: cmd)
        case "x-man-page":
            guard let cmd = OpenRequests.manCommand(url) else { refuseLink(url); return }
            openTab(cwd: nil, run: cmd)
        case "anser":
            handleAnserLink(url)
        default:
            NSSound.beep()
        }
    }

    /// A new tab (in the front window, or a new window) in `cwd`, optionally running a command once the shell is ready.
    func openTab(cwd: String?, run command: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let front = NSApp.orderedWindows.compactMap { $0.windowController as? TerminalWindowController }
            .first { !$0.isQuickTerminal && ($0.window?.isVisible ?? false) }
        let wc: TerminalWindowController
        if let front {
            front.window?.makeKeyAndOrderFront(nil)
            front.addTab(cwd: cwd ?? front.focusedPane?.session.cwd)
            wc = front
        } else {
            newWindow(cwd: cwd)
            guard let c = currentController else { return }
            wc = c
        }
        guard let command else { return }
        let pane = wc.focusedPane
        let start = Date()
        func attempt() {
            if let p = pane, p.session.atPrompt, p.session.integrated { p.run(command); return }
            if Date().timeIntervalSince(start) < 10 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { attempt() } }
        }
        attempt()
    }

    /// Downloaded files carry a quarantine mark; ask before running one.
    static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    private func confirmDownloadedScript(_ path: String, then run: @escaping () -> Void) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Run “\((path as NSString).lastPathComponent)”?"
        a.informativeText = "It was downloaded from the internet. Only run scripts from people you trust.\n\n\(path)"
        a.addButton(withTitle: "Run")
        a.addButton(withTitle: "Cancel")
        a.buttons[1].keyEquivalent = "\u{1b}"
        if a.runModal() == .alertFirstButtonReturn { run() }
    }

    func refuseLink(_ url: URL) {
        let a = NSAlert()
        a.messageText = "Anser didn't open this link"
        a.informativeText = "It doesn't look like a plain \(url.scheme ?? "") address, so it was ignored for safety:\n\n\(url.absoluteString.prefix(300))"
        a.runModal()
    }

    // MARK: Default terminal

    /// Anser opens shell scripts and ssh links right now.
    var isDefaultTerminal: Bool {
        let me = Bundle.main.bundleURL.standardizedFileURL
        let ws = NSWorkspace.shared
        let types = Self.shellScriptTypes.compactMap { UTType($0) }.compactMap { ws.urlForApplication(toOpen: $0)?.standardizedFileURL }
        let schemes = Self.terminalSchemes.compactMap { URL(string: $0 + "://x") }.compactMap { ws.urlForApplication(toOpen: $0)?.standardizedFileURL }
        return !types.isEmpty && (types + schemes).allSatisfy { $0 == me }
    }

    @objc func toggleDefaultTerminal(_ s: Any?) {
        if isDefaultTerminal {
            let a = NSAlert()
            a.messageText = "Anser is your default terminal"
            a.informativeText = "Scripts you double-click in Finder and ssh:// links open in Anser. Switch back to Apple's Terminal?"
            a.addButton(withTitle: "Use Terminal Instead")
            a.addButton(withTitle: "Keep Anser")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            setDefaultTerminal(Self.appleTerminal, name: "Terminal")
        } else {
            setDefaultTerminal(Bundle.main.bundleURL, name: "Anser")
        }
    }

    /// Makes `app` open shell scripts, ssh:// and x-man-page:// links. macOS may ask you to confirm each link type.
    func setDefaultTerminal(_ app: URL, name: String) {
        Services.shared.record("defaultTerminal." + name)
        let ws = NSWorkspace.shared
        let group = DispatchGroup()
        let errors = ErrorBox()
        for t in Self.shellScriptTypes.compactMap({ UTType($0) }) {
            group.enter()
            ws.setDefaultApplication(at: app, toOpen: t) { e in if let e { errors.add(e) }; group.leave() }
        }
        for scheme in Self.terminalSchemes {
            group.enter()
            ws.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { e in if let e { errors.add(e) }; group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            let a = NSAlert()
            if let e = errors.first {
                a.alertStyle = .warning
                a.messageText = "Couldn't make \(name) the default for everything"
                a.informativeText = e.localizedDescription + "\n\nIf macOS asked you to confirm and you chose not to, that link type stays with its old app."
            } else {
                a.messageText = "\(name) is now your default terminal"
                a.informativeText = name == "Anser"
                    ? "Double-clicked .command and .tool scripts, ssh:// links and manual-page links open in Anser. Drop a folder on the Dock icon to open a tab there."
                    : "Scripts and ssh:// links open in Terminal again."
            }
            a.runModal()
            _ = self
        }
    }
}

final class ErrorBox: @unchecked Sendable {
    private var errors: [Error] = []
    private let lock = NSLock()
    func add(_ e: Error) { lock.withLock { errors.append(e) } }
    var first: Error? { lock.withLock { errors.first } }
}
