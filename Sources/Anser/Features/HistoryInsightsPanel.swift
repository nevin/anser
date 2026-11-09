import AppKit
import AnserCore

/// The History Editor's right-hand panel. With nothing selected it gives an
/// overview (activity, most used, busiest folders, things to tidy); with one
/// command, its track record and actions; with several, a breakdown and bulk actions.
final class HistoryInsightsPanel: NSView {
    private final class Flipped: NSView { override var isFlipped: Bool { true } }

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    /// Labels and buttons shown, in order (for tests).
    private(set) var texts: [String] = []
    private var buttons: [String: () -> Void] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = Flipped()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var textForTests: String { texts.joined(separator: "\n") }
    var buttonTitles: [String] { Array(buttons.keys) }
    /// Presses a button by its title (tests).
    @discardableResult func press(_ title: String) -> Bool {
        guard let run = buttons[title] else { return false }
        run(); return true
    }

    // MARK: Building blocks

    func reset() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        texts = []
        buttons = [:]
    }

    private func fill(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
    }

    func heading(_ s: String, first: Bool = false) {
        if !first { stack.setCustomSpacing(14, after: stack.arrangedSubviews.last ?? stack) }
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        stack.addArrangedSubview(l)
        texts.append(s)
    }

    func line(_ s: String, mono: Bool = false, bold: Bool = false, color: NSColor = .labelColor, wrap: Bool = false) {
        let l = wrap ? NSTextField(wrappingLabelWithString: s) : NSTextField(labelWithString: s)
        l.font = mono ? .monospacedSystemFont(ofSize: 12, weight: bold ? .semibold : .regular) : .systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        l.textColor = color
        l.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingMiddle
        l.isSelectable = mono
        l.toolTip = s
        fill(l)
        texts.append(s)
    }

    /// Small numbers side by side: “Runs 42”, “Worked 95%”…
    func stats(_ items: [(String, String)]) {
        let cells: [NSView] = items.map { title, value in
            let v = NSTextField(labelWithString: value)
            v.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 10)
            t.textColor = .secondaryLabelColor
            let s = NSStackView(views: [v, t])
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 1
            texts.append("\(title) \(value)")
            return s
        }
        let row = NSStackView(views: cells)
        row.distribution = .fillEqually
        row.alignment = .top
        fill(row)
    }

    /// A row with a label, a bar sized against `max`, and the count. Clickable when `run` is given.
    func bar(_ label: String, _ count: Int, max: Int, mono: Bool = true, tip: String? = nil, run: (() -> Void)? = nil) {
        let row = BarRow(label: label, count: count, fraction: max > 0 ? Double(count) / Double(max) : 0, mono: mono, run: run)
        row.toolTip = tip ?? label
        fill(row)
        texts.append("\(label) \(count)")
        if let run { buttons[label] = run }
    }

    func chart(_ values: [Int], caption: String) {
        let c = ActivityChart(values: values)
        c.setAccessibilityElement(true)
        c.setAccessibilityRole(.image)
        c.setAccessibilityLabel("Runs per day for the last \(values.count) days: \(caption)")
        c.heightAnchor.constraint(equalToConstant: 46).isActive = true
        fill(c)
        let l = NSTextField(labelWithString: caption)
        l.font = .systemFont(ofSize: 10)
        l.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(l)
        texts.append(caption)
    }

    /// “3 typos [Show]” rows for tidying up.
    func action(_ text: String, button: String, enabled: Bool = true, run: @escaping () -> Void) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = enabled ? .labelColor : .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        let b = ClosureButton(title: button) { DispatchQueue.main.async(execute: run) }
        b.isEnabled = enabled
        let row = NSStackView(views: [l, NSView(), b])
        row.spacing = 6
        fill(row)
        texts.append(text)
        if enabled { buttons[button] = run }
    }

    /// Buttons that wrap into rows of up to three.
    func buttonsRow(_ items: [(String, String, () -> Void)]) {
        var rows: [NSView] = []
        for chunk in stride(from: 0, to: items.count, by: 3).map({ Array(items[$0..<min($0 + 3, items.count)]) }) {
            let bs: [NSView] = chunk.map { title, symbol, run in
                let b = ClosureButton(title: title) { DispatchQueue.main.async(execute: run) }
                b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                b.imagePosition = .imageLeading
                buttons[title] = run
                return b
            }
            let r = NSStackView(views: bs)
            r.spacing = 6
            rows.append(r)
        }
        let col = NSStackView(views: rows)
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        stack.addArrangedSubview(col)
    }

    /// One run: a colored ✓ or ✗, when, and details (how long, exit code, where).
    func runLine(ok: Bool?, when: String, detail: String) {
        let t = NSMutableAttributedString()
        let mark = ok == nil ? "• " : (ok! ? "✓ " : "✗ ")
        let color: NSColor = ok == nil ? .tertiaryLabelColor : (ok! ? .systemGreen : .systemRed)
        t.append(NSAttributedString(string: mark, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color]))
        t.append(NSAttributedString(string: when, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        if !detail.isEmpty {
            t.append(NSAttributedString(string: "  " + detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let l = NSTextField(labelWithAttributedString: t)
        l.lineBreakMode = .byTruncatingTail
        fill(l)
        texts.append("\(ok == false ? "failed" : "ran") \(when) \(detail)")
    }

    /// Output in a shaded box, selectable.
    func codeBlock(_ s: String) {
        let box = ShadedBox()
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.isSelectable = true
        l.textColor = .labelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        l.setContentCompressionResistancePriority(.required, for: .vertical)
        box.addSubview(l)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: box.topAnchor, constant: 6), l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), l.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
        ])
        fill(box)
        box.label = l
        texts.append(s)
    }

    /// The chart's spoken description (tests).
    var chartAccessibilityLabels: [String] {
        stack.arrangedSubviews.compactMap { $0 is ActivityChart ? $0.accessibilityLabel() : nil }
    }

    func finish() {
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
    }
}

