import AppKit

/// The command bar background: a hairline on top, and another above the hints row.
final class BarView: NSView {
    var fill: NSColor = .windowBackgroundColor
    var separator: NSColor = .separatorColor
    /// Sitting right under the output (no band; the line still marks where input starts).
    var floating = false { didSet { if floating != oldValue { needsDisplay = true } } }
    /// Where the hints row starts (its top edge), or nil for no second line.
    var hintsLineY: CGFloat? { didSet { if hintsLineY != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        if !floating {
            fill.setFill()
            bounds.fill()
        }
        // One device pixel, so the lines stay thin on any screen.
        let px = 1 / (window?.backingScaleFactor ?? 2)
        separator.setFill()
        NSRect(x: 0, y: bounds.height - px, width: bounds.width, height: px).fill()
        if let y = hintsLineY {
            NSRect(x: 0, y: y - px, width: bounds.width, height: px).fill()
        }
    }

    // Clicking anywhere in the bar focuses the editor.
    override func mouseDown(with event: NSEvent) {
        (superview as? PaneView)?.focus()
    }
}

/// Holds the editor on the input line. Flat: the lines above and below mark the
/// input area, so there's no box around it.
final class CardView: NSView {
    var focused = false

    override func mouseDown(with event: NSEvent) {
        (superview?.superview as? PaneView)?.focus()
    }
}

/// Left of the editor: a ❯ prompt for one line, line numbers for several.
final class GutterView: NSView {
    static let promptInset: CGFloat = 5
    weak var editor: CommandEditor?
    weak var scroll: NSScrollView?
    var promptColor: NSColor = .systemGreen { didSet { needsDisplay = true } }
    var numberColor: NSColor = .secondaryLabelColor
    var currentColor: NSColor = .labelColor
    var running = false { didSet { needsDisplay = true } }
    /// The input isn't focused: the ❯ fades (there's no box to light up).
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
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
            (glyph as NSString).draw(at: NSPoint(x: Self.promptInset, y: top), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold), .foregroundColor: dimmed ? promptColor.withAlphaComponent(0.45) : promptColor])
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
/// What a status-row chip means; each has one color everywhere.
enum ChipRole {
    /// Something went wrong (failed command, failed tests, conflicts).
    case problem
    /// Waiting on you or on something queued (a prompt, a reconnect, "then run…").
    case waiting
    /// Facts about now (servers, watching, loaded environment).
    case info
    /// Something Anser offers (an alias, a fix, loading a .env). Fades after a while.
    case suggestion

    func color(_ t: Theme) -> NSColor {
        switch self {
        case .problem: t.red
        case .waiting: .systemOrange
        case .info: t.blue
        case .suggestion: t.green
        }
    }
}

final class ChipView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { needsDisplay = true; updateAlpha() } }
    /// Suggestions fade a little once they've been showing a while (hovering brings them back).
    var faded = false { didSet { if faded != oldValue { updateAlpha() } } }
    /// Set by `set(role:…)`: suggestions take part in fading.
    private(set) var role: ChipRole?
    /// When the current text first showed (for fading).
    private(set) var shownSince: Date?
    private func updateAlpha() { alphaValue = faded && !hovering ? 0.45 : 1 }
    /// Filled pill look (used for action chips like "Fix").
    var filled: NSColor? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    /// The right-click (or ⌃-click) menu, if this chip has one.
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() ?? super.menu(for: event) }

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingHead
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Sets a chip by meaning: the color comes from the role, and `filled` gives the pill look for things you can act on.
    func set(role: ChipRole, symbol: String?, text: String, tooltip: String? = nil, filled: Bool = false, theme: Theme) {
        let c = role.color(theme)
        self.filled = filled ? c : nil
        self.role = role
        set(symbol: symbol, text: text, color: c, tooltip: tooltip)
    }

    func set(symbol: String?, text: String, color: NSColor, tooltip: String? = nil) {
        if text != label.stringValue { shownSince = text.isEmpty ? nil : Date(); faded = false }
        if text.isEmpty { role = nil }
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

    var text: String { label.stringValue }
    var textColorForTests: NSColor? { label.textColor }
    var image: NSImage? { icon.image }

    var iconInset: CGFloat { filled != nil ? 7 : 3 }

    var preferredWidth: CGFloat {
        label.sizeToFit()
        return (icon.isHidden ? 0 : 15) + label.frame.width + 2 + iconInset * 2
    }

    override func layout() {
        super.layout()
        let ix: CGFloat = (icon.isHidden ? 0 : 15) + iconInset
        icon.frame = NSRect(x: iconInset, y: (bounds.height - 12) / 2, width: 12, height: 12)
        label.sizeToFit()
        label.frame = NSRect(x: ix, y: (bounds.height - label.frame.height) / 2, width: bounds.width - ix - iconInset, height: label.frame.height)
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
        let tmp = (NSTemporaryDirectory() as NSString).standardizingPath
        for t in [tmp, "/private" + tmp] where p == t || p.hasPrefix(t + "/") {
            p = "$TMPDIR" + p.dropFirst(t.count)
            break
        }
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

