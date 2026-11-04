import AppKit
import Carbon.HIToolbox
import GhosttyKit
import AnserCore

/// One terminal plus its command bar. Splits contain several panes.
final class PaneView: NSView, ShellSessionDelegate {
    let session: ShellSession
    let surfaceView: TerminalSurfaceView
    let editor = CommandEditor()
    weak var windowController: TerminalWindowController?

    private let bar = BarView()
    private let card = CardView()
    private let gutter = GutterView()
    private let editorScroll = NSScrollView()
    private let runningLabel = NSTextField(labelWithString: "")
    private let runningHint = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let cwdChip = ChipView()
    private let branchChip = ChipView()
    private let statusChip = ChipView()
    private let changesChip = ChipView()
    private let fixChip = ChipView()
    private let explainChip = ChipView()
    private let stopButton = NSButton()
    private var welcome: WelcomeView?
    /// A corrected command after "command not found" (e.g. gti → git).
    private(set) var fixCommand: String?
    private let hintLabel = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private let moreButton = NSButton()
    /// Shown above the terminal when the tab is split.
    private let header = PaneHeaderView()
    /// Dims the terminal of panes that don't have focus.
    private let dimView = DimView()
    /// Command block bars and hover actions drawn over the terminal.
    let blocksOverlay = BlocksOverlayView()
    var showsHeader = false { didSet { if showsHeader != oldValue { needsLayout = true } } }
    var dimmed = false { didSet { dimView.isHidden = !dimmed } }
    var zoomed = false { didSet { header.zoomed = zoomed; needsLayout = true } }
    static let headerHeight: CGFloat = 24

    private(set) var title = ""
    /// The user turned the editor off (raw typing into the shell).
    private(set) var editorEnabled = true
    /// The editor is in its tall, line-numbered mode (⇧⌘E).
    private(set) var editorExpanded = false
    /// The user typed directly into the shell's own line editor at a prompt.
    private var rawDirty = false
    private var runningTimer: Timer?
    private var pendingRunningSwitch: DispatchWorkItem?
    private var showRunning = false
    private var closed = false
    /// A full-screen program (vim, less…) is running: the bar steps aside.
    private var fullscreenProgram = false
    private var findBar: FindBar?
    /// File being edited in $EDITOR; read back at the next prompt.
    private var externalEditFile: String?

    static let statusHeight: CGFloat = 24
    static let cardMargin: CGFloat = 8
    var maxEditorLines: Int { editorExpanded ? 24 : 8 }

    var theme: Theme { GhosttyRuntime.shared.theme }

    /// Commands can be typed in the editor right now.
    var editorUsable: Bool { editorEnabled && session.integrated && session.atPrompt }

    init(cwd: String?) {
        session = ShellSession(cwd: cwd)
        surfaceView = TerminalSurfaceView(workingDirectory: cwd ?? NSHomeDirectory(), command: session.shellCommand, env: session.shellEnvironment())
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        session.delegate = self
        surfaceView.pane = self
        editor.pane = self
        addSubview(surfaceView)
        blocksOverlay.pane = self
        addSubview(blocksOverlay)
        dimView.isHidden = true
        addSubview(dimView)
        header.pane = self
        header.isHidden = true
        addSubview(header)
        buildBar()
        addSubview(bar)
        surfaceView.setAccessibilityLabel("Terminal output")
        editor.setAccessibilityLabel("Command editor")
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .anserThemeChanged, object: nil)
        refreshBar()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func themeChanged() { applyTheme() }

    private func applyTheme() {
        let t = theme
        bar.fill = t.barBackground
        bar.separator = t.foreground.withAlphaComponent(0.10)
        bar.needsDisplay = true
        card.fill = t.background.blended(withFraction: t.isDark ? 0.035 : 0.0, of: .white) ?? t.background
        card.border = t.foreground.withAlphaComponent(0.12)
        card.focusBorder = t.blue.withAlphaComponent(0.75)
        gutter.numberColor = t.foreground.withAlphaComponent(0.3)
        gutter.currentColor = t.foreground.withAlphaComponent(0.75)
        editor.applyFont()
        editor.theme = t
        runningLabel.font = NSFont.monospacedSystemFont(ofSize: Services.shared.config.editor.fontSize, weight: .regular)
        runningLabel.textColor = t.foreground.withAlphaComponent(0.85)
        runningHint.textColor = t.dim
        hintLabel.textColor = t.foreground.withAlphaComponent(0.5)
        for b in buttons { b.contentTintColor = t.foreground.withAlphaComponent(0.45) }
        refreshBar()
    }

    // MARK: Layout

    private func buildBar() {
        editorScroll.documentView = editor
        editorScroll.drawsBackground = false
        editorScroll.hasVerticalScroller = false
        editorScroll.hasHorizontalScroller = false
        editorScroll.borderType = .noBorder
        editorScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: editorScroll.contentView, queue: .main) { [weak self] _ in
            self?.gutter.needsDisplay = true
        }
        gutter.editor = editor
        gutter.scroll = editorScroll
        bar.addSubview(card)
        card.addSubview(gutter)
        card.addSubview(editorScroll)

