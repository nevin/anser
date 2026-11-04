import AppKit

/// The command bar background with a hairline on top.
final class BarView: NSView {
    var fill: NSColor = .windowBackgroundColor
    var separator: NSColor = .separatorColor

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // Clicking anywhere in the bar focuses the editor.
    override func mouseDown(with event: NSEvent) {
        (superview as? PaneView)?.focus()
    }
}

/// The rounded input well the editor sits in. Its border lights up when focused.
final class CardView: NSView {
    var fill: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }
    var border: NSColor = .separatorColor { didSet { needsDisplay = true } }
    var focusBorder: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        fill.setFill()
        path.fill()
        (focused ? focusBorder : border).setStroke()
        path.lineWidth = focused ? 1.5 : 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        (superview?.superview as? PaneView)?.focus()
    }
}

/// Left of the editor: a ❯ prompt for one line, line numbers for several.
final class GutterView: NSView {
    weak var editor: CommandEditor?
    weak var scroll: NSScrollView?
    var promptColor: NSColor = .systemGreen { didSet { needsDisplay = true } }
    var numberColor: NSColor = .secondaryLabelColor
    var currentColor: NSColor = .labelColor
    var running = false { didSet { needsDisplay = true } }
    /// Show line numbers even for a single line (expanded editor).
    var alwaysNumbers = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// Width needed for the current number of lines.
    var preferredWidth: CGFloat {
        guard let editor, let font = editor.font, editor.lineCount > 1 || alwaysNumbers else { return 22 }
        let digits = String(max(10, editor.logicalLineCount)).count
        return CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width + 12
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, let font = editor.font, let lm = editor.layoutManager, let tc = editor.textContainer else { return }
        let top = editor.textContainerInset.height - (scroll?.contentView.bounds.origin.y ?? 0)
        if running || (editor.lineCount <= 1 && !alwaysNumbers) {
            let glyph = running ? "" : "❯"
            (glyph as NSString).draw(at: NSPoint(x: 5, y: top), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold), .foregroundColor: promptColor])
            return
        }
        // Line numbers for the lines that are actually visible.
        let ns = editor.string as NSString
        let caret = editor.selectedRange().location
        let small = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize - 1.5, weight: .regular)
        let visible = scroll?.contentView.bounds ?? bounds
        let glyphs = lm.glyphRange(forBoundingRect: visible.offsetBy(dx: 0, dy: -editor.textContainerInset.height), in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Number of the first visible line = newlines before it + 1.
        var lineNo = 1
        var scan = 0
        while scan < chars.location {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: scan, length: chars.location - scan))
            if r.location == NSNotFound { break }
            lineNo += 1
            scan = r.location + 1
        }
        var idx = ns.length == 0 ? 0 : ns.paragraphRange(for: NSRange(location: chars.location, length: 0)).location
        let end = NSMaxRange(chars)
        while true {
            let para = ns.paragraphRange(for: NSRange(location: min(idx, ns.length), length: 0))
            let rect: NSRect
            if idx >= ns.length {
                rect = lm.extraLineFragmentRect
                if rect == .zero { break }
            } else {
                rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: idx), effectiveRange: nil)
            }
            let isCurrent = caret >= para.location && (caret < NSMaxRange(para) || (caret == ns.length && NSMaxRange(para) == ns.length))
            let s = "\(lineNo)" as NSString
            let size = s.size(withAttributes: [.font: small])
            s.draw(at: NSPoint(x: bounds.width - size.width - 6, y: top + rect.minY + (rect.height - size.height) / 2),
                   withAttributes: [.font: small, .foregroundColor: isCurrent ? currentColor : numberColor])
            lineNo += 1
            if idx >= ns.length || NSMaxRange(para) <= idx || NSMaxRange(para) > end + 1 { break }
            idx = NSMaxRange(para)
            if idx == ns.length && !ns.hasSuffix("\n") { break }
        }
    }

    override func mouseDown(with event: NSEvent) {
        (superview?.superview?.superview as? PaneView)?.focus()
    }
}

