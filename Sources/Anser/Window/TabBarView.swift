import AppKit

/// Anser's own tab bar, drawn in the window's title bar area.
/// Click to switch, double-click to rename, drag to reorder, right-click for
/// color / rename / close, + for a new tab.
final class TabBarView: NSView {
    weak var controller: TerminalWindowController?
    var inFullScreen = false { didSet { needsLayout = true } }
    private var items: [TabItemView] = []
    private let plus = NSButton()
    /// Lists every tab when there are too many to read their names.
    private let overflow = NSButton()
    private(set) var editingIndex: Int?

    static let colors: [(name: String, title: String)] = [
        ("red", "Red"), ("orange", "Orange"), ("yellow", "Yellow"), ("green", "Green"),
        ("blue", "Blue"), ("purple", "Purple"), ("teal", "Teal"),
    ]

    static func color(_ name: String?) -> NSColor? {
        guard let name else { return nil }
        let t = GhosttyRuntime.shared.theme
        switch name {
        case "red": return t.red
        case "orange": return .systemOrange
        case "yellow": return t.yellow
        case "green": return t.green
        case "blue": return t.blue
        case "purple": return t.magenta
        case "teal": return t.cyan
        default: return nil
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        plus.isBordered = false
        plus.imageScaling = .scaleProportionallyDown
        plus.toolTip = "New tab (⌘T)"
        plus.target = self
        plus.action = #selector(newTab)
        addSubview(plus)
        overflow.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "All tabs")
        overflow.isBordered = false
        overflow.imageScaling = .scaleProportionallyDown
        overflow.toolTip = "All tabs"
        overflow.target = self
        overflow.action = #selector(showAllTabs)
        overflow.isHidden = true
        addSubview(overflow)
        plus.setAccessibilityLabel("New tab")
        setAccessibilityLabel("Tabs")
    }

