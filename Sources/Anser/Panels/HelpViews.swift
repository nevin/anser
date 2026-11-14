import AppKit

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// A key drawn as a small rounded keycap, e.g. ⌘ R.
final class KeyCapView: NSView {
    private let text: String
    private let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        let w = (text as NSString).size(withAttributes: [.font: font]).width + 12
        frame.size = NSSize(width: max(22, w), height: 20)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: frame.width).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        p.fill()
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        p.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

enum Shortcuts {
    typealias Row = (keys: [String], what: String)

    static let groups: [(title: String, rows: [Row])] = [
        ("Command editor", [
            (["⏎"], "Run"),
            (["⇧", "⏎"], "New line"),
            (["⇥"], "Complete / next {{field}}"),
            (["→"], "Accept gray suggestion"),
            (["⌥", "→"], "Accept one word of it"),
            (["↑", "↓"], "History matching what you typed"),
            (["⌥", "↑"], "Grow selection (word → command → line)"),
            (["⌃", "C"], "Clear line, or stop a program"),
            (["⌥", "⌘", "F"], "Split / join long command"),
            (["⇧", "⌘", "E"], "Tall editor"),
            (["⌥", "⌘", "E"], "Edit in $EDITOR"),
            (["⌘", "E"], "Editor on / off"),
            (["⌥", "click"], "Another cursor (⌥-drag: a column)"),
            (["⌥", "⌘", "G"], "Select the next match too"),
            (["⌃", "⌘", "G"], "Select every match"),
            (["⌘", "/"], "Comment lines out / in"),
            (["⇧", "⌥", "↓"], "Duplicate line"),
            (["⌃", "⌘", "↑↓"], "Move line"),
            (["#…", "⇥"], "Describe it, AI writes the command"),
        ]),
        ("Find & navigate", [
            (["⌘", "R"], "Search: history, tab, output, all tabs, saved"),
            (["⌃", "R"], "History right under the editor"),
            (["⌘", "B"], "Search this tab's commands"),
            (["⇧", "⌘", "F"], "Search all tabs"),
            (["⌥", "⇧", "⌘", "F"], "Search command output"),
            (["⌘", "F"], "Find on screen"),
            (["⌘", "J"], "Jump to a recent folder"),
            (["⇧", "⌘", "P"], "Command palette: every action"),
            (["⌘", "↑"], "Previous prompt"),
            (["⌘", "I"], "Ask AI for a command"),
        ]),
        ("Saved: ⌥⌘", [
            (["⌥", "⌘", "N"], "Saved panel: notebook and runbooks"),
            (["⌥", "⌘", "S"], "Save command to the Notebook"),
            (["⌥", "⌘", "R"], "Run from the Notebook"),
            (["⌥", "⌘", "O"], "Library: manage everything"),
            (["⌥", "⌘", "A"], "Aliases"),
            (["right-click"], "Every action for a command"),
        ]),
        ("Windows & panels: ⌃⌘", [
            (["⌃", "⌘", "S"], "Sidebar"),
            (["⌃", "⌘", "H"], "History (mistakes, compact)"),
            (["⌃", "⌘", "O"], "Filter output"),
            (["⌃", "⌘", "L"], "Log viewer"),
            (["⌃", "⌘", "W"], "Watch a command's output"),
            (["⌃", "⌘", "R"], "Record this tab / stop"),
        ]),
        ("Copy & paste", [
            (["⇧", "⌘", "C"], "Copy last output"),
            (["⇧", "⌘", "S"], "Export tab (Markdown, JSON, PDF…)"),
            (["⌥", "⌘", "C"], "Copy last command"),
            (["⇧", "⌘", "V"], "Clipboard history"),
        ]),
        ("Git", [
            (["⇧", "⌘", "B"], "Switch or create branch"),
            (["⇧", "⌘", "G"], "Changed files: diff, stage, open"),
            (["⇧", "⌘", "L"], "Commit history"),
            (["⌥", "⇧", "⌘", "L"], "Blame a file"),
        ]),
        ("Tabs & splits", [
            (["⌘", "T"], "New tab"),
            (["⇧", "⌘", "I"], "Rename tab (or double-click it)"),
            (["⌥", "⌘", "←→"], "Move tab (or drag it)"),
            (["⌘", "1…9"], "Go to tab"),
            (["⌘", "D"], "Split right"),
            (["⇧", "⌘", "D"], "Split down"),
            (["⌘", "W"], "Close pane"),
            (["⌥", "⇧", "⌘", "B"], "Type in all panes of the tab"),
        ]),
        ("View", [
            (["⌘", "K"], "Clear screen and scrollback"),
            (["⇧", "⌘", "K"], "Deep clean: reset, forget this tab's output"),
            (["⌘", "+"], "Bigger text"),
            (["⌘", ","], "Settings: font, theme, colors"),
            (["⌘", "/"], "This list"),
        ]),
    ]

