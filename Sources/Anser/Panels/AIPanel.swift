import AppKit
import AnserCore
import Security

/// Stores the Anthropic API key in the macOS Keychain (never in the config file).
enum KeychainStore {
    static let service = "Anser"
    static let account = "anthropic-api-key"

    static func get() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Shows Claude's answer (explain an error / generate a command) with an
/// Insert button for each suggested command. Nothing is ever run automatically.
final class AIPanel: NSPanel, NSTextFieldDelegate {
    enum Mode { case explain(command: String, exitCode: Int, output: String), generate }

    private weak var pane: PaneView?
    private let mode: Mode
    private let askField = NSTextField()
    private let answerView = NSTextView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let commandsStack = NSStackView()
    private let privacy = NSTextField(wrappingLabelWithString: "")
    private var task: Task<Void, Never>?
    private(set) var answer: AIHelp.Answer?

    init(pane: PaneView, mode: Mode) {
        self.pane = pane
        self.mode = mode
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        isReleasedWhenClosed = false
        build()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    private func build() {
        let t = GhosttyRuntime.shared.theme
        appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        switch mode {
        case .explain(let cmd, let code, _): title.stringValue = "✨ Why did this fail?  ·  \(cmd.prefix(50)) (exit \(code))"
        case .generate: title.stringValue = "✨ Ask Claude for a command"
        }
        self.title = "AI help"

        askField.placeholderString = "Describe what you want, e.g. “find files over 100 MB changed this week”"
        askField.font = .systemFont(ofSize: 14)
        askField.delegate = self
        askField.isHidden = { if case .generate = mode { return false } else { return true } }()

        answerView.isEditable = false
        answerView.drawsBackground = false
        answerView.textContainerInset = NSSize(width: 4, height: 6)
        let scroll = NSScrollView()
        scroll.documentView = answerView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        answerView.autoresizingMask = [.width]

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        commandsStack.orientation = .vertical
        commandsStack.alignment = .leading
        commandsStack.spacing = 6

        privacy.font = .systemFont(ofSize: 10.5)
        privacy.textColor = .tertiaryLabelColor
        switch mode {
        case .explain: privacy.stringValue = "Sent to Anthropic: the command, the last 200 lines of its output, your shell and folder name. Things that look like secrets are removed first."
        case .generate: privacy.stringValue = "Sent to Anthropic: your description, your shell and folder name. Suggested commands are only inserted when you click Insert; nothing runs on its own."
        }

        let stack = NSStackView(views: [title, askField, NSStackView(views: [spinner, status]), scroll, commandsStack, privacy])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 18, bottom: 14, right: 18)
        for v in [title, askField, scroll, commandsStack, privacy] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        // Themed like the other panels.
        stack.wantsLayer = true
        stack.layer?.backgroundColor = (t.background.blended(withFraction: t.isDark ? 0.05 : 0.02, of: t.isDark ? .white : .black) ?? t.background).cgColor
        contentView = stack
    }

    func present(over parent: NSWindow) {
        let f = parent.frame
        setFrame(NSRect(x: f.midX - 330, y: f.maxY - 520, width: 660, height: 470), display: true)
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        if case .explain = mode { start(nil) } else { makeFirstResponder(askField) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if let first = answer?.commands.first, askField.stringValue.isEmpty { insert(first); return true }
            start(askField.stringValue)
            return true
        }
        return false
    }

    private func context() -> AIHelp.Context {
        let s = pane?.session
        return AIHelp.Context(shell: s?.env.shell ?? "zsh", os: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                              cwdName: ((s?.cwd ?? "") as NSString).lastPathComponent, gitBranch: s?.gitBranch)
    }

    private func start(_ request: String?) {
        task?.cancel()
        if case .generate = mode, (request ?? "").trimmingCharacters(in: .whitespaces).isEmpty { NSSound.beep(); return }
        spinner.startAnimation(nil)
        status.stringValue = "Asking Claude…"
        answerView.string = ""
        commandsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let ai = Services.shared.ai
        let ctx = context()
        let mode = self.mode
        Diagnostics.shared.log("ai request: \(request == nil ? "explain" : "generate")")
        task = Task { @MainActor [weak self] in
            do {
                let a: AIHelp.Answer
                switch mode {
                case .explain(let cmd, let code, let out): a = try await ai.explainFailure(command: cmd, exitCode: code, output: out, context: ctx)
                case .generate: a = try await ai.generateCommand(request ?? "", context: ctx)
                }
                self?.show(a)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.spinner.stopAnimation(nil)
                self.status.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.status.textColor = .systemRed
            }
        }
    }

    func show(_ a: AIHelp.Answer) {
        answer = a
        spinner.stopAnimation(nil)
        status.stringValue = a.commands.isEmpty ? "" : "⏎ inserts the first command"
        status.textColor = .secondaryLabelColor
        answerView.textStorage?.setAttributedString(Self.render(a.text))
        commandsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for cmd in a.commands.prefix(5) {
            let label = NSTextField(labelWithString: cmd.replacingOccurrences(of: "\n", with: " ⏎ "))
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = cmd
            let button = NSButton(title: "Insert", target: self, action: #selector(insertTapped(_:)))
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier(cmd)
            let row = NSStackView(views: [button, label])
            row.spacing = 8
            commandsStack.addArrangedSubview(row)
        }
    }

    @objc private func insertTapped(_ b: NSButton) { if let cmd = b.identifier?.rawValue { insert(cmd) } }

    func insert(_ cmd: String) {
        pane?.insertIntoEditor(cmd)
        close()
        pane?.focus()
    }

    /// Light Markdown: code blocks and `inline code` in monospace.
    static func render(_ md: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let code: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                   .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07)]
        var inBlock = false
        for line in md.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inBlock.toggle(); continue }
            if inBlock { out.append(NSAttributedString(string: line + "\n", attributes: code)); continue }
            let parts = line.components(separatedBy: "`")
            for (i, p) in parts.enumerated() {
                let clean = p.replacingOccurrences(of: "**", with: "")
                out.append(NSAttributedString(string: clean, attributes: i % 2 == 1 ? code : body))
            }
            out.append(NSAttributedString(string: "\n", attributes: body))
        }
        return out
    }
}