    @objc private func showAllTabs() {
        guard let c = controller else { return }
        let m = NSMenu()
        for (i, tab) in c.tabs.enumerated() {
            let item = ClosureMenuItem(title: c.title(of: tab)) { [weak c] in c?.selectTab(i) }
            item.state = i == c.selectedIndex ? .on : .off
            if let color = Self.color(tab.color) { item.image = Self.swatch(color) }
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: overflow.frame.minX, y: overflow.frame.minY), in: self)
    }

    /// Tabs are getting too narrow to read.
    var isCrowded: Bool { !overflow.isHidden }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    // Double-clicking empty space zooms the window, like a normal title bar.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { super.mouseDown(with: event) }
    }

    @objc private func newTab() {
        controller?.addTab(cwd: controller?.focusedPane?.session.cwd)
    }

    func reload() {
        guard editingIndex == nil, let c = controller else { needsLayout = true; return }
        while items.count < c.tabs.count {
            let v = TabItemView(bar: self)
            items.append(v)
            addSubview(v)
        }
        while items.count > c.tabs.count { items.removeLast().removeFromSuperview() }
        for (i, tab) in c.tabs.enumerated() {
            items[i].configure(index: i, title: c.title(of: tab), selected: i == c.selectedIndex,
                               color: Self.color(tab.color), activity: c.activity(of: tab))
        }
        plus.contentTintColor = GhosttyRuntime.shared.theme.foreground.withAlphaComponent(0.55)
        needsLayout = true
        needsDisplay = true
    }

    private var leadingInset: CGFloat { inFullScreen ? 8 : 78 }

    /// Where tab `i` sits.
    func frameForTab(_ i: Int, count: Int) -> NSRect {
        let crowded = (bounds.width - leadingInset - 40) / CGFloat(max(count, 1)) < 90
        let available = bounds.width - leadingInset - (crowded ? 66 : 40)
        let w = max(44, min(230, available / CGFloat(max(count, 1))))
        return NSRect(x: leadingInset + CGFloat(i) * w, y: 3, width: w - 2, height: bounds.height - 6)
    }

    /// Slide tabs into place (used while dragging) instead of jumping.
    private var animateNextLayout = false

    override func layout() {
        super.layout()
        let animate = animateNextLayout
        animateNextLayout = false
        for (i, v) in items.enumerated() where !v.isDragging {
            let target = frameForTab(i, count: items.count)
            guard v.frame != target else { continue }
            if animate {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    ctx.allowsImplicitAnimation = true
                    v.animator().frame = target
                }
            } else {
                v.frame = target
            }
        }
        let last = items.isEmpty ? leadingInset : frameForTab(items.count - 1, count: items.count).maxX
        plus.frame = NSRect(x: last + 6, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let crowded = !items.isEmpty && (bounds.width - leadingInset - 40) / CGFloat(items.count) < 90
        overflow.isHidden = !crowded
        overflow.frame = NSRect(x: plus.frame.maxX + 6, y: (bounds.height - 16) / 2, width: 16, height: 16)
        overflow.contentTintColor = plus.contentTintColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = GhosttyRuntime.shared.theme
        (t.background.blended(withFraction: t.isDark ? 0.18 : 0.06, of: .black) ?? t.background).setFill()
        bounds.fill()
        t.foreground.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    // MARK: Actions from tab items

    func select(_ i: Int) { controller?.selectTab(i) }
    func close(_ i: Int) { controller?.closeTabAsking(i) }

    /// Drop index for a tab dragged to x.
    func dropIndex(forX x: CGFloat) -> Int {
        let n = items.count
        guard n > 0 else { return 0 }
        let w = frameForTab(0, count: n).width + 2
        return min(n - 1, max(0, Int((x - leadingInset) / w)))
    }

    /// Called as a tab is dragged: when it crosses another tab's middle,
    /// the tabs swap places right away (the others slide aside).
    func dragMoved(_ item: TabItemView) {
        guard let from = items.firstIndex(where: { $0 === item }) else { return }
        let to = dropIndex(forX: item.frame.midX)
        guard to != from else { return }
        items.remove(at: from)
        items.insert(item, at: to)
        animateNextLayout = true
        controller?.moveTab(from: from, to: to)
    }

    /// Drag finished: snap the tab into its slot.
    func dragEnded(_ item: TabItemView) {
        guard let i = items.firstIndex(where: { $0 === item }) else { return }
        let target = frameForTab(i, count: items.count)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            item.animator().frame = target
        }, completionHandler: { [weak self] in
            item.layer?.zPosition = 0
            self?.reload()
        })
    }

    func beginEditing(_ i: Int) {
        guard items.indices.contains(i) else { return }
        editingIndex = i
        items[i].beginEditing()
    }

    func endEditing(_ i: Int, newTitle: String?) {
        editingIndex = nil
        if let newTitle { controller?.renameTab(i, to: newTitle) } else { reload() }
        controller?.focusedPane?.focus()
    }

    func menu(for i: Int) -> NSMenu {
        let m = NSMenu()
        let rename = m.addItem(withTitle: "Rename Tab…", action: #selector(menuRename(_:)), keyEquivalent: "")
        rename.tag = i; rename.target = self
        if controller?.tabs[safe: i]?.customTitle != nil {
            let reset = m.addItem(withTitle: "Use Automatic Name", action: #selector(menuResetName(_:)), keyEquivalent: "")
            reset.tag = i; reset.target = self
        }
        let colorItem = m.addItem(withTitle: "Color", action: nil, keyEquivalent: "")
        let colors = NSMenu()
        let none = colors.addItem(withTitle: "None", action: #selector(menuColor(_:)), keyEquivalent: "")
        none.tag = i; none.target = self; none.representedObject = nil
        colors.addItem(.separator())
        for (name, title) in Self.colors {
            let ci = colors.addItem(withTitle: title, action: #selector(menuColor(_:)), keyEquivalent: "")
            ci.tag = i; ci.target = self; ci.representedObject = name
            ci.image = Self.swatch(Self.color(name) ?? .gray)
            if controller?.tabs[safe: i]?.color == name { ci.state = .on }
        }
        colorItem.submenu = colors
        m.addItem(.separator())
        let count = controller?.tabs.count ?? 0
        if i > 0 {
            let left = m.addItem(withTitle: "Move Left", action: #selector(menuMoveLeft(_:)), keyEquivalent: "")
            left.tag = i; left.target = self
        }
        if i < count - 1 {
            let right = m.addItem(withTitle: "Move Right", action: #selector(menuMoveRight(_:)), keyEquivalent: "")
            right.tag = i; right.target = self
        }
        if count > 1 {
            let out = m.addItem(withTitle: "Move Tab to New Window", action: #selector(menuNewWindow(_:)), keyEquivalent: "")
            out.tag = i; out.target = self
        }
        m.addItem(.separator())
        let close = m.addItem(withTitle: "Close Tab", action: #selector(menuClose(_:)), keyEquivalent: "")
        close.tag = i; close.target = self
        if (controller?.tabs.count ?? 0) > 1 {
            let others = m.addItem(withTitle: "Close Other Tabs", action: #selector(menuCloseOthers(_:)), keyEquivalent: "")
            others.tag = i; others.target = self
        }
        return m
    }

    static func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func menuRename(_ s: NSMenuItem) { beginEditing(s.tag) }
    @objc private func menuResetName(_ s: NSMenuItem) { controller?.renameTab(s.tag, to: nil) }
    @objc private func menuColor(_ s: NSMenuItem) { controller?.setTabColor(s.tag, s.representedObject as? String) }
    @objc private func menuClose(_ s: NSMenuItem) { controller?.closeTabAsking(s.tag) }
    @objc private func menuMoveLeft(_ s: NSMenuItem) { controller?.moveTab(from: s.tag, to: s.tag - 1) }
    @objc private func menuMoveRight(_ s: NSMenuItem) { controller?.moveTab(from: s.tag, to: s.tag + 1) }
    @objc private func menuNewWindow(_ s: NSMenuItem) { controller?.moveTabToNewWindow(s.tag) }
    @objc private func menuCloseOthers(_ s: NSMenuItem) { controller?.closeOtherTabs(s.tag) }

    var itemViews: [TabItemView] { items }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// One tab in the tab bar.
final class TabItemView: NSView, NSTextFieldDelegate {
    private weak var bar: TabBarView?
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var editor: NSTextField?
    private var tracking: NSTrackingArea?
    private(set) var index = 0
    private var selected = false
    private var color: NSColor?
    private var activity: TerminalWindowController.Activity = .idle
    private let spinner = NSProgressIndicator()
    private var hovering = false { didSet { updateClose(); needsDisplay = true } }
    private(set) var isDragging = false
    private var dragStartX: CGFloat = 0
    private var dragOrigin: CGFloat = 0

    init(bar: TabBarView) {
        self.bar = bar
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        addSubview(label)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.toolTip = "Close tab"
        addSubview(closeButton)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    // Clicking a tab in a background window works on the first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(index: Int, title: String, selected: Bool, color: NSColor?, activity: TerminalWindowController.Activity) {
        self.index = index
        self.selected = selected
        self.color = color
        self.activity = activity
        if activity == .running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let state: String
        switch activity {
        case .running: state = ", running"
        case .failed: state = ", a command failed"
        case .done: state = ", finished"
        case .idle: state = ""
        }
        setAccessibilityLabel("Tab \(index + 1): \(title)\(state)")
        setAccessibilityValue(selected ? "selected" : nil)
        let t = GhosttyRuntime.shared.theme
        label.stringValue = title
        label.font = .systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        label.textColor = t.foreground.withAlphaComponent(selected ? 0.92 : 0.55)
        closeButton.contentTintColor = t.foreground.withAlphaComponent(0.5)
        toolTip = title + "\nDouble-click to rename"
        updateClose()
        needsLayout = true
        needsDisplay = true
    }

    var title: String { label.stringValue }

    private func updateClose() {
        let compactWidth = bounds.width > 0 && bounds.width < 110
        closeButton.isHidden = !((selected && !compactWidth) || hovering) || editor != nil
        needsLayout = true
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

    /// Narrow tabs (many open): tighter padding, smaller text, close on hover only.
    private var compact: Bool { bounds.width < 110 }

    override func layout() {
        super.layout()
        let dot: CGFloat = color != nil && !selected ? 12 : 0
        closeButton.frame = NSRect(x: compact ? 4 : 7, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.font = .systemFont(ofSize: compact ? 11 : 12, weight: selected ? .medium : .regular)
        label.lineBreakMode = compact ? .byTruncatingTail : .byTruncatingMiddle
        label.sizeToFit()
        let lh = label.frame.height
        let showsClose = !closeButton.isHidden
        let left: CGFloat = compact ? (showsClose ? 20 : 6) : 24
        let right: CGFloat = compact ? (activity == .idle ? 6 : 18) : 24
        label.frame = NSRect(x: left + dot, y: (bounds.height - lh) / 2, width: max(10, bounds.width - left - right - dot), height: lh)
        editor?.frame = NSRect(x: 22, y: (bounds.height - 20) / 2, width: bounds.width - 30, height: 20)
        spinner.frame = NSRect(x: bounds.width - 20, y: (bounds.height - 12) / 2, width: 12, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = GhosttyRuntime.shared.theme
        let r = bounds.insetBy(dx: 1, dy: 0)
        defer {
            // Finished / failed while you were in another tab.
            if activity == .failed || activity == .done {
                (activity == .failed ? t.red : t.blue).setFill()
                NSBezierPath(ovalIn: NSRect(x: bounds.width - 17, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
            }
        }
        if selected {
            t.background.setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            t.foreground.withAlphaComponent(0.10).setStroke()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            p.lineWidth = 1
            p.stroke()
            if let color {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX + 10, y: r.maxY - 3, width: r.width - 20, height: 2.5), xRadius: 1.25, yRadius: 1.25).fill()
            }
        } else {
            if hovering {
                t.foreground.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            }
            if let color {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 26, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
            }
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { bar?.beginEditing(index); return }
        bar?.select(index)
        dragStartX = event.locationInWindow.x
        dragOrigin = frame.origin.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let bar else { return }
        let dx = event.locationInWindow.x - dragStartX
        if !isDragging {
            guard abs(dx) >= 5 else { return }
            isDragging = true
            wantsLayer = true
            layer?.zPosition = 10      // float above the other tabs
            NSCursor.closedHand.push()
        }
        // Follow the mouse, but stay inside the tab strip.
        let minX = bar.frameForTab(0, count: 1).minX
        let maxX = bar.bounds.width - 44 - frame.width
        frame.origin.x = min(max(dragOrigin + dx, minX), max(minX, maxX))
        bar.dragMoved(self)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        bar?.dragEnded(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let bar else { return }
        NSMenu.popUpContextMenu(bar.menu(for: index), with: event, for: self)
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-click closes, like a browser.
        if event.buttonNumber == 2 { bar?.close(index) }
    }

    @objc private func closeTab() { bar?.close(index) }

    // MARK: Renaming

    func beginEditing() {
        let f = NSTextField(string: label.stringValue)
        f.font = .systemFont(ofSize: 12, weight: .medium)
        f.alignment = .center
        f.focusRingType = .none
        f.bezelStyle = .roundedBezel
        f.delegate = self
        editor = f
        addSubview(f)
        label.isHidden = true
        updateClose()
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    private func finishEditing(commit: Bool) {
        guard let f = editor else { return }
        let text = f.stringValue
        editor = nil
        f.removeFromSuperview()
        label.isHidden = false
        updateClose()
        bar?.endEditing(index, newTitle: commit ? text : nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { finishEditing(commit: false); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) { finishEditing(commit: true); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { finishEditing(commit: true) }
}
