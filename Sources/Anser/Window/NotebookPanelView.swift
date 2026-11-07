import AppKit
import AnserCore

/// The right-hand panel (book button at the right of the tab bar, ⌥⌘N):
/// your Command Notebook, grouped, then your workflows (personal and this
/// project's), using the window's full height. Click a command to put it in
/// the editor; hover for Run (asks for any {{values}} first), Copy and Edit.
final class NotebookPanelView: NSView, NSSearchFieldDelegate {
    weak var controller: TerminalWindowController?
    static let defaultWidth: CGFloat = 270

    private let header = NSTextField(labelWithString: "NOTEBOOK")
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private(set) var rowCount = 0
    private var notebook = Notebook()

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        let add = ClosureButton(symbol: "plus", tip: "Save the command in the editor (or the last one) to the notebook (⌥⌘S)") { [weak self] in
            self?.controller?.focusedPane?.saveToNotebook()
        }
        let edit = ClosureButton(symbol: "square.and.pencil", tip: "Open the notebook editor: groups, names, notes") {
            NotebookWindow.shared.show()
        }
        let close = ClosureButton(symbol: "xmark", tip: "Hide (⌥⌘N)") { [weak self] in self?.controller?.toggleNotebookPanel() }
        for b in [add, edit, close] { b.widthAnchor.constraint(equalToConstant: 16).isActive = true }
        let top = NSStackView(views: [header, NSView(), add, edit, close])
        top.spacing = 10
        search.placeholderString = "Search saved commands"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.controlSize = .small

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 12, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = true
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        for v in [top, search, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            search.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityLabel("Command Notebook")
        NotificationCenter.default.addObserver(forName: .anserNotebookChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isHidden == false { self?.reload() } }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = scroll.contentSize.width
        guard w > 0 else { return }
        stack.frame.size.width = w
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(x: 0, y: 0, width: w, height: max(stack.fittingSize.height, scroll.contentSize.height))
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let t = GhosttyRuntime.shared.theme
        t.barBackground.setFill()
        bounds.fill()
        t.foreground.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    /// Re-reads the notebook file and redraws the list.
    func reload() {
        let t = GhosttyRuntime.shared.theme
        header.textColor = t.foreground.withAlphaComponent(0.5)
        notebook = (try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook()
        header.stringValue = "NOTEBOOK · \(notebook.entryCount)"
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowCount = 0
        let groups = notebook.filtered(search.stringValue)
        let showGroupNames = notebook.groups.count > 1
        for g in groups where !g.entries.isEmpty || search.stringValue.isEmpty {
            if showGroupNames {
                let label = NSTextField(labelWithString: g.name.uppercased() + "  ·  \(g.entries.count)")
                label.font = .systemFont(ofSize: 10, weight: .semibold)
                label.textColor = t.foreground.withAlphaComponent(0.45)
                let wrap = NSStackView(views: [label])
                wrap.edgeInsets = NSEdgeInsets(top: 10, left: 6, bottom: 2, right: 0)
                stack.addArrangedSubview(wrap)
            }
            for e in g.entries { add(e) }
        }
        addWorkflows(showHeader: true)
        if rowCount == 0 {
            let empty = NSTextField(wrappingLabelWithString: search.stringValue.isEmpty
                ? "No saved commands or workflows yet.\n\nClick + to save the command in the editor, or use the book button on any command's hover strip."
                : "Nothing matches “\(search.stringValue)”.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = t.foreground.withAlphaComponent(0.5)
            empty.preferredMaxLayoutWidth = Self.defaultWidth - 40
            let wrap = NSStackView(views: [empty])
            wrap.edgeInsets = NSEdgeInsets(top: 12, left: 6, bottom: 0, right: 6)
            stack.addArrangedSubview(wrap)
        }
        needsLayout = true
    }

    /// Workflows (multi-step commands) live here too, under their own heading.
    private(set) var workflowCount = 0
    private func addWorkflows(showHeader: Bool) {
        let t = GhosttyRuntime.shared.theme
        let cwd = controller?.focusedPane?.session.cwd ?? NSHomeDirectory()
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let flows = WorkflowStore.load(cwd: cwd).filter {
            q.isEmpty || $0.name.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q) || $0.steps.joined().lowercased().contains(q)
        }
        workflowCount = flows.count
        guard !flows.isEmpty else { return }
        let label = NSTextField(labelWithString: "WORKFLOWS  ·  \(flows.count)")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = t.foreground.withAlphaComponent(0.45)
        let wrap = NSStackView(views: [label])
        wrap.edgeInsets = NSEdgeInsets(top: 14, left: 6, bottom: 2, right: 0)
        stack.addArrangedSubview(wrap)
        for w in flows {
            let shown = Notebook.Entry(title: w.name + (w.source == .project ? "  ·  project" : ""),
                                       command: w.steps.joined(separator: "\n"), note: w.description ?? "")
            let row = NotebookRow(entry: shown,
                paste: { [weak self] in self?.workflow(w, insertOnly: true) },
                run: { [weak self] in self?.workflow(w, insertOnly: false) },
                edit: { if let f = w.file { NSWorkspace.shared.open(f) } })
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
            rowCount += 1
        }
    }

    private func workflow(_ w: Workflow, insertOnly: Bool) {
        guard let pane = controller?.focusedPane else { NSSound.beep(); return }
        controller?.startWorkflow(w, in: pane, insertOnly: insertOnly)
    }

    private func add(_ e: Notebook.Entry) {
        let row = NotebookRow(entry: e,
            paste: { [weak self] in self?.use(e.command, run: false) },
            run: { [weak self] in
                guard let self, let pane = self.controller?.focusedPane else { NSSound.beep(); return }
                self.controller?.runNotebookEntry(e, in: pane)
            },
            edit: { NotebookWindow.shared.show(); NotebookWindow.shared.selectEntry(e.id) })
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        rowCount += 1
    }

    private func use(_ command: String, run: Bool) {
        guard let pane = controller?.focusedPane else { NSSound.beep(); return }
        pane.insertIntoEditor(command, run: run)
        pane.focus()
    }

    // For tests.
    var rowTitles: [String] { stack.arrangedSubviews.compactMap { ($0 as? NotebookRow)?.titleText } }
    func clickRow(_ i: Int) { stack.arrangedSubviews.compactMap { $0 as? NotebookRow }[i].click() }
}

/// One saved command: its name, the command (up to 3 lines), hover actions.
final class NotebookRow: NSView {
    private let paste: () -> Void
    private var hovering = false { didSet { needsDisplay = true; buttons.forEach { $0.isHidden = !hovering } } }
    private var buttons: [NSButton] = []
    let titleText: String

    init(entry e: Notebook.Entry, paste: @escaping () -> Void, run: @escaping () -> Void, edit: @escaping () -> Void) {
        self.paste = paste
        titleText = e.displayTitle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let t = GhosttyRuntime.shared.theme
        let hasTitle = !e.title.trimmingCharacters(in: .whitespaces).isEmpty
        let title = NSTextField(labelWithString: e.displayTitle)
        title.font = hasTitle ? .systemFont(ofSize: 12.5, weight: .medium) : .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        title.textColor = t.foreground.withAlphaComponent(0.92)
        title.lineBreakMode = .byTruncatingTail
        let cmd = NSTextField(wrappingLabelWithString: e.command)
        cmd.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        cmd.textColor = t.foreground.withAlphaComponent(0.5)
        cmd.maximumNumberOfLines = 3
        cmd.lineBreakMode = .byTruncatingTail
        cmd.isHidden = !hasTitle   // untitled rows already show the command as their title
        let text = NSStackView(views: [title, cmd])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        for v in [title, cmd] { v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        cmd.preferredMaxLayoutWidth = NotebookPanelView.defaultWidth - 50

        let acts = NSStackView()
        acts.spacing = 6
        for (sym, tip, f) in [("play.fill", e.command.contains("{{") ? "Run it (asks for the values first)" : "Run it now", run), ("doc.on.doc", "Copy", {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.command, forType: .string)
        }), ("pencil", "Edit in the notebook", edit)] as [(String, String, () -> Void)] {
            let b = ClosureButton(symbol: sym, tip: tip, run: f)
            b.contentTintColor = t.foreground.withAlphaComponent(0.7)
            b.isHidden = true
            b.widthAnchor.constraint(equalToConstant: 14).isActive = true
            acts.addArrangedSubview(b)
            buttons.append(b)
        }
        for v in [text, acts] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: acts.leadingAnchor, constant: -4),
            acts.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            acts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        toolTip = e.command + (e.note.isEmpty ? "" : "\n\n" + e.note) + "\n\nClick to put it in the editor"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(e.displayTitle)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Run") { run(); return true },
            NSAccessibilityCustomAction(name: "Edit") { edit(); return true },
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func click() { paste() }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { paste() } }
    override func accessibilityPerformPress() -> Bool { paste(); return true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        GhosttyRuntime.shared.theme.foreground.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
