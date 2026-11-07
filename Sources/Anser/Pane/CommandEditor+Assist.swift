import AppKit
import Carbon.HIToolbox
import AnserCore

/// ⌃R history right under the editor, and "# describe it" + Tab: AI writes the command.
extension CommandEditor {
    // MARK: ⌃R history under the editor

    func startInlineHistory() {
        guard let pane, pane.editorUsable else { return }
        inlineHistory = true
        Services.shared.record("history.inline")
        refreshInlineHistory()
    }

    func refreshInlineHistory() {
        guard inlineHistory, let pane else { return }
        let q = string
        let results = Services.shared.history.search(q, scope: .all, cwd: pane.session.cwd, limit: 40)
        let items = results.map { c, m in
            Completion(kind: .history, insert: c.command, display: c.command,
                       detail: "\(c.count)× · \(TerminalWindowController.relative(c.lastUsed))" + ((c.lastExit ?? 0) != 0 ? " · failed" : ""),
                       positions: m.positions, appendSpace: false, replacesLine: true)
        }
        guard !items.isEmpty else { popup.hide(); pane.updateHint(); return }
        popupContext = CompletionContext(line: q, cursor: (q as NSString).length, cwd: pane.session.cwd)
        popupUserNavigated = false
        popup.theme = theme
        var actual = NSRange()
        popup.show(items, query: q, at: firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: &actual), in: window)
        pane.updateHint()
    }

    // MARK: "# describe it" + Tab

    /// A one-line `# description` waiting for Tab.
    var isAIRequest: Bool {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("#") && !t.contains("\n") && t.dropFirst().trimmingCharacters(in: .whitespaces).count >= 3
    }

    func askAIInline() {
        guard let pane else { return }
        guard Services.shared.aiEnabled else { pane.offerAISetup(); return }
        let original = string
        let request = String(original.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
        aiBusy = true
        aiNote = nil
        pane.updateHint()
        let ai = Services.shared.ai
        let s = pane.session
        let ctx = AIHelp.Context(shell: s.env.shell, os: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                                 cwdName: (s.cwd as NSString).lastPathComponent, gitBranch: s.gitBranch)
        Services.shared.record("ai.inline")
        aiTask = Task { @MainActor [weak self] in
            do {
                let a = try await ai.generateCommand(request, context: ctx)
                guard let self, !Task.isCancelled else { return }
                self.aiBusy = false
                // Kept typing meanwhile: leave your text alone.
                guard self.string == original else { self.pane?.updateHint(); return }
                if let cmd = a.commands.first {
                    // One undo step brings your words back.
                    self.programmatic = true
                    self.replaceAll(with: cmd, caret: (cmd as NSString).length)
                    self.programmatic = false
                    let more = a.commands.count > 1 ? " · \(a.commands.count - 1) more with ⌘I" : ""
                    self.aiNote = "From \(a.model ?? Services.shared.aiName): check it, then ⏎ to run · ⌘Z brings back your words\(more)"
                } else {
                    self.aiNote = "The answer had no command in it. ⌘I shows the whole answer."
                }
                self.pane?.updateHint()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.aiBusy = false
                self.aiNote = "⚠︎ " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                self.pane?.updateHint()
            }
        }
    }

    func cancelAIInline() {
        aiTask?.cancel()
        aiBusy = false
        aiNote = nil
        pane?.updateHint()
    }
}
