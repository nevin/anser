import AppKit
import AnserCore

/// Filter Output (⌃⌘O): a panel over the terminal that filters the running
/// (or last) command's output as it streams — search words or a regex, errors
/// or warnings only, repeated lines folded, and a pause button.
final class OutputFilterPanel: NSView, NSSearchFieldDelegate {
    weak var pane: PaneView?
    let search = NSSearchField()
    private let levelPicker = NSSegmentedControl(labels: ["All", "Warnings", "Errors"], trackingMode: .selectOne, target: nil, action: nil)
    private let foldBox = NSButton(checkboxWithTitle: "Fold repeats", target: nil, action: nil)
    private let regexBox = NSButton(checkboxWithTitle: ".*", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let closeButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private var timer: Timer?
    private(set) var paused = false
    private var lastSource = ""
    private var lastOptions = OutputFilter.Options()
    /// Result lines, for tests.
    private(set) var shown: [OutputFilter.Line] = []

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        search.placeholderString = "Filter output (words in any order)"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        levelPicker.selectedSegment = 0
        levelPicker.target = self
        levelPicker.action = #selector(optionsChanged)
        levelPicker.controlSize = .small
        foldBox.state = .on
        regexBox.toolTip = "Use a regular expression"
        for b in [foldBox, regexBox] { b.target = self; b.action = #selector(optionsChanged); b.controlSize = .small; b.font = .systemFont(ofSize: 11) }
        pauseButton.bezelStyle = .rounded
        pauseButton.controlSize = .small
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close filter")
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        for v in [search, levelPicker, foldBox, regexBox, pauseButton, countLabel, closeButton, scroll] as [NSView] { addSubview(v) }
        setAccessibilityLabel("Output filter")
        applyTheme()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.reload() }
        timer?.tolerance = 0.2
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        let t = GhosttyRuntime.shared.theme
        layer?.backgroundColor = t.barBackground.withAlphaComponent(0.98).cgColor
        layer?.borderColor = t.foreground.withAlphaComponent(0.15).cgColor
        textView.backgroundColor = .clear
        appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let rowY = h - 34
        closeButton.frame = NSRect(x: w - 28, y: rowY + 6, width: 18, height: 18)
        pauseButton.sizeToFit()
        pauseButton.frame = NSRect(x: closeButton.frame.minX - pauseButton.frame.width - 8, y: rowY + 3, width: pauseButton.frame.width, height: 24)
        regexBox.sizeToFit(); foldBox.sizeToFit(); levelPicker.sizeToFit()
        regexBox.frame.origin = NSPoint(x: pauseButton.frame.minX - regexBox.frame.width - 10, y: rowY + 7)
        foldBox.frame.origin = NSPoint(x: regexBox.frame.minX - foldBox.frame.width - 10, y: rowY + 7)
        levelPicker.frame.origin = NSPoint(x: foldBox.frame.minX - levelPicker.frame.width - 10, y: rowY + 5)
        let sw = max(120, min(320, levelPicker.frame.minX - 20))
        search.frame = NSRect(x: 10, y: rowY + 4, width: sw, height: 24)
        countLabel.frame = NSRect(x: search.frame.maxX + 10, y: rowY + 8, width: max(0, levelPicker.frame.minX - search.frame.maxX - 20), height: 16)
        scroll.frame = NSRect(x: 4, y: 4, width: w - 8, height: max(0, rowY - 6))
    }

    var options: OutputFilter.Options {
        OutputFilter.Options(query: search.stringValue, minimumLevel: OutputFilter.Level(rawValue: levelPicker.selectedSegment) ?? .normal,
                             fold: foldBox.state == .on, regex: regexBox.state == .on)
    }

    /// The running command's output so far, or the last command's.
    private func source() -> String {
        guard let pane else { return "" }
        if pane.session.running != nil { return pane.surfaceView.commandOutput(index: 0) ?? pane.surfaceView.viewportText() ?? "" }
        if let i = pane.session.blocks.indices.last { return pane.output(ofBlock: i) ?? "" }
        return ""
    }

    @objc func reload() {
        guard !paused else { return }
        let src = source()
        let o = options
        guard src != lastSource || o != lastOptions else { return }
        lastSource = src
        lastOptions = o
        render(OutputFilter.apply(src, o), counts: OutputFilter.counts(src), total: src.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    private func render(_ lines: [OutputFilter.Line], counts: (errors: Int, warnings: Int), total: Int) {
        shown = lines
        let t = GhosttyRuntime.shared.theme
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        let atBottom = scroll.verticalScroller.map { $0.floatValue > 0.98 } ?? true
        for l in lines.suffix(5000) {
            let color: NSColor = l.level == .error ? t.red : (l.level == .warning ? t.yellow : t.foreground.withAlphaComponent(0.85))
            out.append(NSAttributedString(string: String(format: "%5d  ", l.number), attributes: [.font: font, .foregroundColor: t.dim]))
            out.append(NSAttributedString(string: l.text, attributes: [.font: font, .foregroundColor: color]))
            if l.count > 1 {
                out.append(NSAttributedString(string: "  ×\(l.count)", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: t.cyan]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        }
        textView.textStorage?.setAttributedString(out)
        if atBottom || lines.count < 40 { textView.scrollToEndOfDocument(nil) }
        var parts = ["\(lines.count) of \(total) lines"]
        if counts.errors > 0 { parts.append("\(counts.errors) error\(counts.errors == 1 ? "" : "s")") }
        if counts.warnings > 0 { parts.append("\(counts.warnings) warning\(counts.warnings == 1 ? "" : "s")") }
        countLabel.stringValue = parts.joined(separator: " · ")
    }

    @objc private func optionsChanged() { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }

    @objc func togglePause() {
        paused.toggle()
        pauseButton.title = paused ? "Resume" : "Pause"
        if !paused { lastSource = ""; reload() }
    }

    override func cancelOperation(_ sender: Any?) { closePanel() }

    @objc func closePanel() {
        timer?.invalidate()
        timer = nil
        removeFromSuperview()
        if let pane, pane.filterPanel === self {
            pane.filterPanel = nil
            pane.focus()
        }
    }

    /// For tests.
    func setForTest(query: String, level: Int, fold: Bool = true) {
        search.stringValue = query
        levelPicker.selectedSegment = level
        foldBox.state = fold ? .on : .off
        lastSource = ""
        reload()
    }
}

extension PaneView {
    /// ⌃⌘O: opens the filter over the terminal, or closes it.
    func toggleFilterPanel() {
        if let p = filterPanel { p.closePanel(); return }
        let p = OutputFilterPanel(pane: self)
        filterPanel = p
        addSubview(p, positioned: .above, relativeTo: blocksOverlay)
        needsLayout = true
        layoutSubtreeIfNeeded()
        p.reload()
        window?.makeFirstResponder(p.search)
        Services.shared.record("output.filter")
    }
}