/// A label, a proportional bar and a count; clicking runs an action.
private final class BarRow: NSView {
    private let run: (() -> Void)?
    private let fraction: Double
    private let barColor: NSColor

    init(label: String, count: Int, fraction: Double, mono: Bool, run: (() -> Void)?) {
        self.run = run
        self.fraction = min(1, max(0, fraction))
        self.barColor = NSColor.controlAccentColor.withAlphaComponent(0.22)
        super.init(frame: .zero)
        let l = NSTextField(labelWithString: label.replacingOccurrences(of: "\n", with: " ⏎ "))
        l.font = mono ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        l.lineBreakMode = .byTruncatingMiddle
        l.textColor = run == nil ? .labelColor : .linkColor
        let n = NSTextField(labelWithString: "\(count)")
        n.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        n.textColor = .secondaryLabelColor
        n.alignment = .right
        for v in [l, n] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            l.centerYAnchor.constraint(equalTo: centerYAnchor),
            n.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            n.centerYAnchor.constraint(equalTo: centerYAnchor),
            l.trailingAnchor.constraint(lessThanOrEqualTo: n.leadingAnchor, constant: -6),
        ])
        setAccessibilityRole(run == nil ? .staticText : .button)
        setAccessibilityLabel("\(label), \(count)")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 0, y: 2, width: bounds.width * fraction, height: bounds.height - 4)
        barColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
    }

    override func resetCursorRects() { if run != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseUp(with event: NSEvent) { if let run { DispatchQueue.main.async(execute: run) } }
    override func accessibilityPerformPress() -> Bool { run?(); return run != nil }
}

/// Runs per day as small bars, today on the right.
private final class ActivityChart: NSView {
    let values: [Int]
    init(values: [Int]) { self.values = values; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let top = max(1, values.max() ?? 1)
        let gap: CGFloat = 2
        let w = max(1, (bounds.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count))
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        for (i, v) in values.enumerated() {
            let h = v == 0 ? 0 : max(3, (bounds.height - 2) * CGFloat(v) / CGFloat(top))
            let r = NSRect(x: CGFloat(i) * (w + gap), y: 1, width: w, height: h)
            (i == values.count - 1 ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.55)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A rounded, lightly shaded background; keeps its label's wrap width in step with its own.
private final class ShadedBox: NSView {
    weak var label: NSTextField?
    override func layout() {
        super.layout()
        let w = bounds.width - 16
        if let label, w > 0, label.preferredMaxLayoutWidth != w { label.preferredMaxLayoutWidth = w; label.invalidateIntrinsicContentSize() }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
