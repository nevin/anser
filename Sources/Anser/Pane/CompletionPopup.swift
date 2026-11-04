import AppKit
import AnserCore

/// Floating list of completions anchored to the caret.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let detail = NSTextField(labelWithString: "")
    private var items: [Completion] = []
    private weak var parentWindow: NSWindow?
    /// Side panel with the full description of the highlighted item.
    private let docsPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let docsText = NSTextField(wrappingLabelWithString: "")
    private(set) var docsVisible = false

    var onAccept: ((Completion) -> Void)?
    var theme = GhosttyRuntime.shared.theme

    static let rowHeight: CGFloat = 24
    static let maxRows = 9

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 8
        fx.layer?.masksToBounds = true
        panel.contentView = fx

        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        fx.addSubview(scroll)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        fx.addSubview(detail)

        docsPanel.isOpaque = false
        docsPanel.backgroundColor = .clear
        docsPanel.hasShadow = true
        docsPanel.level = .popUpMenu
        let dfx = NSVisualEffectView()
        dfx.material = .popover
        dfx.state = .active
        dfx.wantsLayer = true
        dfx.layer?.cornerRadius = 8
        dfx.layer?.masksToBounds = true
        docsPanel.contentView = dfx
        docsText.isSelectable = false
        dfx.addSubview(docsText)
    }

    /// Shows the full description of the highlighted completion beside the list.
    private func updateDocs() {
        guard panel.isVisible, let c = selected, let detail = c.detail, !detail.isEmpty,
              ![.history, .file, .folder].contains(c.kind), let window = parentWindow else { hideDocs(); return }
        let kind: String
        switch c.kind {
        case .subcommand: kind = "subcommand"
        case .option: kind = "option"
        case .branch: kind = "git branch"
        case .command: kind = "command"
        case .builtin: kind = "shell builtin"
        case .alias: kind = "alias"
        case .function: kind = "shell function"
        case .variable: kind = "environment variable"
        case .snippet: kind = "snippet"
        default: kind = "value"
        }
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: c.display + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        s.append(NSAttributedString(string: kind.uppercased() + "\n", attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor]))
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 4
        s.append(NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        if c.insert != c.display {
            s.append(NSAttributedString(string: "\n\nInserts  ", attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.tertiaryLabelColor]))
            s.append(NSAttributedString(string: c.insert, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        docsText.attributedStringValue = s
        let w: CGFloat = 300
        let size = docsText.sizeThatFits(NSSize(width: w - 24, height: 600))
        let h = min(panel.frame.height, max(60, size.height + 22))
        let main = panel.frame
        var x = main.maxX + 6
        if let screen = window.screen, x + w > screen.visibleFrame.maxX { x = main.minX - w - 6 }
        docsPanel.appearance = panel.appearance
        docsPanel.setFrame(NSRect(x: x, y: main.maxY - h, width: w, height: h), display: false)
        docsText.frame = NSRect(x: 12, y: 10, width: w - 24, height: h - 20)
        if docsPanel.parent !== window { docsPanel.parent?.removeChildWindow(docsPanel); window.addChildWindow(docsPanel, ordered: .above) }
        docsPanel.orderFront(nil)
        docsVisible = true
    }

    func snapshotDocs(to path: String) {
        guard docsVisible, let v = docsPanel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func hideDocs() {
        guard docsVisible else { return }
        docsPanel.parent?.removeChildWindow(docsPanel)
        docsPanel.orderOut(nil)
        docsVisible = false
    }

    var isVisible: Bool { panel.isVisible }
    var selected: Completion? {
        let r = table.selectedRow
        return r >= 0 && r < items.count ? items[r] : nil
    }

    func show(_ items: [Completion], query: String, at caret: NSRect, in window: NSWindow?) {
        self.items = items
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        updateDetail()

        let rows = min(items.count, Self.maxRows)
        let detailH: CGFloat = 20
        let h = CGFloat(rows) * Self.rowHeight + 8 + detailH
        let w = min(640, max(380, widest() + 40))
        guard let screen = window?.screen ?? NSScreen.main else { return }
        var origin = NSPoint(x: caret.minX - 30, y: caret.maxY + 6)
        // Prefer above the caret (the editor sits at the bottom); fall back below.
        if origin.y + h > screen.visibleFrame.maxY { origin.y = caret.minY - h - 4 }
        origin.x = min(max(origin.x, screen.visibleFrame.minX + 4), screen.visibleFrame.maxX - w - 4)
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: w, height: h), display: false)
        scroll.frame = NSRect(x: 0, y: detailH, width: w, height: h - detailH)
        table.tableColumns[0].width = w - 8
        detail.frame = NSRect(x: 10, y: 3, width: w - 20, height: 15)

        if let window, panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parentWindow = window
        }
        panel.orderFront(nil)
        updateDocs()
    }

    func snapshot(to path: String) {
        guard let v = panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func hide() {
        hideDocs()
        guard panel.isVisible else { return }
        parentWindow?.removeChildWindow(panel)
        parentWindow = nil
        panel.orderOut(nil)
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        var r = table.selectedRow + delta
        if delta == 1 || delta == -1 {
            r = (r + items.count) % items.count
        } else {
            r = min(max(r, 0), items.count - 1)
        }
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
        updateDetail()
    }

    @objc private func clicked() {
        guard let c = selected else { return }
        onAccept?(c)
    }

    private func updateDetail() {
        guard let c = selected else { detail.stringValue = ""; return }
        let hint = "⇥ accept   ↑↓ choose   esc close"
        if let d = c.detail, !d.isEmpty, c.kind != .history {
            detail.stringValue = d + "    " + hint
        } else {
            detail.stringValue = hint
        }
    }

    private func widest() -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        var w: CGFloat = 0
        for c in items.prefix(60) {
            var line = (c.display as NSString).size(withAttributes: [.font: font]).width
            if let d = c.detail, c.kind != .history { line += min(260, (d as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5)]).width + 24) }
            w = max(w, line + 34)
        }
        return w
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail(); updateDocs() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = items[row]
        let cell = (tableView.makeView(withIdentifier: .init("row"), owner: nil) as? CompletionRow) ?? CompletionRow()
        cell.identifier = .init("row")
        cell.configure(c)
        return cell
    }

    static func symbol(for kind: Completion.Kind) -> (String, NSColor) {
        switch kind {
        case .history: ("clock.arrow.circlepath", .systemGray)
        case .command: ("terminal", .systemGreen)
        case .alias: ("arrowshape.turn.up.right", .systemPurple)
        case .builtin: ("chevron.left.forwardslash.chevron.right", .systemTeal)
        case .function: ("function", .systemTeal)
        case .subcommand: ("arrow.turn.down.right", .systemBlue)
        case .option: ("flag", .systemOrange)
        case .file: ("doc", .secondaryLabelColor)
        case .folder: ("folder", .systemBlue)
        case .branch: ("arrow.triangle.branch", .systemPink)
        case .argument: ("smallcircle.filled.circle", .systemIndigo)
        case .variable: ("dollarsign", .systemYellow)
        case .snippet: ("text.badge.star", .systemYellow)
        }
    }
}

private final class CompletionRow: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingTail
        detail.alignment = .right
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11.5)
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon); addSubview(title); addSubview(detail)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 16),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ c: Completion) {
        let (name, color) = CompletionPopup.symbol(for: c.kind)
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: c.kind.rawValue)
        icon.contentTintColor = color
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
        let s = NSMutableAttributedString(string: c.display, attributes: [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.88)])
        let chars = Array(c.display)
        var utf16Offsets: [Int] = []
        var off = 0
        for ch in chars { utf16Offsets.append(off); off += ch.utf16.count }
        for p in c.positions where p < chars.count {
            s.addAttributes([.font: bold, .foregroundColor: NSColor.controlAccentColor],
                            range: NSRange(location: utf16Offsets[p], length: chars[p].utf16.count))
        }
        title.attributedStringValue = s
        detail.stringValue = c.kind == .history ? "" : (c.detail ?? "")
    }
}
