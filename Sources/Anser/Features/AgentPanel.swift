import AppKit
import AnserCore

/// "Do a task with AI": the AI proposes one command at a time, you approve
/// (or edit, or skip) each, and it sees the result before the next step.
final class AgentPanel: NSPanel, NSTextFieldDelegate {
    private static var open: [AgentPanel] = []

    weak var pane: PaneView?
    private(set) var goal = ""
    private(set) var steps: [AgentStep] = []
    private(set) var proposal: AgentReply?
    private var task: Task<Void, Never>?
    private var startedAt = Date()
    static let maxSteps = 20

    private let goalField = NSTextField()
    private let startButton = NSButton()
    private let transcript = NSTextView()
    private let why = NSTextField(wrappingLabelWithString: "")
    private let commandField = NSTextField()
    private let risk = NSTextField(wrappingLabelWithString: "")
    private let runButton = NSButton()
    private let skipButton = NSButton()
    private let stopButton = NSButton()
    private let replyField = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let proposalBox = NSStackView()

    static func show(for pane: PaneView, goal: String? = nil) {
        if let p = open.first(where: { $0.pane === pane }) { p.makeKeyAndOrderFront(nil); return }
        let p = AgentPanel(pane: pane)
        open.append(p)
        p.makeKeyAndOrderFront(nil)
        if let goal, !goal.isEmpty { p.goalField.stringValue = goal; p.start() }
    }

    static func forTests(_ pane: PaneView) -> AgentPanel? { open.first { $0.pane === pane } }

