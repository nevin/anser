import AppKit
import Quartz
import Carbon.HIToolbox
import GhosttyKit
import AnserCore

/// One terminal plus its command bar. Splits contain several panes.
final class PaneView: NSView, ShellSessionDelegate {
    let session: ShellSession
    let surfaceView: TerminalSurfaceView
    let editor = CommandEditor()
    weak var windowController: TerminalWindowController?

    let bar = BarView()
    let card = CardView()
    let gutter = GutterView()
    let editorScroll = NSScrollView()
    private let runningLabel = NSTextField(labelWithString: "")
    private let runningHint = NSTextField(labelWithString: "")
    private let spinner = ActivityIndicator(controlSize: .small)
    let cwdChip = ChipView()
    private let branchChip = ChipView()
    var branchChipTooltip: String? { branchChip.toolTip }
    let statusChip = ChipView()
    let changesChip = ChipView()
    let fixChip = ChipView()
    let explainChip = ChipView()
    private let badgeChip = ChipView()
    private let broadcastChip = ChipView()
    private let prChip = ChipView()
    private let conflictChip = ChipView()
    private let shareChip = ChipView()
    let waitChip = ChipView()
    let serverChip = ChipView()
    let contextChip = ChipView()
    let reconnectChip = ChipView()
    let testsChip = ChipView()
    let watchChip = ChipView()
    let afterChip = ChipView()
    let envChip = ChipView()
    let aliasChip = ChipView()
    let logChip = ChipView()
    let recChip = ChipView()
    let hintChip = ChipView()
    /// "+3": the chips that didn't fit (or are over the limit), in a menu.
    let moreChip = ChipView()
    /// At most this many chips besides the folder and branch, so the row stays calm.
    static let maxExtraChips = 4
    private var fadeWork: DispatchWorkItem?
    let forwardChip = ChipView()
    /// What fixed this command last time it failed (from history).
    var fixHint: (command: String, steps: [String])?
    /// Ports a program in this ssh tab announced, and the ones forwarded to this Mac.
    var remotePortsSeen: [Int] = []
    var forwardedPorts: [Int: SSHTunnel] = [:]
    var dismissedRemotePorts: Set<Int> = []
    /// Shell code to send at the next prompt (alias changes made while a command ran).
    var pendingShellScript: String?
    /// The alias suggestion showing in the status row.
    var aliasTip: (command: String, name: String, existing: Bool)?
    /// Recording this tab (Shell → Record This Tab).
    var recorder: TabRecorder?
    /// Failed tests from the last test command (see TestFailures).
    var testReport: (report: TestFailures.Report, command: String, cwd: String)?
    /// One-shot callbacks for the next command that finishes: (block, output).
    var finishWatchers: [(ShellSession.Block, String) -> Void] = []
    /// What to do when the running command finishes (notify, run next).
    var afterSteps: [AfterStep] = []
    /// Re-runs a command when files change.
    var fileWatch: FileWatch?
    /// The project environment Anser loaded into this shell, or is offering to.
    var envLoaded: ProjectEnv.Loaded?
    var envOffer: ProjectEnv.Found?
    var envCheckedCwd: String?
    var lastHandledFinish: UUID?
    /// Names of failed tests being re-run from the tests chip.
    var pendingTestRerun: Set<String>?
    /// The last environment script handed to the shell (for tests).
    var lastEnvScript: String?
    /// A running program is waiting for an answer (see InputWait).
    var waitState: InputWait.Wait?
    var waitScreen = ""
    var waitScreenChangedAt = Date()
    /// The current screen was already checked for a question: skip it until it changes.
    var waitScreenChecked = false
    /// A dropped ssh session being reconnected (or offered).
    var reconnect: ReconnectState?
    /// Filter Output (⌃⌘O), over the terminal.
    var filterPanel: OutputFilterPanel?
    var cloudCache: (at: Date, vars: CloudContext.Vars, ctx: CloudContext)?
    /// Chips from plugins (see PluginHost).
    var pluginChipViews: [ChipView] = []
    /// Settings from a matching profile (Settings → Profiles).
    var profile: Profile?
    var pullRequest: GitInfo.PullRequest?
    var conflicts: [GitInfo.Conflict] = []
    var gitOperation: GitInfo.Operation?
    /// A one-time tip showing in the status row (never over the output).
    var activeTip: String?
    var tipShownAt: Date?
    var lastTip: String?
    let stopButton = NSButton()
    /// How long the running command usually takes (from history), for the estimate.
    private(set) var runningTiming: HistoryStore.Timing?
    /// A thin bar along the bottom of the editor box while a command with a known usual time runs.
    private let progressBar = NSView()
    var welcome: WelcomeView?
    /// A corrected command after "command not found" (e.g. gti → git).
    private(set) var fixCommand: String?
    private let hintLabel = NSTextField(labelWithString: "")
    /// The whole hint; the label shows as much of it as fits.
    private var hintFull = NSAttributedString()
    private let helpButton = NSButton()
    var buttons: [NSButton] = []
    private let moreButton = NSButton()
    private var overflowChips: [ChipView] = []
    /// Texts of the chips folded under "+N" (tests).
    var overflowChipTexts: [String] { overflowChips.map(\.text) }
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
    var editorEnabled = true
    /// The editor is in its tall, line-numbered mode (⇧⌘E).
    var editorExpanded = false
    /// The user typed directly into the shell's own line editor at a prompt.
    private var rawDirty = false
    private var runningTimer: Timer?
    private var pendingRunningSwitch: DispatchWorkItem?
    private var showRunning = false
    private var closed = false
    /// A full-screen program (vim, less…) is running: the bar steps aside.
    var fullscreenProgram = false
    /// Set when a command opened a full-screen program itself (git → less), so it's undone when that ends.
    var fullscreenDetected = false
    /// Stop presses for the running command: ⌃C, then SIGTERM, then SIGKILL.
    var stopPresses = 0
    var findBar: FindBar?
    /// File being edited in $EDITOR; read back at the next prompt.
    var externalEditFile: String?

    /// Top edge of the bar when it follows the output (pane coordinates), or
    /// nil when it sits at the bottom of the pane.
    private(set) var followTop: CGFloat?
    private(set) var viewportAtBottom = true
    private var followCheckScheduled = false
    private var followTimer: Timer?
    private var resizeSettle: DispatchWorkItem?
    private var followStillTicks = 0

    /// The status row under the editor box (chips centered, even space above and below).
    static let statusHeight: CGFloat = 30
    static let chipHeight: CGFloat = 20
    /// Space between the line at the top of the input area and the editor box.
    static let cardMargin: CGFloat = 12
    var maxEditorLines: Int { editorExpanded ? 24 : 8 }

    var theme: Theme { GhosttyRuntime.shared.theme }

    /// Commands can be typed in the editor right now.
    var editorUsable: Bool { editorEnabled && session.integrated && session.atPrompt }

