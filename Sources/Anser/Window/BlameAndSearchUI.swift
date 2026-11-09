import AppKit
import AnserCore

/// Git blame, and Search All Tabs (a scope of the one search).
extension TerminalWindowController {

    // MARK: Git blame

    /// Git → Blame File…: pick a tracked file, then see who changed each line.
    func showBlameFilePicker(for pane: PaneView) {
        let cwd = pane.session.cwd, env = pane.session.env
        guard pane.session.gitBranch != nil, !pane.session.isRemote else { pane.flash("Not in a git repository"); return }
        guard !pane.session.gitRisky else { pane.flash("Git checks are off in this repository (its config can run programs)"); return }
        Task { @MainActor [weak self, weak pane] in
            let out = await ScriptRunner.shared.run(argv: ["/usr/bin/env", "git", "ls-files"], cwd: cwd, env: env, timeout: 6) ?? ""
            guard let self, let pane else { return }
            let files = Array(out.split(separator: "\n").map(String.init).prefix(30000))
            guard !files.isEmpty else { pane.flash("No tracked files here"); return }
            self.showPicker(PickerPanel.Config(
                title: "Blame a file",
                placeholder: "Find a file…",
                scopes: [],
                hint: "⏎ blame it   ⌘C copy path",
                provider: { query, _ in
                    var scored: [(PickerItem, Int)] = []
                    for f in files {
                        guard let m = Fuzzy.match(query, f) else { continue }
                        scored.append((PickerItem(title: f, subtitle: nil, accessory: nil, accessoryColor: nil, positions: m.positions, payload: f), m.score))
                        if scored.count > 4000 { break }
                    }
                    return scored.sorted { $0.1 > $1.1 }.prefix(200).map(\.0)
                },
                onAccept: { [weak self, weak pane] item, _ in
                    guard let pane, let f = item.payload as? String else { return }
                    self?.showBlame(for: pane, path: (cwd as NSString).appendingPathComponent(f), line: nil)
                },
                onCopy: { $0.payload as? String },
                onDelete: nil,
                preview: { item in
                    guard let f = item.payload as? String else { return nil }
                    let text = (try? String(contentsOfFile: (cwd as NSString).appendingPathComponent(f), encoding: .utf8)) ?? "(binary or unreadable)"
                    return PickerPanel.previewText(text.components(separatedBy: "\n").prefix(80).joined(separator: "\n"))
                }), pane: pane)
        }
    }

    /// Who last changed each line of `path`, starting at `line`.
    func showBlame(for pane: PaneView, path: String, line: Int?) {
        let dir = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let env = pane.session.env
        guard !GitSafety.isRisky(cwd: dir) else { pane.flash("Git checks are off in this repository (its config can run programs)"); return }
        Services.shared.record("git.blame")
        Task { @MainActor [weak self, weak pane] in
            let out = await ScriptRunner.shared.run(argv: ["/usr/bin/env", "git", "blame", "--porcelain", "--", name], cwd: dir, env: env, timeout: 15) ?? ""
            guard let self, let pane else { return }
            let lines = GitBlame.parse(out)
            guard !lines.isEmpty else { pane.flash("Can't blame \(name): is it tracked by git?"); return }
            let panel = self.presentBlame(lines, path: path, dir: dir, pane: pane)
            if let line { panel?.selectRow(max(0, line - 1)) }
        }
    }

    private func presentBlame(_ lines: [GitBlame.Line], path: String, dir: String, pane: PaneView) -> PickerPanel? {
        let env = pane.session.env
        let name = (path as NSString).lastPathComponent
        func open(_ l: GitBlame.Line) { pane.openFile("\(path):\(l.number)") }
        func showCommit(_ l: GitBlame.Line) {
            guard !l.isUncommitted, pane.session.atPrompt else { NSSound.beep(); return }
            pane.run("git -C \(ShellLexer.escape(dir)) show \(l.commit)")
        }
        func line(_ i: PickerItem) -> GitBlame.Line? { i.payload as? GitBlame.Line }
        showPicker(PickerPanel.Config(
            title: "Blame · \(name) · \(lines.count) lines",
            placeholder: "Filter by text, author, commit or message…",
            scopes: [],
            hint: "⏎ open at this line   ⌘⏎ show the commit   ⌘C copy commit",
            provider: { query, _ in
                let q = query.lowercased()
                return lines.compactMap { l in
                    if !q.isEmpty, ![l.text, l.author, l.summary, l.commit].contains(where: { $0.lowercased().contains(q) }) { return nil }
                    let who = l.isUncommitted ? "Not committed yet" : "\(l.author) · \(TerminalWindowController.relative(l.time)) · \(l.summary)"
                    return PickerItem(title: String(format: "%5d  ", l.number) + l.text, subtitle: who,
                                      accessory: l.isUncommitted ? "new" : l.shortCommit,
                                      accessoryColor: l.isUncommitted ? .systemGreen : .secondaryLabelColor, positions: [], payload: l)
                }
            },
            onAccept: { item, mods in
                guard let l = line(item) else { return }
                if mods.contains(.command) { showCommit(l) } else { open(l) }
            },
            onCopy: { line($0).map { $0.isUncommitted ? $0.text : $0.commit } },
            onDelete: nil,
            preview: { item in
                guard let l = line(item) else { return nil }
                if l.isUncommitted { return PickerPanel.previewText("Line \(l.number) isn't committed yet.\n\n\(l.text)") }
                let show = await ScriptRunner.shared.run(argv: ["/usr/bin/env", "git", "show", "--stat", "--patch", "--format=commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n    %s%n", l.commit, "--", name],
                                                         cwd: dir, env: env, timeout: 6) ?? ""
                return PickerPanel.previewText(String(show.prefix(60_000)), diff: true)
            },
            actions: [
                .init(title: "Open at This Line", symbol: "chevron.left.forwardslash.chevron.right", button: true) { i in if let l = line(i) { open(l) } },
                .init(title: "Show Commit", symbol: "doc.text.magnifyingglass", button: true, applies: { line($0)?.isUncommitted == false }) { i in
                    if let l = line(i) { showCommit(l) }
                },
                .init(title: "Copy Commit", symbol: "number", applies: { line($0)?.isUncommitted == false }) { i in
                    if let l = line(i) { TerminalWindowController.copy(l.commit) }
                },
                .init(title: "Copy Line", symbol: "doc.on.clipboard") { i in if let l = line(i) { TerminalWindowController.copy(l.text) } },
            ]), pane: pane)
        return picker
    }

    // MARK: Find in all tabs

    /// Edit → Search All Tabs (⇧⌘F): the search window on "All tabs".
    func showSearchAllTabs(for pane: PaneView) { showSearch(for: pane, scope: .allTabs) }
}