    init(pane: PaneView) {
        self.pane = pane
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "Task with \(Services.shared.aiName)"
        isFloatingPanel = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 400, height: 380)
        build()
        if let pw = pane.window {
            let f = pw.frame
            setFrameTopLeftPoint(NSPoint(x: min(f.maxX + 8, (pw.screen?.visibleFrame.maxX ?? f.maxX) - 520), y: f.maxY))
        } else {
            center()
        }
        showProposal(nil)
    }

    override func close() {
        task?.cancel()
        Self.open.removeAll { $0 === self }
        super.close()
    }

    // MARK: Layout

    private func build() {
        guard let content = contentView else { return }
        goalField.placeholderString = "What should be done? e.g. “find why the build is slow” or “upgrade eslint and fix the lint errors”"
        goalField.delegate = self
        startButton.title = "Start"
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(startTapped)
        startButton.keyEquivalent = "\r"
        let top = NSStackView(views: [goalField, startButton])
        top.spacing = 8

        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.font = .systemFont(ofSize: 12)
            transcriptView = tv
        }
        scroll.borderType = .bezelBorder

        why.font = .systemFont(ofSize: 12)
        commandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandField.toolTip = "You can change the command before running it"
        risk.font = .systemFont(ofSize: 11, weight: .medium)
        risk.textColor = .systemRed
        runButton.title = "Run"
        runButton.bezelStyle = .rounded
        runButton.target = self
        runButton.action = #selector(runTapped)
        runButton.keyEquivalent = "\r"
        runButton.keyEquivalentModifierMask = .command
        runButton.toolTip = "Run it in the terminal (⌘↩)"
        skipButton.title = "Skip"
        skipButton.bezelStyle = .rounded
        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        skipButton.toolTip = "Don't run it; the AI picks another way"
        stopButton.title = "Stop"
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        replyField.placeholderString = "Answer, or tell it what to do instead…"
        replyField.delegate = self
        let buttons = NSStackView(views: [runButton, skipButton, NSView(), stopButton])
        proposalBox.orientation = .vertical
        proposalBox.alignment = .leading
        proposalBox.spacing = 6
        for v in [why, commandField, risk, buttons, replyField] as [NSView] { proposalBox.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: proposalBox.widthAnchor).isActive = true }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let foot = NSStackView(views: [spinner, status])
        foot.spacing = 6

        let note = NSTextField(wrappingLabelWithString: "Each command waits for you. The task, commands and their output (secrets removed) go to \(Services.shared.aiName).")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor

        let main = NSStackView(views: [top, scroll, proposalBox, foot, note])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        main.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(main)
        NSLayoutConstraint.activate([
            main.topAnchor.constraint(equalTo: content.topAnchor),
            main.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            main.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for v in [top, scroll, proposalBox, foot, note] as [NSView] { v.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -24).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        initialFirstResponder = goalField
    }

    private var transcriptView: NSTextView?

    // MARK: Flow

    @objc private func startTapped() { start() }

    func start() {
        let g = goalField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !g.isEmpty else { NSSound.beep(); return }
        guard Services.shared.aiEnabled else { pane?.offerAISetup(); return }
        goal = g
        steps = []
        startedAt = Date()
        goalField.isEditable = false
        startButton.isEnabled = false
        Services.shared.record("ai.task")
        append("Task: " + g, bold: true)
        askNext()
    }

    private var context: AIHelp.Context {
        let s = pane?.session
        return AIHelp.Context(shell: s?.env.shell ?? "zsh", os: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                              cwdName: s.map { $0.isRemote ? $0.displayCwd : ($0.cwd as NSString).lastPathComponent } ?? "",
                              gitBranch: s?.gitBranch)
    }

    private func askNext() {
        guard steps.filter({ !$0.command.isEmpty }).count < Self.maxSteps else {
            finish("Stopped after \(Self.maxSteps) steps. Start again with a narrower task if there's more to do.")
            return
        }
        showProposal(nil)
        spinner.startAnimation(nil)
        status.stringValue = "\(Services.shared.aiName) is thinking…"
        let ai = Services.shared.ai
        let (g, s, c) = (goal, steps, context)
        task?.cancel()
        task = Task { @MainActor [weak self] in
            do {
                let reply = try await ai.nextStep(goal: g, steps: s, context: c, maxSteps: Self.maxSteps)
                guard let self, !Task.isCancelled else { return }
                self.spinner.stopAnimation(nil)
                self.received(reply)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.spinner.stopAnimation(nil)
                self.status.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.status.textColor = .systemRed
                self.append("Couldn't get the next step: " + self.status.stringValue, color: .systemRed)
                self.offerReply()
            }
        }
    }

    /// Exposed for tests (no network).
    func received(_ reply: AgentReply) {
        status.textColor = .secondaryLabelColor
        switch reply {
        case let .run(_, reason):
            proposal = reply
            showProposal(reply)
            if !reason.isEmpty { append("→ " + reason) }
            status.stringValue = "Step \(steps.filter { !$0.command.isEmpty }.count + 1): check the command, then Run (⌘↩), Skip or Stop"
            makeKeyAndOrderFront(nil)
        case let .ask(q):
            proposal = reply
            append("Question: " + q, bold: true)
            offerReply()
            status.stringValue = "Answer below and press Return"
        case let .done(summary):
            finish(summary)
        }
    }

    private func offerReply() {
        showProposal(nil)
        proposalBox.isHidden = false
        for v in proposalBox.arrangedSubviews { v.isHidden = v !== replyField }
        makeFirstResponder(replyField)
    }

    private func showProposal(_ r: AgentReply?) {
        guard case let .run(cmd, reason)? = r else {
            proposalBox.isHidden = steps.isEmpty && goal.isEmpty
            for v in proposalBox.arrangedSubviews { v.isHidden = true }
            return
        }
        proposalBox.isHidden = false
        for v in proposalBox.arrangedSubviews { v.isHidden = false }
        why.stringValue = reason.isEmpty ? "Next step:" : reason
        commandField.stringValue = cmd
        if let danger = CommandRisk.reason(cmd) {
            risk.stringValue = "⚠︎ This command \(danger). Read it carefully before running."
            risk.isHidden = false
        } else {
            risk.isHidden = true
        }
        makeFirstResponder(commandField)
    }

    @objc func runTapped() {
        guard case .run? = proposal, let pane else { NSSound.beep(); return }
        let cmd = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { NSSound.beep(); return }
        guard pane.session.atPrompt, pane.session.running == nil else { pane.flash("Wait for the running command to finish"); NSSound.beep(); return }
        proposal = nil
        showProposal(nil)
        append("$ " + cmd, mono: true)
        status.stringValue = "Running…"
        spinner.startAnimation(nil)
        let since = Date()
        waitFor(cmd, since: since)
        Services.shared.record("ai.task.step")
        pane.submitFromEditor(cmd)
    }

    private func waitFor(_ cmd: String, since: Date) {
        pane?.onNextFinish { [weak self] b, out in
            guard let self, !self.goal.isEmpty else { return }
            guard b.started >= since.addingTimeInterval(-0.5), b.command.trimmingCharacters(in: .whitespacesAndNewlines) == cmd else {
                if Date().timeIntervalSince(since) < 3600 { self.waitFor(cmd, since: since) }
                return
            }
            self.spinner.stopAnimation(nil)
            let code = b.exitCode ?? 0
            self.append(code == 0 ? "✓ done" + (b.duration.map { " in " + Services.formatDuration($0) } ?? "") : "✗ exit \(code)", color: code == 0 ? .systemGreen : .systemRed)
            self.steps.append(AgentStep(command: cmd, exitCode: code, output: out))
            self.askNext()
        }
    }

    @objc private func skipTapped() {
        guard case let .run(cmd, _)? = proposal else { return }
        let note = replyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        steps.append(AgentStep(command: cmd, skipped: true, note: note.isEmpty ? nil : note))
        replyField.stringValue = ""
        append("Skipped: " + cmd, color: .secondaryLabelColor)
        proposal = nil
        askNext()
    }

    @objc private func stopTapped() {
        task?.cancel()
        finish("Stopped.")
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.userInfo?["NSTextMovement"] as? Int) == NSReturnTextMovement else { return }
        guard (obj.object as? NSTextField) === replyField else { return }
        let text = replyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !goal.isEmpty else { return }
        replyField.stringValue = ""
        append("You: " + text)
        // An answer to a question, or "do this instead" while a command is proposed.
        if case let .run(cmd, _)? = proposal { steps.append(AgentStep(command: cmd, skipped: true, note: text)) }
        else { steps.append(AgentStep(command: "", note: text)) }
        proposal = nil
        askNext()
    }

    private func finish(_ summary: String) {
        proposal = nil
        showProposal(nil)
        proposalBox.isHidden = true
        spinner.stopAnimation(nil)
        append("Done: " + summary, bold: true)
        status.stringValue = "\(steps.filter { !$0.command.isEmpty && !$0.skipped }.count) command\(steps.count == 1 ? "" : "s") run · " + Services.formatDuration(Date().timeIntervalSince(startedAt))
        goal = ""
        goalField.isEditable = true
        goalField.stringValue = ""
        startButton.isEnabled = true
    }

    private func append(_ text: String, bold: Bool = false, mono: Bool = false, color: NSColor = .labelColor) {
        guard let tv = transcriptView else { return }
        let font: NSFont = mono ? .monospacedSystemFont(ofSize: 12, weight: .regular) : (bold ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12))
        tv.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color]))
        tv.scrollToEndOfDocument(nil)
    }

    /// For tests.
    var transcriptText: String { transcriptView?.string ?? "" }
    var proposedCommand: String { commandField.stringValue }
    var riskText: String? { risk.isHidden ? nil : risk.stringValue }
    func setGoalForTests(_ g: String) { goal = g; goalField.stringValue = g }
}
