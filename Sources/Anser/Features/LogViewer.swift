import AppKit
import UniformTypeIdentifiers
import AnserCore

/// Saved log filters and highlight words (~/.config/anser/log-viewer.json).
struct LogViewerPrefs: Codable, Equatable {
    struct Filter: Codable, Equatable { var name: String; var level: Int; var search: String; var highlight: String? }
    var filters: [Filter] = []
    var highlight: String = ""

    static var fileURL: URL = AnserConfig.directory.appendingPathComponent("log-viewer.json")
    static func load() -> LogViewerPrefs {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(LogViewerPrefs.self, from: $0) } ?? LogViewerPrefs()
    }
    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(self).write(to: Self.fileURL, options: .atomic)
    }

    /// Words to highlight: "req-42, timeout" or /regex/.
    static func terms(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Shell → Log Viewer: a tab's log output with levels in color, a level
/// filter, search, pretty JSON, pause and jump-to-error. It keeps lines even
/// after they scroll out of the terminal.
final class LogViewerWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private static var open: [LogViewerWindowController] = []

    weak var pane: PaneView?
    private(set) var lines: [LogLines.Line] = []
    private var rawKept: [String] = []
    private var timer: Timer?
    private(set) var paused = false
    private var pendingWhilePaused = 0
    private var lastSource = ""
    /// Lines shown with their place in `lines` (for jump-to-error).
    private(set) var shownIndices: [Int] = []
    private var lineRanges: [NSRange] = []
    static let maxLines = 50_000

    private let levelPicker = NSSegmentedControl(labels: ["All", "Info+", "Warnings+", "Errors"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let jsonBox = NSButton(checkboxWithTitle: "Expand JSON", target: nil, action: nil)
    private let fieldsBox = NSButton(checkboxWithTitle: "Fields", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let nextError = NSButton(title: "Next Error", target: nil, action: nil)
    private let counts = NSTextField(labelWithString: "")
    private let highlightField = NSSearchField()
    private let savedPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var prefs = LogViewerPrefs.load()
    private let textView = NSTextView()

    @discardableResult
    static func show(for pane: PaneView) -> LogViewerWindowController {
        if let w = open.first(where: { $0.pane === pane }) { w.showWindow(nil); w.poll(); return w }
        let c = LogViewerWindowController(pane: pane)
        open.append(c)
        c.showWindow(nil)
        return c
    }

    static func forTests(_ pane: PaneView) -> LogViewerWindowController? { open.first { $0.pane === pane } }

    init(pane: PaneView) {
        self.pane = pane
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Logs · " + (pane.session.running?.command ?? pane.session.blocks.last?.command ?? pane.displayTitle).prefix(60)
        w.minSize = NSSize(width: 520, height: 260)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
        if let pw = pane.window { w.setFrame(pw.frame.insetBy(dx: 30, dy: 30), display: false) } else { w.center() }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.2
        Services.shared.record("logs.open")
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        Self.open.removeAll { $0 === self }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        levelPicker.selectedSegment = 0
        levelPicker.target = self
        levelPicker.action = #selector(render)
        levelPicker.controlSize = .small
        search.placeholderString = "Search (words in any order)"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        jsonBox.state = .off
        fieldsBox.state = .on
        fieldsBox.toolTip = "Show key=value fields from JSON and logfmt lines"
        for b in [jsonBox, fieldsBox] { b.target = self; b.action = #selector(render); b.controlSize = .small }
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.controlSize = .small
        pauseButton.bezelStyle = .rounded
        nextError.target = self
        nextError.action = #selector(jumpToNextError)
        nextError.controlSize = .small
        nextError.bezelStyle = .rounded
        nextError.keyEquivalent = "e"
        nextError.keyEquivalentModifierMask = .command
        nextError.toolTip = "Jump to the next error (⌘E)"
        counts.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        counts.textColor = .secondaryLabelColor
        counts.lineBreakMode = .byTruncatingTail
        highlightField.placeholderString = "Highlight: words, /regex/"
        highlightField.stringValue = prefs.highlight
        highlightField.target = self
        highlightField.action = #selector(highlightChanged)
        highlightField.sendsSearchStringImmediately = false
        highlightField.toolTip = "Comma-separated words (or /regex/) to mark in yellow, like a request id. Remembered."
        savedPopup.controlSize = .small
        rebuildSavedMenu()
        let export = NSButton(title: "Export…", target: self, action: #selector(exportTapped))
        export.controlSize = .small
        export.bezelStyle = .rounded
        export.toolTip = "Save the lines shown (with the current filter) to a file"
        let bar = NSStackView(views: [levelPicker, search, highlightField, savedPopup, jsonBox, fieldsBox, nextError, pauseButton, export])
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        highlightField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        let t = GhosttyRuntime.shared.theme
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = t.background
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        counts.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar); content.addSubview(scroll); content.addSubview(counts)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            counts.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            counts.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            counts.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            counts.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
    }

    func controlTextDidChange(_ obj: Notification) { render() }

    // MARK: Reading

    /// The running command's output (or the last command's), from the terminal.
    private func source() -> String {
        guard let pane else { return "" }
        if pane.session.running != nil { return pane.surfaceView.commandOutput(index: 0) ?? pane.surfaceView.viewportText() ?? "" }
        if let i = pane.session.blocks.indices.last { return pane.output(ofBlock: i) ?? "" }
        return ""
    }

    func poll() {
        let src = source()
        guard src != lastSource else { return }
        lastSource = src
        var latest = src.components(separatedBy: "\n")
        while latest.last?.isEmpty == true { latest.removeLast() }
        let new = LogLines.appended(to: rawKept, from: latest)
        guard !new.isEmpty else { return }
        rawKept += new
        if rawKept.count > 400 { rawKept.removeFirst(rawKept.count - 400) }
        lines += new.map(LogLines.parse)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        if paused { pendingWhilePaused += new.count; updateCounts(); return }
        render()
    }

    @objc private func togglePause() {
        paused.toggle()
        pauseButton.title = paused ? "Resume" : "Pause"
        if !paused { pendingWhilePaused = 0; render() }
    }

    // MARK: Showing

    var minimumLevel: LogLines.Level {
        switch levelPicker.selectedSegment {
        case 1: .info
        case 2: .warn
        case 3: .error
        default: .unknown
        }
    }

    func setFilterForTests(level: Int, search text: String) { levelPicker.selectedSegment = level; search.stringValue = text; render() }
    var shownText: String { textView.string }

    @objc func render() {
        let t = GhosttyRuntime.shared.theme
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let words = search.stringValue.lowercased().split(separator: " ").map(String.init)
        let minLevel = minimumLevel
        let expand = jsonBox.state == .on
        let showFields = fieldsBox.state == .on
        // A line with no level (a stack trace, a continuation) goes with the line before it.
        var keepRun = false
        var picked: [Int] = []
        for (i, l) in lines.enumerated() {
            let levelOK: Bool
            if minLevel == .unknown { levelOK = true }
            else if l.level == .unknown { levelOK = keepRun }
            else { levelOK = l.level >= minLevel; keepRun = levelOK }
            guard levelOK else { continue }
            if !words.isEmpty {
                let hay = l.raw.lowercased()
                guard words.allSatisfy(hay.contains) else { continue }
            }
            picked.append(i)
        }
        let shown = Array(picked.suffix(5000))
        shownIndices = shown
        let out = NSMutableAttributedString()
        lineRanges = []
        func color(_ level: LogLines.Level) -> NSColor {
            switch level {
            case .fatal, .error: t.red
            case .warn: t.yellow
            case .info: t.green
            case .debug: t.blue
            case .trace: t.dim
            case .unknown: t.foreground
            }
        }
        for i in shown {
            let l = lines[i]
            let start = out.length
            func add(_ s: String, _ c: NSColor, _ f: NSFont = mono) { out.append(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])) }
            if let time = l.time { add(time + " ", t.dim) }
            if l.level != .unknown { add(l.level.label.padding(toLength: 5, withPad: " ", startingAt: 0) + " ", color(l.level), bold) }
            if let src = l.source { add(src + " ", t.cyan) }
            if expand, l.isJSON, let pretty = LogLines.prettyJSON(String(l.raw.drop(while: { $0 != "{" }))) {
                add(l.message.isEmpty ? "" : l.message + "\n", l.level >= .error ? t.red : t.foreground)
                add(pretty, t.foreground.withAlphaComponent(0.8))
            } else {
                add(l.message, l.level >= .error ? t.red : t.foreground)
                if showFields, !l.fields.isEmpty {
                    add("  " + l.fields.map { "\($0.key)=\($0.value)" }.joined(separator: " "), t.dim)
                }
            }
            add("\n", t.foreground)
            lineRanges.append(NSRange(location: start, length: out.length - start))
        }
        if lines.isEmpty {
            out.append(NSAttributedString(string: "Waiting for log lines…\nRun something that prints logs in this tab (tail -f, docker logs -f, kubectl logs -f), or pick a tab whose last command printed some.",
                                          attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: t.dim]))
        } else if shown.isEmpty {
            out.append(NSAttributedString(string: "No lines match this filter.", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: t.dim]))
        }
        applyHighlights(out, theme: t)
        let atBottom = (textView.enclosingScrollView?.contentView.bounds.maxY ?? 0) >= textView.frame.height - 40
        textView.textStorage?.setAttributedString(out)
        if atBottom || textView.string.isEmpty { textView.scrollToEndOfDocument(nil) }
        updateCounts()
    }

    private func updateCounts() {
        var by: [LogLines.Level: Int] = [:]
        for l in lines { by[l.level, default: 0] += 1 }
        let errors = (by[.error] ?? 0) + (by[.fatal] ?? 0)
        var parts = ["\(lines.count) line\(lines.count == 1 ? "" : "s")"]
        if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        if let w = by[.warn], w > 0 { parts.append("\(w) warning\(w == 1 ? "" : "s")") }
        if shownIndices.count != lines.count { parts.append("showing \(shownIndices.count)") }
        if paused { parts.append(pendingWhilePaused > 0 ? "paused · \(pendingWhilePaused) new" : "paused") }
        counts.stringValue = parts.joined(separator: " · ")
    }

    var errorCount: Int { lines.filter { $0.level >= .error }.count }

    // MARK: Highlights, saved filters, export

    private(set) var highlightCount = 0

    private func applyHighlights(_ out: NSMutableAttributedString, theme t: Theme) {
        highlightCount = 0
        let text = out.string as NSString
        for term in LogViewerPrefs.terms(highlightField.stringValue) {
            let re: NSRegularExpression?
            if term.count > 2, term.hasPrefix("/"), term.hasSuffix("/") { re = try? NSRegularExpression(pattern: String(term.dropFirst().dropLast()), options: .caseInsensitive) }
            else { re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: term), options: .caseInsensitive) }
            guard let re else { continue }
            for m in re.matches(in: out.string, range: NSRange(location: 0, length: text.length)) where m.range.length > 0 {
                out.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.45), .foregroundColor: NSColor.black], range: m.range)
                highlightCount += 1
            }
        }
    }

    @objc private func highlightChanged() {
        prefs.highlight = highlightField.stringValue
        prefs.save()
        render()
    }

    func setHighlightForTests(_ s: String) { highlightField.stringValue = s; highlightChanged() }

    private func rebuildSavedMenu() {
        savedPopup.removeAllItems()
        savedPopup.addItem(withTitle: "Saved Filters")
        let menu = savedPopup.menu
        for f in prefs.filters {
            let i = ClosureMenuItem(title: f.name) { [weak self] in self?.apply(f) }
            i.toolTip = [["All", "Info+", "Warnings+", "Errors"][max(0, min(3, f.level))], f.search, f.highlight ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            menu?.addItem(i)
        }
        if !prefs.filters.isEmpty { menu?.addItem(.separator()) }
        menu?.addItem(ClosureMenuItem(title: "Save Current Filter…") { [weak self] in self?.promptSaveFilter() })
        if !prefs.filters.isEmpty {
            let del = NSMenuItem(title: "Delete", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for f in prefs.filters {
                sub.addItem(ClosureMenuItem(title: f.name) { [weak self] in
                    self?.prefs.filters.removeAll { $0.name == f.name }; self?.prefs.save(); self?.rebuildSavedMenu()
                })
            }
            del.submenu = sub
            menu?.addItem(del)
        }
    }

    func apply(_ f: LogViewerPrefs.Filter) {
        levelPicker.selectedSegment = max(0, min(3, f.level))
        search.stringValue = f.search
        if let h = f.highlight { highlightField.stringValue = h }
        render()
    }

    func saveFilter(named name: String) {
        let f = LogViewerPrefs.Filter(name: name, level: levelPicker.selectedSegment, search: search.stringValue,
                                      highlight: highlightField.stringValue.isEmpty ? nil : highlightField.stringValue)
        prefs.filters.removeAll { $0.name == name }
        prefs.filters.append(f)
        prefs.save()
        rebuildSavedMenu()
        Services.shared.record("logs.saveFilter")
    }

    private func promptSaveFilter() {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Save this filter"
        a.informativeText = "Keeps the level, search and highlight words for any log."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.placeholderString = "e.g. Payment errors"
        a.accessoryView = f
        a.window.initialFirstResponder = f
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            let name = f.stringValue.trimmingCharacters(in: .whitespaces)
            if r == .alertFirstButtonReturn, !name.isEmpty { self?.saveFilter(named: name) }
        }
    }

    /// The lines shown, as plain text.
    var exportText: String { shownIndices.map { lines[$0].raw }.joined(separator: "\n") + "\n" }

    @objc private func exportTapped() {
        guard let w = window else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.log, .plainText]
        p.nameFieldStringValue = "logs.log"
        let text = exportText
        p.beginSheetModal(for: w) { r in
            guard r == .OK, let url = p.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
            Services.shared.record("logs.export")
        }
    }

    @objc func jumpToNextError() {
        let caret = textView.selectedRange().location
        let errorRows = shownIndices.enumerated().filter { lines[$0.element].level >= .error }.map(\.offset)
        guard !errorRows.isEmpty else { NSSound.beep(); return }
        let next = errorRows.first { lineRanges[$0].location > caret } ?? errorRows[0]
        let r = lineRanges[next]
        textView.setSelectedRange(NSRange(location: r.location, length: max(0, r.length - 1)))
        textView.scrollRangeToVisible(r)
        textView.showFindIndicator(for: r)
    }
}

extension PaneView {
    func openLogViewer() {
        guard session.running != nil || !session.blocks.isEmpty else { flash("Run a command that prints logs first"); return }
        LogViewerWindowController.show(for: self)
    }
}