/// A small icon + text label used in the status row.
final class ChipView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { needsDisplay = true } }
    /// Filled pill look (used for action chips like "Fix").
    var filled: NSColor? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingHead
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String?, text: String, color: NSColor, tooltip: String? = nil) {
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.contentTintColor = color
        icon.isHidden = icon.image == nil
        label.stringValue = text
        label.textColor = color
        toolTip = tooltip
        isHidden = text.isEmpty
        setAccessibilityElement(!text.isEmpty)
        setAccessibilityRole(onClick != nil ? .button : .staticText)
        setAccessibilityLabel(text + (tooltip.map { ". " + $0.replacingOccurrences(of: "\n", with: ". ") } ?? ""))
    }

    private var inset: CGFloat { filled != nil ? 7 : 3 }

    var preferredWidth: CGFloat {
        label.sizeToFit()
        return (icon.isHidden ? 0 : 15) + label.frame.width + 2 + inset * 2
    }

    override func layout() {
        super.layout()
        let ix: CGFloat = (icon.isHidden ? 0 : 15) + inset
        icon.frame = NSRect(x: inset, y: (bounds.height - 12) / 2, width: 12, height: 12)
        label.sizeToFit()
        label.frame = NSRect(x: ix, y: (bounds.height - label.frame.height) / 2, width: bounds.width - ix - inset, height: label.frame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 0)
        if let filled {
            filled.withAlphaComponent(hovering ? 0.28 : 0.18).setFill()
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        } else if hovering, onClick != nil {
            (label.textColor ?? .labelColor).withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        }
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

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
}

enum PathDisplay {
    /// "~/dev/library/anser/build" → "~/dev/…/anser/build" when long.
    static func short(_ path: String, max: Int = 36) -> String {
        var p = path
        let home = NSHomeDirectory()
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        guard p.count > max else { return p }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 4 else { return p }
        let head = parts.prefix(2).joined(separator: "/")
        let tail = parts.suffix(2).joined(separator: "/")
        return head + "/…/" + tail
    }
}


/// A translucent layer over the terminal of panes that don't have focus.
/// Clicks pass straight through.
final class DimView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) { fill.setFill(); bounds.fill() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Small title strip over each pane when a tab is split: what's running,
/// where, and buttons to zoom or close the pane.
final class PaneHeaderView: NSView {
    weak var pane: PaneView?
    var zoomed = false { didSet { refresh() } }
    private let title = NSTextField(labelWithString: "")
    private let zoomButton = NSButton()
    private let closeButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        addSubview(title)
        for (b, sym, tip, sel) in [(zoomButton, "arrow.up.left.and.arrow.down.right", "Zoom pane (⇧⌘↩)", #selector(zoom)),
                                   (closeButton, "xmark", "Close pane (⌘W)", #selector(close))] {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
            b.isBordered = false
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = tip
            b.target = self
            b.action = sel
            b.setAccessibilityLabel(tip)
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        guard let pane else { return }
        let t = GhosttyRuntime.shared.theme
        let focused = pane.isFocusedPane
        title.stringValue = pane.displayTitle + "  ·  " + PathDisplay.short(pane.session.cwd, max: 40) + (zoomed ? "  ·  zoomed" : "")
        title.textColor = t.foreground.withAlphaComponent(focused ? 0.85 : 0.45)
        zoomButton.image = NSImage(systemSymbolName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                   accessibilityDescription: zoomButton.toolTip)
        zoomButton.toolTip = zoomed ? "Restore split (⇧⌘↩)" : "Zoom pane (⇧⌘↩)"
        for b in [zoomButton, closeButton] { b.contentTintColor = t.foreground.withAlphaComponent(0.5) }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 12) / 2, width: 12, height: 12)
        zoomButton.frame = NSRect(x: bounds.width - 42, y: (bounds.height - 12) / 2, width: 12, height: 12)
        title.sizeToFit()
        title.frame = NSRect(x: 10, y: (bounds.height - title.frame.height) / 2, width: bounds.width - 60, height: title.frame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pane else { return }
        let t = GhosttyRuntime.shared.theme
        t.barBackground.setFill()
        bounds.fill()
        (pane.isFocusedPane ? t.blue.withAlphaComponent(0.8) : t.foreground.withAlphaComponent(0.08)).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: pane.isFocusedPane ? 2 : 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { zoom() } else { pane?.focus() }
    }

    @objc private func zoom() { if let pane { pane.windowController?.toggleZoom(pane) } }
    @objc private func close() { if let pane { pane.windowController?.closeAsking(pane) } }
}
