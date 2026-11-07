import AppKit
import Carbon.HIToolbox

struct PickerItem {
    var title: String
    var subtitle: String?
    var accessory: String?
    var accessoryColor: NSColor?
    var positions: [Int]
    var payload: Any
    /// Names (workflows, folders…) read better in the system font; commands stay monospaced.
    var proportional = false
}

/// A search-as-you-type list used for history, clipboard history and the
/// command palette.
final class PickerPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    struct Config {
        var title: String
        var placeholder: String
        var scopes: [String]
        var hint: String
        var provider: (String, Int) -> [PickerItem]
        var onAccept: (PickerItem, NSEvent.ModifierFlags) -> Void
        var onCopy: ((PickerItem) -> String?)?
        var onDelete: ((PickerItem) -> Void)?
        /// Optional right-hand preview for the selected item (diff, output, log…).
        var preview: ((PickerItem) async -> NSAttributedString?)? = nil
        /// What you can do with an item: shown when you right-click it, and the
        /// ones marked `button` also as buttons at the bottom (for the selected item).
        var actions: [Action] = []
    }

    struct Action {
        var title: String
        var symbol: String
        var button = false
        /// Shown only for items this returns true for.
        var applies: (PickerItem) -> Bool = { _ in true }
        /// A submenu instead of an action (e.g. the files in a folder).
        var children: ((PickerItem) -> [Action])? = nil
        var closesPicker = true
        var run: (PickerItem) -> Void = { _ in }
    }

    /// Monospaced preview text; colors diff lines when `diff` is true.
    static func previewText(_ s: String, diff: Bool = false) -> NSAttributedString {
        let t = GhosttyRuntime.shared.theme
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let out = NSMutableAttributedString()
        for line in s.split(separator: "\n", omittingEmptySubsequences: false).prefix(400) {
            var color = t.foreground.withAlphaComponent(0.85)
            if diff {
                if line.hasPrefix("+") && !line.hasPrefix("+++") { color = t.green }
                else if line.hasPrefix("-") && !line.hasPrefix("---") { color = t.red }
                else if line.hasPrefix("@@") { color = t.cyan }
                else if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("+++") || line.hasPrefix("---") { color = t.dim }
            }
            out.append(NSAttributedString(string: String(line) + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        return out
    }

    private let config: Config
    private let search = NSSearchField()
    private let scopeControl = NSSegmentedControl()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let previewScroll = NSScrollView()
    private let previewText = NSTextView()
    private var previewTask: Task<Void, Never>?
    private let titleLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private var items: [PickerItem] = []
    private var scope = 0
    private var closing = false
    var onClose: (() -> Void)?

    init(config: Config) {
        self.config = config
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = true
        build()
        reload()
    }

    override var canBecomeKey: Bool { true }

    private func build() {
        // Themed like the terminal rather than the system's gray panel.
        let t = GhosttyRuntime.shared.theme
        let fx = NSView()
        fx.wantsLayer = true
        fx.layer?.backgroundColor = (t.background.blended(withFraction: t.isDark ? 0.05 : 0.02, of: t.isDark ? .white : .black) ?? t.background).cgColor
        fx.layer?.cornerRadius = 12
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = t.foreground.withAlphaComponent(0.14).cgColor
        contentView = fx
        backgroundColor = .clear
        isOpaque = false
        appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)

        previewText.isEditable = false
        previewText.isSelectable = true
        previewText.drawsBackground = false
        previewText.textContainerInset = NSSize(width: 10, height: 8)
        previewText.isHorizontallyResizable = true
        previewText.textContainer?.widthTracksTextView = false
        previewText.textContainer?.containerSize = NSSize(width: 4000, height: CGFloat.greatestFiniteMagnitude)
        previewScroll.documentView = previewText
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.drawsBackground = true
        previewScroll.backgroundColor = t.background
        previewScroll.wantsLayer = true
        previewScroll.layer?.cornerRadius = 8
        previewScroll.isHidden = config.preview == nil

        titleLabel.stringValue = config.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor

        search.placeholderString = config.placeholder
        search.font = .systemFont(ofSize: 15)
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.focusRingType = .none

        scopeControl.segmentCount = config.scopes.count
        for (i, s) in config.scopes.enumerated() { scopeControl.setLabel(s, forSegment: i) }
        scopeControl.selectedSegment = 0
        scopeControl.controlSize = .small
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.isHidden = config.scopes.isEmpty

        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 40
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay

        hintLabel.stringValue = config.hint
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right

        // Right-click a row for its actions; buttons for the main ones.
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        for (i, a) in config.actions.enumerated() where a.button {
            let b = NSButton(title: a.title, target: self, action: #selector(actionButton(_:)))
            b.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.controlSize = .small
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: 11)
            b.tag = i
            b.toolTip = a.title + " (or right-click an item for more)"
            buttonRow.addArrangedSubview(b)
        }
        buttonRow.spacing = 6
        buttonRow.isHidden = buttonRow.arrangedSubviews.isEmpty
        if !config.actions.isEmpty { hintLabel.stringValue = config.hint + "   ·   right-click for more" }

        for v in [titleLabel, search, scopeControl, scroll, previewScroll, hintLabel, countLabel, buttonRow] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: fx.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 16),
            scopeControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            scopeControl.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -14),
            search.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 6),
            config.preview == nil
                ? scroll.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -6)
                : scroll.widthAnchor.constraint(equalTo: fx.widthAnchor, multiplier: 0.48),
            scroll.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -6),
            previewScroll.topAnchor.constraint(equalTo: scroll.topAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            previewScroll.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 6),
            previewScroll.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -10),
            hintLabel.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 16),
            hintLabel.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -8),
            countLabel.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: hintLabel.centerYAnchor),
            buttonRow.centerYAnchor.constraint(equalTo: hintLabel.centerYAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -12),
            buttonRow.leadingAnchor.constraint(greaterThanOrEqualTo: hintLabel.trailingAnchor, constant: 8),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: hintLabel.trailingAnchor, constant: 8),
        ])
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.lineBreakMode = .byTruncatingTail
    }

    func present(over parent: NSWindow) {
        appearance = parent.appearance
        let pf = parent.frame
        let w = min(config.preview == nil ? 720 : 1040, pf.width - 40)
        let h = min(460, pf.height - 80)
        setFrame(NSRect(x: pf.midX - w / 2, y: pf.maxY - h - 70, width: w, height: h), display: true)
        table.tableColumns[0].width = config.preview == nil ? w - 20 : w * 0.48 - 14
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(search)
    }

    override func close() {
        guard !closing else { return }
        closing = true
        parent?.removeChildWindow(self)
        orderOut(nil)
        super.close()
        onClose?()
    }

    override func resignKey() {
        super.resignKey()
        // Clicking elsewhere dismisses the picker.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isKeyWindow, self.attachedSheet == nil else { return }
            self.close()
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    private func reload() {
        items = config.provider(search.stringValue, scope)
        table.reloadData()
        if !items.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        countLabel.stringValue = items.isEmpty ? "No matches" : "\(items.count)\(items.count >= 200 ? "+" : "")"
        updatePreview()
    }

    /// Re-runs the search (e.g. when more results arrived in the background).
    func refresh() { reload() }

    /// A short status after the title ("fetching…"); nil shows the title alone.
    func setStatus(_ status: String?) {
        titleLabel.stringValue = config.title + (status.map { "  ·  " + $0 } ?? "")
    }
    var titleText: String { titleLabel.stringValue }

    /// For tests: type a query as the user would.
    func setQuery(_ q: String) {
        search.stringValue = q
        reload()
    }

    var itemTitles: [String] { items.map(\.title) }

    /// For tests: pick a scope tab as the user would.
    /// Selects (and scrolls to) an item, e.g. the line you came to blame.
    func selectRow(_ i: Int) {
        guard items.indices.contains(i) else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(min(items.count - 1, i + 6))
        table.scrollRowToVisible(max(0, i - 6))
        table.scrollRowToVisible(i)
    }
    var selectedRowIndex: Int { table.selectedRow }
    /// Tests: press ⏎ on the selected item.
    func acceptSelectedForTest() { accept([]) }

    func selectScope(_ i: Int) {
        scopeControl.selectedSegment = i
        scopeChanged()
    }

    @objc private func scopeChanged() {
        scope = scopeControl.selectedSegment
        reload()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    private var selectedItem: PickerItem? {
        let r = table.selectedRow
        return r >= 0 && r < items.count ? items[r] : nil
    }

    private func accept(_ mods: NSEvent.ModifierFlags) {
        guard let item = selectedItem else { NSSound.beep(); return }
        let keep = config.onAccept
        close()
        keep(item, mods)
    }

    @objc private func doubleClicked() { accept([]) }

    // MARK: Actions (right-click menu and buttons)

    @objc private func actionButton(_ b: NSButton) {
        guard config.actions.indices.contains(b.tag), let item = selectedItem else { NSSound.beep(); return }
        perform(config.actions[b.tag], on: item)
    }

    private func perform(_ a: Action, on item: PickerItem) {
        guard a.applies(item) else { NSSound.beep(); return }
        if a.closesPicker { close() }
        a.run(item)
    }

    /// The menu for the right-clicked row (it becomes the selection, so the preview follows).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard items.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        for item in menuItems(for: items[row], config.actions) { menu.addItem(item) }
    }

    private func menuItems(for item: PickerItem, _ actions: [Action]) -> [NSMenuItem] {
        actions.filter { $0.applies(item) }.map { a in
            let mi: NSMenuItem
            if let children = a.children {
                mi = NSMenuItem(title: a.title, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let kids = menuItems(for: item, children(item))
                if kids.isEmpty { sub.addItem(NSMenuItem(title: "Nothing here", action: nil, keyEquivalent: "")) } else { kids.forEach(sub.addItem) }
                mi.submenu = sub
            } else {
                mi = ClosureMenuItem(title: a.title) { [weak self] in self?.perform(a, on: item) }
            }
            mi.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil)
            return mi
        }
    }

    /// For tests: the right-click menu's titles for an item.
    func actionTitles(forRow row: Int) -> [String] {
        guard items.indices.contains(row) else { return [] }
        return menuItems(for: items[row], config.actions).map(\.title)
    }
    var buttonTitles: [String] { buttonRow.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        switch sel {
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): move(-8); return true
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): move(8); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            accept(flags); return true
        case #selector(NSResponder.insertTab(_:)):
            if !config.scopes.isEmpty {
                scopeControl.selectedSegment = (scopeControl.selectedSegment + 1) % config.scopes.count
                scopeChanged()
            }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if !config.scopes.isEmpty {
                scopeControl.selectedSegment = (scopeControl.selectedSegment - 1 + config.scopes.count) % config.scopes.count
                scopeChanged()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            // Cmd-Backspace: forget the selected item.
            if let item = selectedItem, let del = config.onDelete {
                del(item)
                let r = table.selectedRow
                reload()
                if r < items.count { table.selectRowIndexes([r], byExtendingSelection: false) }
                return true
            }
            return false
        default: return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "c",
           (search.currentEditor()?.selectedRange.length ?? 0) == 0,
           let item = selectedItem, let text = config.onCopy?(item) {
            TerminalWindowController.copy(text)
            close()
            return true
        }
        if flags.contains(.command), Int(event.keyCode) == kVK_Return || Int(event.keyCode) == kVK_ANSI_KeypadEnter {
            accept(flags)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func move(_ d: Int) {
        guard !items.isEmpty else { return }
        let r = min(max(table.selectedRow + d, 0), items.count - 1)
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updatePreview() }

    /// Loads the preview for the selected row (slightly delayed so fast
    /// arrowing through the list doesn't run a command per row).
    private func updatePreview() {
        guard let preview = config.preview else { return }
        previewTask?.cancel()
        guard let item = selectedItem else { showPreviewNote("Nothing selected"); return }
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)
            if Task.isCancelled { return }
            // Say it's loading if the preview takes more than a moment (git on a big repo).
            let loading = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                if !Task.isCancelled { self?.showPreviewNote("Loading…") }
            }
            let text = await preview(item)
            loading.cancel()
            guard !Task.isCancelled, let self else { return }
            if let text, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.previewText.textStorage?.setAttributedString(text)
            } else {
                self.showPreviewNote("Nothing to preview")
            }
            self.previewText.scrollToBeginningOfDocument(nil)
        }
    }

    /// A dim one-line message in the preview pane (loading, empty).
    private func showPreviewNote(_ note: String) {
        let t = GhosttyRuntime.shared.theme
        previewText.textStorage?.setAttributedString(NSAttributedString(string: note, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: t.foreground.withAlphaComponent(0.45)]))
    }

    var previewString: String { previewText.string }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("p"), owner: nil) as? PickerRow) ?? PickerRow()
        cell.identifier = .init("p")
        cell.configure(items[row])
        let it = items[row]
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.cell)
        cell.setAccessibilityLabel([it.title, it.subtitle, it.accessory].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", "))
        return cell
    }
}