    /// `sessionID`: re-attach to a shell kept by anser-session (after a restart), or start one under that id.
    init(cwd: String?, sessionID: String? = nil) {
        let host = SessionHost.shared
        let id: String? = host.enabled ? (sessionID.flatMap { SessionProtocol.isValidID($0) ? $0 : nil } ?? UUID().uuidString) : nil
        // Only a shell that is still running comes back as it was.
        let restored = id.flatMap { host.liveAtLaunch.contains($0) ? host.loadState($0) : nil }
        session = ShellSession(cwd: cwd, persistentID: id, restored: restored)
        var env = session.shellEnvironment()
        var command = session.shellCommand
        if let id, let helper = host.helperPath {
            // The terminal runs the attach helper, which runs (or reconnects to) the real shell.
            env["ANSER_SESSION_ID"] = id
            env["ANSER_SESSION_SOCKET"] = host.socketPath
            env["ANSER_SESSION_COMMAND"] = command ?? ""
            command = ShellLexer.escape(helper) + " attach"
        }
        surfaceView = TerminalSurfaceView(workingDirectory: session.cwd, command: command, env: env)
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
        welcome?.applyTheme()
        bar.separator = t.foreground.withAlphaComponent(0.2)
        bar.needsDisplay = true
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
        for v in [runningLabel, runningHint, spinner] as [NSView] { v.isHidden = true; card.addSubview(v) }

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.lineBreakMode = .byTruncatingTail
        for v in [waitChip, reconnectChip, badgeChip, contextChip, broadcastChip, shareChip, cwdChip, branchChip, prChip, conflictChip, changesChip,
                  serverChip, statusChip, fixChip, explainChip, hintLabel] as [NSView] { bar.addSubview(v) }
        setUpLiveChips()
        shareChip.onClick = { [weak self] in
            guard let self, let s = TabShare.share(for: self) else { return }
            self.showShareMenu(s)
        }
        prChip.onClick = { [weak self] in self?.openPullRequest() }
        conflictChip.onClick = { [weak self] in
            guard let self else { return }
            self.windowController?.showConflicts(for: self)
        }
        broadcastChip.onClick = { [weak self] in
            guard let self else { return }
            self.windowController?.toggleBroadcast(for: self)
        }
        badgeChip.onClick = { SettingsWindowController.shared.show(section: "Profiles") }
        explainChip.onClick = { [weak self] in self?.explainLastError() }
        cwdChip.onClick = { [weak self] in
            guard let self else { return }
            self.windowController?.showFolderJumper(for: self)
        }
        // Right-click the folder: cd, new tab or window here, Finder, copy path.
        cwdChip.menuProvider = { [weak self] in
            guard let self, !self.session.isRemote else { return nil }
            return FileActions.folderMenu(self.session.cwd, pane: self)
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
        stopButton.title = "Stop"
        stopButton.imagePosition = .imageLeading
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .regular
        stopButton.font = .systemFont(ofSize: 11, weight: .medium)
        stopButton.toolTip = "Interrupt the running program (⌃C)"
        stopButton.target = self
        stopButton.action = #selector(stopRunning)
        stopButton.isHidden = true
        card.addSubview(stopButton)
        progressBar.wantsLayer = true
        progressBar.layer?.cornerRadius = 1
        progressBar.isHidden = true
        card.addSubview(progressBar)

        func button(_ symbol: String, _ tip: String, _ action: Selector) {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: action)
            b.isBordered = false
            b.toolTip = tip
            b.imageScaling = .scaleProportionallyDown
            bar.addSubview(b)
            buttons.append(b)
        }
        button("clock.arrow.circlepath", "Search history (⌘R or ⌃R)", #selector(AppDelegate.historySearch(_:)))
        button("square.stack.3d.up", "Search this tab’s commands (⌘B)", #selector(AppDelegate.blockNavigator(_:)))
        button("doc.on.clipboard", "Copy last output (⇧⌘C)", #selector(AppDelegate.copyLastOutput(_:)))
        button("arrow.up.left.and.arrow.down.right", "Expand editor (⇧⌘E)", #selector(AppDelegate.toggleExpandedEditor(_:)))
        button("command", "Command palette (⇧⌘P)", #selector(AppDelegate.commandPalette(_:)))
        for b in buttons { b.setAccessibilityLabel(b.toolTip); b.isHidden = true }
        // The actions live in one menu, so the row stays quiet.
        moreButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Actions")
        moreButton.isBordered = false
        moreButton.imageScaling = .scaleProportionallyDown
        moreButton.toolTip = "Actions: history, commands, copy output, expand editor, command palette"
        moreButton.target = self
        moreButton.action = #selector(showMoreMenu)
        moreButton.isHidden = true
        bar.addSubview(moreButton)
        helpButton.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Keyboard shortcuts")
        helpButton.isBordered = false
        helpButton.imageScaling = .scaleProportionallyDown
        helpButton.toolTip = "Keyboard shortcuts (⌘/)"
        helpButton.action = #selector(AppDelegate.showShortcuts(_:))
        bar.addSubview(helpButton)
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
        let headerH = showsHeader && !fullscreenProgram ? Self.headerHeight : 0
        header.isHidden = headerH == 0
        header.frame = NSRect(x: 0, y: bounds.height - headerH, width: w, height: headerH)
        let welcomeInset: CGFloat = 8
        let welcomeY = barHeight + welcomeInset
        let welcomeBottom = welcomeY + WelcomeView.height + welcomeInset
        let showWelcome = welcome != nil && editorEnabled && !fullscreenProgram && !editorExpanded
            && w >= 268 && bounds.height - headerH - welcomeBottom >= 80
        welcome?.isHidden = !showWelcome
        if showWelcome {
            welcome?.frame = NSRect(x: 10, y: welcomeY, width: min(440, w - 20), height: WelcomeView.height)
        }
        let reserved = showWelcome ? welcomeBottom : reservedBarHeight
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
        if let fp = filterPanel {
            let fh = min(max(160, target.height * 0.6), target.height - 8)
            fp.frame = NSRect(x: 8, y: target.maxY - fh - 6, width: max(200, w - 16), height: fh)
        }
        let h = barHeight
        followTop = computeFollowTop()
        let barY = followTop.map { max(0, $0 - h) } ?? 0
        bar.floating = barY > 0.5
        bar.frame = NSRect(x: 0, y: barY, width: w, height: h)
        let pad: CGFloat = 10

        card.isHidden = !editorEnabled
        // A little more room above the input line than below it.
        card.frame = NSRect(x: pad, y: Self.statusHeight + 4, width: max(40, w - 2 * pad), height: cardHeight)
        bar.hintsLineY = editorEnabled ? Self.statusHeight : nil
        let textH = editorTextHeight
        let gw = showRunning ? 26 : gutter.preferredWidth
        gutter.frame = NSRect(x: 4, y: 4, width: gw, height: textH)
        let ex = gutter.frame.maxX

        // The command gets the whole line: commands can be long.
        editorScroll.frame = NSRect(x: ex, y: 4, width: max(10, card.bounds.width - ex - 8), height: textH)
        editor.frame.size.width = editorScroll.contentSize.width
        editor.minSize = NSSize(width: 0, height: textH)
        gutter.needsDisplay = true

        // Running state, inside the card.
        spinner.frame = NSRect(x: 9, y: (card.bounds.height - 16) / 2, width: 16, height: 16)
        stopButton.sizeToFit()
        // Keep the action aligned and large enough for the longer running states.
        let stopWidth = min(max(108, stopButton.frame.width), max(0, card.bounds.width - 16))
        stopButton.frame = NSRect(x: card.bounds.width - stopWidth - 8, y: (card.bounds.height - 26) / 2,
                                  width: stopWidth, height: 26)
        stopButton.isHidden = !showRunning
        runningHint.sizeToFit()
        runningLabel.sizeToFit()
        let labelX = ex + 5
        let available = max(0, (showRunning ? stopButton.frame.minX : card.bounds.width) - labelX - 10)
        let hintWidth = runningHint.frame.width + 12
        let showHint = showRunning && available >= runningLabel.frame.width + hintWidth
        if showHint {
            runningHint.frame.origin = NSPoint(x: stopButton.frame.minX - hintWidth,
                                               y: (card.bounds.height - runningHint.frame.height) / 2)
        }
        runningHint.isHidden = !showHint
        runningLabel.frame = NSRect(x: labelX, y: (card.bounds.height - runningLabel.frame.height) / 2,
                                    width: available - (showHint ? hintWidth : 0), height: runningLabel.frame.height)

        // Reserve room for the actions menu before placing any chips.
        let y = ((Self.statusHeight - Self.chipHeight) / 2).rounded()
        let onInputLine: [ChipView] = []
        let chips = ([cwdChip, recChip, waitChip, reconnectChip, afterChip, watchChip, logChip, forwardChip, badgeChip, contextChip, envChip, broadcastChip, shareChip, branchChip, prChip, conflictChip, changesChip,
                     serverChip, statusChip, testsChip, fixChip, hintChip, explainChip, aliasChip] + pluginChipViews).filter { c in !onInputLine.contains { $0 === c } }
        let moreX = w - pad - 18
        buttons.forEach { $0.isHidden = true }
        moreButton.isHidden = false
        moreButton.frame = NSRect(x: moreX, y: ((Self.statusHeight - 18) / 2).rounded(), width: 18, height: 18)
        let helpX = moreX - 22
        helpButton.isHidden = !editorEnabled
        helpButton.frame = NSRect(x: helpX, y: ((Self.statusHeight - 16) / 2).rounded(), width: 16, height: 16)
        helpButton.contentTintColor = theme.foreground.withAlphaComponent(0.4)
        moreButton.contentTintColor = theme.foreground.withAlphaComponent(0.5)

        let promptX = card.frame.minX + gutter.frame.minX + GutterView.promptInset
        let rowStart = editorEnabled ? promptX - cwdChip.iconInset : pad
        let rowEnd = editorEnabled ? helpX : moreX
        let spacing: CGFloat = 12
        let room = rowEnd - spacing - rowStart
        // Recording, sharing and typing in all panes affect privacy or where input goes: they come first and never fold into +N.
        let mustShow: [ChipView] = [recChip, shareChip, broadcastChip]
        let priorities = (mustShow + [cwdChip, waitChip, reconnectChip, afterChip, watchChip, logChip, forwardChip, hintChip, badgeChip, contextChip, conflictChip, statusChip, testsChip, serverChip,
                          envChip, fixChip, aliasChip, branchChip, changesChip, prChip, explainChip] + pluginChipViews).filter { c in !onInputLine.contains { $0 === c } }
        var active = priorities.filter { !$0.text.isEmpty }.map { ($0, $0.preferredWidth) }
        // Keep the row calm: the folder and branch, plus the most important few.
        var extras = 0
        active = active.filter { chip, _ in
            if chip === cwdChip || chip === branchChip || mustShow.contains(where: { $0 === chip }) { return true }
            extras += 1
            return extras <= Self.maxExtraChips
        }
        let overLimit = priorities.filter { !$0.text.isEmpty }.count - active.count
        let moreRoom: CGFloat = 34
        let excess = max(0, active.reduce(CGFloat.zero) { $0 + $1.1 + spacing } - spacing - room + (overLimit > 0 ? moreRoom : 0))
        var widths: [ObjectIdentifier: CGFloat] = [:]
        var remaining = room + spacing - (overLimit > 0 ? moreRoom : 0)
        for (chip, preferred) in active {
            let width = chip === cwdChip ? max(min(preferred, 108), preferred - excess) : preferred
            let must = mustShow.contains { $0 === chip }
            guard must || width + spacing <= remaining else { continue }
            widths[ObjectIdentifier(chip)] = width
            remaining -= width + spacing
        }

        var x = rowStart
        overflowChips = []
        for chip in chips {
            let width = widths[ObjectIdentifier(chip)]
            chip.isHidden = width == nil
            guard let width else {
                if !chip.text.isEmpty { overflowChips.append(chip) }
                continue
            }
            chip.frame = NSRect(x: x, y: y, width: width, height: Self.chipHeight)
            x = chip.frame.maxX + spacing
        }
        if overflowChips.isEmpty {
            moreChip.set(symbol: nil, text: "", color: theme.dim)
        } else {
            let attention = overflowChips.contains { $0.role == .problem || $0.role == .waiting || $0.filled == theme.red }
            moreChip.set(symbol: nil, text: "+\(overflowChips.count)", color: attention ? .systemOrange : theme.foreground.withAlphaComponent(0.6),
                         tooltip: overflowChips.map(\.text).joined(separator: "\n") + "\nClick to see them")
            moreChip.isHidden = false
            moreChip.frame = NSRect(x: x, y: y, width: moreChip.preferredWidth, height: Self.chipHeight)
            x = moreChip.frame.maxX + spacing
        }
        updateFading()
        let hintW = rowEnd - x - 10
        // Too narrow for the whole hint: drop tips from the right ("⇥ complete   ↑ history   …").
        var shown = hintFull
        while shown.size().width > hintW, let cut = shown.string.range(of: "   ", options: .backwards) {
            shown = shown.attributedSubstring(from: NSRange(location: 0, length: NSRange(cut, in: shown.string).location))
        }
        if !hintLabel.attributedStringValue.isEqual(to: shown) { hintLabel.attributedStringValue = shown }
        hintLabel.isHidden = hintW < 60 || shown.length == 0
        hintLabel.frame = NSRect(x: x, y: y + (Self.chipHeight - 15) / 2, width: max(0, hintW), height: 15)
    }

    // MARK: Following the output

    /// While the screen isn't full, the editor sits just under the last line
    /// of output instead of at the bottom, so your eyes don't jump.
    private func computeFollowTop() -> CGFloat? {
        guard welcome?.isHidden != false, viewportAtBottom, Services.shared.config.editorFollowsOutput, editorEnabled, !fullscreenProgram, !editorExpanded,
              let surface = surfaceView.surface, surfaceView.frame.height > 0 else { return nil }
        var x = 0.0, y = 0.0, cw = 0.0, ch = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &cw, &ch)
        let sf = surfaceView.frame
        let cellH = surfaceView.cellSize.height > 0 ? surfaceView.cellSize.height : CGFloat(max(ch, 14))
        // y is the top of the cursor's row, measured from the top.
        let cursorTop = sf.maxY - CGFloat(y)
        // At a hidden prompt the cursor's row is empty: the editor takes its
        // place. Otherwise it goes below the cursor's row.
        let hiddenPrompt = session.atPrompt && session.integrated && Services.shared.config.shellPrompt == "hidden"
        // The divider at the top of the input area sits this far below the last output line.
        let gap: CGFloat = 6
        let top = hiddenPrompt ? cursorTop - gap : cursorTop - cellH - gap
        // Close to the bottom anyway: sit at the bottom (full band and divider) rather than squeezed a few points above it.
        guard top - barHeight > 20, top < sf.maxY else { return nil }
        return top.rounded()
    }

    func viewportChanged(atBottom: Bool) {
        guard viewportAtBottom != atBottom else { return }
        viewportAtBottom = atBottom
        // The cursor belongs to the live screen. Its position cannot place
        // the editor safely over a viewport showing older output.
        if Services.shared.config.editorFollowsOutput { needsLayout = true }
    }

    /// Re-checks the bar position soon (coalesced; output can stream fast).
    func scheduleFollowCheck() {
        guard Services.shared.config.editorFollowsOutput, !followCheckScheduled else { return }
        followCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.followCheckScheduled = false
            if self.computeFollowTop() != self.followTop { self.needsLayout = true }
        }
    }

    /// The terminal re-wraps its text a moment after a resize: redraw the command
    /// blocks and re-place the input area once it has, not just before.
    func surfaceDidResize() {
        resizeSettle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.blocksOverlay.refresh()
            self.needsLayout = true
        }
        resizeSettle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    /// While a command runs, its output moves the cursor without other signals.
    /// Checks often while the cursor moves, and once a second when it has stopped
    /// (output reached the bottom, or the program is waiting) or the pane is hidden.
    private func setFollowTimer(_ on: Bool, interval: TimeInterval = 0.12) {
        followTimer?.invalidate()
        followTimer = nil
        followStillTicks = 0
        guard on, Services.shared.config.editorFollowsOutput else { return }
        followTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.followTick() }
        followTimer?.tolerance = interval / 3
    }

    private func followTick() {
        let slow = (followTimer?.timeInterval ?? 0) >= 1
        guard sessionIsVisible else { if !slow { setFollowTimer(true, interval: 1) }; return }
        if computeFollowTop() != followTop {
            needsLayout = true
            if slow { setFollowTimer(true) }
            return
        }
        followStillTicks += 1
        if !slow, followStillTicks >= 16 { setFollowTimer(true, interval: 1) }
    }

    @objc private func showMoreMenu() {
        layoutSubtreeIfNeeded()
        let m = actionsMenu()
        m.popUp(positioning: nil, at: NSPoint(x: moreButton.frame.minX, y: moreButton.frame.maxY + 4), in: bar)
    }

    /// The pane's actions, with their shortcuts shown the macOS way.
    func actionsMenu() -> NSMenu {
        let m = NSMenu()
        let keys: [(String, NSEvent.ModifierFlags)] = [("r", .command), ("b", .command), ("c", [.command, .shift]), ("e", [.command, .shift]), ("p", [.command, .shift])]
        for (b, k) in zip(buttons, keys) {
            let tip = b.toolTip ?? ""
            let title = tip.components(separatedBy: " (").first ?? tip
            let item = NSMenuItem(title: title, action: b.action, keyEquivalent: k.0)
            item.keyEquivalentModifierMask = k.1
            item.image = b.image
            m.addItem(item)
        }
        m.addItem(.separator())
        let clear = ClosureMenuItem(title: "Clear") { [weak self] in self?.clearScreen() }
        clear.keyEquivalent = "k"; clear.keyEquivalentModifierMask = .command
        clear.image = NSImage(systemSymbolName: "eraser", accessibilityDescription: nil)
        m.addItem(clear)
        let deep = ClosureMenuItem(title: "Deep Clean…") { [weak self] in self?.confirmDeepClean() }
        deep.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: nil)
        m.addItem(deep)
        m.addItem(.separator())
        if session.running != nil {
            let after = ClosureMenuItem(title: "When This Finishes…") { [weak self] in self?.promptWhenDone() }
            after.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
            m.addItem(after)
        }
        let watch = ClosureMenuItem(title: fileWatch == nil ? "Re-run Last Command When Files Change" : "Stop Watching Files") { [weak self] in self?.toggleWatch() }
        watch.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        m.addItem(watch)
        if testReport != nil {
            let tests = ClosureMenuItem(title: "Failed Tests…") { [weak self] in self?.showFailedTestsMenu(from: self?.testsChip) }
            tests.image = NSImage(systemSymbolName: "xmark.octagon", accessibilityDescription: nil)
            m.addItem(tests)
        }
        m.addItem(.separator())
        let save = ClosureMenuItem(title: "Save Command to Notebook") { [weak self] in self?.saveToNotebook() }
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = [.command, .option]
        save.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        m.addItem(save)
        let nb = ClosureMenuItem(title: "Saved Panel") { [weak self] in self?.windowController?.toggleNotebookPanel() }
        nb.keyEquivalent = "n"; nb.keyEquivalentModifierMask = [.command, .option]
        m.addItem(nb)
        let open = (window?.windowController as? TerminalWindowController)?.sidebarVisible ?? false
        let sb = NSMenuItem(title: open ? "Hide Sidebar" : "Show Sidebar", action: #selector(AppDelegate.toggleSidebar(_:)), keyEquivalent: "s")
        sb.keyEquivalentModifierMask = [.command, .control]
        sb.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        m.addItem(sb)

        if let statusMenu = overflowStatusMenu() {
            m.addItem(.separator())
            let item = NSMenuItem(title: "Pane Status", action: nil, keyEquivalent: "")
            item.submenu = statusMenu
            m.addItem(item)
        }
        return m
    }

    /// The chips that don't fit in the status row, as menu items.
    func overflowStatusMenu() -> NSMenu? {
        if !overflowChips.isEmpty {
            let statusMenu = NSMenu()
            statusMenu.autoenablesItems = false
            for chip in overflowChips {
                let item: NSMenuItem
                if chip === statusChip || chip === shareChip {
                    item = NSMenuItem(title: chip.text, action: nil, keyEquivalent: "")
                    if chip === shareChip, let share = TabShare.share(for: self) {
                        item.submenu = shareMenu(share)
                    } else if chip === statusChip {
                        item.submenu = resultMenu()
                    }
                    item.isEnabled = item.submenu != nil
                } else if let action = chip.onClick {
                    item = ClosureMenuItem(title: chip.text, action: action)
                } else {
                    item = NSMenuItem(title: chip.text, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                }
                item.image = chip.image
                item.toolTip = chip.toolTip
                statusMenu.addItem(item)
                if let menu = chip.menuProvider?() {
                    let options = NSMenuItem(title: "Folder Options", action: nil, keyEquivalent: "")
                    options.submenu = menu
                    statusMenu.addItem(options)
                }
            }
            return statusMenu
        }
        return nil
    }

    // MARK: Fading suggestions

    /// Chips that are offers rather than facts: they fade after 20 seconds (hover brings them back).
    var suggestionChips: [ChipView] {
        var list: [ChipView] = [aliasChip, hintChip, logChip, explainChip]
        if fixCommand != nil { list.append(fixChip) }
        if envOffer != nil { list.append(envChip) }
        if forwardedPorts.isEmpty, !remotePortsSeen.isEmpty { list.append(forwardChip) }
        return list
    }

    static var fadeAfter: TimeInterval = 20

    private func updateFading() {
        let now = Date()
        var next: TimeInterval?
        let suggestions = suggestionChips
        // Timed dimming is easy to miss: skip it with Reduce Motion or Increase Contrast.
        let ws = NSWorkspace.shared
        let steady = ws.accessibilityDisplayShouldReduceMotion || ws.accessibilityDisplayShouldIncreaseContrast
        for chip in [aliasChip, hintChip, logChip, explainChip, fixChip, envChip, forwardChip] {
            if steady { chip.faded = false; continue }
            guard suggestions.contains(where: { $0 === chip }), !chip.isHidden, let since = chip.shownSince else { chip.faded = false; continue }
            let age = now.timeIntervalSince(since)
            chip.faded = age >= Self.fadeAfter
            if age < Self.fadeAfter { next = min(next ?? .infinity, Self.fadeAfter - age) }
        }
        fadeWork?.cancel()
        guard let next else { return }
        let work = DispatchWorkItem { [weak self] in self?.needsLayout = true }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + next + 0.05, execute: work)
    }

    var actionsMenuButtonVisible: Bool { !moreButton.isHidden }

    func editorContentChanged() {
        refreshContextChip()
        needsLayout = true
        gutter.needsDisplay = true
        // Keep the caret visible inside a tall editor.
        editor.scrollRangeToVisible(editor.selectedRange())
    }

    func editorFocusChanged(_ focused: Bool) { card.focused = focused; gutter.dimmed = !focused }

    /// Explains the word under the cursor, or shows key tips when empty.
    func updateHint() {
        guard editorUsable, !showRunning else { return }
        let text = editor.string
        if editor.vimNormal {
            setNote("NORMAL", "i type · a append · dd clear · cw change word · u undo · p paste · / history · ⏎ run", theme.blue)
            return
        }
        if editor.aiBusy {
            setNote("✨", "Asking \(Services.shared.aiName) to write it… (Esc cancels)", theme.magenta)
            return
        }
        if let note = editor.aiNote {
            setNote("✨", note, note.hasPrefix("⚠︎") ? theme.red : theme.magenta)
            return
        }
        if editor.inlineHistory {
            setNote("History", "⌃R older · ⏎ use it · Esc cancel · ⌘R full search", theme.foreground.withAlphaComponent(0.7))
            return
        }
        if editor.isAIRequest, Services.shared.aiEnabled {
            setNote("⇥", "Tab asks \(Services.shared.aiName) to turn this into a command", theme.magenta)
            return
        }
        if let issue = editor.hintIssue {
            if issue.message != lastAnnouncedIssue, issue.severity != .error {
                // Warnings are read out once (mistakes stay visual, so typing isn't interrupted).
                lastAnnouncedIssue = issue.message
                NSAccessibility.post(element: editor, notification: .announcementRequested,
                                     userInfo: [.announcement: issue.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
            let color: NSColor = issue.severity == .warning ? .systemOrange : theme.red
            setNote(issue.severity == .error ? "✗" : "⚠︎", issue.message + (issue.severity == .danger ? " Anser will ask before running it." : ""), color)
            return
        }
        if let tip = activeTip, text.isEmpty {
            let s = NSMutableAttributedString(string: "💡 ", attributes: [.font: NSFont.systemFont(ofSize: 11)])
            s.append(NSAttributedString(string: tip.replacingOccurrences(of: "Tip: ", with: ""),
                                        attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: theme.yellow]))
            setHintText(s)
            hintLabel.toolTip = tip + "\nTips show once. Turn them off in Settings → Editor → Keyboard tips."
            needsLayout = true
            if tipShownAt == nil {
                tipShownAt = Date()
                let shown = tip
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in if self?.activeTip == shown { self?.hideTip() } }
            }
            return
        }
        hintLabel.toolTip = nil
        if text.utf16.count > CommandEditor.largeText {
            setHint(nil, "\(editor.logicalLineCount) lines · ⏎ runs them all · ⌥⌘E edit in $EDITOR")
            return
        }
        if text.isEmpty, editorExpanded {
            setHint(nil, "Expanded editor · ⏎ runs · ⇧⏎ new line · ⇧⌘E or Esc to shrink")
            return
        }
        if text.isEmpty {
            setHint(nil, showKeyTips ? Self.keyTipsRow : nil)
            return
        }
        let h = Services.shared.engine.hint(line: text, cursor: editor.selectedRange().location, cwd: session.cwd, env: session.env)
        setHint(h?.title, h?.detail)
    }

    var hintText: String { hintFull.string }

    private func setHintText(_ s: NSAttributedString) {
        hintFull = s
        hintLabel.attributedStringValue = s
        needsLayout = true
    }

    /// Key tips under the editor: while you're new ("auto"), always, or never.
    var showKeyTips: Bool {
        switch Services.shared.config.keyTips {
        case "always": return true
        case "never": return false
        default: return Services.shared.history.commandCount < 300
        }
    }

    /// Tips for the empty editor, with the keys they mention (so tips already
    /// shown in the key-tips row underneath aren't repeated).
    private static let placeholderTips: [(tip: String, keys: [String])] = [
        ("⌘R searches history", ["⌘R"]),
        ("⇥ completes, → accepts the gray suggestion", ["⇥"]),
        ("⌘J jumps to a folder", []),
        ("⇧⏎ adds a line, ⇧⌘E expands the editor", ["⇧⏎"]),
        ("⇧⌘P opens the command palette", []),
        ("⌥↑ selects word, then command, then line", []),
        ("⌥⌘R runs anything from your Notebook", []),
        ("⌘B lists the commands in this tab", []),
    ]
    static let runningTipsRow = "⌃C stop   ⌘K clear   ⌘B commands in this tab"
    static let keyTipsRow = "⇥ complete   ↑ history   ⌘R search   ⇧⏎ new line   ⌥⌘E open in $EDITOR"
    private var placeholderIndex = 0

    /// The editor's empty-state text, rotating once per prompt. Falls back to
    /// plain "Type a command" when the tip wouldn't fit `width`.
    func placeholder(fitting width: CGFloat, font: NSFont) -> String {
        let base = "Type a command"
        let tips = Self.placeholderTips.filter { t in !(showKeyTips && t.keys.contains { Self.keyTipsRow.contains($0) }) }
        guard !tips.isEmpty else { return base }
        let full = base + " · " + tips[placeholderIndex % tips.count].tip
        return (full as NSString).size(withAttributes: [.font: font]).width <= width ? full : base
    }

    private func nextPlaceholder() {
        placeholderIndex = Int.random(in: 0..<Self.placeholderTips.count)
        editor.needsDisplay = true
    }

    /// A colored note in the status row (editor mode, AI, a mistake).
    private func setNote(_ label: String, _ text: String, _ color: NSColor) {
        let s = NSMutableAttributedString(string: label + "  ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color])
        s.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color.withAlphaComponent(0.85)]))
        setHintText(s)
        hintLabel.toolTip = text
        needsLayout = true
    }

    private func setHint(_ title: String?, _ detail: String?) {
        let t = theme
        let s = NSMutableAttributedString()
        if let title, !title.isEmpty {
            s.append(NSAttributedString(string: title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: t.foreground.withAlphaComponent(0.7)]))
        }
        if let detail, detail == Self.keyTipsRow || detail == Self.runningTipsRow {
            // "⇥ complete   ↑ history …": each key a little brighter than what it does.
            for (i, tip) in detail.components(separatedBy: "   ").enumerated() {
                if i > 0 { s.append(NSAttributedString(string: "   ", attributes: [.font: NSFont.systemFont(ofSize: 11)])) }
                let parts = tip.split(separator: " ", maxSplits: 1).map(String.init)
                s.append(NSAttributedString(string: parts[0], attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: t.foreground.withAlphaComponent(0.7)]))
                if parts.count > 1 {
                    s.append(NSAttributedString(string: " " + parts[1], attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: t.foreground.withAlphaComponent(0.45)]))
                }
            }
        } else if let detail, !detail.isEmpty {
            if s.length > 0 { s.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: 11)])) }
            s.append(NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: t.foreground.withAlphaComponent(0.45)]))
        }
        setHintText(s)
        needsLayout = true
    }

    // MARK: State

    func refreshBar() {
        let s = session
        let t = theme
        let dim = t.foreground.withAlphaComponent(0.55)
        if s.isRemote {
            cwdChip.set(symbol: "network", text: (s.remoteHost ?? "") + ":" + PathDisplay.short(s.remoteCwd ?? "~", max: 30), color: t.cyan,
                        tooltip: "ssh session on \(s.remoteHost ?? "a remote host") — the editor and history work here too")
        } else {
            cwdChip.set(symbol: "folder", text: PathDisplay.short(s.cwd), color: dim, tooltip: s.cwd + "\nClick to jump to another folder (⌘J) · right-click for options")
        }
        if let b = s.gitBranch, !s.isRemote, s.gitRisky {
            branchChip.set(symbol: "exclamationmark.shield", text: b, color: t.yellow,
                           tooltip: "Automatic git checks are off in this repo: its .git/config can make git run programs (e.g. core.fsmonitor or filters). Check it before running git here.")
        } else if let b = s.gitBranch, !s.isRemote {
            branchChip.set(symbol: "arrow.triangle.branch", text: b, color: dim, tooltip: "Switch branch (⇧⌘B)")
        } else {
            branchChip.set(symbol: nil, text: "", color: dim)
        }
        if let badge = profile?.badge, !badge.isEmpty {
            let c = TabBarView.color(profile?.tabColor) ?? t.red
            badgeChip.filled = c
            badgeChip.set(symbol: "shield.lefthalf.filled", text: badge, color: c,
                          tooltip: "Profile\(profile?.name.map { " “\($0)”" } ?? ""): \(profile?.confirm?.isEmpty == false ? "asks before running some commands here" : "applies here"). Click to edit profiles.")
        } else {
            badgeChip.filled = nil
            badgeChip.set(symbol: nil, text: "", color: dim)
        }
        if let wc = windowController, wc.isBroadcasting(self) {
            broadcastChip.filled = ChipRole.waiting.color(t)
            broadcastChip.set(symbol: "dot.radiowaves.left.and.right", text: "all panes", color: ChipRole.waiting.color(t),
                              tooltip: "Commands you run here also run in every pane of this tab. Click to stop.")
        } else {
            broadcastChip.filled = nil
            broadcastChip.set(symbol: nil, text: "", color: dim)
        }
        if let share = TabShare.share(for: self) {
            let n = share.viewerCount
            shareChip.filled = t.blue
            shareChip.set(symbol: "dot.radiowaves.up.forward", text: n == 0 ? "Sharing" : "Sharing · \(n) watching", color: t.blue,
                          tooltip: "This tab is shared read-only at \(share.link)" + (share.code.map { "\nCode: \($0)" } ?? "") + "\nClick to copy the link or stop sharing.")
        } else {
            shareChip.filled = nil
            shareChip.set(symbol: nil, text: "", color: dim)
        }
        if let pr = pullRequest, s.gitBranch != nil, !s.isRemote {
            let c: NSColor = pr.checks == .failing ? t.red : (pr.checks == .passing ? t.green : dim)
            prChip.set(symbol: "arrow.triangle.pull", text: pr.chipText, color: c, tooltip: pr.summary + "\nClick to open on GitHub")
        } else {
            prChip.set(symbol: nil, text: "", color: dim)
        }
        if !conflicts.isEmpty, !s.isRemote {
            conflictChip.filled = t.red
            let op = gitOperation.map { "\($0.title) · " } ?? ""
            conflictChip.set(symbol: "exclamationmark.triangle", text: "\(op)\(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s")", color: t.red,
                             tooltip: "Files with merge conflicts. Click to resolve: open, keep yours or theirs, continue or abort.")
        } else {
            conflictChip.filled = nil
            conflictChip.set(symbol: nil, text: "", color: dim)
        }
        if s.gitBranch != nil, s.gitChangeCount > 0, !s.isRemote {
            let n = s.gitChangeCount
            changesChip.set(symbol: "plusminus.circle", text: n >= 5000 ? "5000+ changed" : "\(n) changed", color: t.foreground.withAlphaComponent(0.75),
                            tooltip: "Changed files: diff, stage, open (⇧⌘G)")
        } else {
            changesChip.set(symbol: nil, text: "", color: dim)
        }
        if let fix = fixCommand {
            fixChip.set(role: .suggestion, symbol: "wand.and.stars", text: "Did you mean: " + fix, tooltip: "Put the corrected command in the editor", filled: true, theme: t)
        } else if let last = s.lastBlockInContext, (last.exitCode ?? 0) != 0, !last.command.isEmpty, s.atPrompt {
            fixChip.filled = t.foreground
            fixChip.set(symbol: "arrow.uturn.backward", text: "Edit & retry", color: t.foreground.withAlphaComponent(0.75), tooltip: last.command)
        } else {
            fixChip.filled = nil
            fixChip.set(symbol: nil, text: "", color: dim)
        }
        if Services.shared.aiEnabled, let last = s.lastBlockInContext, (last.exitCode ?? 0) != 0, !last.command.isEmpty, s.atPrompt {
            explainChip.set(role: .suggestion, symbol: "sparkles", text: "Explain", tooltip: "Ask \(Services.shared.aiName) why this failed (⌥⌘I)", filled: true, theme: t)
        } else {
            explainChip.filled = nil
            explainChip.set(symbol: nil, text: "", color: dim)
        }
        if s.historyPaused {
            statusChip.set(role: .waiting, symbol: "pause.circle", text: "history paused", theme: t)
        } else if let last = s.lastBlockInContext, (last.exitCode ?? 0) != 0 {
            // Success needs no badge (each command shows ✓ and its time in
            // the output); a failure stays visible here.
            let d = last.duration.map { " · " + Services.formatDuration($0) } ?? ""
            statusChip.set(symbol: "xmark.circle", text: "exit \(last.exitCode ?? 0)\(d)", color: t.red,
                           tooltip: last.command + "\nClick for options")
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
        spinner.isHidden = !showRunning
        spinner.running = showRunning
        runningHint.isHidden = !showRunning
        if showRunning { setHint(nil, showKeyTips ? Self.runningTipsRow : nil) } else { updateHint() }
        refreshLiveChips()
        updateRunningLabel()
        needsLayout = true
    }

    private func updateRunningLabel() {
        guard showRunning, let r = session.running else { progressBar.isHidden = true; return }
        let t = theme
        let secs = Date().timeIntervalSince(r.started)
        let elapsed = Services.formatDuration(secs)
        let s = NSMutableAttributedString(string: r.command.isEmpty ? "running" : r.command, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: Services.shared.config.editor.fontSize, weight: .regular),
            .foregroundColor: t.foreground.withAlphaComponent(0.85)])
        s.append(NSAttributedString(string: "   " + elapsed, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: t.yellow]))
        // "usually 40s": from this command's recent successful runs.
        if let timing = runningTiming {
            let slow = secs > timing.typical * 1.5 + 2
            let note = slow ? "  · slower than usual (\(Services.formatDuration(timing.typical)))" : "  · usually \(Services.formatDuration(timing.typical))"
            s.append(NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                   .foregroundColor: slow ? NSColor.systemOrange : t.foreground.withAlphaComponent(0.5)]))
            let fraction = min(0.97, secs / max(timing.typical, 0.1))
            progressBar.isHidden = false
            progressBar.layer?.backgroundColor = (slow ? NSColor.systemOrange : t.blue).withAlphaComponent(0.7).cgColor
            let inset: CGFloat = 8
            progressBar.frame = NSRect(x: inset, y: 1, width: max(2, (card.bounds.width - 2 * inset) * fraction), height: 2)
            runningLabel.setAccessibilityValue("\(elapsed) of usually \(Services.formatDuration(timing.typical))")
        } else {
            progressBar.isHidden = true
        }
        if !runningLabel.attributedStringValue.isEqual(to: s) { runningLabel.attributedStringValue = s }
    }

    /// For tests: the running command's line ("make   12s · usually 40s").
    var runningLabelText: String { runningLabel.stringValue }

    /// The usual time for a command, shown only for ones that take a while.
    static func usefulTiming(for command: String) -> HistoryStore.Timing? {
        guard let t = Services.shared.history.timing(for: command), t.typical >= 3 else { return nil }
        return t
    }

    /// A short message over the pane ("Copied output").
    func flash(_ text: String) { AppDelegate.shared.flash(self, text) }

    func sessionDidShowPrompt(_ session: ShellSession) {
        Startup.firstPrompt()
        if let b = session.blocks.last, session.running == nil, b.duration != nil {
            Diagnostics.shared.log(String(format: "command end: %@ exit=%d %.2fs", HistoryStore.programName(b.command) ?? "?", b.exitCode ?? 0, b.duration ?? 0))
        }
        blocksOverlay.setNeedsRefresh()
        setFollowTimer(false)
        nextPlaceholder()
        scheduleFollowCheck()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.scheduleFollowCheck() }
        if session.running == nil, !session.blocks.isEmpty {
            let i = session.blocks.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.captureOutput(forBlockAt: i) }
        }
        if let last = session.blocks.last, last.duration != nil, session.running == nil {
            windowController?.paneActivityChanged(self, finished: true, failed: (last.exitCode ?? 0) != 0)
            let ai = Services.shared.aiEnabled
            Services.shared.tip(in: self) { $0.commandFinished(exitCode: last.exitCode ?? 0, aiEnabled: ai) }
        }
        if session.running == nil { sshTarget = nil }
        clearWaiting()
        ServerMonitor.shared.wake()
        PluginHost.shared.refresh(self)
        PluginHost.shared.commandFinished(in: self)
        commandFinishedForRunTools()
        checkProjectEnvironment()
        flushPendingShellScript()
        recorder?.capture()
        handleCommandFinishedForReconnect()
        filterPanel?.reload()
        updateProfile()
        refreshGitExtras()
        pendingRunningSwitch?.cancel()
        pendingRunningSwitch = nil
        runningTimer?.invalidate()
        runningTimer = nil
        runningTiming = nil
        progressBar.isHidden = true
        let wasRunning = showRunning
        showRunning = false
        if fullscreenProgram { fullscreenProgram = false; needsLayout = true }
        fullscreenDetected = false
        if stopPresses > 0 { stopPresses = 0; updateStopButton() }
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
        ServerMonitor.shared.wake()
        commandStartedForReconnect(command)
        commandStartedForRunTools(command)
        commandStartedForHabits(command)
        waitScreen = ""
        waitScreenChangedAt = Date()
        let ai = Services.shared.aiEnabled
        runningTiming = Self.usefulTiming(for: command)
        sshTarget = SSHConfig.target(of: command)
        if sshTarget != nil { updateProfile() }
        // A tip you've already seen goes away when you run something; a new one waits for the next prompt.
        if tipShownAt != nil { hideTip() }
        Services.shared.tip(in: self) { $0.commandStarted(command, aiEnabled: ai) }
        blocksOverlay.setNeedsRefresh()
        setFollowTimer(true)
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
            self.checkForegroundProgram()
            if self.isFocusedPane, self.window?.firstResponder === self.editor {
                self.window?.makeFirstResponder(self.surfaceView)
            }
            self.refreshBar()
            var tick = 0
            self.runningTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                tick += 1
                // Hidden panes (other tabs, Anser in the background) update less often.
                let visible = self.sessionIsVisible
                if visible { self.updateRunningLabel() }
                // A screen that has been still for a while is read every 3 seconds instead of every second.
                let quietLong = Date().timeIntervalSince(self.waitScreenChangedAt) > 10
                if (visible && !quietLong) || tick % 3 == 0 { self.checkWaiting() }
                if visible { self.checkForegroundProgram() }
                if self.session.isRemote, tick % 2 == 0 { self.checkRemotePorts() }
            }
            self.runningTimer?.tolerance = 0.25
        }
        pendingRunningSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        windowController?.paneTitleChanged(self)
    }

    func sessionDidUpdateInfo(_ session: ShellSession) {
        updateProfile()
        refreshBar()
    }

    /// Whether you can see this pane now: Anser in front, this window showing, this tab selected.
    var sessionIsVisible: Bool {
        guard AppDelegate.shared.isActive, let w = window, w.isVisible, w.occlusionState.contains(.visible),
              let wc = windowController, let tab = wc.tab(for: self) else { return false }
        return wc.selectedTab === tab
    }

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
        // With Anser's hooks the folder comes over the private channel; an
        // OSC 7 here could be printed by any program (or a file you cat), so
        // it's only trusted for shells without the hooks.
        guard !session.integrated, !session.isRemote else { ignoredCwdReports += 1; return }
        session.setCwd(p)
        refreshBar()
    }

    /// Tab name: the running program (or the title it set), else the folder.
    var displayTitle: String {
        if session.isRemote, let host = session.remoteHost {
            let short = host.components(separatedBy: ".").first ?? host
            if let r = session.running, !r.command.isEmpty, let p = HistoryStore.programName(r.command) {
                return "⇄ \(short) · \((p as NSString).lastPathComponent)"
            }
            return "⇄ " + short
        }
        if let r = session.running, !r.command.isEmpty {
            if titleFromProgram, !title.isEmpty { return title }
            return HistoryStore.programName(r.command).map { ($0 as NSString).lastPathComponent } ?? r.command
        }
        if !session.integrated, !title.isEmpty { return title }
        let cwd = session.cwd
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    var tabLocation: String {
        if session.isRemote {
            return "ssh: \(session.remoteHost ?? "")\(session.remoteCwd.map { ":" + $0 } ?? "")"
        }
        return PathDisplay.short(session.cwd, max: 60) + (session.gitBranch.map { "  (\($0))" } ?? "")
    }

    /// Hover text for this pane's tab: where it is and what's running.
    var tabTooltip: String {
        var lines = [tabLocation]
        if let r = session.running, !r.command.isEmpty { lines.append("Running: " + String(r.command.prefix(80))) }
        else if let b = session.blocks.last, (b.exitCode ?? 0) != 0 { lines.append("Last command failed (exit \(b.exitCode ?? 0))") }
        return lines.joined(separator: "\n")
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
        var command = command
        if SecretRefs.contains(command) {
            guard let filled = fillSecrets(command) else { return }
            command = filled
        }
        if !command.isEmpty { surfaceView.sendText(command) }
        surfaceView.sendSyntheticKey(keyCode: kVK_Return, text: "\r", unshifted: "\r")
    }

    /// Puts text in the editor (from history, a snippet, or clipboard history).
    /// Tools → Save Command to Notebook: what's in the editor, or else the last command.
    func saveToNotebook() {
        let typed = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let cmd = typed.isEmpty ? (session.blocks.last { !$0.command.isEmpty }?.command ?? "") : typed
        guard !cmd.isEmpty else { flash("Type or run a command first"); return }
        NotebookWindow.shared.add(command: cmd)
    }

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

    /// Clear (⌘K): the screen and scrollback, and the session helper's copy, so a restart doesn't bring it back.
    func clearScreen() {
        surfaceView.binding("clear_screen")
        if session.persistent { SessionHost.shared.request(["cmd": "clearReplay", "id": session.id], timeout: 0.5) }
        blocksOverlay.setNeedsRefresh()
        Services.shared.record("clear")
    }

    /// Menu option that also lets the user remove this tab's runs from History.
    func confirmDeepClean() {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Deep clean this tab?"
        a.informativeText = "Resets the terminal (fixes garbled text or a missing cursor), clears the screen and scrollback, "
            + "and forgets this tab's list of commands and their output. Your shell and anything running keep going."
        let alsoHistory = NSButton(checkboxWithTitle: "Also remove this tab's commands from History", target: nil, action: nil)
        alsoHistory.state = .off
        a.accessoryView = alsoHistory
        a.addButton(withTitle: "Deep Clean")
        a.addButton(withTitle: "Cancel")
        lastConfirmation = a
        a.beginSheetModal(for: w) { [weak self] r in
            self?.lastConfirmation = nil
            if r == .alertFirstButtonReturn { self?.deepClean(removeFromHistory: alsoHistory.state == .on) }
        }
    }

    func deepClean(removeFromHistory: Bool) {
        // A full terminal reset: modes, colors, character sets, cursor, scroll region.
        surfaceView.binding("reset")
        surfaceView.binding("clear_screen")
        if session.persistent { SessionHost.shared.request(["cmd": "clearReplay", "id": session.id], timeout: 0.5) }
        let ids = session.forgetBlocks()
        MemoryManager.shared.releaseSoon()
        if removeFromHistory {
            let history = Services.shared.history
            DispatchQueue.global(qos: .utility).async { history.delete(ids: ids) }
        }
        closePreview()
        hideFind()
        fixCommand = nil
        blocksOverlay.setNeedsRefresh()
        windowController?.paneActivityChanged(self, finished: true, failed: false)
        refreshBar()
        Services.shared.record(removeFromHistory ? "deepClean.history" : "deepClean")
        flash(removeFromHistory ? "Deep cleaned, and removed from History" : "Deep cleaned")
        focus()
    }

    func showHistorySearch() { windowController?.showHistorySearch(for: self) }

    /// For tests: the last path opened with ⌘-click.
    var lastOpenedLink: (path: String, line: Int?)?
    var lastOpenedArgv: [String] = []
    var lastOpenAction = ""
    private(set) var ignoredCwdReports = 0
    var confirmedDanger = false
    private var lastAnnouncedIssue: String?
    /// The open "Run this?" question (for tests).
    var lastConfirmation: NSAlert?
    /// The host of an `ssh` command running here (profiles apply right away,
    /// even on servers without Anser's hooks).
    private(set) var sshTarget: String?
    var gitExtrasRunning = false
    var previewPopover: NSPopover?
    var previewAnchor: NSPoint = .zero
    /// The file being previewed (for tests).
    var previewedPath: String?
    /// Last match count reported by Ghostty's search (for tests and the find bar).
    var searchTotal = -1
    // MARK: Lifecycle

    func surfaceRequestedClose() {
        guard !closed else { return }
        windowController?.close(self)
    }

    /// Tests: let go of the shell without ending it, as quitting does.
    var keepShellOnClose = false

    func teardown() {
        guard !closed else { return }
        Diagnostics.shared.log("pane closed")
        closed = true
        // Quitting keeps the shell (it comes back next launch); closing the pane ends it.
        TabShare.share(for: self)?.stop()
        let keep = session.persistent && (keepShellOnClose || (AppDelegate.shared.isTerminating && AppDelegate.shared.keepingShellsOnQuit))
        if keep { SessionHost.shared.save(session) } else if session.persistent { SessionHost.shared.end(session.id) }
        runningTimer?.invalidate()
        followTimer?.invalidate()
        reconnect?.timer?.invalidate()
        reconnect = nil
        fileWatch?.stop()
        fileWatch = nil
        recorder?.stop()
        stopForwards()
        PluginHost.shared.forget(self)
        filterPanel?.removeFromSuperview()
        filterPanel = nil
        editor.hidePopup()
        surfaceView.destroy()
        session.close(keepShell: keep)
        MemoryManager.shared.releaseSoon()
        NotificationCenter.default.removeObserver(self)
    }
}