        let size = Services.shared.config.editor.fontSize
        runningLabel.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        runningLabel.lineBreakMode = .byTruncatingTail
        runningHint.font = .systemFont(ofSize: 11)
        runningHint.alignment = .right
        runningHint.stringValue = "keys go to the program"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for v in [runningLabel, runningHint, spinner] as [NSView] { v.isHidden = true; card.addSubview(v) }

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.lineBreakMode = .byTruncatingTail
        for v in [cwdChip, branchChip, changesChip, statusChip, fixChip, explainChip, hintLabel] as [NSView] { bar.addSubview(v) }
        explainChip.onClick = { [weak self] in self?.explainLastError() }
        cwdChip.onClick = { [weak self] in
            guard let self else { return }
            self.windowController?.showFolderJumper(for: self)
        }
        branchChip.onClick = { [weak self] in
            guard let self else { return }
            self.windowController?.showBranchSwitcher(for: self)
        }
        changesChip.onClick = { [weak self] in
            guard let self else { return }
            self.windowController?.showChanges(for: self)
        }
        statusChip.onClick = { [weak self] in self?.showResultMenu() }
        fixChip.onClick = { [weak self] in self?.applyFix() }

        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
        stopButton.title = " Stop"
        stopButton.imagePosition = .imageLeading
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.font = .systemFont(ofSize: 11, weight: .medium)
        stopButton.toolTip = "Send ⌃C to the running program"
        stopButton.target = self
        stopButton.action = #selector(stopRunning)
        stopButton.isHidden = true
        card.addSubview(stopButton)

