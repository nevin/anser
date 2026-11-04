import AppKit
import AnserCore

/// Optional left sidebar (⌃⌘S): the focused pane's git changes, recent
/// folders and your snippets. Everything is one click away.
final class SidebarView: NSView {
    weak var controller: TerminalWindowController?
    private let scroll = NSScrollView()
    private let stack = FlippedStack()
    private var loadTask: Task<Void, Never>?
    private(set) var rowCount = 0

    final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }

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
            let changes = session.gitBranch != nil ? await Generators.gitChanges(cwd: session.cwd, env: session.env) : []
            guard let self, !Task.isCancelled else { return }
            self.build(pane: pane, changes: changes)
        }
    }

    private func build(pane: PaneView, changes: [GitChange]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowCount = 0
        defer { needsLayout = true }
        let t = GhosttyRuntime.shared.theme
        let s = pane.session

        if let branch = s.gitBranch {
            section("Git")
            row(symbol: "arrow.triangle.branch", text: branch, detail: "switch…", color: t.foreground) { [weak self] in
                self?.controller?.showBranchSwitcher(for: pane)
            }
            if changes.isEmpty {
                row(symbol: "checkmark.circle", text: "No changes", detail: nil, color: t.dim, action: nil)
            }
            for c in changes.prefix(40) {
                let color: NSColor = c.untracked ? t.green : (c.code.contains("D") ? t.red : t.yellow)
                row(symbol: c.untracked ? "plus.square" : (c.code.contains("D") ? "minus.square" : "pencil"),
                    text: (c.path as NSString).lastPathComponent, detail: c.summary, color: color, tooltip: c.path) {
                    guard s.atPrompt else { NSSound.beep(); return }
                    let f = ShellLexer.escape(c.path)
                    pane.run(c.untracked ? "cat -- \(f)" : (c.staged ? "git diff --cached -- \(f)" : "git diff -- \(f)"))
                }
            }
            if changes.count > 40 {
                row(symbol: "ellipsis", text: "\(changes.count - 40) more…", detail: nil, color: t.dim) { [weak self] in
                    self?.controller?.showChanges(for: pane)
                }
            }
        }

        section("Recent folders")
        let fm = FileManager.default
        for d in Services.shared.history.recentDirectories(limit: 30).filter({ fm.fileExists(atPath: $0.path) && $0.path != s.cwd }).prefix(8) {
            row(symbol: "folder", text: (d.path as NSString).lastPathComponent, detail: nil, color: t.foreground, tooltip: d.path) {
                if s.atPrompt { pane.run("cd " + ShellLexer.escape(d.path)) } else { NSSound.beep() }
            }
        }
        row(symbol: "magnifyingglass", text: "More folders…", detail: "⌘J", color: t.dim) { [weak self] in
            self?.controller?.showFolderJumper(for: pane)
        }

        let snippets = Services.shared.config.snippets
        if !snippets.isEmpty {
            section("Snippets")
            for sn in snippets {
                row(symbol: "text.badge.star", text: sn.name, detail: nil, color: t.foreground, tooltip: sn.command) {
                    pane.insertIntoEditor(sn.command)
                }
            }
        }
    }

    private func section(_ title: String) {
        let l = NSTextField(labelWithString: title.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = GhosttyRuntime.shared.theme.dim
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
        stack.addArrangedSubview(l)
        stack.setCustomSpacing(6, after: l)
    }

    private func row(symbol: String, text: String, detail: String?, color: NSColor, tooltip: String? = nil, action: (() -> Void)?) {
        let r = SidebarRow(symbol: symbol, text: text, detail: detail, color: color, action: action)
        r.toolTip = tooltip ?? text
        stack.addArrangedSubview(r)
        r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        rowCount += 1
    }
}

private final class SidebarRow: NSView {
    private let action: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(symbol: String, text: String, detail: String?, color: NSColor, action: (() -> Void)?) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color.withAlphaComponent(0.8)
        icon.imageScaling = .scaleProportionallyDown
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = color.withAlphaComponent(0.9)
        label.lineBreakMode = .byTruncatingMiddle
        let d = NSTextField(labelWithString: detail ?? "")
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
            d.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            d.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            d.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(action == nil ? .staticText : .button)
        setAccessibilityLabel(text + (detail.map { ", " + $0 } ?? ""))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering, action != nil else { return }
        GhosttyRuntime.shared.theme.foreground.withAlphaComponent(0.08).setFill()
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
