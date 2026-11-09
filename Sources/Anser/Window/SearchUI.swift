import AppKit
import AnserCore

/// Where one search (⌘R) looks. The first five are history scopes; then every
/// open tab, and what you saved (Notebook, workflows, runbooks).
enum SearchScope: Int, CaseIterable {
    case all, folder, tab, failed, output, allTabs, saved

    var title: String {
        switch self {
        case .all: "All"
        case .folder: "This folder"
        case .tab: "This tab"
        case .failed: "Failed"
        case .output: "Output"
        case .allTabs: "All tabs"
        case .saved: "Saved"
        }
    }

    var history: HistoryScope? {
        switch self {
        case .all: .all
        case .folder: .directory
        case .tab: .session
        case .failed: .failed
        case .output: .output
        case .allTabs, .saved: nil
        }
    }

    init(_ h: HistoryScope) {
        switch h {
        case .all: self = .all
        case .directory: self = .folder
        case .session: self = .tab
        case .failed: self = .failed
        case .output: self = .output
        }
    }
}

/// A command block in this tab.
struct TabBlockHit { let id: UUID; let command: String }

/// A line or command in any open tab.
struct TabHit {
    weak var pane: PaneView?
    let tab: String
    let command: String
    let started: Date
    let output: String
    let lineIndex: Int?
}

/// Something saved.
enum SavedHit {
    case entry(Notebook.Entry, group: String)
    case workflow(Workflow)
    case runbook(Runbook)
}

/// A history command (or a run's saved output).
struct HistoryHit { let command: String; var historyID: Int64?; var query: String = "" }

