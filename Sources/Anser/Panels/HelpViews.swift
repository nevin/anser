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
        ]),
        ("Find & navigate", [
            (["⌘", "R"], "Search all history"),
            (["⌘", "B"], "Commands in this tab"),
            (["⌘", "F"], "Find in output"),
            (["⌘", "J"], "Jump to a recent folder"),
            (["⌥", "⌘", "R"], "Run a workflow"),
            (["⌘", "I"], "Ask Claude for a command"),
            (["⇧", "⌘", "S"], "Export tab as Markdown"),
            (["⇧", "⌘", "P"], "Command palette"),
            (["⌘", "↑"], "Previous prompt"),
        ]),
        ("Copy & paste", [
            (["⇧", "⌘", "C"], "Copy last output"),
            (["⌥", "⌘", "C"], "Copy last command"),
            (["⇧", "⌘", "V"], "Clipboard history"),
        ]),
        ("Git", [
            (["⇧", "⌘", "B"], "Switch or create branch"),
            (["⇧", "⌘", "G"], "Changed files: diff, stage, open"),
        ]),
        ("Tabs & splits", [
            (["⌘", "T"], "New tab"),
            (["⇧", "⌘", "I"], "Rename tab (or double-click it)"),
            (["⌥", "⌘", "←→"], "Move tab (or drag it)"),
            (["⌘", "1…9"], "Go to tab"),
            (["⌘", "D"], "Split right"),
            (["⇧", "⌘", "D"], "Split down"),
            (["⌘", "W"], "Close pane"),
        ]),
        ("View", [
            (["⌘", "K"], "Clear screen"),
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
        let cols = NSStackView(views: [column(groups[0..<2]), column(groups[2..<groups.count])])
        cols.orientation = .horizontal
        cols.alignment = .top
        cols.spacing = 40
        cols.edgeInsets = NSEdgeInsets(top: 40, left: 32, bottom: 28, right: 32)
        contentView = cols
        setContentSize(cols.fittingSize)
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

/// First-launch card that explains the basics, shown over the terminal.
final class WelcomeView: NSView {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: 540, height: 190))
        wantsLayer = true
        let t = GhosttyRuntime.shared.theme
        layer?.backgroundColor = (t.background.blended(withFraction: t.isDark ? 0.08 : 0.04, of: t.isDark ? .white : .black) ?? t.background).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = t.foreground.withAlphaComponent(0.12).cgColor
        shadow = NSShadow()
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 12

        let title = NSTextField(labelWithString: "Welcome to Anser")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = t.foreground
        let sub = NSTextField(labelWithString: "Type commands in the bar at the bottom. A few things worth knowing:")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = t.foreground.withAlphaComponent(0.65)

        let tips: [Shortcuts.Row] = [
            (["⇥"], "Complete commands, flags, files and git branches"),
            (["↑"], "Bring back earlier commands; ⌘R searches all of them"),
            (["⇧", "⌘", "C"], "Copy the last command's output"),
            (["⌘", "/"], "See every shortcut"),
        ]
        let rows = NSStackView(views: tips.map { r in
            let v = Shortcuts.row(r)
            (v.subviews.last as? NSTextField)?.textColor = t.foreground.withAlphaComponent(0.85)
            return v
        })
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6

        let close = NSButton(title: "Got it", target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded
        close.keyEquivalent = ""

        let stack = NSStackView(views: [title, sub, rows])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: sub)
        for v in [stack, close] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            close.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped() { onClose() }
}