        func button(_ symbol: String, _ tip: String, _ action: Selector) {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: action)
            b.isBordered = false
            b.toolTip = tip
            b.imageScaling = .scaleProportionallyDown
            bar.addSubview(b)
            buttons.append(b)
        }
        button("clock.arrow.circlepath", "Search history (⌘R or ⌃R)", #selector(AppDelegate.historySearch(_:)))
        button("square.stack.3d.up", "Commands in this tab (⌘B)", #selector(AppDelegate.blockNavigator(_:)))
        button("doc.on.clipboard", "Copy last output (⇧⌘C)", #selector(AppDelegate.copyLastOutput(_:)))
        button("arrow.up.left.and.arrow.down.right", "Expand editor (⇧⌘E)", #selector(AppDelegate.toggleExpandedEditor(_:)))
        button("command", "Command palette (⇧⌘P)", #selector(AppDelegate.commandPalette(_:)))
        for b in buttons { b.setAccessibilityLabel(b.toolTip) }
        // When the row is too narrow, the buttons fold into this menu.
        moreButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More actions")
        moreButton.isBordered = false
        moreButton.imageScaling = .scaleProportionallyDown
        moreButton.toolTip = "More actions"
        moreButton.target = self
        moreButton.action = #selector(showMoreMenu)
        moreButton.isHidden = true
        bar.addSubview(moreButton)
    }

    /// Expanded mode opens a tall editing area (about 45% of the pane),
    /// whatever the length of the command.
    private var expandedLines: Int {
        let available = (bounds.height * 0.45) / max(editor.lineHeight, 1)
        return max(8, min(20, Int(available)))
    }

    private var editorTextHeight: CGFloat {
        var lines = showRunning ? 1 : min(editor.lineCount, maxEditorLines)
        if editorExpanded, !showRunning { lines = max(lines, expandedLines) }
        return CGFloat(lines) * editor.lineHeight + editor.textContainerInset.height * 2
    }

    private var cardHeight: CGFloat { editorTextHeight + 8 }

    private var barHeight: CGFloat {
        guard editorEnabled else { return Self.statusHeight }
        return cardHeight + Self.cardMargin + Self.statusHeight
    }

    /// The terminal keeps a fixed size for a one-line editor; extra editor
    /// lines float over the terminal instead of resizing it.
    private var reservedBarHeight: CGFloat {
        if fullscreenProgram { return 0 }
        guard editorEnabled else { return Self.statusHeight }
        return editor.lineHeight + editor.textContainerInset.height * 2 + 8 + Self.cardMargin + Self.statusHeight
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let reserved = reservedBarHeight
        let headerH = showsHeader && !fullscreenProgram ? Self.headerHeight : 0
        header.isHidden = headerH == 0
        header.frame = NSRect(x: 0, y: bounds.height - headerH, width: w, height: headerH)
        let target = NSRect(x: 0, y: reserved, width: w, height: max(0, bounds.height - reserved - headerH))
        if surfaceView.frame != target { surfaceView.frame = target }
        dimView.frame = target
        if blocksOverlay.frame != target { blocksOverlay.frame = target; blocksOverlay.setNeedsRefresh() }
        dimView.fill = theme.background.withAlphaComponent(0.38)
        header.refresh()

        bar.isHidden = fullscreenProgram
        if let fb = findBar {
            fb.frame.origin = NSPoint(x: max(8, w - fb.frame.width - 12), y: bounds.height - fb.frame.height - 10)
        }
        let h = barHeight
        bar.frame = NSRect(x: 0, y: 0, width: w, height: h)
        let pad: CGFloat = 10

        card.isHidden = !editorEnabled
        card.frame = NSRect(x: pad, y: Self.statusHeight, width: max(40, w - 2 * pad), height: cardHeight)
        let textH = editorTextHeight
        let gw = showRunning ? 26 : gutter.preferredWidth
        gutter.frame = NSRect(x: 4, y: 4, width: gw, height: textH)
        let ex = gutter.frame.maxX
        editorScroll.frame = NSRect(x: ex, y: 4, width: max(10, card.bounds.width - ex - 8), height: textH)
        editor.frame.size.width = editorScroll.contentSize.width
        editor.minSize = NSSize(width: 0, height: textH)
        gutter.needsDisplay = true

        // Running state, inside the card.
        spinner.frame = NSRect(x: 9, y: (card.bounds.height - 16) / 2, width: 16, height: 16)
        stopButton.sizeToFit()
        stopButton.frame = NSRect(x: card.bounds.width - stopButton.frame.width - 8, y: (card.bounds.height - stopButton.frame.height) / 2,
                                  width: stopButton.frame.width, height: stopButton.frame.height)
        stopButton.isHidden = !showRunning
        runningHint.sizeToFit()
        runningHint.frame = NSRect(x: stopButton.frame.minX - runningHint.frame.width - 10, y: (card.bounds.height - runningHint.frame.height) / 2, width: runningHint.frame.width, height: runningHint.frame.height)
        runningLabel.sizeToFit()
        let rlx = ex + 5
        runningLabel.frame = NSRect(x: rlx, y: (card.bounds.height - runningLabel.frame.height) / 2,
                                    width: max(20, runningHint.frame.minX - rlx - 12), height: runningLabel.frame.height)
        runningHint.isHidden = !showRunning || runningLabel.frame.width < 120

        // Status row. Priority: chips, then buttons (folded into "…" when
        // tight), then the hint text in whatever room is left.
        let y: CGFloat = 4
        let chips = [cwdChip, branchChip, changesChip, statusChip, fixChip, explainChip].filter { !$0.isHidden }
        let fullButtonsW = CGFloat(buttons.count) * 24
        var chipWidths = chips.map(\.preferredWidth)
        let spacing = CGFloat(max(0, chips.count - 1)) * 8
        let roomForChips = w - 2 * pad - 30
        // Shrink the folder chip first (its path truncates from the left).
        if let i = chips.firstIndex(where: { $0 === cwdChip }), chipWidths.reduce(0, +) + spacing > roomForChips {
            let others = chipWidths.reduce(0, +) - chipWidths[i]
            chipWidths[i] = max(70, roomForChips - others - spacing)
        }
        let chipsW = chipWidths.reduce(0, +) + spacing
        let overflow = pad + chipsW + 12 + fullButtonsW > w - pad
        var bx = w - pad
        if overflow {
            buttons.forEach { $0.isHidden = true }
            moreButton.isHidden = false
            bx -= 18
            moreButton.frame = NSRect(x: bx, y: 3, width: 18, height: 18)
            bx -= 8
        } else {
            moreButton.isHidden = true
            for b in buttons.reversed() {
                b.isHidden = false
                bx -= 16
                b.frame = NSRect(x: bx, y: 4, width: 16, height: 16)
                bx -= 8
            }
        }
        var x = pad + 2
        for (chip, cw) in zip(chips, chipWidths) {
            chip.frame = NSRect(x: x, y: y - 1, width: min(cw, max(40, bx - x - 4)), height: 18)
            x = chip.frame.maxX + 8
        }
        if let welcome {
            let ww = min(560, w - 40)
            welcome.frame = NSRect(x: (w - ww) / 2, y: bounds.height - welcome.frame.height - 24, width: ww, height: welcome.frame.height)
        }
        let hintW = bx - x - 10
        hintLabel.isHidden = hintW < 150 || hintLabel.stringValue.isEmpty
        hintLabel.frame = NSRect(x: x, y: y + 1, width: max(0, hintW), height: 15)
    }

    @objc private func showMoreMenu() {
        let m = NSMenu()
        for b in buttons {
            let item = NSMenuItem(title: b.toolTip ?? "", action: b.action, keyEquivalent: "")
            item.image = b.image
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: moreButton.frame.minX, y: moreButton.frame.maxY + 4), in: bar)
    }

    var buttonsFolded: Bool { !moreButton.isHidden }

    func editorContentChanged() {
        needsLayout = true
        gutter.needsDisplay = true
        // Keep the caret visible inside a tall editor.
        editor.scrollRangeToVisible(editor.selectedRange())
    }

    func editorFocusChanged(_ focused: Bool) { card.focused = focused }

    /// Explains the word under the cursor, or shows key tips when empty.
    func updateHint() {
        guard editorUsable, !showRunning else { return }
        let text = editor.string
        if text.utf16.count > CommandEditor.largeText {
            setHint(nil, "\(editor.logicalLineCount) lines · ⏎ runs them all · ⌥⌘E edit in $EDITOR")
            return
        }
        if text.isEmpty, editorExpanded {
            setHint(nil, "Expanded editor · ⏎ runs · ⇧⏎ new line · ⇧⌘E or Esc to shrink")
            return
        }
        if text.isEmpty {
            setHint(nil, "⇥ complete   ↑ history   ⌘R search   ⇧⏎ new line   ⌥⌘E open in $EDITOR")
            return
        }
        let h = Services.shared.engine.hint(line: text, cursor: editor.selectedRange().location, cwd: session.cwd, env: session.env)
        setHint(h?.title, h?.detail)
    }

    var hintText: String { hintLabel.stringValue }

    private func setHint(_ title: String?, _ detail: String?) {
        let t = theme
        let s = NSMutableAttributedString()
        if let title, !title.isEmpty {
            s.append(NSAttributedString(string: title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: t.foreground.withAlphaComponent(0.7)]))
        }
        if let detail, !detail.isEmpty {
            if s.length > 0 { s.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: 11)])) }
            s.append(NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: t.foreground.withAlphaComponent(0.45)]))
        }
        hintLabel.attributedStringValue = s
        needsLayout = true
    }

    // MARK: State

    private func refreshBar() {
        let s = session
        let t = theme
        let dim = t.foreground.withAlphaComponent(0.55)
        if s.isRemote {
            cwdChip.set(symbol: "network", text: (s.remoteHost ?? "") + ":" + PathDisplay.short(s.remoteCwd ?? "~", max: 30), color: t.cyan,
                        tooltip: "ssh session on \(s.remoteHost ?? "a remote host") — the editor and history work here too")
        } else {
            cwdChip.set(symbol: "folder", text: PathDisplay.short(s.cwd), color: dim, tooltip: s.cwd + "\nClick to jump to another folder (⌘J)")
        }
        if let b = s.gitBranch, !s.isRemote {
            branchChip.set(symbol: "arrow.triangle.branch", text: b, color: dim, tooltip: "Switch branch (⇧⌘B)")
        } else {
            branchChip.set(symbol: nil, text: "", color: dim)
        }
        if s.gitBranch != nil, s.gitChangeCount > 0, !s.isRemote {
            let n = s.gitChangeCount
            changesChip.set(symbol: "plusminus.circle", text: n >= 5000 ? "5000+ changed" : "\(n) changed", color: t.yellow,
                            tooltip: "Changed files: diff, stage, open (⇧⌘G)")
        } else {
            changesChip.set(symbol: nil, text: "", color: dim)
        }
        if let fix = fixCommand {
            fixChip.filled = t.yellow
            fixChip.set(symbol: "wand.and.stars", text: "Did you mean: " + fix, color: t.yellow, tooltip: "Put the corrected command in the editor")
        } else if let last = s.lastBlockInContext, (last.exitCode ?? 0) != 0, !last.command.isEmpty, s.atPrompt {
            fixChip.filled = t.foreground
            fixChip.set(symbol: "arrow.uturn.backward", text: "Edit & retry", color: t.foreground.withAlphaComponent(0.75), tooltip: last.command)
        } else {
            fixChip.filled = nil
            fixChip.set(symbol: nil, text: "", color: dim)
        }
        if Services.shared.aiEnabled, let last = s.lastBlockInContext, (last.exitCode ?? 0) != 0, !last.command.isEmpty, s.atPrompt {
            explainChip.filled = t.magenta
            explainChip.set(symbol: "sparkles", text: "Explain", color: t.magenta, tooltip: "Ask Claude why this failed (⌥⌘I)")
        } else {
            explainChip.filled = nil
            explainChip.set(symbol: nil, text: "", color: dim)
        }
        if s.historyPaused {
            statusChip.set(symbol: "pause.circle", text: "history paused", color: t.yellow)
        } else if let last = s.lastBlockInContext {
            let ok = (last.exitCode ?? 0) == 0
            let d = last.duration.map { Services.formatDuration($0) } ?? ""
            statusChip.set(symbol: ok ? "checkmark.circle" : "xmark.circle", text: ok ? d : "exit \(last.exitCode ?? 0) · \(d)",
                           color: ok ? t.green.withAlphaComponent(0.8) : t.red, tooltip: last.command)
        } else if !s.integrated {
            statusChip.set(symbol: "bolt.slash", text: "shell integration not active", color: dim,
                           tooltip: "Typing goes straight to the shell. zsh and bash get the full editor.")
        } else {
            statusChip.set(symbol: nil, text: "", color: dim)
        }
        gutter.promptColor = (s.lastExit ?? 0) == 0 ? t.green : t.red

        let waiting = editorEnabled && !s.integrated && !showRunning
        editorScroll.isHidden = !editorEnabled || showRunning || !s.integrated
        gutter.running = showRunning || waiting
        runningLabel.isHidden = !(showRunning || waiting)
        if waiting {
            runningLabel.stringValue = "Waiting for the shell…"
            runningLabel.textColor = t.dim
        }
        if showRunning { spinner.isHidden = false; spinner.startAnimation(nil) } else { spinner.stopAnimation(nil); spinner.isHidden = true }
        runningHint.isHidden = !showRunning
        if showRunning { hintLabel.stringValue = "" } else { updateHint() }
        updateRunningLabel()
        needsLayout = true
    }

    private func updateRunningLabel() {
        guard showRunning, let r = session.running else { return }
        let t = theme
        let elapsed = Services.formatDuration(Date().timeIntervalSince(r.started))
        let s = NSMutableAttributedString(string: r.command.isEmpty ? "running" : r.command, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: Services.shared.config.editor.fontSize, weight: .regular),
            .foregroundColor: t.foreground.withAlphaComponent(0.85)])
        s.append(NSAttributedString(string: "   " + elapsed, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: t.yellow]))
        runningLabel.attributedStringValue = s
    }

    /// A short message over the pane ("Copied output").
    func flash(_ text: String) { AppDelegate.shared.flash(self, text) }

    func sessionDidShowPrompt(_ session: ShellSession) {
        if let b = session.blocks.last, session.running == nil, b.duration != nil {
            Diagnostics.shared.log(String(format: "command end: %@ exit=%d %.2fs", HistoryStore.programName(b.command) ?? "?", b.exitCode ?? 0, b.duration ?? 0))
        }
        blocksOverlay.setNeedsRefresh()
        if session.running == nil, !session.blocks.isEmpty {
            let i = session.blocks.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.captureOutput(forBlockAt: i) }
        }
        if let last = session.blocks.last, last.duration != nil, session.running == nil {
            windowController?.paneActivityChanged(self, finished: true, failed: (last.exitCode ?? 0) != 0)
        }
        pendingRunningSwitch?.cancel()
        pendingRunningSwitch = nil
        runningTimer?.invalidate()
        runningTimer = nil
        let wasRunning = showRunning
        showRunning = false
        if fullscreenProgram { fullscreenProgram = false; needsLayout = true }
        rawDirty = false
        fixCommand = nil
        if session.lastExit == 127, let cmd = session.blocks.last?.command, let prog = HistoryStore.programName(cmd),
           let better = CommandIndex.shared.suggestions(for: prog, env: session.env, frequency: Services.shared.history.commandNameFrequency()).first,
           let r = cmd.range(of: prog) {
            fixCommand = cmd.replacingCharacters(in: r, with: better)
        }
        if let file = externalEditFile {
            externalEditFile = nil
            if let text = try? String(contentsOfFile: file, encoding: .utf8) {
                var t = text
                while t.hasSuffix("\n") { t.removeLast() }
                editor.setCommand(t)
            }
            unlink(file)
        }
        refreshBar()
        if isFocusedPane, editorEnabled {
            let fr = window?.firstResponder
            // Leave focus in the terminal only if the user is mid-selection there.
            if wasRunning || fr !== surfaceView || !surfaceView.hasSelection { window?.makeFirstResponder(editor) }
        }
        windowController?.paneTitleChanged(self)
    }

    func sessionDidStartCommand(_ session: ShellSession, command: String) {
        Diagnostics.shared.log("command start: \(HistoryStore.programName(command) ?? "?")")
        blocksOverlay.setNeedsRefresh()
        editor.hidePopup()
        windowController?.paneActivityChanged(self, finished: false, failed: false)
        titleFromProgram = false
        fixCommand = nil
        dismissWelcome()
        // Resize right away so the program starts at its final size.
        if let name = HistoryStore.programName(command).map({ ($0 as NSString).lastPathComponent }),
           Services.shared.config.fullscreenApps.contains(name) {
            fullscreenProgram = true
            needsLayout = true
            layoutSubtreeIfNeeded()
            if isFocusedPane { window?.makeFirstResponder(surfaceView) }
        }
        // Fast commands finish before this fires; avoids flicker on `ls`, `cd`.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.session.atPrompt else { return }
            self.showRunning = true
            if self.isFocusedPane, self.window?.firstResponder === self.editor {
                self.window?.makeFirstResponder(self.surfaceView)
            }
            self.refreshBar()
            self.runningTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateRunningLabel() }
        }
        pendingRunningSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        windowController?.paneTitleChanged(self)
    }

    func sessionDidUpdateInfo(_ session: ShellSession) { refreshBar() }

    func historyPausedChanged() { refreshBar() }

    /// True when a running program set the title itself (vim, ssh, htop…).
    private var titleFromProgram = false

    func titleChanged(_ t: String) {
        title = t
        titleFromProgram = session.running != nil && !t.contains(session.running?.command ?? "\u{0}")
        windowController?.paneTitleChanged(self)
    }

    func pwdChanged(_ path: String) {
        var p = path
        if let url = URL(string: path), url.scheme == "file" { p = url.path }
        session.setCwd(p)
        refreshBar()
    }

    /// Tab name: the running program (or the title it set), else the folder.
    var displayTitle: String {
        if let r = session.running, !r.command.isEmpty {
            if titleFromProgram, !title.isEmpty { return title }
            return HistoryStore.programName(r.command).map { ($0 as NSString).lastPathComponent } ?? r.command
        }
        if !session.integrated, !title.isEmpty { return title }
        let cwd = session.cwd
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    // MARK: Focus

    var isFocusedPane: Bool { windowController?.focusedPane === self }

    func didFocus() { windowController?.paneDidFocus(self) }

    func focus() {
        if editorUsable { window?.makeFirstResponder(editor) } else { window?.makeFirstResponder(surfaceView) }
    }

    /// Called by the terminal view for keys typed while it has focus.
    func redirectKeyToEditor(_ event: NSEvent) -> Bool {
        guard editorUsable, !event.modifierFlags.contains(.command) else { return false }
        window?.makeFirstResponder(editor)
        editor.keyDown(with: event)
        return true
    }

    func noteRawTyping() {
        if session.atPrompt { rawDirty = true }
    }

    func mouseFinishedInTerminal(hasSelection: Bool) {
        if !hasSelection, editorUsable { window?.makeFirstResponder(editor) }
    }

    func pasteIntoEditorIfAtPrompt() -> Bool {
        guard editorUsable else { return false }
        window?.makeFirstResponder(editor)
        editor.paste(nil)
        return true
    }

    // MARK: Running commands

    /// Types a command into the shell and presses Return.
    func run(_ command: String) {
        // Save the previous command's output now, while the cursor still sits
        // at its prompt (the delayed capture may not have run yet).
        if session.atPrompt, session.running == nil, let i = session.blocks.indices.last { captureOutput(forBlockAt: i) }
        if rawDirty {
            // Clear whatever was typed directly into the shell's line editor.
            // The hooks bind this private key sequence in every keymap (emacs and vi).
            surfaceView.binding("text:\\x1b[9999~")
            rawDirty = false
        }
        if !command.isEmpty { surfaceView.sendText(command) }
        surfaceView.sendSyntheticKey(keyCode: kVK_Return, text: "\r", unshifted: "\r")
    }

    /// Puts text in the editor (from history, a snippet, or clipboard history).
    func insertIntoEditor(_ text: String, run runNow: Bool = false) {
        if runNow, session.atPrompt { run(text); return }
        if editorUsable {
            editor.setCommand(text, selectPlaceholder: text.contains("{{"))
            window?.makeFirstResponder(editor)
        } else {
            surfaceView.sendText(text)
        }
    }

    func sendControl(_ ch: Character) {
        let codes: [Character: Int] = ["c": kVK_ANSI_C, "d": kVK_ANSI_D, "z": kVK_ANSI_Z, "l": kVK_ANSI_L]
        guard let code = codes[ch] else { return }
        surfaceView.sendSyntheticKey(keyCode: code, mods: GHOSTTY_MODS_CTRL, text: nil, unshifted: ch)
    }

    func clearScreen() { surfaceView.binding("clear_screen") }

    func showHistorySearch() { windowController?.showHistorySearch(for: self) }

    // MARK: Opening file paths from output

    /// Opens a path from the terminal output in your editor (at its line).
    /// Returns false if it isn't a file, so the click goes to the terminal.
    @discardableResult
    func openLink(_ word: String) -> Bool {
        guard let link = PathLink.find(word: word, in: surfaceView.viewportText() ?? "") else { return false }
        let path = link.resolved(cwd: session.cwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { NSWorkspace.shared.open(URL(fileURLWithPath: path)); return true }
        lastOpenedLink = (path, link.line)

        let configured = Services.shared.config.openFilesWith?.trimmingCharacters(in: .whitespaces)
        let editor = (configured?.isEmpty == false ? configured : nil)
            ?? PathLink.guiEditors.first { CommandIndex.shared.contains($0, env: session.env) }
        guard let editor else { NSWorkspace.shared.open(URL(fileURLWithPath: path)); return true }
        let argv = link.editorCommand(editor, absolutePath: path)
        lastOpenedArgv = argv
        if ProcessInfo.processInfo.environment["ANSER_SELFTEST"] != nil { return true }  // don't launch editors in tests
        if PathLink.terminalEditors.contains((editor as NSString).lastPathComponent) {
            // Terminal editors open right here.
            if session.atPrompt { run(argv.map { ShellLexer.escape($0) }.joined(separator: " ")) } else { NSSound.beep() }
            return true
        }
        let env = session.env
        Task.detached {
            _ = await ScriptRunner.shared.run(argv: ["/usr/bin/env"] + argv, cwd: (path as NSString).deletingLastPathComponent, env: env, timeout: 10)
        }
        return true
    }

    /// For tests: the last path opened with ⌘-click.
    private(set) var lastOpenedLink: (path: String, line: Int?)?
    private(set) var lastOpenedArgv: [String] = []

    // MARK: AI help

    func explainLastError() {
        guard Services.shared.aiEnabled else { offerAISetup(); return }
        guard let i = session.blocks.indices.last, let w = window else { NSSound.beep(); return }
        let b = session.blocks[i]
        let panel = AIPanel(pane: self, mode: .explain(command: b.command, exitCode: b.exitCode ?? 0, output: output(ofBlock: i) ?? ""))
        panel.present(over: w)
    }

    func askClaude() {
        guard Services.shared.aiEnabled else { offerAISetup(); return }
        guard let w = window else { return }
        AIPanel(pane: self, mode: .generate).present(over: w)
    }

    private func offerAISetup() {
        let a = NSAlert()
        a.messageText = "Turn on AI help?"
        a.informativeText = "AI help uses Claude to explain failed commands and write commands from a description. It's off by default and needs your Anthropic API key. Nothing is sent until you ask."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Not Now")
        if let w = window {
            a.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { SettingsWindowController.shared.show() } }
        }
    }

    // MARK: Actions from the status row

    @objc func stopRunning() { sendControl("c") }

    /// Puts the fixed (or failed) command back in the editor to run again.
    func applyFix() {
        guard editorUsable else { NSSound.beep(); return }
        let cmd = fixCommand ?? session.blocks.last?.command ?? ""
        editor.setCommand(cmd)
        window?.makeFirstResponder(editor)
    }

    private func showResultMenu() {
        guard let last = session.blocks.last else { return }
        let m = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            m.addItem(item)
        }
        add("Edit & Retry", "arrow.uturn.backward") { [weak self] in self?.editor.setCommand(last.command); self?.focus() }
        add("Run Again", "play") { [weak self] in if self?.session.atPrompt == true { self?.run(last.command) } }
        m.addItem(.separator())
        if (last.exitCode ?? 0) != 0 {
            add("Explain with Claude", "sparkles") { [weak self] in self?.explainLastError() }
        }
        add("Copy Output", "doc.on.clipboard") { AppDelegate.shared.copyLastOutput(nil) }
        add("Copy Command", "terminal") { TerminalWindowController.copy(last.command) }
        add("Show in Commands List", "square.stack.3d.up") { [weak self] in
            guard let self else { return }
            self.windowController?.showBlocks(for: self)
        }
        m.popUp(positioning: nil, at: NSPoint(x: statusChip.frame.minX, y: statusChip.frame.maxY + 4), in: bar)
    }

    // MARK: Welcome

    func showWelcome() {
        guard welcome == nil else { return }
        let w = WelcomeView { [weak self] in self?.dismissWelcome() }
        welcome = w
        addSubview(w)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func dismissWelcome() {
        guard let w = welcome else { return }
        welcome = nil
        w.removeFromSuperview()
        if ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil {
            UserDefaults.standard.set(true, forKey: "AnserWelcomeShown")
        }
    }

    var welcomeVisible: Bool { welcome != nil }
    var fixChipText: String { fixChip.isHidden ? "" : (fixChip.toolTip.map { _ in fixChipLabel } ?? "") }
    private var fixChipLabel: String { fixCommand.map { "Did you mean: " + $0 } ?? (fixChip.isHidden ? "" : "Edit & retry") }
    var changesChipVisible: Bool { !changesChip.isHidden }
    var stopVisible: Bool { !stopButton.isHidden }

    func toggleExpanded() {
        editorExpanded.toggle()
        gutter.alwaysNumbers = editorExpanded
        if let b = buttons.first(where: { $0.action == #selector(AppDelegate.toggleExpandedEditor(_:)) }) {
            b.image = NSImage(systemSymbolName: editorExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              accessibilityDescription: nil)
            b.toolTip = editorExpanded ? "Shrink editor (⇧⌘E or Esc)" : "Expand editor (⇧⌘E)"
            b.setAccessibilityLabel(b.toolTip)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        gutter.needsDisplay = true
        updateHint()
        focus()
    }

    /// Height of the editor area right now (for tests).
    var editorAreaHeight: CGFloat { editorScroll.frame.height }

    func formatCommand() {
        guard editorUsable else { NSSound.beep(); return }
        editor.toggleFormat()
        window?.makeFirstResponder(editor)
    }

    /// Opens the current command in $VISUAL / $EDITOR in this terminal; it comes
    /// back into the editor when you save and quit. (GUI editors need a wait flag,
    /// e.g. EDITOR="code --wait".)
    func editInExternalEditor() {
        guard editorUsable else { NSSound.beep(); return }
        let file = NSTemporaryDirectory() + "anser-edit-\(session.id.prefix(8)).sh"
        try? (editor.string + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        externalEditFile = file
        editor.clear()
        // The leading space keeps it out of history.
        run(" ${VISUAL:-${EDITOR:-vi}} " + ShellLexer.escape(file))
    }

    func toggleEditor() {
        editorEnabled.toggle()
        // Give raw typing a real prompt; restore the configured one when the editor returns.
        if session.atPrompt, session.integrated, Services.shared.config.shellPrompt != "full" {
            surfaceView.binding(editorEnabled ? "text:\\x1b[9997~" : "text:\\x1b[9998~")
        }
        editor.hidePopup()
        refreshBar()
        layoutSubtreeIfNeeded()
        focus()
    }

    /// Something other than the shell is in the foreground (a build, ssh, vim…).
    var hasRunningProcess: Bool {
        if session.running != nil { return true }
        guard let s = surfaceView.surface, session.shellPID > 0 else { return false }
        let fg = ghostty_surface_foreground_pid(s)
        return fg != 0 && fg != UInt64(session.shellPID)
    }

    var runningDescription: String {
        session.running?.command ?? "a running program"
    }

    // MARK: Find

    func showFind() {
        if findBar == nil {
            let fb = FindBar(pane: self)
            addSubview(fb)
            findBar = fb
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        findBar?.focus(with: surfaceView.hasSelection ? surfaceView.selectionText() : nil)
    }

    func hideFind() {
        guard let fb = findBar else { return }
        surfaceView.binding("end_search")
        fb.removeFromSuperview()
        findBar = nil
        focus()
    }

    /// Last match count reported by Ghostty's search (for tests and the find bar).
    private(set) var searchTotal = -1
    var isFullscreenProgram: Bool { fullscreenProgram }
    var findVisible: Bool { findBar != nil }

    func searchUpdated(total: Int? = nil, selected: Int? = nil) {
        if let total { searchTotal = total }
        findBar?.update(total: total, selected: selected)
    }

    // MARK: Copying

    func lastOutput() -> String? {
        if let b = session.blocks.last, let out = b.output { return out }
        return surfaceView.commandOutput(index: 0)
    }

    /// Output of a finished command, by its position in `session.blocks`.
    /// Uses the copy saved when it finished; nil if it was never captured.
    func output(ofBlock i: Int) -> String? {
        guard session.blocks.indices.contains(i) else { return nil }
        if let out = session.blocks[i].output { return out }
        return i == session.blocks.count - 1 ? surfaceView.commandOutput(index: 0) : nil
    }

    /// Saves a finished command's output, after checking (by the text on its
    /// prompt row) that the terminal's prompt mark really is that command.
    /// Retries for a couple of seconds, since the terminal draws asynchronously
    /// and newer commands may start in the meantime.
    private func captureOutput(forBlockAt i: Int, attempt: Int = 0) {
        guard session.blocks.indices.contains(i), session.blocks[i].output == nil else { return }
        let newer = session.blocks.count - 1 - i + (session.running != nil ? 1 : 0)
        let cmd = session.blocks[i].command.trimmingCharacters(in: .whitespaces)
        let marks = surfaceView.promptMarks()
        let verified: Bool
        if cmd.isEmpty {
            verified = newer == 0 && session.running == nil
        } else if let m = marks.first(where: { Int($0.index) == newer + 1 }) {
            verified = surfaceView.promptText(m).contains(String(cmd.prefix(24)))
        } else {
            // Its prompt has scrolled off the top: trust the count only right away.
            verified = newer == 0 && attempt > 0
        }
        if verified {
            session.setOutput(surfaceView.commandOutput(index: newer) ?? "", forBlockAt: i)
        } else if attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.captureOutput(forBlockAt: i, attempt: attempt + 1) }
        }
    }

    func lastCommand() -> String? {
        session.running?.command ?? session.blocks.last?.command
    }

    // MARK: Snapshots (self-test)

    /// Draws the pane's AppKit UI (not the GPU terminal) into a PNG.
    func snapshotBar(to path: String, includeTerminalArea: Bool = false) {
        layoutSubtreeIfNeeded()
        let rect = includeTerminalArea ? bounds : NSRect(x: 0, y: 0, width: bounds.width, height: max(bar.frame.maxY, editorScroll.frame.maxY) + 4)
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return }
        // The terminal is drawn by Metal and won't appear; paint its background instead.
        let saved = surfaceView.isHidden
        cacheDisplay(in: rect, to: rep)
        surfaceView.isHidden = saved
        let img = NSImage(size: rect.size)
        img.lockFocus()
        theme.background.setFill()
        NSRect(origin: .zero, size: rect.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: rect.size))
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let r = NSBitmapImageRep(data: tiff), let png = r.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: Lifecycle

    func surfaceRequestedClose() {
        guard !closed else { return }
        windowController?.close(self)
    }

    func teardown() {
        guard !closed else { return }
        Diagnostics.shared.log("pane closed")
        closed = true
        runningTimer?.invalidate()
        editor.hidePopup()
        surfaceView.destroy()
        session.close()
        NotificationCenter.default.removeObserver(self)
    }
}
