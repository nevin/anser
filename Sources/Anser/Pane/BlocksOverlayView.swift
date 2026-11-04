import AppKit
import AnserCore
import GhosttyKit

/// Draws command blocks over the terminal: a colored bar beside each command
/// and its output (green ok, red failed, yellow running), and on hover a
/// small strip with the result and Copy output / Copy command / Re-run.
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
        /// Stable identity for remembering which blocks are collapsed.
        var key: Double? { info?.started.timeIntervalSince1970 }
    }

    private(set) var blocks: [Block] = []
    /// Blocks whose output is covered ("collapsed"), by start time.
    private(set) var collapsed = Set<Double>()
    private var hovered: Int?
    private let strip = NSView()
    private let stripLabel = NSTextField(labelWithString: "")
    private var stripButtons: [NSButton] = []
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
        for (sym, tip, sel) in [("doc.on.doc", "Copy output", #selector(copyOutput)),
                                ("terminal", "Copy command", #selector(copyCommand)),
                                ("arrow.clockwise", "Run again", #selector(rerun)),
                                ("chevron.up.chevron.down", "Collapse output", #selector(toggleCollapse))] {
            let b = NSButton(image: NSImage(systemSymbolName: sym, accessibilityDescription: tip)!, target: self, action: sel)
            b.isBordered = false
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = tip
            b.setAccessibilityLabel(tip)
            strip.addSubview(b)
            stripButtons.append(b)
        }
        addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Only the hover strip and collapsed covers take clicks; everything else
    // goes to the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !strip.isHidden, strip.frame.contains(local) { return super.hitTest(point) }
        if blocks.contains(where: { isCollapsed($0) && coverRect($0).contains(local) }) { return self }
        return nil
    }

    func isCollapsed(_ b: Block) -> Bool { b.key.map(collapsed.contains) ?? false }

    /// The output rows of a block (everything below its command line).
    func coverRect(_ b: Block) -> NSRect {
        let top = b.top + b.rowHeight
        return NSRect(x: 0, y: top, width: bounds.width, height: max(0, b.bottom - top - 2))
    }

    func setCollapsed(_ b: Block, _ on: Bool) {
        guard let k = b.key, !b.running else { return }
        if on { collapsed.insert(k) } else { collapsed.remove(k) }
        updateStrip()
        needsDisplay = true
    }

    @objc private func toggleCollapse() {
        guard let b = hoveredBlock else { return }
        setCollapsed(b, !isCollapsed(b))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let b = blocks.first(where: { isCollapsed($0) && coverRect($0).contains(p) }) { setCollapsed(b, false) }
    }

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
        blocks = out
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
        for btn in stripButtons {
            btn.contentTintColor = t.foreground.withAlphaComponent(0.7)
            btn.frame = NSRect(x: x, y: 4, width: 14, height: 14)
            x += 22
        }
        let w = x - 2
        strip.frame = NSRect(x: bounds.width - w - 10, y: max(0, b.top + 1), width: w, height: 22)
        if let toggle = stripButtons.last {
            toggle.toolTip = isCollapsed(b) ? "Show output" : "Hide output"
            toggle.image = NSImage(systemSymbolName: isCollapsed(b) ? "chevron.down" : "chevron.up", accessibilityDescription: toggle.toolTip)
        }
        strip.isHidden = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = GhosttyRuntime.shared.theme
        for b in blocks {
            let color: NSColor
            if b.running { color = t.yellow }
            else if let e = b.info?.exitCode, e != 0 { color = t.red }
            else { color = t.green.withAlphaComponent(0.55) }
            let hovered = b.markIndex == self.hovered
            let rect = NSRect(x: 1, y: b.top + 2, width: hovered ? 3.5 : 2.5, height: max(4, b.bottom - b.top - 5))
            color.withAlphaComponent(hovered ? 1 : (b.running ? 0.9 : 0.75)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.25, yRadius: 1.25).fill()
            if hovered && !isCollapsed(b) {
                t.foreground.withAlphaComponent(0.035).setFill()
                NSRect(x: 0, y: b.top, width: bounds.width, height: b.bottom - b.top).fill()
            }
            if isCollapsed(b) {
                // Cover the output with a placeholder (the terminal can't remove
                // rows, so the space stays; the noise goes).
                let r = coverRect(b)
                guard r.height > 2 else { continue }
                t.background.setFill()
                r.fill()
                let lines = max(1, Int((r.height / max(b.rowHeight, 1)).rounded()))
                let label = "▸ Output hidden · \(lines) line\(lines == 1 ? "" : "s") · click to show" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: t.dim]
                let pill = NSRect(x: 14, y: r.minY + 3, width: label.size(withAttributes: attrs).width + 20, height: min(r.height - 6, 22))
                t.foreground.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
                label.draw(at: NSPoint(x: pill.minX + 10, y: pill.midY - 7.5), withAttributes: attrs)
            }
        }
    }

    // MARK: Actions

    @objc private func copyOutput() {
        guard let b = hoveredBlock, let pane else { return }
        let text = b.blockIndex.flatMap { pane.output(ofBlock: $0) } ?? pane.surfaceView.commandOutput(index: b.markIndex - 1)
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

    @objc private func rerun() {
        guard let cmd = hoveredBlock?.info?.command, let pane, pane.session.atPrompt else { NSSound.beep(); return }
        pane.run(cmd)
    }
}
