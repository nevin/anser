import AppKit
import Quartz
import Carbon.HIToolbox
import GhosttyKit
import AnserCore

/// A pane's features beyond the terminal itself: opening paths, AI help,
/// running from the editor, profiles, pull requests and conflicts, Quick Look, tips.
extension PaneView {
    // MARK: Opening file paths from output

    /// Opens a path from the terminal output in your editor (at its line).
    /// Returns false if it isn't a file, so the click goes to the terminal.
    @discardableResult
    func openLink(_ word: String) -> Bool {
        guard let link = PathLink.find(word: word, in: surfaceView.viewportText() ?? "") else { return false }
        return open(link)
    }

    /// Opens a file (relative to this pane's folder) the way ⌘-click does.
    @discardableResult
    func openFile(_ path: String) -> Bool {
        guard let link = PathLink.find(word: path, in: path) else { return false }
        return open(link)
    }

    private func open(_ link: PathLink) -> Bool {
        let path = link.resolved(cwd: session.cwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        lastOpenedLink = (path, link.line)
        // Apps, scripts and other runnable things are revealed, never launched.
        guard OpenSafety.canOpenDirectly(path: path) else {
            lastOpenAction = "reveal"
            if ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            return true
        }
        if isDir.boolValue { lastOpenAction = "finder"; NSWorkspace.shared.open(URL(fileURLWithPath: path)); return true }

        let configured = Services.shared.config.openFilesWith?.trimmingCharacters(in: .whitespaces)
        let editor = (configured?.isEmpty == false ? configured : nil)
            ?? PathLink.guiEditors.first { CommandIndex.shared.contains($0, env: session.env) }
        guard let editor else { lastOpenAction = "open"; NSWorkspace.shared.open(URL(fileURLWithPath: path)); return true }
        lastOpenAction = "editor"
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

    /// For tests: the folder chip's right-click menu.
    var folderChipMenuTitles: [String] { cwdChip.menuProvider?()?.items.map(\.title) ?? [] }

    /// For tests: where the input area's top edge is.
    var barTopForTest: CGFloat { bar.frame.maxY }

    /// For tests: the bottom edge of the last output line (the top of the cursor's row), in pane coordinates.
    var outputBottomForTest: CGFloat? {
        guard let surface = surfaceView.surface else { return nil }
        var x = 0.0, y = 0.0, cw = 0.0, ch = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &cw, &ch)
        return surfaceView.frame.maxY - CGFloat(y)
    }


    // MARK: AI help

    func explainLastError() {
        guard Services.shared.aiEnabled else { offerAISetup(); return }
        guard let i = session.blocks.indices.last, let w = window else { NSSound.beep(); return }
        let b = session.blocks[i]
        Services.shared.record("ai.explain")
        let panel = AIPanel(pane: self, mode: .explain(command: b.command, exitCode: b.exitCode ?? 0, output: output(ofBlock: i) ?? ""))
        panel.present(over: w)
    }

    /// Explain any finished command (from its block's hover strip).
    func explainBlock(at i: Int) {
        guard Services.shared.aiEnabled else { offerAISetup(); return }
        guard session.blocks.indices.contains(i), let w = window else { NSSound.beep(); return }
        let b = session.blocks[i]
        Services.shared.record("ai.explain")
        AIPanel(pane: self, mode: .explain(command: b.command, exitCode: b.exitCode ?? 0, output: output(ofBlock: i) ?? "")).present(over: w)
    }

    func askClaude() {
        Services.shared.record("ai.ask")
        guard Services.shared.aiEnabled else { offerAISetup(); return }
        guard let w = window else { return }
        AIPanel(pane: self, mode: .generate).present(over: w)
    }

    func offerAISetup() {
        let a = NSAlert()
        a.messageText = "Turn on AI help?"
        a.informativeText = "AI help explains failed commands and writes commands from a description, using Claude (your Anthropic API key), GitHub Copilot (your GitHub sign-in) or a local model with Ollama (nothing leaves your Mac). It's off by default, and nothing is sent until you ask."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Not Now")
        if let w = window {
            a.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { SettingsWindowController.shared.show() } }
        }
    }

    // MARK: Actions from the status row

