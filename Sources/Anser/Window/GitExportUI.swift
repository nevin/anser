import AppKit
import AnserCore
import UniformTypeIdentifiers

/// Export (Markdown, JSON, PDF, HTML, text), the Git menu's pickers and
/// commands, and the workflows folder.
extension TerminalWindowController {

    // MARK: Export

    /// This tab's commands, or one of them, as export entries.
    func exportEntries(for pane: PaneView, block: Int? = nil) -> [SessionExport.Entry] {
        let blocks = pane.session.blocks
        let indices = block.map { [$0] } ?? Array(blocks.indices)
        return indices.filter { blocks.indices.contains($0) && !blocks[$0].command.isEmpty }.map { i in
            let b = blocks[i]
            return SessionExport.Entry(command: b.command, cwd: b.cwd, exitCode: b.exitCode, duration: b.duration,
                                       started: b.started, output: pane.output(ofBlock: i))
        }
    }

    /// Shell → Export Tab… (all commands) or Export Last Command's Output….
    func exportOutput(for pane: PaneView, onlyLast: Bool) {
        let finished = pane.session.blocks.indices.last { pane.session.blocks[$0].exitCode != nil || pane.session.blocks[$0].duration != nil }
        if onlyLast, finished == nil { NSSound.beep(); return }
        exportOutput(for: pane, block: onlyLast ? finished : nil)
    }

