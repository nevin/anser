import AppKit

/// ⌘F search over the terminal's scrollback, powered by Ghostty's own search.
final class FindBar: NSView, NSSearchFieldDelegate {
    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private weak var pane: PaneView?
    private var total = -1
    private var selected = -1

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 34))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        shadow = NSShadow()

        field.placeholderString = "Find in terminal"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.focusRingType = .none
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right

        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")!, target: self, action: #selector(previous))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")!, target: self, action: #selector(nextMatch))
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!, target: self, action: #selector(closeBar))
        for b in [prev, next, close] { b.isBordered = false; b.imageScaling = .scaleProportionallyDown }
        prev.toolTip = "Previous (⇧⏎)"
        next.toolTip = "Next (⏎)"

        field.frame = NSRect(x: 6, y: 6, width: 190, height: 22)
        count.frame = NSRect(x: 198, y: 9, width: 56, height: 16)
        prev.frame = NSRect(x: 258, y: 7, width: 20, height: 20)
        next.frame = NSRect(x: 280, y: 7, width: 20, height: 20)
        close.frame = NSRect(x: 304, y: 7, width: 20, height: 20)
        [field, count, prev, next, close].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus(with text: String? = nil) {
        if let text, !text.isEmpty { field.stringValue = text; search() }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func update(total: Int? = nil, selected: Int? = nil) {
        if let total { self.total = total }
        if let selected { self.selected = selected }
        if field.stringValue.isEmpty || self.total < 0 { count.stringValue = ""; return }
        count.stringValue = self.total == 0 ? "none" : "\(max(self.selected, 0) + 1)/\(self.total)"
        count.textColor = self.total == 0 ? .systemRed : .secondaryLabelColor
    }

    private func search() {
        total = -1
        pane?.surfaceView.binding(field.stringValue.isEmpty ? "end_search" : "search:" + field.stringValue)
        update()
    }

    func controlTextDidChange(_ obj: Notification) { search() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previous() } else { nextMatch() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeBar(); return true
        default: return false
        }
    }

    @objc private func previous() { pane?.surfaceView.binding("navigate_search:previous") }
    @objc private func nextMatch() { pane?.surfaceView.binding("navigate_search:next") }
    @objc func closeBar() { pane?.hideFind() }
}
