import AppKit
import CoreServices
import AnserCore

/// What to do when the running command finishes.
enum AfterStep: Equatable {
    case notify
    case run(String, onlyIfSucceeded: Bool)

    var label: String {
        switch self {
        case .notify: "notify me"
        case let .run(cmd, ok): (ok ? "if it works: " : "then: ") + cmd
        }
    }
}

/// Watches a folder and calls back with changed files (build output, caches
/// and dependencies don't count, see WatchRules).
final class FileWatch {
    let root: String
    let cwd: String
    let command: String
    /// Only files matching these count ("*.py"); empty = any file.
    var patterns: [String] = []
    private(set) var runs = 0
    var quietUntil = Date()
    var lastChange: String?
    var onChange: (([String]) -> Void)?
    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?

    init(root: String, cwd: String, command: String) {
        self.root = root; self.cwd = cwd; self.command = command
    }

    @discardableResult
    func start() -> Bool {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatch>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            me.received(Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else { return false }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        return FSEventStreamStart(s)
    }

    func stop() {
        debounce?.cancel()
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// The folder with symlinks resolved (FSEvents reports /private/var/…, not /var/…).
    private lazy var realRoot: String = {
        guard let r = realpath(root, nil) else { return root }
        defer { free(r) }
        return String(cString: r)
    }()

    func received(_ paths: [String]) {
        let prefixes = Set([root, realRoot].map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        let relevant = paths.compactMap { p -> String? in
            guard let prefix = prefixes.first(where: { p.hasPrefix($0) }) else { return nil }
            let rel = String(p.dropFirst(prefix.count))
            return WatchRules.isIgnored(rel) || !WatchRules.matches(rel, patterns: patterns) ? nil : rel
        }
        guard !relevant.isEmpty, Date() >= quietUntil else { return }
        lastChange = relevant.first
        // Editors save in bursts (temp file, rename, chmod): wait for it to settle.
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?(relevant) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func noteRun() { runs += 1 }

    deinit { stop() }
}

extension PaneView {
    // MARK: Chips

    func setUpRunToolChips() {
        testsChip.onClick = { [weak self] in self?.showFailedTestsMenu(from: self?.testsChip) }
        watchChip.onClick = { [weak self] in self?.showWatchMenu() }
        afterChip.onClick = { [weak self] in self?.showAfterMenu() }
        envChip.onClick = { [weak self] in self?.showProjectEnvMenu() }
        aliasChip.onClick = { [weak self] in self?.showAliasTipMenu() }
        bar.addSubview(moreChip)
        moreChip.onClick = { [weak self] in
            guard let self, let m = self.overflowStatusMenu() else { return }
            m.popUp(positioning: nil, at: NSPoint(x: self.moreChip.frame.minX, y: self.moreChip.frame.maxY + 2), in: self.bar)
        }
        logChip.onClick = { [weak self] in self?.openLogViewer() }
        recChip.onClick = { [weak self] in self?.showRecordingMenu() }
        hintChip.onClick = { [weak self] in self?.showFixHintMenu() }
        forwardChip.onClick = { [weak self] in self?.showForwardMenu() }
    }

    func refreshRunToolChips() {
        let t = theme
        let dim = t.foreground.withAlphaComponent(0.55)
        if let r = testReport?.report, !r.failures.isEmpty {
            let n = r.failures.count
            testsChip.filled = t.red
            testsChip.set(symbol: "xmark.octagon", text: "\(n) test\(n == 1 ? "" : "s") failed", color: t.red,
                          tooltip: r.failures.prefix(8).map { "✗ " + $0.name }.joined(separator: "\n") + (n > 8 ? "\n…" : "") + "\nClick to open one or re-run it")
        } else {
            testsChip.filled = nil
            testsChip.set(symbol: nil, text: "", color: dim)
        }
        if let w = fileWatch {
            let away = session.cwd != w.cwd
            watchChip.filled = away ? nil : t.blue
            watchChip.set(symbol: "eye", text: away ? "watching (paused)" : (w.runs == 0 ? "watching files" : "watching · \(w.runs) run\(w.runs == 1 ? "" : "s")"),
                          color: away ? dim : t.blue,
                          tooltip: "Runs “\(w.command)” when " + (w.patterns.isEmpty ? "files" : w.patterns.joined(separator: ", ") + " files") + " in \(PathDisplay.short(w.root)) change" + (away ? "\nPaused: you're in another folder" : "")
                            + (w.lastChange.map { "\nLast change: \($0)" } ?? "") + "\nClick for options")
        } else {
            watchChip.filled = nil
            watchChip.set(symbol: nil, text: "", color: dim)
        }
        if let first = afterSteps.first {
            let more = afterSteps.count > 1 ? " +\(afterSteps.count - 1)" : ""
            afterChip.filled = ChipRole.waiting.color(t)
            afterChip.set(symbol: first == .notify ? "bell" : "arrow.turn.down.right", text: String(first.label.prefix(40)) + more, color: ChipRole.waiting.color(t),
                          tooltip: "When the running command finishes:\n" + afterSteps.map { "• " + $0.label }.joined(separator: "\n") + "\nClick to change")
        } else {
            afterChip.filled = nil
            afterChip.set(symbol: nil, text: "", color: dim)
        }
        refreshProjectEnvChip()
        refreshHabitChips()
        refreshFixAndForwardChips()
    }

    // MARK: After a command finishes

    func commandStartedForRunTools(_ command: String) {
        if fixHint != nil { fixHint = nil }
        if let w = fileWatch, command != w.command { w.quietUntil = .distantFuture }
    }

    /// Called at every prompt: runs "when done" steps, finish callbacks and the test check once per finished command.
    func commandFinishedForRunTools() {
        guard let b = session.lastFinished, b.duration != nil, b.id != lastHandledFinish, session.running == nil else { return }
        lastHandledFinish = b.id
        fileWatch?.quietUntil = Date().addingTimeInterval(0.8)
        runAfterSteps(after: b)
        // Output is saved a moment after the prompt appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            let i = self.session.blocks.lastIndex { $0.id == b.id }
            let out = i.flatMap { self.output(ofBlock: $0) } ?? ""
            let due = self.finishWatchers
            self.finishWatchers = []
            due.forEach { $0(b, out) }
            self.checkTestFailures(b, output: out)
            self.checkHabit(b)
            self.checkFixHint(b)
        }
    }

    /// Calls `fn` once, when the next command finishes (with its output).
    func onNextFinish(_ fn: @escaping (ShellSession.Block, String) -> Void) {
        finishWatchers.append(fn)
    }

    private func runAfterSteps(after b: ShellSession.Block) {
        guard !afterSteps.isEmpty else { return }
        let ok = (b.exitCode ?? 0) == 0
        if afterSteps.contains(.notify) {
            afterSteps.removeAll { $0 == .notify }
            Services.shared.notifyCommandFinished(b.command, exitCode: b.exitCode ?? 0, duration: b.duration ?? 0, sessionID: session.id)
            if sessionIsVisible { NSSound(named: ok ? "Glass" : "Basso")?.play() }
        }
        if let i = afterSteps.firstIndex(where: { if case .run = $0 { return true } else { return false } }), case let .run(cmd, onlyOK) = afterSteps[i] {
            afterSteps.remove(at: i)
            if onlyOK && !ok {
                flash("Didn't run “\(cmd.prefix(40))”: the command failed")
                afterSteps.removeAll()
            } else {
                Services.shared.record("after.run")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.session.atPrompt else { return }
                    self.submitFromEditor(cmd)
                }
            }
        }
        refreshBar()
    }

    /// Shell → When This Finishes…: notify, or run something next.
    func promptWhenDone() {
        guard let running = session.running, let w = window else {
            flash("Nothing is running. Use this while a command runs.")
            return
        }
        let kinds = ["Notify me", "Run this next if it succeeds", "Run this next either way"]
        let f = FormSheet(title: "When “\(running.command.prefix(50))” finishes", message: "Anser can tell you, or run another command next.",
                          fields: [
                            .init("kind", "Then", .popup(options: kinds), value: kinds[0]),
                            .init("command", "Command", .text(placeholder: "e.g. npm test", mono: true)),
                          ], ok: "Add")
        f.validate = { v in
            v["kind"] != kinds[0] && v["command", default: ""].trimmingCharacters(in: .whitespaces).isEmpty ? "Type the command to run next." : nil
        }
        f.preview = { v in
            let c = v["command", default: ""].trimmingCharacters(in: .whitespaces)
            switch v["kind"] {
            case kinds[1]?: return c.isEmpty ? nil : "\(running.command.prefix(30)) && \(c)"
            case kinds[2]?: return c.isEmpty ? nil : "\(running.command.prefix(30)) ; \(c)"
            default: return "A notification when it finishes (with a sound if Anser is in front)."
            }
        }
        f.present(over: w, focus: "command") { [weak self] v in
            guard let self, let v else { return }
            let cmd = v["command", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            switch v["kind"] {
            case kinds[0]?: if !self.afterSteps.contains(.notify) { self.afterSteps.append(.notify) }
            default: self.afterSteps.append(.run(cmd, onlyIfSucceeded: v["kind"] == kinds[1]))
            }
            Services.shared.record("after.add")
            self.refreshBar()
        }
    }

    func showAfterMenu() {
        let m = NSMenu()
        for (i, step) in afterSteps.enumerated() {
            m.addItem(ClosureMenuItem(title: "Remove “\(step.label.prefix(50))”") { [weak self] in
                guard let self, self.afterSteps.indices.contains(i) else { return }
                self.afterSteps.remove(at: i)
                self.refreshBar()
            })
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Add Another…") { [weak self] in self?.promptWhenDone() })
        m.addItem(ClosureMenuItem(title: "Clear All") { [weak self] in self?.afterSteps = []; self?.refreshBar() })
        m.popUp(positioning: nil, at: NSPoint(x: afterChip.frame.minX, y: afterChip.frame.maxY + 2), in: bar)
    }

    // MARK: Re-run when files change

    func toggleWatch() {
        if fileWatch != nil { stopWatching(); return }
        guard !session.isRemote else { flash("Watching works for folders on this Mac"); return }
        guard let last = session.blocks.last(where: { !$0.command.isEmpty }) else { flash("Run the command you want to repeat first"); return }
        startWatching(command: last.command, cwd: last.cwd)
    }

    func startWatching(command: String, cwd: String, patterns: [String] = []) {
        fileWatch?.stop()
        let root = WatchRules.root(for: cwd)
        guard root != NSHomeDirectory(), root != "/" else { flash("Watching your whole home folder would be too much; cd into a project first"); return }
        let w = FileWatch(root: root, cwd: cwd, command: command)
        w.patterns = patterns
        w.onChange = { [weak self] _ in self?.watchedFilesChanged() }
        guard w.start() else { flash("Couldn't watch \(PathDisplay.short(root))"); return }
        fileWatch = w
        Services.shared.record("watch.start")
        flash("Re-runs “\(command.prefix(40))” when files change")
        refreshBar()
    }

    /// Limits which changed files re-run the command ("*.py, *.toml").
    func promptWatchPatterns() {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Which files should re-run it?"
        a.informativeText = "Patterns separated by commas, like *.py, *.toml or src/. Leave empty for any file. Build output and dependencies never count."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        f.stringValue = fileWatch?.patterns.joined(separator: ", ") ?? ""
        f.placeholderString = "e.g. *.py, *.toml"
        a.accessoryView = f
        a.window.initialFirstResponder = f
        a.addButton(withTitle: fileWatch == nil ? "Start Watching" : "Save")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            let pats = WatchRules.parsePatterns(f.stringValue)
            if let fw = self.fileWatch { fw.patterns = pats; self.refreshBar() }
            else if let last = self.session.blocks.last(where: { !$0.command.isEmpty }) { self.startWatching(command: last.command, cwd: last.cwd, patterns: pats) }
        }
    }

    func stopWatching() {
        fileWatch?.stop()
        fileWatch = nil
        refreshBar()
    }

    private func watchedFilesChanged() {
        guard let w = fileWatch else { return }
        refreshBar()
        guard session.atPrompt, session.running == nil, session.cwd == w.cwd else { return }
        w.noteRun()
        w.quietUntil = .distantFuture   // until it finishes
        run(w.command)
        refreshBar()
    }

    func showWatchMenu() {
        guard let w = fileWatch else { return }
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "Run Now") { [weak self] in
            guard let self, self.session.atPrompt else { NSSound.beep(); return }
            self.fileWatch?.noteRun()
            self.run(w.command)
        })
        m.addItem(ClosureMenuItem(title: w.patterns.isEmpty ? "Only Some Files…" : "Change Files (\(w.patterns.joined(separator: ", ")))…") { [weak self] in self?.promptWatchPatterns() })
        m.addItem(ClosureMenuItem(title: "Stop Watching") { [weak self] in self?.stopWatching() })
        let info = NSMenuItem(title: "Watching \(PathDisplay.short(w.root))", action: nil, keyEquivalent: "")
        info.isEnabled = false
        m.addItem(.separator())
        m.addItem(info)
        m.popUp(positioning: nil, at: NSPoint(x: watchChip.frame.minX, y: watchChip.frame.maxY + 2), in: bar)
    }

    // MARK: Failed tests

    private func checkTestFailures(_ b: ShellSession.Block, output: String) {
        guard Services.shared.config.testFailureList, !session.isRemote, !b.command.isEmpty else { return }
        let ok = (b.exitCode ?? 0) == 0
        let isTest = TestFailures.runnerFromCommand(b.command) != nil || (testReport.map { b.command.hasPrefix(TestFailures.prefixOf($0.command)) } ?? false)
        if ok {
            guard let current = testReport else { return }
            if let names = pendingTestRerun, !names.isEmpty {
                // A re-run of some failed tests passed: drop those.
                var r = current.report
                r.failures.removeAll { names.contains($0.name) }
                testReport = r.failures.isEmpty ? nil : (r, current.command, current.cwd)
                if r.failures.isEmpty { flash("All the failed tests pass now") }
            } else if isTest {
                testReport = nil
            }
            pendingTestRerun = nil
            refreshBar()
            return
        }
        guard let r = TestFailures.report(command: b.command, output: output) else { pendingTestRerun = nil; return }
        if let names = pendingTestRerun, let current = testReport {
            // Re-ran a few: keep the others, update these.
            var merged = current.report
            merged.failures.removeAll { names.contains($0.name) }
            merged.failures = r.failures + merged.failures
            testReport = (merged, current.command, current.cwd)
        } else {
            testReport = (r, b.command, b.cwd)
        }
        pendingTestRerun = nil
        Services.shared.record("tests.failed." + r.runner.rawValue)
        refreshBar()
        if windowController?.focusedPane === self { windowController?.refreshSidebar() }
    }

    func showFailedTestsMenu(from chip: ChipView?) {
        guard let menu = failedTestsMenu() else { flash("No failed tests from the last test run"); return }
        if let chip, !chip.isHidden {
            menu.popUp(positioning: nil, at: NSPoint(x: chip.frame.minX, y: chip.frame.maxY + 2), in: bar)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 20, y: bar.frame.maxY), in: self)
        }
    }

    func failedTestsMenu() -> NSMenu? {
        guard let (r, cmd, cwd) = testReport, !r.failures.isEmpty else { return nil }
        let m = NSMenu()
        let head = NSMenuItem(title: "\(r.failures.count) failed · \(r.runner.displayName)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        for f in r.failures.prefix(25) {
            let item = NSMenuItem(title: f.name.count > 70 ? String(f.name.prefix(69)) + "…" : f.name, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            item.toolTip = [f.location, f.message].compactMap { $0 }.joined(separator: "\n")
            let sub = NSMenu()
            if let loc = f.location {
                sub.addItem(ClosureMenuItem(title: "Open \((loc as NSString).lastPathComponent)") { [weak self] in self?.openTestLocation(f, cwd: cwd) })
            }
            if let re = TestFailures.rerunCommand(f, runner: r.runner, original: cmd) {
                sub.addItem(ClosureMenuItem(title: "Re-run This Test") { [weak self] in self?.rerunTests([f], command: re, cwd: cwd) })
                sub.addItem(ClosureMenuItem(title: "Put Re-run Command in Editor") { [weak self] in self?.insertIntoEditor(re) })
            }
            sub.addItem(ClosureMenuItem(title: "Copy Test Name") { TerminalWindowController.copy(f.name) })
            if let msg = f.message {
                sub.addItem(.separator())
                let info = NSMenuItem(title: String(msg.prefix(90)), action: nil, keyEquivalent: "")
                info.isEnabled = false
                sub.addItem(info)
            }
            item.submenu = sub
            m.addItem(item)
        }
        if r.failures.count > 25 {
            let more = NSMenuItem(title: "\(r.failures.count - 25) more", action: nil, keyEquivalent: "")
            more.isEnabled = false
            m.addItem(more)
        }
        m.addItem(.separator())
        if let all = TestFailures.rerunCommand(r.failures, runner: r.runner, original: cmd) {
            m.addItem(ClosureMenuItem(title: "Re-run All Failed Tests") { [weak self] in self?.rerunTests(r.failures, command: all, cwd: cwd) })
        }
        m.addItem(ClosureMenuItem(title: "Run the Whole Suite Again") { [weak self] in
            guard let self, self.session.atPrompt else { NSSound.beep(); return }
            self.run(cmd)
        })
        m.addItem(ClosureMenuItem(title: "Dismiss") { [weak self] in self?.testReport = nil; self?.refreshBar() })
        return m
    }

    func rerunTests(_ fs: [TestFailures.Failure], command: String, cwd: String) {
        guard session.atPrompt else { flash("Wait for the running command to finish"); return }
        Services.shared.record("tests.rerun")
        pendingTestRerun = Set(fs.map(\.name))
        run(session.cwd == cwd ? command : "cd \(ShellLexer.escape(cwd)) && \(command)")
    }

    /// Opens a failure's file at its line (searching the project when the runner printed a bare file name).
    func openTestLocation(_ f: TestFailures.Failure, cwd: String) {
        guard let file = f.file else { return }
        let fm = FileManager.default
        var path: String?
        let direct = file.hasPrefix("/") ? file : (cwd as NSString).appendingPathComponent(file)
        if fm.fileExists(atPath: direct) { path = direct }
        else { path = Self.findFile(named: (file as NSString).lastPathComponent, under: WatchRules.root(for: cwd), endingWith: file) }
        guard let p = path else { flash("Couldn't find \(file)"); return }
        Services.shared.record("tests.open")
        if !openFile(p + (f.line.map { ":\($0)" } ?? "")) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }

    /// A file by name under `root` (skipping dependencies and build output), preferring one whose path ends with `endingWith`.
    static func findFile(named name: String, under root: String, endingWith suffix: String) -> String? {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var hits: [String] = []
        var seen = 0
        for case let url as URL in e {
            seen += 1
            if seen > 40_000 { break }
            if WatchRules.ignoredFolders.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            if url.lastPathComponent == name { hits.append(url.path) }
        }
        return hits.first { $0.hasSuffix("/" + suffix) } ?? hits.first
    }
}

extension TestFailures {
    /// The runner part of a test command ("npx jest src/x.test.js" → "npx jest").
    static func prefixOf(_ command: String) -> String {
        command.split(separator: " ").prefix(2).joined(separator: " ")
    }
}