    static func row(_ r: Row) -> NSView {
        let keys = NSStackView(views: r.keys.map { KeyCapView($0) })
        keys.spacing = 3
        keys.translatesAutoresizingMaskIntoConstraints = false
        keys.widthAnchor.constraint(equalToConstant: 92).isActive = true
        keys.alignment = .centerY
        keys.distribution = .gravityAreas
        let label = NSTextField(labelWithString: r.what)
        label.font = .systemFont(ofSize: 12.5)
        let row = NSStackView(views: [keys, label])
        row.spacing = 10
        return row
    }
}

/// ⌘/ — every shortcut on one sheet.
final class ShortcutsPanel: NSPanel {
    static var shared: ShortcutsPanel?

    static func toggle(over parent: NSWindow?) {
        if let p = shared, p.isVisible { p.close(); return }
        let p = ShortcutsPanel()
        shared = p
        if let parent {
            let f = parent.frame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.midY - p.frame.height / 2))
        } else {
            p.center()
        }
        p.makeKeyAndOrderFront(nil)
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Keyboard Shortcuts"
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false

        func column(_ groups: ArraySlice<(title: String, rows: [Shortcuts.Row])>) -> NSStackView {
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 6
            for g in groups {
                let h = NSTextField(labelWithString: g.title.uppercased())
                h.font = .systemFont(ofSize: 10.5, weight: .semibold)
                h.textColor = .secondaryLabelColor
                col.addArrangedSubview(h)
                col.setCustomSpacing(8, after: h)
                for r in g.rows { col.addArrangedSubview(Shortcuts.row(r)) }
                if let last = col.arrangedSubviews.last { col.setCustomSpacing(18, after: last) }
            }
            return col
        }
        let groups = Shortcuts.groups
        let cols = NSStackView(views: [column(groups[0..<1]), column(groups[1..<4]), column(groups[4..<groups.count])])
        cols.orientation = .horizontal
        cols.alignment = .top
        cols.spacing = 40
        cols.edgeInsets = NSEdgeInsets(top: 40, left: 32, bottom: 28, right: 32)
        let size = cols.fittingSize
        let fx = OverlayBackground.make(cornerRadius: 0)
        OverlayBackground.prepare(self)
        appearance = fx.appearance
        cols.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(cols)
        NSLayoutConstraint.activate([
            cols.leadingAnchor.constraint(equalTo: fx.leadingAnchor), cols.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            cols.topAnchor.constraint(equalTo: fx.topAnchor), cols.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        contentView = fx
        setContentSize(size)
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

/// A short introduction in its own row above the editor.
final class WelcomeView: NSView {
    static let height: CGFloat = 72
    private let hint = NSTextField(labelWithString: "Type a command below. Press Tab for completions.")
    private let onClose: () -> Void
    private let onCommands: () -> Void

    init(onClose: @escaping () -> Void, onCommands: @escaping () -> Void) {
        self.onClose = onClose
        self.onCommands = onCommands
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        hint.font = .systemFont(ofSize: 12, weight: .medium)
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping

        let commands = NSButton(title: "Commands", target: self, action: #selector(commandsTapped))
        commands.toolTip = "Open the command palette (⇧⌘P)"
        let tour = NSButton(title: "Take the Tour", target: self, action: #selector(tourTapped))
        let close = NSButton(title: "Done", target: self, action: #selector(closeTapped))
        for button in [commands, tour, close] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let actions = NSStackView(views: [commands, tour, close])
        actions.spacing = 6
        for view in [hint, actions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hint.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            hint.bottomAnchor.constraint(lessThanOrEqualTo: actions.topAnchor, constant: -4),
            actions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        let theme = GhosttyRuntime.shared.theme
        layer?.backgroundColor = theme.barBackground.cgColor
        layer?.borderColor = theme.foreground.withAlphaComponent(0.18).cgColor
        hint.textColor = theme.foreground
    }

    @objc private func closeTapped() { onClose() }
    @objc private func commandsTapped() { onClose(); onCommands() }
    @objc private func tourTapped() { onClose(); TourWindowController.shared.show() }
}
