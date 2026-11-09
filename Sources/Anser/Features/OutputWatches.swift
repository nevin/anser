import AppKit
import UserNotifications
import AnserCore

/// Runs commands in the background every few minutes and tells you when
/// their output changes or they start failing (Shell → Watch a Command's Output…).
/// Watches last until you stop them or quit Anser.
final class OutputWatchManager {
    static let shared = OutputWatchManager()
    static let changed = Notification.Name("AnserOutputWatchesChanged")

    private(set) var watches: [OutputWatch] = []
    private var timers: [UUID: Timer] = [:]
    private var envs: [UUID: ShellEnvironment] = [:]
    private var busy: Set<UUID> = []
    /// Tests turn notifications off.
    var notify = true

    @discardableResult
    func add(command: String, cwd: String, env: ShellEnvironment, minutes: Double) -> OutputWatch {
        let w = OutputWatch(command: command, cwd: cwd, intervalMinutes: minutes)
        watches.append(w)
        envs[w.id] = env
        schedule(w)
        run(w.id)
        Services.shared.record("outputwatch.add")
        NotificationCenter.default.post(name: Self.changed, object: nil)
        return w
    }

    func remove(_ id: UUID) {
        timers[id]?.invalidate()
        timers[id] = nil
        envs[id] = nil
        watches.removeAll { $0.id == id }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func stopAll() { for w in watches { remove(w.id) } }

    private func schedule(_ w: OutputWatch) {
        let t = Timer.scheduledTimer(withTimeInterval: w.intervalMinutes * 60, repeats: true) { [weak self] _ in self?.run(w.id) }
        t.tolerance = min(30, w.intervalMinutes * 6)
        timers[w.id] = t
    }

    func run(_ id: UUID, done: ((OutputWatch.Event) -> Void)? = nil) {
        guard let w = watches.first(where: { $0.id == id }), !busy.contains(id) else { return }
        busy.insert(id)
        let env = envs[id] ?? ShellEnvironment()
        Task { @MainActor in
            let (out, status) = await ScriptRunner.shared.runWithStatus(argv: ["/bin/sh", "-c", w.command], cwd: w.cwd, env: env, timeout: 120)
            self.busy.remove(id)
            guard let i = self.watches.firstIndex(where: { $0.id == id }) else { return }
            let text = String(out.suffix(200_000))
            let event = self.watches[i].record(output: text, exit: status)
            NotificationCenter.default.post(name: Self.changed, object: nil)
            if self.notify, [.changed, .failed, .recovered].contains(event) { self.post(event, self.watches[i]) }
            done?(event)
        }
    }

    private func post(_ e: OutputWatch.Event, _ w: OutputWatch) {
        let content = UNMutableNotificationContent()
        switch e {
        case .failed: content.title = "Watched command failed"
        case .recovered: content.title = "Watched command works again"
        default: content.title = "Watched output changed"
        }
        let line = (w.lastOutput ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        content.body = w.command + (line.isEmpty ? "" : "\n" + line.prefix(140))
        content.sound = e == .failed ? .default : nil
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            if ok { center.add(UNNotificationRequest(identifier: "watch-" + w.id.uuidString, content: content, trigger: nil)) }
        }
    }

    /// What changed last time, side by side.
    func showChange(_ w: OutputWatch, over window: NSWindow?) {
        if let before = w.previousOutput, let after = w.lastOutput {
            DiffViewer(command: w.command, old: before, new: after, oldDate: w.lastChange ?? Date(), oldExit: nil, newExit: w.lastExit.map(Int.init)).show(over: window)
        } else {
            OutputViewer(command: w.command, output: w.lastOutput ?? "(no output yet)", exitCode: w.lastExit.map(Int.init), onExport: {}).show(over: window)
        }
    }

    func menu(for w: OutputWatch, window: NSWindow?) -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: w.previousOutput != nil ? "Show What Changed" : "Show Output") { [weak self] in self?.showChange(w, over: window) })
        m.addItem(ClosureMenuItem(title: "Run Now") { [weak self] in self?.run(w.id) })
        m.addItem(ClosureMenuItem(title: "Stop Watching") { [weak self] in self?.remove(w.id) })
        return m
    }
}

extension PaneView {
    /// Shell → Watch a Command's Output…: the editor's command, or the last one.
    func promptOutputWatch(command given: String? = nil) {
        guard !session.isRemote, let w = window else { flash("Watching works for commands on this Mac"); return }
        let typed = given ?? editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = outputWatchForm(typed.isEmpty ? (session.blocks.last { !$0.command.isEmpty }?.command ?? "") : typed)
        f.present(over: w, focus: "command") { [weak self] v in
            guard let self, let v else { return }
            let c = v["command", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            OutputWatchManager.shared.add(command: c, cwd: self.session.cwd, env: self.session.env, minutes: Self.watchMinutes(v["every", default: ""]))
            self.flash("Watching “\(c.prefix(40))”. It's in the sidebar.")
        }
    }

    static let watchIntervals = ["Every minute", "Every 5 minutes", "Every 15 minutes", "Every hour"]
    static func watchMinutes(_ title: String) -> Double { [1, 5, 15, 60][max(0, watchIntervals.firstIndex(of: title) ?? 1)] }

    func outputWatchForm(_ command: String) -> FormSheet {
        let f = FormSheet(title: "Watch a command's output",
                          message: "Anser runs it in the background and notifies you when its output changes or it fails. Times and dates in the output don't count as changes.",
                          fields: [
                            .init("command", "Command", .text(placeholder: "e.g. kubectl get pods  or  curl -s localhost:8080/health", mono: true), value: command),
                            .init("every", "How often", .popup(options: Self.watchIntervals), value: Self.watchIntervals[1]),
                          ], ok: "Watch")
        f.validate = { v in
            let c = v["command", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if c.isEmpty { return "Enter the command to run." }
            if OutputWatchManager.shared.watches.contains(where: { $0.command == c && $0.cwd == self.session.cwd }) { return "You're already watching this command here." }
            return nil
        }
        f.warn = { v in
            let c = v["command", default: ""]
            if let why = CommandRisk.reason(c) { return "This command \(why), and it would run again and again." }
            if LogLines.isFollowCommand(c) || c.contains(" -f ") || c.hasPrefix("watch ") { return "It looks like it never finishes; watched commands should end by themselves." }
            return nil
        }
        f.preview = { [weak self] v in
            let c = v["command", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !c.isEmpty, let self else { return nil }
            return "\(v["every", default: ""]) in \(PathDisplay.short(self.session.cwd)): \(c)"
        }
        return f
    }
}
