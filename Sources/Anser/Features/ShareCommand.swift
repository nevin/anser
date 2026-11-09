import AppKit
import AnserCore

/// Share one command and its output (instead of the whole tab): as Markdown
/// to paste anywhere, or as a secret GitHub gist link. Things that look like
/// secrets are removed first, and you see exactly what will be shared.
extension PaneView {
    static func shareMarkdown(command: String, output: String, exitCode: Int?, duration: Double?, cwd: String) -> String {
        let out = AIHelp.redact(output.count > 200_000 ? String(output.suffix(200_000)) : output)
        let status = exitCode.map { $0 == 0 ? "succeeded" : "exit \($0)" } ?? ""
        let time = duration.map { " · " + Services.formatDuration($0) } ?? ""
        let fence = out.contains("```") ? "~~~" : "```"
        return """
        ```sh
        $ \(AIHelp.redact(command))
        ```

        \(fence)
        \(out.trimmingCharacters(in: .newlines))
        \(fence)

        <sub>\(status)\(time) · in \(PathDisplay.short(cwd)) · shared from Anser</sub>

        """
    }

    func shareCommand(block i: Int) {
        guard session.blocks.indices.contains(i), let w = window else { NSSound.beep(); return }
        let b = session.blocks[i]
        let out = output(ofBlock: i) ?? (b.historyID > 0 ? Services.shared.history.output(forHistoryID: b.historyID) : nil) ?? ""
        let md = Self.shareMarkdown(command: b.command, output: out, exitCode: b.exitCode, duration: b.duration, cwd: b.cwd)
        let redacted = md.components(separatedBy: "[redacted]").count - 1

        let a = NSAlert()
        a.messageText = "Share this command and its output"
        a.informativeText = (redacted > 0 ? "\(redacted) thing\(redacted == 1 ? "" : "s") that looked like secrets \(redacted == 1 ? "was" : "were") removed. " : "")
            + "Check the text below before sharing it."
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        text.string = md
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isEditable = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        a.accessoryView = scroll
        a.addButton(withTitle: "Copy Markdown")
        a.addButton(withTitle: "Create Secret Gist Link")
        a.addButton(withTitle: "Cancel")
        Services.shared.record("share.command")
        a.beginSheetModal(for: w) { [weak self] r in
            guard let self else { return }
            let final = text.string
            switch r {
            case .alertFirstButtonReturn:
                TerminalWindowController.copy(final)
                self.flash("Copied as Markdown")
            case .alertSecondButtonReturn:
                self.createGist(final, title: b.command)
            default: break
            }
        }
    }

    /// Uploads to a secret gist with the GitHub CLI and copies the link.
    private func createGist(_ text: String, title: String) {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("anser-share-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = (dir as NSString).appendingPathComponent("command.md")
        guard (try? text.write(toFile: file, atomically: true, encoding: .utf8)) != nil else { flash("Couldn't prepare the gist"); return }
        flash("Creating a secret gist…")
        let env = session.env
        let desc = "Anser: " + String(AIHelp.redact(title).prefix(80))
        Task { @MainActor [weak self] in
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let script = "command -v gh >/dev/null || { echo 'NO_GH'; exit 0; }; gh gist create \(ShellLexer.escape(file)) --desc \(ShellLexer.escape(desc)) 2>&1"
            let out = (await ScriptRunner.shared.run(argv: ["/bin/sh", "-c", script], cwd: NSHomeDirectory(), env: env, timeout: 25) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self else { return }
            if out.contains("NO_GH") {
                self.flash("Install the GitHub CLI (brew install gh) and sign in (gh auth login) to create links")
            } else if let link = out.split(separator: "\n").map(String.init).last(where: { $0.hasPrefix("https://gist.github.com/") }) {
                TerminalWindowController.copy(link)
                self.flash("Secret gist link copied: \(link)")
            } else {
                self.flash("Couldn't create the gist: " + String(out.split(separator: "\n").last ?? "unknown error").prefix(120))
            }
        }
    }
}