    /// The local job in front of this pane's shell (nil at the prompt, for ssh sessions, or before the shell said hello).
    var foregroundJob: ForegroundJob.Info? {
        guard !session.isRemote, session.shellPID > 1, !session.atPrompt else { return nil }
        return ForegroundJob.of(shellPID: session.shellPID)
    }

    /// A command that opens a full-screen program itself (`git branch` → less, `git log`, `psql` → less)
    /// gets the whole window, like vim does, so q, arrows and search reach it.
    func checkForegroundProgram() {
        guard let job = foregroundJob else {
            if fullscreenDetected { leaveDetectedFullscreen() }
            return
        }
        let apps = Set(Services.shared.config.fullscreenApps)
        let inFront = job.names.contains { apps.contains($0) }
        if inFront, !fullscreenProgram {
            fullscreenProgram = true
            fullscreenDetected = true
            needsLayout = true
            layoutSubtreeIfNeeded()
            if isFocusedPane { window?.makeFirstResponder(surfaceView) }
        } else if !inFront, fullscreenDetected {
            leaveDetectedFullscreen()
        }
    }

    private func leaveDetectedFullscreen() {
        fullscreenDetected = false
        fullscreenProgram = false
        needsLayout = true
    }

    /// Stop: ⌃C first. A pager (which ignores ⌃C) is ended right away; anything else
    /// still running gets SIGTERM on the next click, then SIGKILL.
    @objc func stopRunning() {
        if let wc = windowController, wc.isBroadcasting(self) {
            for p in wc.panes(inSameTabAs: self) where p !== self && !p.session.atPrompt { p.sendControl("c") }
        }
        let job = foregroundJob
        if let job, ForegroundJob.isPager(job) {
            ForegroundJob.send(SIGTERM, to: job)
            Services.shared.record("stop.pager")
            return
        }
        stopPresses += 1
        switch stopPresses {
        case 1:
            sendControl("c")
            let command = session.running?.command
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.stopPresses == 1, !self.session.atPrompt, self.session.running?.command == command else { return }
                self.updateStopButton()
                self.flash("Still running: click Force Stop to end it")
            }
        case 2:
            if let job { ForegroundJob.send(SIGTERM, to: job) } else { sendControl("c") }
            Services.shared.record("stop.term")
            updateStopButton()
        default:
            if let job { ForegroundJob.send(SIGKILL, to: job) } else { sendControl("c") }
            Services.shared.record("stop.kill")
        }
    }

    /// "Stop", then "Force Stop" once ⌃C didn't end it.
    func updateStopButton() {
        let force = stopPresses >= 1 && !session.atPrompt
        stopButton.title = force ? " Force Stop" : " Stop"
        stopButton.toolTip = force ? "End the program now (it didn't stop on ⌃C)" : "Stop the running program (⌃C; click again to force it)"
        needsLayout = true
    }

    // MARK: Running from the editor

    /// The editor's Enter: asks first where a profile says so, and runs in
    /// every pane of the tab while "Type in All Panes" is on.
    func submitFromEditor(_ command: String) {
        Services.shared.record("command.run")
        let go = { [weak self] in
            guard let self else { return }
            self.run(command)
            if let wc = self.windowController, wc.isBroadcasting(self) {
                for p in wc.panes(inSameTabAs: self) where p !== self && p.session.atPrompt { p.run(command) }
            }
        }
        // Commands that can destroy a lot ask first, whatever the profile.
        if Services.shared.config.editor.lint, !confirmedDanger,
           let danger = CommandLint.check(command, isKnown: { _ in true }).first(where: { $0.severity == .danger }), let w = window {
            let a = NSAlert()
            a.alertStyle = .critical
            a.messageText = "Run this anyway?"
            a.informativeText = danger.message + "\n\n" + String(command.prefix(400))
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Run It")
            lastConfirmation = a
            a.beginSheetModal(for: w) { [weak self] r in
                guard let self else { return }
                self.lastConfirmation = nil
                if r == .alertSecondButtonReturn {
                    self.confirmedDanger = true
                    self.submitFromEditor(command)
                    self.confirmedDanger = false
                } else {
                    self.editor.setCommand(command)
                    self.focus()
                }
            }
            return
        }
        // A folder/host profile, or one for the cloud context this command talks to (e.g. a prod cluster).
        guard let p = [profile, contextProfile(for: command)].compactMap({ $0 }).first(where: { $0.needsConfirmation(command) }),
              let w = window else { go(); return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Run this \(p.badge.map { "on \($0)" } ?? "here")?"
        a.informativeText = String(command.prefix(600)) + "\n\nThe profile for this \(session.isRemote ? "host" : "folder") asks before running commands like this."
        a.addButton(withTitle: "Run")
        a.addButton(withTitle: "Cancel")
        lastConfirmation = a
        a.beginSheetModal(for: w) { [weak self] r in
            self?.lastConfirmation = nil
            if r == .alertFirstButtonReturn { go() } else { self?.editor.setCommand(command); self?.focus() }
        }
    }

    // MARK: Profiles


    func updateProfile() {
        let cfg = Services.shared.config
        var p: Profile?
        if !cfg.profiles.isEmpty {
            if let host = session.remoteHost {
                p = Profile.resolve(cfg.profiles, host: host, cwd: session.remoteCwd ?? "~")
            } else if let target = sshTarget {
                // Match the name you typed, then its real host name from ~/.ssh/config.
                let real = SSHConfig.load().first { $0.alias == target }?.hostName
                p = Profile.resolve(cfg.profiles, host: target, cwd: "~") ?? real.flatMap { Profile.resolve(cfg.profiles, host: $0, cwd: "~") }
            } else {
                p = Profile.resolve(cfg.profiles, host: nil, cwd: session.cwd)
            }
        }
        guard p != profile else { return }
        profile = p
        windowController?.paneProfileChanged(self)
        refreshBar()
    }

    // MARK: Pull requests and conflicts

    private static var prCache: [String: (at: Date, pr: GitInfo.PullRequest?)] = [:]

    func refreshGitExtras() {
        guard let branch = session.gitBranch, !session.isRemote, !session.gitRisky else {
            if pullRequest != nil || !conflicts.isEmpty { pullRequest = nil; conflicts = []; gitOperation = nil; refreshBar() }
            return
        }
        guard !gitExtrasRunning else { return }
        gitExtrasRunning = true
        let cwd = session.cwd, env = session.env
        Task { @MainActor [weak self] in
            let porcelain = await ScriptRunner.shared.run("git status --porcelain 2>/dev/null | grep -E '^(UU|AA|DD|AU|UA|DU|UD) ' | head -300",
                                                          cwd: cwd, env: env, timeout: 3) ?? ""
            guard let self else { return }
            defer { self.gitExtrasRunning = false }
            guard self.session.cwd == cwd else { return }
            let gitDir = GitInfo.gitDir(for: cwd)
            self.conflicts = GitInfo.parseConflicts(porcelain)
            self.gitOperation = gitDir.flatMap(GitInfo.operation(gitDir:))
            self.refreshBar()
            guard Services.shared.config.showPullRequests, Self.ghPath(env) != nil else {
                if self.pullRequest != nil { self.pullRequest = nil; self.refreshBar() }
                return
            }
            let key = (gitDir ?? cwd) + "#" + branch
            if let c = Self.prCache[key], Date().timeIntervalSince(c.at) < 120 {
                self.pullRequest = c.pr
                self.refreshBar()
                return
            }
            Self.prCache[key] = (Date(), self.pullRequest)   // one lookup at a time per branch
            let json = await ScriptRunner.shared.run("gh pr view --json \(GitInfo.prFields) 2>/dev/null", cwd: cwd, env: env, timeout: 10) ?? ""
            let pr = GitInfo.parsePullRequest(json)
            Self.prCache[key] = (Date(), pr)
            guard self.session.gitBranch == branch, self.session.cwd == cwd else { return }
            self.pullRequest = pr
            self.refreshBar()
        }
    }

    /// Forgets cached pull request info (after a push, say).
    static func forgetPullRequests() { prCache = [:] }

    static func ghPath(_ env: ShellEnvironment) -> String? {
        (env.path + ShellEnvironment.defaultPath).map { $0 + "/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func openPullRequest() {
        if let url = pullRequest.flatMap({ URL(string: $0.url) }), !(pullRequest?.url.isEmpty ?? true) {
            Services.shared.record("git.openPR")
            NSWorkspace.shared.open(url)
        } else if Self.ghPath(session.env) != nil, session.gitBranch != nil {
            // No PR yet: offer to create one in the browser.
            run("gh pr create --web")
        } else {
            flash("Needs the GitHub CLI (brew install gh) in a GitHub repository")
        }
    }

    // MARK: Quick Look on hover


    /// A path (with its line, if given) in `word` that exists on this Mac.
    func pathLink(_ word: String, viewport: String? = nil) -> (path: String, line: Int?)? {
        guard !session.isRemote, let link = PathLink.find(word: word, in: viewport ?? word) else { return nil }
        let path = link.resolved(cwd: session.cwd)
        return FileManager.default.fileExists(atPath: path) ? (path, link.line) : nil
    }

    /// A file path in `word` (relative to this pane's folder) that exists on this Mac.
    func previewCandidate(_ word: String, viewport: String? = nil) -> String? {
        guard !session.isRemote, let link = PathLink.find(word: word, in: viewport ?? word) else { return nil }
        let path = link.resolved(cwd: session.cwd)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    func previewPathUnderMouse(at point: NSPoint) {
        guard Services.shared.config.previewFilesOnHover, window?.isKeyWindow == true, session.running == nil || !fullscreenProgram,
              let word = surfaceView.wordUnderMouse(), let path = previewCandidate(word, viewport: surfaceView.viewportText()) else { return }
        showPreview(of: path, at: point)
    }

    func showPreview(of path: String, at point: NSPoint) {
        if previewedPath == path, previewPopover?.isShown == true { return }
        closePreview()
        let view = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 460, height: 320), style: .compact)!
        view.autostarts = true
        view.previewItem = URL(fileURLWithPath: path) as NSURL
        let vc = NSViewController()
        vc.view = view
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .semitransient
        pop.animates = false
        pop.show(relativeTo: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), of: surfaceView, preferredEdge: .maxY)
        previewPopover = pop
        previewAnchor = point
        previewedPath = path
        Services.shared.record("quicklook.hover")
    }

    /// Moving well away from the path closes its preview.
    func mouseMovedOverOutput(at point: NSPoint) {
        guard previewPopover?.isShown == true else { return }
        if abs(point.x - previewAnchor.x) > 60 || abs(point.y - previewAnchor.y) > 20 { closePreview() }
    }

    func closePreview() {
        previewPopover?.close()
        previewPopover = nil
        previewedPath = nil
    }

    var previewShowing: Bool { previewPopover?.isShown == true }

    // MARK: Tips

    /// A one-time tip in the status row under the editor, so it never covers
    /// output. It shows at the next prompt and stays about 12 seconds.
    func showTip(_ text: String) {
        lastTip = text
        activeTip = text
        tipShownAt = nil
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        updateHint()
    }

    func hideTip() {
        activeTip = nil
        tipShownAt = nil
        updateHint()
    }

    /// Puts the fixed (or failed) command back in the editor to run again.
    func applyFix() {
        guard editorUsable else { NSSound.beep(); return }
        let cmd = fixCommand ?? session.blocks.last?.command ?? ""
        editor.setCommand(cmd)
        window?.makeFirstResponder(editor)
    }

    func showResultMenu() {
        resultMenu()?.popUp(positioning: nil, at: NSPoint(x: statusChip.frame.minX, y: statusChip.frame.maxY + 4), in: bar)
    }

    func resultMenu() -> NSMenu? {
        guard let last = session.blocks.last else { return nil }
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
            add("Explain with \(Services.shared.aiName)", "sparkles") { [weak self] in self?.explainLastError() }
        }
        add("Copy Output", "doc.on.clipboard") { AppDelegate.shared.copyLastOutput(nil) }
        add("Copy Command", "terminal") { TerminalWindowController.copy(last.command) }
        add("Find in This Tab’s Commands", "square.stack.3d.up") { [weak self] in
            guard let self else { return }
            self.windowController?.showBlocks(for: self)
        }
        return m
    }

}
