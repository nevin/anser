import AppKit
import AnserCore

/// A runbook beside its terminal: each step with Run, and a tick or cross once it has run.
final class RunbookWindowController: NSWindowController, NSWindowDelegate {
    enum StepState: Equatable { case idle, running, ok(Double), failed(Int), skipped }

    private static var open: [RunbookWindowController] = []

    private(set) var runbook: Runbook
    weak var pane: PaneView?
    private(set) var states: [StepState]
    private var values: [String: String] = [:]
    private var continueAfter = false
    private let stack = NSStackView()
    private let progress = NSTextField(labelWithString: "")

    /// Opens (or brings back) the window for this runbook and pane.
    @discardableResult
    static func show(_ r: Runbook, pane: PaneView) -> RunbookWindowController? {
        if let w = open.first(where: { $0.runbook.file == r.file && $0.runbook.title == r.title && $0.pane === pane }) {
            w.showWindow(nil); return w
        }
        let go = { () -> RunbookWindowController in
            let c = RunbookWindowController(r, pane: pane)
            open.append(c)
            c.showWindow(nil)
            return c
        }
        if FileTrust.runbooks.isTrusted(r) { return go() }
        // From a repo you cloned: show what it runs first.
        let a = NSAlert()
        a.messageText = "Trust the runbook “\(r.title)”?"
        a.informativeText = "It comes with the project in \(PathDisplay.short(r.file?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path ?? "")) and is new or changed since you last trusted it. Its steps:\n\n"
            + r.steps.enumerated().map { "\($0.offset + 1). \($0.element.command)" }.joined(separator: "\n").prefix(1500)
            + "\n\nNothing runs until you click a step's Run button."
        a.addButton(withTitle: "Trust & Open")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        FileTrust.runbooks.trust(r)
        return go()
    }

    static func forTests(_ pane: PaneView) -> RunbookWindowController? { open.last { $0.pane === pane } }

    init(_ r: Runbook, pane: PaneView) {
        runbook = r
        self.pane = pane
        states = Array(repeating: .idle, count: r.steps.count)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = r.title
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 380, height: 300)
        super.init(window: panel)
        panel.delegate = self
        build()
        if let pw = pane.window {
            let f = pw.frame
            panel.setFrameTopLeftPoint(NSPoint(x: min(f.maxX + 8, (pw.screen?.visibleFrame.maxX ?? f.maxX) - 520), y: f.maxY))
        } else {
            panel.center()
        }
        Services.shared.record("runbook.open")
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let runNext = NSButton(title: "Run Next Step", target: self, action: #selector(runNextTapped))
        runNext.keyEquivalent = "\r"
        runNext.keyEquivalentModifierMask = .command
        runNext.toolTip = "Runs the first step that hasn't succeeded yet (⌘↩)"
        let runAll = NSButton(title: "Run the Rest", target: self, action: #selector(runRestTapped))
        runAll.toolTip = "Runs the remaining steps one after another, stopping at the first failure"
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetTapped))
        let edit = NSButton(title: "Edit", target: self, action: #selector(editTapped))
        edit.isEnabled = runbook.file != nil
        progress.textColor = .secondaryLabelColor
        progress.font = .systemFont(ofSize: 11)
        let bar = NSStackView(views: [runNext, runAll, progress, NSView(), edit, reset])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(line)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func add(_ v: NSView) {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        if !runbook.intro.isEmpty { add(Self.textLabel(runbook.intro)) }
        if runbook.steps.isEmpty {
            add(Self.textLabel("This runbook has no shell code blocks yet. Click Edit to add some: every ```sh block becomes a step."))
        }
        for (i, step) in runbook.steps.enumerated() { add(stepView(i, step)) }
        if !runbook.outro.isEmpty { add(Self.textLabel(runbook.outro)) }
        let done = states.filter { if case .ok = $0 { return true } else { return false } }.count
        progress.stringValue = runbook.steps.isEmpty ? "" : "\(done) of \(runbook.steps.count) done"
    }

    private static func textLabel(_ md: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: "")
        l.attributedStringValue = AIPanel.render(md)
        l.isSelectable = true
        return l
    }

