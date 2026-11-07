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
        lastPane = pane
        lastChanges = changes
        defer { needsLayout = true }
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

        // Saved commands from the Command Notebook: click puts one in the editor.
        let notebook = (try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook()
        if section("Notebook", count: notebook.entryCount) {
            for g in notebook.groups where !g.entries.isEmpty {
                for e in g.entries.prefix(12) {
                    row(symbol: "book.closed", text: e.displayTitle, detail: notebook.groups.count > 1 ? g.name : nil, color: t.foreground,
                        tooltip: e.command + (e.note.isEmpty ? "" : "\n\n" + e.note) + "\nClick to put it in the editor", wraps: true) {
                        pane.insertIntoEditor(e.command)
                    }
                }
            }
            row(symbol: notebook.entryCount == 0 ? "plus" : "book", text: notebook.entryCount == 0 ? "Save a command…" : "Open Notebook…",
                detail: "⌥⌘N", color: t.dim) {
                if notebook.entryCount == 0 { pane.saveToNotebook() } else { NotebookWindow.shared.show() }
            }
        }

        // Saved workflows (personal and this project's): click to run, with its parameter form.
        let workflows = s.isRemote ? [] : WorkflowStore.load(cwd: s.cwd)
        if !workflows.isEmpty, section("Workflows", count: workflows.count) {
            for w in workflows.prefix(10) {
                row(symbol: w.source == .project ? "folder.badge.gearshape" : "list.bullet.rectangle", text: w.name,
                    detail: "\(w.steps.count) step\(w.steps.count == 1 ? "" : "s")", color: t.foreground,
                    tooltip: (w.description.map { $0 + "\n" } ?? "") + w.steps.joined(separator: "\n") + "\nClick to view and run", wraps: true) { [weak self] in
                    self?.controller?.showWorkflows(for: pane)
                }
            }
        }

    }

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
        let folded = collapsedSections.contains(title)
        let text = title.uppercased() + (count.map { " · \($0)" } ?? "")
        sectionTitles.append(text)
        let h = SidebarHeader(title: text, folded: folded) { [weak self] in self?.toggleSection(title) }
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
    init(title: String, folded: Bool, action: @escaping () -> Void) {
        self.action = action
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