extension TerminalWindowController {
    /// One place to search: history, this tab, output, every open tab and saved commands.
    /// ⌘R opens it; ⌘B, ⇧⌘F and ⌥⇧⌘F open it on their scope.
    func showSearch(for pane: PaneView, scope initial: SearchScope = .all) {
        let history = Services.shared.history
        let sessionBlocks = pane.session.blocks
        Services.shared.record("search." + "\(initial)")
        let cwd = pane.session.isRemote ? NSHomeDirectory() : pane.session.cwd
        // Snapshots taken once per opening, so typing stays fast.
        var tabCorpus: [(pane: PaneView, tab: String, blocks: [(String, Date, String)])]?
        func corpus() -> [(pane: PaneView, tab: String, blocks: [(String, Date, String)])] {
            if let tabCorpus { return tabCorpus }
            var out: [(pane: PaneView, tab: String, blocks: [(String, Date, String)])] = []
            for p in AppDelegate.shared.allPanes {
                let tabTitle = p.windowController.flatMap { wc in wc.tab(for: p).map { wc.title(of: $0) } } ?? "Terminal"
                var blocks: [(String, Date, String)] = []
                for i in p.session.blocks.indices.reversed() {
                    blocks.append((p.session.blocks[i].command, p.session.blocks[i].started, p.output(ofBlock: i) ?? ""))
                }
                out.append((p, tabTitle, blocks))
            }
            tabCorpus = out
            return out
        }
        var savedCache: [SavedHit]?
        func saved() -> [SavedHit] {
            if let savedCache { return savedCache }
            let nb = (try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook()
            var out: [SavedHit] = nb.groups.flatMap { g in g.entries.map { SavedHit.entry($0, group: g.name) } }
            out += WorkflowStore.load(cwd: cwd).map { .workflow($0) }
            if !pane.session.isRemote { out += Runbook.load(cwd: cwd).map { .runbook($0) } }
            savedCache = out
            return out
        }

        func command(of item: PickerItem) -> String? {
            switch item.payload {
            case let h as HistoryHit: h.command
            case let b as TabBlockHit: b.command
            case let t as TabHit: t.command
            case let s as SavedHit:
                switch s {
                case .entry(let e, _): e.command
                case .workflow(let w): w.render([:])
                case .runbook: nil
                }
            default: nil
            }
        }
        func blockIndex(_ item: PickerItem) -> Int? {
            guard let b = item.payload as? TabBlockHit else { return nil }
            return pane.session.blocks.firstIndex { $0.id == b.id }
        }
        func isHistory(_ i: PickerItem) -> Bool { i.payload is HistoryHit }
        func isBlock(_ i: PickerItem) -> Bool { i.payload is TabBlockHit }
        func isCommand(_ i: PickerItem) -> Bool { i.payload is HistoryHit || i.payload is TabBlockHit || i.payload is TabHit }

        let panel = presentPickerReturning(PickerPanel.Config(
            title: "Search",
            placeholder: "Search history, this tab, output, every tab and saved commands…",
            scopes: SearchScope.allCases.map(\.title),
            hint: "⏎ edit   ⌘⏎ run   ⌥⏎ copy output   ⌃⏎ Actions   ⌘⌫ forget   ⇥ scope",
            provider: { query, scopeIndex in
                let scope = SearchScope(rawValue: scopeIndex) ?? .all
                switch scope {
                case .output:
                    return history.searchOutput(query).map { hit in
                        let failed = (hit.entry.exitCode ?? 0) != 0
                        return PickerItem(
                            title: hit.entry.command,
                            subtitle: "\(Self.relative(hit.entry.started)) · \(hit.line.isEmpty ? "(no output)" : hit.line)",
                            accessory: hit.entry.exitCode == nil ? nil : (failed ? "✗" : "✓"),
                            accessoryColor: failed ? .systemRed : .systemGreen,
                            positions: [],
                            payload: HistoryHit(command: hit.entry.command, historyID: hit.entry.id, query: query))
                    }
                case .tab:
                    return sessionBlocks.reversed().compactMap { b -> PickerItem? in
                        guard let m = Fuzzy.match(query, b.command) else { return nil }
                        let ok = (b.exitCode ?? 0) == 0
                        return PickerItem(
                            title: b.command,
                            subtitle: "\(Self.relative(b.started)) · \(Self.shortPath(b.cwd))\(b.duration.map { " · " + Services.formatDuration($0) } ?? "")",
                            accessory: ok ? "✓" : "✗ \(b.exitCode ?? 0)",
                            accessoryColor: ok ? .systemGreen : .systemRed,
                            positions: m.positions,
                            payload: TabBlockHit(id: b.id, command: b.command))
                    }
                case .allTabs:
                    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
                    let all = corpus()
                    guard q.count >= 2 else {
                        // Before typing: each tab's latest commands.
                        return all.flatMap { c in c.blocks.prefix(5).map { command, started, output in
                            PickerItem(title: command, subtitle: c.tab + " · " + Self.relative(started), accessory: c.tab, accessoryColor: .secondaryLabelColor,
                                       positions: [], payload: TabHit(pane: c.pane, tab: c.tab, command: command, started: started, output: output, lineIndex: nil))
                        } }
                    }
                    var items: [PickerItem] = []
                    outer: for c in all {
                        for (command, started, output) in c.blocks {
                            if command.lowercased().contains(q) {
                                items.append(PickerItem(title: command, subtitle: c.tab + " · command · " + Self.relative(started), accessory: c.tab,
                                                        accessoryColor: .secondaryLabelColor, positions: [],
                                                        payload: TabHit(pane: c.pane, tab: c.tab, command: command, started: started, output: output, lineIndex: nil)))
                            }
                            for (n, l) in output.components(separatedBy: "\n").enumerated() where l.lowercased().contains(q) {
                                items.append(PickerItem(title: l.trimmingCharacters(in: .whitespaces), subtitle: "\(c.tab) · $ \(command) · \(Self.relative(started))",
                                                        accessory: c.tab, accessoryColor: .secondaryLabelColor, positions: [],
                                                        payload: TabHit(pane: c.pane, tab: c.tab, command: command, started: started, output: output, lineIndex: n)))
                                if items.count >= 300 { break outer }
                            }
                        }
                    }
                    return items
                case .saved:
                    return saved().compactMap { s -> PickerItem? in
                        switch s {
                        case .entry(let e, let group):
                            guard let m = Fuzzy.match(query, e.displayTitle) ?? Fuzzy.match(query, e.command) else { return nil }
                            return PickerItem(title: e.displayTitle, subtitle: "Notebook · \(group) · " + e.command.replacingOccurrences(of: "\n", with: " ⏎ "),
                                              accessory: "notebook", accessoryColor: .secondaryLabelColor,
                                              positions: Fuzzy.match(query, e.displayTitle)?.positions ?? m.positions, payload: s, proportional: true)
                        case .workflow(let w):
                            guard Fuzzy.match(query, w.name) != nil || Fuzzy.match(query, w.steps.joined(separator: " ")) != nil else { return nil }
                            return PickerItem(title: w.name, subtitle: "Notebook · \(w.source == .project ? "this project" : "workflow") · \(w.steps.count) step\(w.steps.count == 1 ? "" : "s")",
                                              accessory: "\(w.steps.count) steps", accessoryColor: .systemTeal,
                                              positions: Fuzzy.match(query, w.name)?.positions ?? [], payload: s, proportional: true)
                        case .runbook(let r):
                            guard Fuzzy.match(query, r.title) != nil || Fuzzy.match(query, r.intro) != nil else { return nil }
                            return PickerItem(title: r.title, subtitle: "Runbook · \(r.steps.count) step\(r.steps.count == 1 ? "" : "s")" + (r.intro.isEmpty ? "" : " · " + r.intro.prefix(80)),
                                              accessory: "runbook", accessoryColor: .systemPurple,
                                              positions: Fuzzy.match(query, r.title)?.positions ?? [], payload: s, proportional: true)
                        }
                    }
                case .all, .folder, .failed:
                    return history.search(query, scope: scope.history ?? .all, cwd: pane.session.cwd, session: pane.session.id).map { c, m in
                        let failed = (c.lastExit ?? 0) != 0
                        return PickerItem(
                            title: c.command,
                            subtitle: "\(c.count)× · \(Self.relative(c.lastUsed))\(c.lastCwd.map { " · " + Self.shortPath($0) } ?? "")",
                            accessory: c.lastExit == nil ? nil : (failed ? "✗" : "✓"),
                            accessoryColor: failed ? .systemRed : .systemGreen,
                            positions: m.positions,
                            payload: HistoryHit(command: c.command))
                    }
                }
            },
            onAccept: { [weak self, weak pane] item, mods in
                guard let self, let pane else { return }
                switch item.payload {
                case let hit as TabHit:
                    guard let p = hit.pane else { NSSound.beep(); return }
                    AppDelegate.shared.reveal(sessionID: p.session.id)
                    p.showFind(query: hit.lineIndex == nil ? hit.command : (item.title.count < 80 ? item.title : hit.command))
                case let s as SavedHit:
                    switch s {
                    case .entry(let e, _):
                        if mods.contains(.command), pane.session.atPrompt { self.runNotebookEntry(e, in: pane) } else { pane.insertIntoEditor(e.command); pane.focus() }
                    case .workflow(let w): self.startWorkflow(w, in: pane, insertOnly: !mods.contains(.command))
                    case .runbook(let r): RunbookWindowController.show(r, pane: pane)
                    }
                case let b as TabBlockHit:
                    guard let index = blockIndex(item) else { return }
                    if mods.contains(.option) {
                        if let out = pane.output(ofBlock: index) { Self.copy(out) } else { NSSound.beep() }
                        return
                    }
                    if mods.contains(.command) { pane.insertIntoEditor(b.command, run: true); return }
                    if mods.contains(.shift) { pane.insertIntoEditor(b.command); return }
                    // ⏎ in this tab jumps to the command in the scrollback.
                    let offset = pane.session.blocks.count - index + (pane.session.running == nil ? 0 : 1)
                    pane.surfaceView.binding("scroll_to_bottom")
                    pane.surfaceView.binding("jump_to_prompt:-\(offset)")
                case let h as HistoryHit:
                    if mods.contains(.option), let id = h.historyID {
                        if let out = history.output(forHistoryID: id) { Self.copy(out) } else { NSSound.beep() }
                        return
                    }
                    pane.insertIntoEditor(h.command, run: mods.contains(.command))
                default: break
                }
            },
            onCopy: { item in
                if isBlock(item), let i = blockIndex(item), let out = pane.output(ofBlock: i) { return out }
                return command(of: item)
            },
            onDelete: { item in
                if let h = item.payload as? HistoryHit { history.delete(command: h.command) }
            },
            preview: { [weak pane] item in
                switch item.payload {
                case let hit as TabHit:
                    var lines = ["$ " + hit.command, ""]
                    let out = hit.output.components(separatedBy: "\n")
                    if let n = hit.lineIndex {
                        let lo = max(0, n - 8), hi = min(out.count, n + 9)
                        if lo > 0 { lines.append("…") }
                        for i in lo..<hi { lines.append((i == n ? "▶ " : "  ") + out[i]) }
                        if hi < out.count { lines.append("…") }
                    } else {
                        lines += out.prefix(40)
                    }
                    return PickerPanel.previewText(lines.joined(separator: "\n"))
                case let s as SavedHit:
                    switch s {
                    case .entry(let e, _):
                        return Self.workflowPreview(Workflow(name: e.displayTitle, description: e.note.isEmpty ? nil : e.note, steps: [e.command]))
                    case .workflow(let w): return Self.workflowPreview(w)
                    case .runbook(let r):
                        let steps = r.steps.enumerated().map { "\($0.offset + 1). \($0.element.title)\n   $ \($0.element.command)" }
                        return PickerPanel.previewText(([r.title, r.intro, ""] + steps).joined(separator: "\n"))
                    }
                case let b as TabBlockHit:
                    guard let pane, let i = pane.session.blocks.firstIndex(where: { $0.id == b.id }) else { return nil }
                    return PickerPanel.previewText("$ " + b.command + "\n\n" + (pane.output(ofBlock: i) ?? "(output not available)"))
                case let h as HistoryHit:
                    if let id = h.historyID {
                        let out = history.output(forHistoryID: id) ?? ""
                        let q = h.query.lowercased()
                        var lines = out.components(separatedBy: "\n")
                        if !q.isEmpty, let i = lines.firstIndex(where: { $0.lowercased().contains(q) }), i > 3 {
                            lines = ["… \(i - 3) lines above"] + Array(lines[(i - 3)...])
                        }
                        return PickerPanel.previewText("$ " + h.command + "\n\n" + lines.joined(separator: "\n"))
                    }
                    let c = history.search(h.command, scope: .all, limit: 50).first { $0.0.command == h.command }?.0
                    var lines = ["$ " + h.command, ""]
                    if let c {
                        lines.append("Run \(c.count) time\(c.count == 1 ? "" : "s"), last \(Self.relative(c.lastUsed))")
                        if let e = c.lastExit { lines.append(e == 0 ? "Last run succeeded" : "Last run failed with exit \(e)") }
                        if let t = history.timing(for: h.command) {
                            lines.append("Usually takes \(Services.formatDuration(t.typical)) (\(Services.formatDuration(t.fastest))–\(Services.formatDuration(t.slowest)) over \(t.runs) runs)")
                        }
                        if !c.cwds.isEmpty { lines += ["", "Folders:"] + c.cwds.sorted().prefix(12).map { "  " + Self.shortPath($0) } }
                    }
                    return PickerPanel.previewText(lines.joined(separator: "\n"))
                default: return nil
                }
            },
            actions: [
                // This tab's commands.
                .init(title: "Copy Output", symbol: "doc.on.doc", applies: isBlock) { item in
                    guard let i = blockIndex(item), let out = pane.output(ofBlock: i), !out.isEmpty else { NSSound.beep(); return }
                    Self.copy(out)
                },
                .init(title: "Copy Command", symbol: "terminal", applies: isBlock) { item in command(of: item).map(Self.copy) },
                .init(title: "Edit & Retry", symbol: "arrow.uturn.backward", applies: isBlock) { [weak pane] item in
                    guard let pane, let cmd = command(of: item) else { return }
                    pane.editor.setCommand(cmd)
                    pane.focus()
                },
                .init(title: "Save to Notebook", symbol: "book.closed", applies: isCommand) { [weak pane] item in
                    guard let cmd = command(of: item) else { return }
                    NotebookSaver.save([cmd], over: pane?.window) { n in pane?.flash(n == 0 ? "Already in the Notebook" : "Saved to the Notebook") }
                },
                .init(title: "Export Output…", symbol: "square.and.arrow.up", applies: isBlock) { [weak self, weak pane] item in
                    guard let pane, let i = blockIndex(item) else { return }
                    self?.exportOutput(for: pane, block: i)
                },
                .init(title: "Run Again", symbol: "play", applies: isBlock) { [weak pane] item in
                    guard let pane, pane.session.atPrompt, let cmd = command(of: item) else { NSSound.beep(); return }
                    pane.submitFromEditor(cmd)
                },
                // History.
                .init(title: "Put in Editor", symbol: "pencil", applies: isHistory) { [weak pane] item in
                    if let cmd = command(of: item) { pane?.insertIntoEditor(cmd) }
                },
                .init(title: "Run", symbol: "play", applies: isHistory) { [weak pane] item in
                    if let cmd = command(of: item) { pane?.insertIntoEditor(cmd, run: true) }
                },
                .init(title: "Open in History Editor", symbol: "clock.arrow.circlepath", applies: isHistory) { [weak pane] item in
                    HistoryEditorWindowController.shared.show(for: pane, select: command(of: item))
                },
                // Saved.
                .init(title: "Edit in Notebook", symbol: "book", applies: { if case .entry = $0.payload as? SavedHit { return true }; return false }) { item in
                    if case .entry(let e, _) = item.payload as? SavedHit { NotebookWindow.shared.show(); NotebookWindow.shared.selectEntry(e.id) }
                },
                .init(title: "Show File", symbol: "folder", applies: {
                    switch $0.payload as? SavedHit { case .workflow(let w): w.file != nil; case .runbook(let r): r.file != nil; default: false }
                }) { item in
                    switch item.payload as? SavedHit {
                    case .workflow(let w): if let f = w.file { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    case .runbook(let r): if let f = r.file { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    default: break
                    }
                },
            ],
            selectionHint: { item in
                switch item.payload {
                case is TabHit: "⏎ go to it (and find it there)   ⇥ scope"
                case let s as SavedHit:
                    switch s {
                    case .runbook: "⏎ open beside the terminal   ⇥ scope"
                    default: "⏎ put in editor   ⌘⏎ run   ⌃⏎ Actions   ⇥ scope"
                    }
                case is TabBlockHit: "⏎ jump to it   ⇧⏎ edit   ⌘⏎ run   ⌥⏎ copy output   ⌃⏎ Actions   ⇥ scope"
                default: "⏎ edit   ⌘⏎ run   ⌥⏎ copy output   ⌃⏎ Actions   ⌘⌫ forget   ⇥ scope"
                }
            },
            showsActionMenu: true), pane: pane)
        if initial != .all { panel?.selectScope(initial.rawValue) }
    }
}
