import AppKit
import AnserCore
import GhosttyKit

/// Draws command blocks over the terminal: a colored bar beside each command
/// and its output (green ok, red failed, yellow running), and on hover a
/// small strip with the result and Explain (failed only) / Copy output /
/// Copy command / Re-run / Open in window / Export / Save to notebook.
/// Positions come from the prompt marks shell integration writes (OSC 133).
final class BlocksOverlayView: NSView {
    weak var pane: PaneView?

    struct Block {
        var top: CGFloat
        var bottom: CGFloat
        /// 0 = the running/current prompt, 1 = the most recent finished command, …
        var markIndex: Int
        var info: ShellSession.Block?
        /// Position in `session.blocks` (nil while running / unmatched).
        var blockIndex: Int?
        var running: Bool
        var rowHeight: CGFloat = 17
    }

    private(set) var blocks: [Block] = []

    /// The rule that finishes each "── you@mac · 14:02:11" separator: the shell prints
    /// only the label, and the line is drawn to the edge so it fits any width.
    struct SeparatorRule: Equatable {
        var y: CGFloat
        /// The short lead-in before the label ends here (nil for older separators that draw their own).
        var leadEnd: CGFloat?
        /// The line after the label starts here and runs to the edge.
        var startX: CGFloat
        var dotted: Bool
    }
    private(set) var separatorRules: [SeparatorRule] = []
    private var hovered: Int?
    private let strip = NSView()
    private let stripLabel = NSTextField(labelWithString: "")
    private var stripButtons: [NSButton] = []
    /// "Explain with AI": only on failed commands.
    private var explainButton: NSButton!
    private var refreshScheduled = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        strip.wantsLayer = true
        strip.layer?.cornerRadius = 6
        strip.isHidden = true
        stripLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        strip.addSubview(stripLabel)
        // Four everyday actions; "…" opens the same full menu as right-click.
        for (sym, tip, sel) in [("sparkles", "Explain with AI (why did this fail?)", #selector(explain)),
                                ("arrow.clockwise", "Run again", #selector(rerun)),
                                ("doc.on.doc", "Copy output", #selector(copyOutput)),
                                ("terminal", "Copy command", #selector(copyCommand)),
                                ("book.closed", "Save command to notebook", #selector(saveToNotebook)),
                                ("ellipsis.circle", "More: open in a window, compare, view as table, share, export…", #selector(moreActions))] {
            let b = NSButton(image: NSImage(systemSymbolName: sym, accessibilityDescription: tip)!, target: self, action: sel)
            b.isBordered = false
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = tip
            b.setAccessibilityLabel(tip)
            strip.addSubview(b)
            stripButtons.append(b)
        }
        explainButton = stripButtons.first
        addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Only the hover strip takes clicks; everything else goes to the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !strip.isHidden, strip.frame.contains(local) { return super.hitTest(point) }
        return nil
    }

    /// The buttons showing on the hover strip right now (for tests).
    var visibleStripActions: [String] { strip.isHidden ? [] : stripButtons.filter { !$0.isHidden }.compactMap(\.toolTip) }

    private var lastRefresh = Date.distantPast

    /// Coalesces refresh requests (they arrive constantly while output
    /// streams) into at most ten refreshes a second.
    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        let wait = max(0, 0.1 - Date().timeIntervalSince(lastRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.lastRefresh = Date()
            self.refresh()
        }
    }

    func refresh() {
        pane?.scheduleFollowCheck()
        guard let pane, let surface = pane.surfaceView.surface, Services.shared.config.commandBlocks else {
            blocks = []; strip.isHidden = true; needsDisplay = true; return
        }
        _ = surface
        let marks = pane.surfaceView.promptMarks().sorted { $0.y < $1.y }
        let session = pane.session
        let cmds = session.blocks
        // Match marks to commands newest-first. Counting from the bottom is the
        // starting guess; the command text on the prompt row confirms it (and
        // corrects the count if the terminal merged or dropped a mark).
        var offset = 0
        var assigned: [Int: Int] = [:]   // mark index -> block index
        for m in marks.sorted(by: { $0.index < $1.index }) where m.index >= 1 {
            let guess = cmds.count - Int(m.index) - offset
            let text = pane.surfaceView.promptText(m)
            var found: Int?
            for delta in [0, 1, -1, 2, 3, -2, 4, 5] {
                let j = guess - delta
                guard cmds.indices.contains(j) else { continue }
                let cmd = cmds[j].command.trimmingCharacters(in: .whitespaces)
                if !cmd.isEmpty, text.contains(String(cmd.prefix(24))) { found = j; break }
            }
            if let j = found {
                offset = cmds.count - Int(m.index) - j
                assigned[Int(m.index)] = j
            } else if cmds.indices.contains(guess) {
                assigned[Int(m.index)] = guess
            }
        }
        var out: [Block] = []
        for (i, m) in marks.enumerated() {
            let idx = Int(m.index)
            let running = idx == 0 && session.running != nil
            guard idx >= 1 || running else { continue }
            let bottom = i + 1 < marks.count ? CGFloat(marks[i + 1].y) : bounds.height
            let bi = assigned[idx]
            out.append(Block(top: CGFloat(m.y), bottom: bottom, markIndex: idx, info: bi.map { cmds[$0] } ?? (running ? session.running : nil),
                             blockIndex: bi, running: running, rowHeight: CGFloat(m.height)))
        }
        // A command whose prompt has scrolled off the top still owns the output above the first visible prompt.
        if let first = marks.first, first.y > first.height * 0.5 {
            let idx = Int(first.index) + 1
            let j = cmds.count - idx - offset
            if cmds.indices.contains(j) {
                out.insert(Block(top: 0, bottom: CGFloat(first.y), markIndex: idx, info: cmds[j], blockIndex: j,
                                 running: false, rowHeight: CGFloat(first.height)), at: 0)
            }
        } else if marks.isEmpty, let running = session.running {
            // Long output from a running command fills the screen: its prompt is above.
            out.append(Block(top: 0, bottom: bounds.height, markIndex: 0, info: running, blockIndex: nil, running: true))
        }
        blocks = out
        separatorRules = findSeparatorRules(marks)
        if let h = hovered, !blocks.contains(where: { $0.markIndex == h }) { hovered = nil }
        updateStrip()
        needsDisplay = true
    }

    /// Called with the mouse position (in this view) as it moves over the terminal.
    func hover(at point: NSPoint?) {
        let idx = point.flatMap { p in blocks.first { p.y >= $0.top && p.y < $0.bottom }?.markIndex }
        guard idx != hovered else { return }
        hovered = idx
        updateStrip()
        needsDisplay = true
    }

    func stripContains(_ p: NSPoint) -> Bool { !strip.isHidden && strip.frame.contains(p) }

    private var hoveredBlock: Block? { hovered.flatMap { h in blocks.first { $0.markIndex == h } } }

    private func updateStrip() {
        guard let b = hoveredBlock, !b.running, let info = b.info else { strip.isHidden = true; return }
        let t = GhosttyRuntime.shared.theme
        let ok = (info.exitCode ?? 0) == 0
        let d = info.duration.map { Services.formatDuration($0) } ?? ""
        stripLabel.stringValue = ok ? "✓ \(d)" : "✗ exit \(info.exitCode ?? 0) · \(d)"
        stripLabel.textColor = ok ? t.green : t.red
        stripLabel.sizeToFit()
        strip.layer?.backgroundColor = t.barBackground.withAlphaComponent(0.96).cgColor
        strip.layer?.borderColor = t.foreground.withAlphaComponent(0.15).cgColor
        strip.layer?.borderWidth = 1
        var x: CGFloat = 8
        stripLabel.frame.origin = NSPoint(x: x, y: (22 - stripLabel.frame.height) / 2)
        x = stripLabel.frame.maxX + 8
        explainButton.isHidden = ok
        explainButton.toolTip = "Explain with \(Services.shared.aiName) (why did this fail?)"
        for btn in stripButtons where !btn.isHidden {
            btn.contentTintColor = btn === explainButton ? t.magenta : t.foreground.withAlphaComponent(0.7)
            btn.frame = NSRect(x: x, y: 4, width: 14, height: 14)
            x += 22
        }
        let w = x - 2
        strip.frame = NSRect(x: bounds.width - w - 10, y: max(0, b.top + 1), width: w, height: 22)
        strip.isHidden = false
    }

    /// Separator labels sit on the row or two above each prompt.
    private func findSeparatorRules(_ marks: [ghostty_prompt_mark_s]) -> [SeparatorRule] {
        guard Services.shared.config.commandSeparator != "none", let pane, let surface = pane.surfaceView.surface else { return [] }
        let size = ghostty_surface_size(surface)
        let scale = pane.window?.backingScaleFactor ?? 2
        let cellW = CGFloat(size.cell_width_px) / scale
        guard cellW > 0 else { return [] }
        let padX = Self.paddingX()
        var rules: [SeparatorRule] = []
        for m in marks where m.height > 0 {
            let row = Int((m.y / m.height).rounded(.down))
            let padTop = CGFloat(m.y) - CGFloat(row) * CGFloat(m.height)
            for r in [row - 1, row - 2] where r >= 0 {
                guard let text = pane.surfaceView.rowText(r), CommandSeparator.isSeparator(text) else { continue }
                let label = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                let lead = label.prefix { $0 == " " }.count
                let y = padTop + (CGFloat(r) + 0.5) * CGFloat(m.height)
                rules.append(SeparatorRule(y: y.rounded() + 0.5,
                                           leadEnd: lead >= 2 ? padX + (CGFloat(lead) - 0.6) * cellW : nil,
                                           startX: padX + (CGFloat(label.count) + (lead >= 2 ? 0.6 : 0)) * cellW,
                                           dotted: Services.shared.config.commandSeparator == "dotted"))
                break
            }
        }
        return rules
    }

    /// The terminal's left padding in points (window-padding-x; Ghostty's default is 2).
    static func paddingX() -> CGFloat {
        let lines = GhosttyRuntime.shared.configText.split(separator: "\n")
        guard let line = lines.last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("window-padding-x") }),
              let value = line.split(separator: "=").last?.split(separator: ",").first,
              let n = Double(value.trimmingCharacters(in: .whitespaces)) else { return 2 }
        return CGFloat(n)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = GhosttyRuntime.shared.theme
        let padX = Self.paddingX()
        let scale = window?.backingScaleFactor ?? 2
        for r in separatorRules {
            let path = NSBezierPath()
            if let lead = r.leadEnd, lead > padX {
                path.move(to: NSPoint(x: padX, y: r.y))
                path.line(to: NSPoint(x: lead, y: r.y))
            }
            if r.startX < bounds.width - padX {
                path.move(to: NSPoint(x: r.startX, y: r.y))
                path.line(to: NSPoint(x: bounds.width - padX, y: r.y))
            }
            if r.dotted {
                // Small round dots, 3 points apart.
                path.lineWidth = 1.2
                path.lineCapStyle = .round
                path.setLineDash([0.01, 3], count: 2, phase: 0)
                t.foreground.withAlphaComponent(0.4).setStroke()
            } else {
                path.lineWidth = 1 / scale
                t.foreground.withAlphaComponent(0.3).setStroke()
            }
            path.stroke()
        }
        for b in blocks {
            let color: NSColor
            if b.running { color = t.yellow }
            else if let e = b.info?.exitCode, e != 0 { color = t.red }
            else { color = t.green.withAlphaComponent(0.55) }
            let failed = (b.info?.exitCode ?? 0) != 0 && !b.running
            let hovered = b.markIndex == self.hovered
            let rect = NSRect(x: 1, y: b.top + 2, width: hovered ? 3.5 : (failed ? 3 : 2.5), height: max(4, b.bottom - b.top - 5))
            color.withAlphaComponent(hovered || failed ? 1 : (b.running ? 0.9 : 0.75)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.25, yRadius: 1.25).fill()
            if !hovered { drawResultMark(b) }
            if hovered {
                t.foreground.withAlphaComponent(0.035).setFill()
                NSRect(x: 0, y: b.top, width: bounds.width, height: b.bottom - b.top).fill()
            }
        }
    }

    /// The command's result at the right end of its line: "✓ 2.8s" or
    /// "✗ exit 1 · 2.8s". Shape as well as color, so it reads without color.
    /// Successful commands at least this long show "✓ time".
    static let slowCommand: TimeInterval = 1

    func resultMark(_ b: Block) -> String? {
        if b.running { return "● running" }
        guard let info = b.info, info.exitCode != nil || info.duration != nil else { return nil }
        let d = info.duration.map { Services.formatDuration($0) } ?? ""
        let ec = info.exitCode ?? 0
        if ec != 0 { return "✗ exit \(ec)\(d.isEmpty ? "" : " · " + d)" }
        // Quick successes stay quiet (the green bar says enough); slow ones show their time.
        guard let dur = info.duration, dur >= Self.slowCommand else { return nil }
        return "✓ \(d)"
    }

    /// Whether "❯ command" on its row ends clear of a mark starting at `markStart`.
    static func markFits(command: String, cellWidth: CGFloat, markStart: CGFloat) -> Bool {
        let firstLine = command.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !command.contains("\n") else { return false }
        // Wide characters (CJK, emoji) take two cells.
        let cells = firstLine.unicodeScalars.reduce(2) { $0 + ($1.properties.isEmojiPresentation || ($1.value >= 0x1100 && $1.value <= 0xFFDC && $1.properties.isIdeographic) ? 2 : 1) }
        return CGFloat(cells) * cellWidth + 16 < markStart
    }

    private func drawResultMark(_ b: Block) {
        guard bounds.width > 320, let text = resultMark(b) else { return }
        let t = GhosttyRuntime.shared.theme
        let failed = (b.info?.exitCode ?? 0) != 0 && !b.running
        let color: NSColor = b.running ? t.yellow : (failed ? t.red : t.foreground.withAlphaComponent(0.4))
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: failed ? .semibold : .regular),
                                                    .foregroundColor: color]
        let s = text as NSString
        let size = s.size(withAttributes: attrs)
        let pill = NSRect(x: bounds.width - size.width - 22, y: b.top + max(0, (b.rowHeight - size.height - 2) / 2), width: size.width + 12, height: size.height + 2)
        // Never cover text: skip the mark when the command line reaches it
        // (the hover strip still shows the result).
        if let cmd = b.info?.command, !Self.markFits(command: cmd, cellWidth: pane?.surfaceView.cellSize.width ?? 8, markStart: pill.minX) { return }
        // A backing so a long command line under it stays readable around it.
        t.background.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        if failed {
            t.red.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        }
        s.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 1), withAttributes: attrs)
    }

    // MARK: Right-click menu

    /// The finished command at `point` (this view's coordinates), if any.
    func block(at point: NSPoint) -> Block? {
        blocks.first { point.y >= $0.top && point.y < $0.bottom && !$0.running && $0.info != nil }
    }

    /// Every action for the command under the mouse, grouped, for the terminal's right-click menu.
    func commandMenuItems(at point: NSPoint) -> [NSMenuItem]? {
        guard let pane, let b = block(at: point), let info = b.info, !info.command.isEmpty else { return nil }
        return Self.commandMenuItems(for: info, blockIndex: b.blockIndex, markIndex: b.markIndex, pane: pane)
    }

    static func commandMenuItems(for info: ShellSession.Block, blockIndex: Int?, markIndex: Int?, pane: PaneView) -> [NSMenuItem] {
        let cmd = info.command
        var items: [NSMenuItem] = []
        func item(_ title: String, _ symbol: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, action: action)
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            i.isEnabled = enabled
            items.append(i)
        }
        func sep() { items.append(.separator()) }
        // Header: the command and how it went.
        let ok = (info.exitCode ?? 0) == 0
        let head = NSMenuItem(title: (ok ? "✓ " : "✗ ") + String(cmd.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(60))
                              + (info.duration.map { "  ·  " + Services.formatDuration($0) } ?? "") + (ok ? "" : "  ·  exit \(info.exitCode ?? 0)"),
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        items.append(head)
        let atPrompt = pane.session.atPrompt
        // Run
        item("Run Again", "arrow.clockwise", enabled: atPrompt) { pane.run(cmd) }
        item("Edit and Run…", "pencil") { pane.insertIntoEditor(cmd) }
        if !ok, Services.shared.aiEnabled, let i = blockIndex { item("Explain with \(Services.shared.aiName)", "sparkles") { pane.explainBlock(at: i) } }
        if !ok, let (r, c, _) = pane.testReport, c == cmd, !r.failures.isEmpty {
            item("Failed Tests (\(r.failures.count))…", "xmark.octagon") { pane.showFailedTestsMenu(from: pane.testsChip) }
        }
        sep()
        // Output
        item("Copy Output", "doc.on.doc") {
            let live = (markIndex ?? 0) >= 1 ? pane.surfaceView.commandOutput(index: (markIndex ?? 1) - 1) : nil
            let text = (live?.isEmpty == false ? live : nil) ?? blockIndex.flatMap { pane.output(ofBlock: $0) }
            if let out = text, !out.isEmpty { TerminalWindowController.copy(out); pane.flash("Copied output (\(out.components(separatedBy: "\n").count) lines)") }
            else { pane.flash("This command printed nothing") }
        }
        item("Copy Command", "terminal") { TerminalWindowController.copy(cmd); pane.flash("Copied command") }
        if let i = blockIndex {
            item("Open Output in a Window", "macwindow") { pane.windowController?.showOutputViewer(for: pane, block: i) }
            item("View as Table or JSON", "tablecells") { pane.viewOutputAsData(block: i) }
            item("Compare with Previous Run", "arrow.left.arrow.right") { pane.compareWithPreviousRun(block: i) }
            item("Open in Log Viewer", "list.bullet.rectangle") { pane.openLogViewer() }
        }
        sep()
        // Keep it
        item("Save to Notebook…", "book.closed") { NotebookSaver.save([cmd], over: pane.window) { n in pane.flash(n == 0 ? "Already in the Notebook" : "Saved to the Notebook") } }
        item("Make an Alias…", "text.badge.plus") {
            let env = pane.session.env
            let taken = Set(pane.session.env.aliases.keys).union(AliasManager.load().aliases.map(\.name))
            let name = HabitSuggestions.name(for: cmd) { taken.contains($0) || CommandIndex.shared.contains($0, env: env) }
            AliasManager.edit(nil, suggestedName: name, command: cmd, over: pane.window, pane: pane)
        }
        item("Watch Its Output…", "eye") { pane.promptOutputWatch(command: cmd) }
        item("Re-run When Files Change", "eye.circle", enabled: !pane.session.isRemote) { pane.startWatching(command: cmd, cwd: info.cwd) }
        item("Show in History Editor", "clock.arrow.circlepath") { HistoryEditorWindowController.shared.show(for: pane, select: cmd) }
        sep()
        // Share
        if let i = blockIndex {
            item("Share…", "link") { pane.shareCommand(block: i) }
            item("Export Output…", "square.and.arrow.up") { pane.windowController?.exportOutput(for: pane, block: i) }
        }
        while items.last?.isSeparatorItem == true { items.removeLast() }
        return items
    }

    // MARK: Actions

    @objc private func copyOutput() {
        guard let b = hoveredBlock, let pane else { return }
        // The terminal still has the whole output while it's in scrollback; the kept copy may be just its end.
        let live = b.markIndex >= 1 ? pane.surfaceView.commandOutput(index: b.markIndex - 1) : nil
        let text = (live?.isEmpty == false ? live : nil) ?? b.blockIndex.flatMap { pane.output(ofBlock: $0) }
        if let out = text, !out.isEmpty {
            TerminalWindowController.copy(out)
            pane.flash("Copied output (\(out.components(separatedBy: "\n").count) lines)")
        } else {
            pane.flash("This command printed nothing")
        }
    }

    @objc private func copyCommand() {
        guard let cmd = hoveredBlock?.info?.command, let pane else { return }
        TerminalWindowController.copy(cmd)
        pane.flash("Copied command")
    }


    @objc private func saveToNotebook() {
        guard let cmd = hoveredBlock?.info?.command, !cmd.isEmpty else { NSSound.beep(); return }
        NotebookWindow.shared.add(command: cmd)
    }

    @objc private func explain() {
        guard let pane, let i = hoveredBlock?.blockIndex else { NSSound.beep(); return }
        pane.explainBlock(at: i)
    }





    @objc private func moreActions(_ sender: NSButton) {
        guard let pane, let b = hoveredBlock, let info = b.info else { NSSound.beep(); return }
        let menu = NSMenu()
        Self.commandMenuItems(for: info, blockIndex: b.blockIndex, markIndex: b.markIndex, pane: pane).forEach { menu.addItem($0) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// The "…" menu's titles for the hovered command (tests).
    var moreMenuTitles: [String] {
        guard let pane, let b = hoveredBlock, let info = b.info else { return [] }
        return Self.commandMenuItems(for: info, blockIndex: b.blockIndex, markIndex: b.markIndex, pane: pane).map(\.title)
    }

    @objc private func rerun() {
        guard let cmd = hoveredBlock?.info?.command, let pane, pane.session.atPrompt else { NSSound.beep(); return }
        pane.run(cmd)
    }
}