private final class PickerRow: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let accessory = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        for v in [title, subtitle, accessory] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.lineBreakMode = .byTruncatingMiddle
        title.maximumNumberOfLines = 1
        title.cell?.wraps = false
        title.cell?.truncatesLastVisibleLine = true
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        accessory.font = .systemFont(ofSize: 11.5, weight: .medium)
        accessory.alignment = .right
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -10),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            accessory.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: PickerItem) {
        let font = item.proportional ? NSFont.systemFont(ofSize: 13, weight: .medium) : NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bold = item.proportional ? NSFont.systemFont(ofSize: 13, weight: .bold) : NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        // Shorten long titles in the middle so the end (e.g. a folder's name) stays visible.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        let s = NSMutableAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
        let chars = Array(item.title)
        var offsets: [Int] = []
        var o = 0
        for c in chars { offsets.append(o); o += c.utf16.count }
        for p in item.positions where p < chars.count {
            s.addAttributes([.font: bold, .foregroundColor: NSColor.controlAccentColor], range: NSRange(location: offsets[p], length: chars[p].utf16.count))
        }
        title.attributedStringValue = s
        subtitle.stringValue = item.subtitle ?? ""
        subtitle.isHidden = item.subtitle == nil
        accessory.stringValue = item.accessory ?? ""
        accessory.textColor = item.accessoryColor ?? .tertiaryLabelColor
    }
}