    /// Asks where to save and in which format, then writes the file.
    func exportOutput(for pane: PaneView, block: Int?) {
        let entries = exportEntries(for: pane, block: block)
        guard !entries.isEmpty, let window else { NSSound.beep(); return }
        let tabName = tab(for: pane).map { self.title(of: $0) } ?? "Terminal"
        let title = block == nil ? "\(tabName) session" : entries[0].command
        let baseName = block == nil ? tabName : Self.fileName(for: entries[0].command)

        let panel = NSSavePanel()
        let formatPopup = NSPopUpButton()
        for f in SessionExport.Format.allCases { formatPopup.addItem(withTitle: f.title); formatPopup.lastItem?.representedObject = f.rawValue }
        let saved = UserDefaults.standard.string(forKey: "AnserExportFormat").flatMap(SessionExport.Format.init) ?? .markdown
        formatPopup.selectItem(at: SessionExport.Format.allCases.firstIndex(of: saved) ?? 0)
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, formatPopup])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        let applyFormat = {
            let f = SessionExport.Format(rawValue: formatPopup.selectedItem?.representedObject as? String ?? "") ?? .markdown
            panel.allowedContentTypes = [UTType(filenameExtension: f.fileExtension) ?? .plainText]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = (name.isEmpty ? baseName : name) + "." + f.fileExtension
        }
        formatPopup.target = ClosureTarget.shared
        formatPopup.action = #selector(ClosureTarget.fire(_:))
        ClosureTarget.shared.handler = applyFormat
        panel.nameFieldStringValue = baseName
        applyFormat()
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak pane] r in
            ClosureTarget.shared.handler = nil
            guard r == .OK, let url = panel.url else { return }
            let f = SessionExport.Format(rawValue: formatPopup.selectedItem?.representedObject as? String ?? "") ?? .markdown
            UserDefaults.standard.set(f.rawValue, forKey: "AnserExportFormat")
            do {
                try Self.write(f, title: title, entries: entries, to: url)
                pane?.flash("Exported \(entries.count == 1 ? "1 command" : "\(entries.count) commands") as \(f.title)")
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Writes an export. PDF is laid out from the HTML version onto paginated pages.
    static func write(_ format: SessionExport.Format, title: String, entries: [SessionExport.Entry], to url: URL) throws {
        let text = SessionExport.render(format, title: title, entries: entries)
        guard format == .pdf else {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let doc = NSAttributedString(html: Data(text.utf8), documentAttributes: nil) else {
            throw NSError(domain: "Anser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't lay out the PDF."])
        }
        let info = NSPrintInfo()
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(doc)
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else {
            throw NSError(domain: "Anser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't write the PDF."])
        }
    }

    /// "npm run build --prod" → "npm-run-build-prod".
    static func fileName(for command: String) -> String {
        let cleaned = command.prefix(40).map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let s = String(cleaned).split(separator: "-").joined(separator: "-")
        return s.isEmpty ? "output" : s
    }

    // MARK: Git commands (shown in the terminal)

    enum GitAction { case fetch, pull, push }

    func runGit(_ action: GitAction, in pane: PaneView) {
        guard let branch = pane.session.gitBranch, !pane.session.isRemote else { pane.flash("Not a git repository"); return }
        guard pane.session.atPrompt else { pane.flash("Wait for the running command to finish"); return }
        switch action {
        case .fetch: pane.run("git fetch --all --prune")
        case .pull: pane.run("git pull")
        case .push:
            let cwd = pane.session.cwd, env = pane.session.env
            Task { @MainActor [weak pane] in
                // First push of a new branch: set its upstream on the first remote (origin if there is one).
                let upstream = await ScriptRunner.shared.run("git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null", cwd: cwd, env: env)
                let remotes = (await ScriptRunner.shared.run("git remote", cwd: cwd, env: env) ?? "").split(separator: "\n").map(String.init)
                guard let pane else { return }
                if (upstream ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let remote = remotes.contains("origin") ? "origin" : remotes.first {
                    pane.run("git push -u \(ShellLexer.escape(remote)) \(ShellLexer.escape(branch))")
                } else {
                    pane.run("git push")
                }
            }
        }
    }

    // MARK: Commit history

    func showGitHistory(for pane: PaneView) {
        guard pane.session.gitBranch != nil, !pane.session.isRemote else { pane.flash("Not a git repository"); return }
        let cwd = pane.session.cwd, env = pane.session.env
        Task { @MainActor [weak self, weak pane] in
            let fmt = "--format='%h%x09%ct%x09%an%x09%D%x09%s'"
            let here = Self.parseLog(await ScriptRunner.shared.run("git log \(fmt) -400", cwd: cwd, env: env, timeout: 5))
            let all = Self.parseLog(await ScriptRunner.shared.run("git log --all \(fmt) -400", cwd: cwd, env: env, timeout: 5))
            guard let self, let pane else { return }
            guard !here.isEmpty || !all.isEmpty else { pane.flash("No commits yet"); return }
            self.showPicker(PickerPanel.Config(
                title: "Commit history",
                placeholder: "Find a commit by message, author or hash…",
                scopes: ["This branch", "All branches"],
                hint: "⏎ show in terminal   ⌥⏎ put hash in editor   ⌘C copy hash",
                provider: { query, scope in
                    (scope == 0 ? here : all).compactMap { c in
                        guard let m = Fuzzy.match(query, c.subject) ?? Fuzzy.match(query, c.hash + " " + c.author) else { return nil }
                        let positions = Fuzzy.match(query, c.subject)?.positions ?? []
                        return PickerItem(title: c.subject, subtitle: "\(c.hash) · \(c.when) · \(c.author)", accessory: c.refs.isEmpty ? nil : c.refs,
                                          accessoryColor: .systemTeal, positions: m.score > 0 ? positions : [], payload: c.hash, proportional: true)
                    }
                },
                onAccept: { [weak pane] item, mods in
                    guard let pane, let hash = item.payload as? String else { return }
                    if mods.contains(.option) || !pane.session.atPrompt { pane.insertIntoEditor(pane.editor.string + hash); return }
                    pane.run("git show --stat \(hash)")
                },
                onCopy: { $0.payload as? String },
                onDelete: nil,
                preview: { item in
                    guard let hash = item.payload as? String else { return nil }
                    let out = await ScriptRunner.shared.run("git show --stat --patch --format='commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n%w(0,4,4)%B' \(hash) | head -600",
                                                            cwd: cwd, env: env, timeout: 4)
                    return PickerPanel.previewText(out ?? "", diff: true)
                }), pane: pane)
        }
    }

    struct Commit { let hash, when, author, refs, subject: String }

    static func parseLog(_ out: String?) -> [Commit] {
        (out ?? "").split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard p.count == 5 else { return nil }
            let refs = p[3].replacingOccurrences(of: "HEAD -> ", with: "").split(separator: ",").prefix(2)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            return Commit(hash: p[0], when: RelativeTime.format(unix: p[1]) ?? "", author: p[2], refs: refs, subject: p[4])
        }
    }

    // MARK: Stashes

    func showStashes(for pane: PaneView) {
        guard pane.session.gitBranch != nil, !pane.session.isRemote else { pane.flash("Not a git repository"); return }
        let cwd = pane.session.cwd, env = pane.session.env
        let hasChanges = pane.session.gitChangeCount > 0
        Task { @MainActor [weak self, weak pane] in
            let out = await ScriptRunner.shared.run("git stash list --format='%gd%x09%ct%x09%gs'", cwd: cwd, env: env, timeout: 4)
            let stashes: [(ref: String, when: String, message: String)] = (out ?? "").split(separator: "\n").compactMap { line in
                let p = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                return p.count == 3 ? (p[0], RelativeTime.format(unix: p[1]) ?? "", p[2]) : nil
            }
            guard let self, let pane else { return }
            self.showPicker(PickerPanel.Config(
                title: "Stashes  ·  \(stashes.count)",
                placeholder: "Find a stash…",
                scopes: [],
                hint: "⏎ apply   ⌥⏎ pop (apply and remove)   ⌘⌫ drop",
                provider: { query, _ in
                    var items: [PickerItem] = []
                    if hasChanges, query.isEmpty || "stash changes".contains(query.lowercased()) {
                        items.append(PickerItem(title: "Stash my changes", subtitle: "git stash push --include-untracked", accessory: "new",
                                                accessoryColor: .systemGreen, positions: [], payload: "push", proportional: true))
                    }
                    for s in stashes {
                        guard let m = Fuzzy.match(query, s.message) else { continue }
                        items.append(PickerItem(title: s.message, subtitle: "\(s.ref) · \(s.when)", accessory: nil, accessoryColor: nil,
                                                positions: m.positions, payload: s.ref, proportional: true))
                    }
                    if items.isEmpty, query.isEmpty {
                        items.append(PickerItem(title: "No stashes", subtitle: "Stash saves uncommitted changes so you can switch tasks",
                                                accessory: nil, accessoryColor: nil, positions: [], payload: "none", proportional: true))
                    }
                    return items
                },
                onAccept: { [weak pane] item, mods in
                    guard let pane, let ref = item.payload as? String, ref != "none" else { return }
                    guard pane.session.atPrompt else { NSSound.beep(); return }
                    if ref == "push" { pane.run("git stash push --include-untracked"); return }
                    pane.run("git stash \(mods.contains(.option) ? "pop" : "apply") \(ShellLexer.escape(ref))")
                },
                onCopy: { $0.payload as? String },
                onDelete: { [weak self, weak pane] item in
                    guard let self, let pane, let ref = item.payload as? String, ref.hasPrefix("stash@") else { return }
                    let a = NSAlert()
                    a.messageText = "Drop \(ref)?"
                    a.informativeText = "\(item.title)\n\nIts changes are deleted. (git prints the commit hash, so it can still be recovered for a while.)"
                    a.addButton(withTitle: "Drop Stash")
                    a.addButton(withTitle: "Cancel")
                    if let w = self.window {
                        a.beginSheetModal(for: w) { r in
                            if r == .alertFirstButtonReturn, pane.session.atPrompt {
                                self.picker?.close()
                                pane.run("git stash drop \(ShellLexer.escape(ref))")
                            }
                        }
                    }
                },
                preview: { item in
                    guard let ref = item.payload as? String else { return nil }
                    if ref == "push" { return PickerPanel.previewText("Saves your uncommitted changes (including new files) and cleans the working folder.") }
                    if ref == "none" { return nil }
                    let out = await ScriptRunner.shared.run("git stash show --stat --patch --include-untracked \(ShellLexer.escape(ref)) 2>/dev/null || git stash show --stat --patch \(ShellLexer.escape(ref)) | head -600",
                                                            cwd: cwd, env: env, timeout: 4)
                    return PickerPanel.previewText(out ?? "", diff: true)
                }), pane: pane)
        }
    }

    // MARK: Workflows folder

    static func openWorkflowsFolder() {
        let dir = WorkflowStore.personalDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

/// Target/action shim for a control that lives only as long as a sheet.
@MainActor
final class ClosureTarget: NSObject {
    static let shared = ClosureTarget()
    var handler: (() -> Void)?
    @objc func fire(_ sender: Any?) { handler?() }
}