    private func stepView(_ i: Int, _ step: Runbook.Step) -> NSView {
        let state = states[i]
        let (symbol, color): (String, NSColor) = {
            switch state {
            case .idle: return ("\(i + 1).circle", .secondaryLabelColor)
            case .running: return ("clock", .systemBlue)
            case .ok: return ("checkmark.circle.fill", .systemGreen)
            case .failed: return ("xmark.circle.fill", .systemRed)
            case .skipped: return ("arrow.right.circle", .tertiaryLabelColor)
            }
        }()
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        let title = NSTextField(labelWithString: step.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        var resultText = ""
        switch state {
        case .running: resultText = "running…"
        case let .ok(d): resultText = "done · " + Services.formatDuration(d)
        case let .failed(c): resultText = "failed · exit \(c)"
        case .skipped: resultText = "skipped"
        case .idle: break
        }
        let result = NSTextField(labelWithString: resultText)
        result.font = .systemFont(ofSize: 11)
        result.textColor = color
        let head = NSStackView(views: [icon, title, NSView(), result])
        head.spacing = 6

        let code = NSTextField(wrappingLabelWithString: step.command)
        code.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        code.isSelectable = true
        code.textColor = .labelColor
        let codeBox = NSBox()
        codeBox.boxType = .custom
        codeBox.cornerRadius = 6
        codeBox.borderWidth = 0
        codeBox.fillColor = NSColor.textBackgroundColor.blended(withFraction: 0.06, of: .labelColor) ?? .textBackgroundColor
        codeBox.contentViewMargins = NSSize(width: 10, height: 8)
        codeBox.contentView = code

        func button(_ t: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: action)
            b.controlSize = .small
            b.bezelStyle = .rounded
            b.tag = i
            b.toolTip = tip
            return b
        }
        let run = button(state == .running ? "Running…" : "Run", "Run this step in the terminal", #selector(runTapped(_:)))
        run.isEnabled = state != .running
        let insert = button("Put in Editor", "Check or change it first", #selector(insertTapped(_:)))
        let copy = button("Copy", "Copy the command", #selector(copyTapped(_:)))
        let skip = button("Skip", "Mark this step as skipped", #selector(skipTapped(_:)))
        let buttons = NSStackView(views: [run, insert, copy, skip])
        buttons.spacing = 6

        var views: [NSView] = [head]
        if !step.text.isEmpty { views.append(Self.textLabel(step.text)) }
        views += [codeBox, buttons]
        let v = NSStackView(views: views)
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 6
        for sub in views where sub !== buttons { sub.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        return v
    }

    // MARK: Running

    @objc private func runTapped(_ b: NSButton) { continueAfter = false; run(step: b.tag) }
    @objc private func runNextTapped() { continueAfter = false; if let i = nextStep { run(step: i) } else { NSSound.beep() } }
    @objc private func runRestTapped() { continueAfter = true; if let i = nextStep { run(step: i) } else { NSSound.beep() } }
    @objc private func resetTapped() { states = Array(repeating: .idle, count: runbook.steps.count); values = [:]; rebuild() }
    @objc private func editTapped() {
        guard let f = runbook.file, let w = window, let text = try? String(contentsOf: f, encoding: .utf8) else { return }
        let a = NSAlert()
        a.messageText = "Edit “\(runbook.title)”"
        a.informativeText = "Markdown: every ```sh code block is a step. {{name}} asks for a value."
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 560, height: 380)
        scroll.borderType = .bezelBorder
        let tv = scroll.documentView as? NSTextView
        tv?.string = text
        tv?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv?.isAutomaticQuoteSubstitutionEnabled = false
        tv?.isAutomaticDashSubstitutionEnabled = false
        tv?.allowsUndo = true
        a.accessoryView = scroll
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Open in Editor")
        a.window.initialFirstResponder = tv
        a.beginSheetModal(for: w) { [weak self] r in
            guard let self else { return }
            if r == .alertThirdButtonReturn { if self.pane?.openFile(f.path) != true { NSWorkspace.shared.open(f) }; return }
            guard r == .alertFirstButtonReturn, let newText = tv?.string, newText != text else { return }
            self.save(newText)
        }
    }

    /// Saves edited Markdown and reloads the steps (your own edit keeps a project runbook trusted).
    func save(_ text: String) {
        guard let f = runbook.file else { return }
        do { try text.write(to: f, atomically: true, encoding: .utf8) } catch { NSSound.beep(); return }
        var r = Runbook.parse(text, fallbackTitle: runbook.title)
        r.file = f
        r.source = runbook.source
        if r.source == .project { FileTrust.runbooks.trust(r) }
        let old = runbook
        runbook = r
        // Keep ticks for steps that didn't change.
        states = r.steps.map { step in
            old.steps.firstIndex(of: step).map { states.indices.contains($0) ? states[$0] : .idle } ?? .idle
        }
        window?.title = r.title
        Services.shared.record("runbook.edit")
        rebuild()
    }
    @objc private func copyTapped(_ b: NSButton) { TerminalWindowController.copy(runbook.steps[b.tag].command) }
    @objc private func skipTapped(_ b: NSButton) { states[b.tag] = .skipped; rebuild() }
    @objc private func insertTapped(_ b: NSButton) {
        withValues(for: b.tag) { [weak self] cmd in
            guard let self, let pane = self.pane else { return }
            pane.insertIntoEditor(cmd)
            pane.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// The first step not yet done or skipped.
    var nextStep: Int? {
        states.indices.first { i in
            switch states[i] { case .ok, .skipped, .running: return false; default: return true }
        }
    }

    /// Fills in {{values}} the step uses (asking for ones not given yet), then calls `go` with the command.
    private func withValues(for i: Int, _ go: @escaping (String) -> Void) {
        let step = runbook.steps[i]
        let w = Workflow(name: runbook.title, description: "Values for “\(step.title)”. They're kept for the rest of this runbook.", steps: [step.command], params: runbook.params)
        let used = Set(Workflow(name: "", steps: [step.command]).allParams.map(\.name))
        let missing = w.allParams.filter { used.contains($0.name) && values[$0.name] == nil }
        guard !missing.isEmpty, let window, let wc = pane?.windowController else { go(runbook.render(step: i, values: values)); return }
        let ask = Workflow(name: w.name, description: w.description, steps: missing.map { "{{\($0.name)\($0.default.map { ":" + $0 } ?? "")}}" }, params: missing)
        let form = wc.makeParameterForm(ask)
        let a = NSAlert()
        a.messageText = step.title
        a.informativeText = ask.description ?? ""
        a.accessoryView = form.view
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { self?.continueAfter = false; return }
            self.values.merge(form.values()) { _, b in b }
            go(self.runbook.render(step: i, values: self.values))
        }
    }

    func run(step i: Int) {
        guard runbook.steps.indices.contains(i), let pane else { return }
        guard pane.session.atPrompt, pane.session.running == nil else { pane.flash("Wait for the running command to finish"); NSSound.beep(); return }
        guard FileTrust.runbooks.isTrusted(runbook) else { NSSound.beep(); return }
        withValues(for: i) { [weak self] cmd in
            guard let self, let pane = self.pane, pane.session.atPrompt else { return }
            self.states[i] = .running
            self.rebuild()
            Services.shared.record("runbook.step")
            self.waitForFinish(of: cmd, step: i, since: Date())
            pane.submitFromEditor(cmd)
        }
    }

    private func waitForFinish(of cmd: String, step i: Int, since: Date) {
        pane?.onNextFinish { [weak self] b, _ in
            guard let self else { return }
            // Another command finished first (or a profile asked and you said no): keep waiting.
            guard b.started >= since.addingTimeInterval(-0.5), b.command.trimmingCharacters(in: .whitespacesAndNewlines) == cmd.trimmingCharacters(in: .whitespacesAndNewlines) else {
                if self.states[i] == .running, Date().timeIntervalSince(since) < 6 * 3600 { self.waitForFinish(of: cmd, step: i, since: since) }
                return
            }
            let ok = (b.exitCode ?? 0) == 0
            self.states[i] = ok ? .ok(b.duration ?? 0) : .failed(b.exitCode ?? 1)
            self.rebuild()
            if ok, self.continueAfter, let next = self.nextStep {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.run(step: next) }
            } else {
                self.continueAfter = false
                if ok, self.nextStep == nil, !self.runbook.steps.isEmpty { self.pane?.flash("Runbook “\(self.runbook.title)” done") }
            }
        }
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

// MARK: Opening runbooks

extension PaneView {
    /// Shell → Runbooks: a menu of this project's runbooks and yours.
    func showRunbooksMenu() {
        let m = runbooksMenu()
        m.popUp(positioning: nil, at: NSPoint(x: bounds.midX - 120, y: bounds.midY + 100), in: self)
    }

    func runbooksMenu() -> NSMenu {
        let m = NSMenu()
        let list = session.isRemote ? Runbook.load(cwd: NSHomeDirectory()) : Runbook.load(cwd: session.cwd)
        if list.isEmpty {
            let none = NSMenuItem(title: "No runbooks yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            m.addItem(none)
        }
        for r in list {
            let item = ClosureMenuItem(title: r.title + (r.source == .project ? "  (project)" : "")) { [weak self] in
                guard let self else { return }
                RunbookWindowController.show(r, pane: self)
            }
            item.image = NSImage(systemSymbolName: r.source == .project ? "folder.badge.gearshape" : "list.bullet.clipboard", accessibilityDescription: nil)
            item.toolTip = "\(r.steps.count) step\(r.steps.count == 1 ? "" : "s")" + (r.intro.isEmpty ? "" : "\n" + r.intro.prefix(200))
            m.addItem(item)
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "New Runbook…") { [weak self] in self?.newRunbook() })
        m.addItem(ClosureMenuItem(title: "Open Runbooks Folder") {
            try? FileManager.default.createDirectory(at: Runbook.personalDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Runbook.personalDirectory)
        })
        return m
    }

    func newRunbook() {
        guard let w = window else { return }
        let project = session.isRemote ? nil : Runbook.projectDirectory(for: session.cwd)
        let places = ["Just for me"] + (project != nil ? ["Shared with this project"] : [])
        let f = FormSheet(title: "New runbook", message: "A Markdown file whose shell code blocks become steps you can run one by one.",
                          fields: [
                            .init("title", "Name", .text(placeholder: "e.g. Deploy to staging", mono: false)),
                            .init("where", "Keep it", .popup(options: places), value: places[0]),
                          ], ok: "Create")
        f.validate = { v in v["title", default: ""].trimmingCharacters(in: .whitespaces).isEmpty ? "Give it a name." : nil }
        f.preview = { v in
            let title = v["title", default: ""].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            let dir = v["where"] == places.last && project != nil && places.count > 1 ? project! : Runbook.personalDirectory
            let slug = Workflow(name: title, steps: []).slug
            return PathDisplay.short(dir.appendingPathComponent((slug.isEmpty ? "runbook" : slug) + ".md").path, max: 70)
        }
        f.present(over: w, focus: "title") { [weak self] v in
            guard let self, let v else { return }
            let title = v["title", default: ""].trimmingCharacters(in: .whitespaces)
            let shared = places.count > 1 && v["where"] == places[1]
            let dir = shared ? project! : Runbook.personalDirectory
            do {
                let url = try Runbook.create(in: dir, title: title)
                if shared { FileTrust.runbooks.trust(path: url.standardizedFileURL.path, fingerprint: FileTrust.fingerprint((try? Data(contentsOf: url)) ?? Data())) }
                Services.shared.record("runbook.new")
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    var rb = Runbook.parse(text, fallbackTitle: title)
                    rb.file = url
                    rb.source = shared ? .project : .personal
                    RunbookWindowController.show(rb, pane: self)
                }
            } catch {
                self.flash("Couldn't create the runbook: \(error.localizedDescription)")
            }
        }
    }
}
