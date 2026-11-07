import AppKit
import GhosttyKit
import AnserCore

/// The welcome card, find bar, copying output, and self-test snapshots.
extension PaneView {
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
        // The terminal's own foreground process is the attach helper; ask anser-session about the real shell.
        if session.persistent { return SessionHost.shared.busy(session.id) }
        guard let s = surfaceView.surface, session.shellPID > 0 else { return false }
        let fg = ghostty_surface_foreground_pid(s)
        return fg != 0 && fg != UInt64(session.shellPID)
    }

    var runningDescription: String {
        session.running?.command ?? "a running program"
    }

    // MARK: Find

    func showFind(query: String? = nil) {
        if findBar == nil {
            let fb = FindBar(pane: self)
            addSubview(fb)
            findBar = fb
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        findBar?.focus(with: query ?? (surfaceView.hasSelection ? surfaceView.selectionText() : nil))
    }

    func hideFind() {
        guard let fb = findBar else { return }
        surfaceView.binding("end_search")
        fb.removeFromSuperview()
        findBar = nil
        focus()
    }

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
    func captureOutput(forBlockAt i: Int, attempt: Int = 0) {
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
            let text = surfaceView.commandOutput(index: newer) ?? ""
            session.setOutput(text, forBlockAt: i)
            let id = session.blocks[i].historyID
            if Services.shared.config.saveOutput, id > 0, !session.historyPaused {
                // Only the end is kept, so only the end is scanned for secrets (no copy of a huge output).
                let tail = OutputBudget.tail(text, bytes: HistoryStore.maxOutputCharacters)
                let history = Services.shared.history
                DispatchQueue.global(qos: .utility).async { history.saveOutput(AIHelp.redact(tail), forHistoryID: id) }
            }
            if text.utf8.count > 2 << 20 { MemoryManager.shared.releaseSoon() }
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
        let rect = includeTerminalArea ? bounds
            : NSRect(x: 0, y: bar.frame.minY, width: bounds.width, height: min(bounds.height - bar.frame.minY, bar.frame.height + (bar.floating ? 40 : 4)))
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

}
