import AppKit
import AnserCore

/// The window's pickers: history, commands in this tab, folders, branches,
/// changed files, clipboard, the command palette.
extension TerminalWindowController {
    // MARK: Pickers

    /// ⌘R: the one search window (see SearchUI.swift), on a history scope.
    func showHistorySearch(for pane: PaneView, scope initialScope: HistoryScope = .all) {
        showSearch(for: pane, scope: SearchScope(initialScope))
    }

    /// ⌘B: the search window on "This tab".
    func showBlocks(for pane: PaneView) { showSearch(for: pane, scope: .tab) }

    /// Folders found by the disk scan, kept for a minute so ⌘J reopens instantly.
    private static var folderScan: (date: Date, root: String, paths: [String])?
    static func resetFolderScanCache() { folderScan = nil }

    /// Jump to a folder: ones you've used, `cd` targets from your shell
    /// history, and a quick scan of this folder and your home folder.
    func showFolderJumper(for pane: PaneView) {
        guard !pane.session.isRemote else { NSSound.beep(); return }
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let current = pane.session.cwd
        let history = Services.shared.history

        final class Box: @unchecked Sendable { var candidates: [FolderIndex.Candidate] = []; var scanning = true }
        let box = Box()
        var seen = Set<String>([current])
        func add(_ path: String, _ boost: Double, _ note: String?) {
            guard seen.insert(path).inserted else { return }
            box.candidates.append(.init(path: path, boost: boost, note: note))
        }
        // 1. Folders you've used in Anser (strongest signal).
        for (i, d) in history.recentDirectories(limit: 200).enumerated() where fm.fileExists(atPath: d.path) {
            add(d.path, max(1, 6 - Double(i) * 0.05), "\(d.count) command\(d.count == 1 ? "" : "s") · \(Self.relative(d.last))")
        }
        // 2. Absolute folders from cd/pushd in your shell history.
        let cdCommands = history.recentCommands(withPrefix: "cd ", limit: 3000) + history.recentCommands(withPrefix: "pushd ", limit: 500)
        for p in FolderIndex.cdTargets(from: cdCommands, home: home) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { add(p, 1.5, "from your shell history") }
        }
        add(home, 1, "home")
        // 3. Recent scan, if fresh.
        if let cached = Self.folderScan, Date().timeIntervalSince(cached.date) < 60, cached.root == current {
            cached.paths.forEach { add($0, 0, nil) }
            box.scanning = false
        }

        let picker = presentPickerReturning(PickerPanel.Config(
            title: "Jump to folder",
            placeholder: "Type part of a folder name, or a path like ~/dev…",
            scopes: [],
            hint: "⏎ cd there   ⌘⏎ new tab there   ⌥⏎ open in Finder   ⌘C copy path",
            provider: { query, _ in
                var items: [PickerItem] = []
                // A typed path that exists goes first.
                var typed = query.trimmingCharacters(in: .whitespaces)
                if typed.hasPrefix("~") { typed = home + typed.dropFirst() }
                var isDir: ObjCBool = false
                if typed.hasPrefix("/"), fm.fileExists(atPath: typed, isDirectory: &isDir), isDir.boolValue {
                    items.append(PickerItem(title: Self.shortPath(typed), subtitle: "typed path", accessory: "go", accessoryColor: .systemGreen,
                                            positions: [], payload: (typed as NSString).standardizingPath))
                }
                for (c, m, shown) in FolderIndex.rank(query, box.candidates, home: home) {
                    let inHere = c.path.hasPrefix(current + "/")
                    let sub = c.note ?? (inHere ? "inside " + (current as NSString).lastPathComponent : nil)
                    items.append(PickerItem(title: shown, subtitle: sub, accessory: nil, accessoryColor: nil, positions: m.positions, payload: c.path))
                }
                if items.isEmpty && box.scanning {
                    items.append(PickerItem(title: "Searching folders…", subtitle: nil, accessory: nil, accessoryColor: nil, positions: [], payload: ""))
                }
                return items
            },
            onAccept: { [weak self, weak pane] item, mods in
                guard let pane, let path = item.payload as? String, !path.isEmpty else { return }
                if mods.contains(.option) { NSWorkspace.shared.open(URL(fileURLWithPath: path)); return }
                if mods.contains(.command) || !pane.session.atPrompt { self?.addTab(cwd: path); return }
                pane.run("cd " + ShellLexer.escape(path))
            },
            onCopy: { ($0.payload as? String).flatMap { $0.isEmpty ? nil : $0 } },
            onDelete: nil,
            preview: { item in
                guard let path = item.payload as? String, !path.isEmpty else { return nil }
                let entries = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
                    .filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                var lines = [Self.shortPath(path), ""]
                for e in entries.prefix(80) {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: path + "/" + e, isDirectory: &isDir)
                    lines.append((isDir.boolValue ? "▸ " : "  ") + e + (isDir.boolValue ? "/" : ""))
                }
                if entries.count > 80 { lines.append("  … \(entries.count - 80) more") }
                return PickerPanel.previewText(lines.joined(separator: "\n"))
            },
            actions: Self.folderActions(pane: pane, controller: self)), pane: pane)

        // 4. Scan the disk in the background, then refresh the list.
        guard box.scanning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = FolderIndex.scan(roots: [(current, 4), (home, 3)], limit: 15000, deadline: Date().addingTimeInterval(2.0))
            DispatchQueue.main.async { [weak picker] in
                Self.folderScan = (Date(), current, found)
                found.forEach { add($0, 0, nil) }
                box.scanning = false
                picker?.refresh()
            }
        }
    }

    /// Branches, most recent first. Enter switches; typing a new name offers to create it.
    func showBranchSwitcher(for pane: PaneView) {
        guard pane.session.gitBranch != nil else { pane.flash("This folder isn't in a git repository"); return }
        if pane.session.gitRisky { pane.flash("Git checks are off in this repo (its config can run programs)"); return }
        let current = pane.session.gitBranch ?? ""
        let cwd = pane.session.cwd, env = pane.session.env, risky = pane.session.gitRisky
        Task { @MainActor [weak self, weak pane] in
            guard let pane else { return }
            let list = BranchList()
            await list.load(cwd: cwd, env: env)
            self?.presentBranchPicker(list: list, current: current, pane: pane)
            // Look for branches pushed since the last fetch, then update the open list.
            guard !risky, list.hasRemotes, Self.shouldFetch(cwd) else { return }
            self?.picker?.setStatus("fetching…")
            let failed = await list.fetch(cwd: cwd, env: env)
            await list.load(cwd: cwd, env: env)
            guard let p = self?.picker, p.titleText.hasPrefix("Switch branch") else { return }
            p.setStatus(failed ? "couldn't reach the remote" : nil)
            p.refresh()
        }
    }

    /// Remote fetches at most once a minute per repo, so reopening the switcher stays quiet.
    private static var lastFetch: [String: Date] = [:]
    private static func shouldFetch(_ cwd: String) -> Bool {
        if let t = lastFetch[cwd], Date().timeIntervalSince(t) < 60 { return false }
        lastFetch[cwd] = Date()
        return true
    }

    private func presentBranchPicker(list: BranchList, current: String, pane: PaneView) {
        presentPicker(PickerPanel.Config(
                title: "Switch branch  ·  on \(current)",
                placeholder: "Find a branch, or type a new name to create it…",
                scopes: ["All", "Local", "Remote"],
                hint: "⏎ switch   ⌥⏎ put name in editor   ⌘C copy name",
                provider: { query, scope in
                    var items: [PickerItem] = []
                    let q = query.trimmingCharacters(in: .whitespaces)
                    let known = Set(list.locals.map(\.name) + list.remotes.map(\.name))
                    // "origin/x" is a remote branch name, not a new local branch.
                    let looksRemote = list.remoteNames.contains { q.hasPrefix($0 + "/") }
                    if !q.isEmpty, !known.contains(q), !q.contains(" "), !looksRemote, scope != 2 {
                        items.append(PickerItem(title: "Create branch “\(q)”", subtitle: "git switch -c \(q)", accessory: "new",
                                                accessoryColor: .systemGreen, positions: [], payload: ("create", q)))
                    }
                    let localNames = Set(list.locals.map(\.name))
                    var rows: [(Suggestion, Bool)] = []
                    if scope != 2 { rows += list.locals.map { ($0, false) } }
                    // All: remote branches you don't have locally. Remote: every remote branch.
                    if scope != 1 { rows += list.remotes.filter { scope == 2 || !localNames.contains(BranchList.shortName($0.name)) }.map { ($0, true) } }
                    for (b, remote) in rows {
                        guard let m = Fuzzy.match(q, b.name) else { continue }
                        let isCurrent = !remote && b.name == current
                        let accessory = isCurrent ? "● current" : remote ? (localNames.contains(BranchList.shortName(b.name)) ? "remote · also local" : "remote") : nil
                        items.append(PickerItem(title: b.name, subtitle: b.description, accessory: accessory,
                                                accessoryColor: isCurrent ? .systemGreen : nil, positions: m.positions,
                                                payload: (remote ? "remote" : "switch", b.name)))
                    }
                    if scope == 2, rows.isEmpty, q.isEmpty {
                        items.append(PickerItem(title: list.hasRemotes ? "No remote branches yet" : "This repo has no remotes",
                                                subtitle: list.hasRemotes ? "Fetching runs when the switcher opens" : "Add one with git remote add origin <url>",
                                                accessory: nil, accessoryColor: nil, positions: [], payload: ("none", "")))
                    }
                    return items
                },
                onAccept: { [weak pane] item, mods in
                    guard let pane, let (kind, name) = item.payload as? (String, String), kind != "none" else { return }
                    // "origin/feature" → switch to a local "feature" (git creates it tracking the remote).
                    let target = kind == "remote" ? BranchList.shortName(name) : name
                    let cmd = kind == "create" ? "git switch -c " + ShellLexer.escape(target) : "git switch " + ShellLexer.escape(target)
                    if mods.contains(.option) { pane.insertIntoEditor(pane.editor.string + target); return }
                    if kind == "switch", target == current { pane.flash("Already on \(current)"); return }
                    guard pane.session.atPrompt else { pane.flash("Wait for the running command to finish, then switch"); return }
                    pane.run(cmd)
                },
                onCopy: { item in (item.payload as? (String, String))?.1 },
                onDelete: nil,
                preview: { [weak pane] item in
                    guard let pane, let (kind, name) = item.payload as? (String, String) else { return nil }
                    if kind == "none" { return nil }
                    if kind == "create" { return PickerPanel.previewText("Creates a new branch “\(name)” from \(current) and switches to it.") }
                    if kind == "remote", BranchList.shortName(name) == current { return PickerPanel.previewText("The remote copy of your current branch, \(current).") }
                    let raw = await ScriptRunner.shared.run("git log --format='%h%x09%ct%x09%an%x09%s' -25 \(ShellLexer.escape(name)) --",
                                                            cwd: pane.session.cwd, env: pane.session.env, timeout: 3)
                    let counts = await ScriptRunner.shared.run("git rev-list --left-right --count \(ShellLexer.escape(current))...\(ShellLexer.escape(name)) 2>/dev/null",
                                                               cwd: pane.session.cwd, env: pane.session.env, timeout: 3)
                    let log = (raw ?? "").split(separator: "\n").map { line -> String in
                        let p = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                        guard p.count == 4 else { return String(line) }
                        return "\(p[0])  \(p[3])  (\(RelativeTime.format(unix: p[1]) ?? "?"), \(p[2]))"
                    }.joined(separator: "\n")
                    var head = name
                    let parts = (counts ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                    if parts.count == 2, name != current { head += "  ·  \(parts[1]) ahead, \(parts[0]) behind \(current)" }
                    let commits = log.trimmingCharacters(in: .whitespacesAndNewlines)
                    return PickerPanel.previewText(head + "\n\n" + (commits.isEmpty ? "No commits yet." : commits))
                }), pane: pane)
    }

    /// Changed files in the repo: view the diff, stage/unstage, or open.
    /// Right-click actions (and buttons) for folders in Jump to Folder.
    static func folderActions(pane: PaneView, controller: TerminalWindowController) -> [PickerPanel.Action] {
        func path(_ i: PickerItem) -> String? { (i.payload as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let has: (PickerItem) -> Bool = { path($0) != nil }
        return [
            .init(title: "cd Here", symbol: "arrow.right.circle", applies: has) { [weak pane] i in
                guard let pane, let p = path(i) else { return }
                FileActions.cdHere(p, pane: pane)
            },
            .init(title: "New Tab Here", symbol: "plus.rectangle.on.rectangle", button: true, applies: has) { [weak controller] i in
                if let p = path(i) { controller?.addTab(cwd: p) }
            },
            .init(title: "New Window Here", symbol: "macwindow.badge.plus", applies: has) { i in
                if let p = path(i) { AppDelegate.shared.newWindow(cwd: p) }
            },
            .init(title: "Open in Finder", symbol: "folder", button: true, applies: has) { i in
                if let p = path(i) { FileActions.reveal(p) }
            },
            .init(title: "Copy Path", symbol: "doc.on.clipboard", applies: has) { i in
                if let p = path(i) { FileActions.copyPath(p) }
            },
            .init(title: FileActions.editorTitle(for: pane), symbol: "chevron.left.forwardslash.chevron.right",
                  button: true, applies: has, run: { [weak pane] i in
                if let pane, let p = path(i) { FileActions.openInEditor(PathLink(path: p), pane: pane) }
            }),
            .init(title: "Open With…", symbol: "ellipsis.circle", applies: has, run: { [weak pane] i in
                if let pane, let p = path(i) { FileActions.chooseEditor(for: PathLink(path: p), pane: pane) }
            }),
            .init(title: "Quick Look", symbol: "eye", applies: has) { i in
                if let p = path(i) { FileActions.quickLook(p) }
            },
            .init(title: "Files", symbol: "doc.on.doc", applies: has, children: { [weak pane] i in
                // Open anything inside the folder straight from here.
                FileActions.contents(of: path(i) ?? "").map { entry in
                    PickerPanel.Action(title: entry.name + (entry.folder ? "/" : ""), symbol: entry.folder ? "folder" : "doc") { _ in
                        if entry.folder { FileActions.reveal(entry.path) }
                        else if let pane { FileActions.openInEditor(PathLink(path: entry.path), pane: pane) }
                    }
                }
            }),
        ]
    }

    /// Right-click actions (and buttons) for files in a picker.
    static func fileActions(pane: PaneView, path: @escaping (PickerItem) -> String?) -> [PickerPanel.Action] {
        let exists: (PickerItem) -> Bool = { path($0).map { FileManager.default.fileExists(atPath: $0) } ?? false }
        return [
            .init(title: FileActions.editorTitle(for: pane), symbol: "chevron.left.forwardslash.chevron.right",
                  button: true, applies: exists, run: { [weak pane] i in
                if let pane, let p = path(i) { FileActions.openInEditor(PathLink(path: p), pane: pane) }
            }),
            .init(title: "Open With…", symbol: "ellipsis.circle", applies: exists, run: { [weak pane] i in
                if let pane, let p = path(i) { FileActions.chooseEditor(for: PathLink(path: p), pane: pane) }
            }),
            .init(title: "Open with Default App", symbol: "arrow.up.forward.app", applies: exists) { i in
                if let p = path(i) { FileActions.openDefault(p) }
            },
            .init(title: "Show in Finder", symbol: "folder", button: true, applies: exists) { i in
                if let p = path(i) { FileActions.reveal(p) }
            },
            .init(title: "Quick Look", symbol: "eye", applies: exists) { i in
                if let p = path(i) { FileActions.quickLook(p) }
            },
            .init(title: "Copy Path", symbol: "doc.on.clipboard") { i in
                if let p = path(i) { FileActions.copyPath(p) }
            },
        ]
    }

    func showChanges(for pane: PaneView) {
        guard pane.session.gitBranch != nil else { pane.flash("This folder isn't in a git repository"); return }
        if pane.session.gitRisky { pane.flash("Git checks are off in this repo (its config can run programs)"); return }
        Task { @MainActor [weak self, weak pane] in
            guard let pane else { return }
            // Asked for on purpose, so wait longer than the background checks do.
            let changes = await Generators.gitChanges(cwd: pane.session.cwd, env: pane.session.env, timeout: 10)
            guard !changes.isEmpty else { pane.flash("No changed files: everything is committed"); return }
            self?.presentPicker(PickerPanel.Config(
                title: "Changed files  ·  \(changes.count)",
                placeholder: "Filter changed files…",
                scopes: ["All", "Unstaged", "Staged"],
                hint: "⏎ show diff   ⌘⏎ stage / unstage   ⌥⏎ open in $EDITOR   ⌘C copy path",
                provider: { query, scope in
                    changes.compactMap { c in
                        if scope == 1 && c.staged && !c.untracked { return nil }
                        if scope == 2 && !c.staged { return nil }
                        guard let m = Fuzzy.match(query, c.path) else { return nil }
                        let color: NSColor = c.untracked ? .systemGreen : (c.code.contains("D") ? .systemRed : .systemOrange)
                        return PickerItem(title: c.path, subtitle: c.summary, accessory: c.code.trimmingCharacters(in: .whitespaces),
                                          accessoryColor: color, positions: m.positions, payload: c)
                    }
                },
                onAccept: { [weak pane] item, mods in
                    guard let pane, let c = item.payload as? GitChange else { return }
                    guard pane.session.atPrompt else { pane.flash("Wait for the running command to finish"); return }
                    let f = ShellLexer.escape(c.path)
                    var isDir: ObjCBool = false
                    let folder = FileManager.default.fileExists(atPath: (pane.session.cwd as NSString).appendingPathComponent(c.path), isDirectory: &isDir) && isDir.boolValue
                    if mods.contains(.command) {
                        pane.run(c.staged ? "git restore --staged -- \(f)" : "git add -- \(f)")
                    } else if mods.contains(.option) {
                        pane.run("${VISUAL:-${EDITOR:-vi}} \(f)")
                    } else if c.untracked {
                        pane.run(folder ? "ls -la -- \(f)" : "cat -- \(f)")
                    } else {
                        pane.run(c.staged ? "git diff --cached -- \(f)" : "git diff -- \(f)")
                    }
                },
                onCopy: { ($0.payload as? GitChange)?.path },
                onDelete: nil,
                preview: { [weak pane] item in
                    guard let pane, let c = item.payload as? GitChange else { return nil }
                    let f = ShellLexer.escape(c.path)
                    if c.untracked {
                        let text = (try? String(contentsOfFile: (pane.session.cwd as NSString).appendingPathComponent(c.path), encoding: .utf8)) ?? "(binary or unreadable file)"
                        return PickerPanel.previewText("New file: \(c.path)\n\n" + String(text.prefix(20000)))
                    }
                    let diff = await ScriptRunner.shared.run(c.staged ? "git diff --cached -- \(f)" : "git diff -- \(f)",
                                                             cwd: pane.session.cwd, env: pane.session.env, timeout: 3)
                    return PickerPanel.previewText(diff ?? "", diff: true)
                },
                actions: Self.fileActions(pane: pane) { item in
                    (item.payload as? GitChange).map { (pane.session.cwd as NSString).appendingPathComponent($0.path) }
                }), pane: pane)
        }
    }

    func showClipboardHistory(for pane: PaneView) {
        let clip = Services.shared.clipboard
        presentPicker(PickerPanel.Config(
            title: "Clipboard",
            placeholder: "Search clipboard history…",
            scopes: [],
            hint: "⏎ insert   ⌘⏎ paste into terminal   ⌘C copy   ⌘⌫ remove",
            provider: { query, _ in
                clip.items.compactMap { item in
                    let oneLine = item.text.replacingOccurrences(of: "\n", with: " ⏎ ")
                    guard let m = Fuzzy.match(query, oneLine) else { return nil }
                    let lines = item.text.components(separatedBy: "\n").count
                    return PickerItem(title: String(oneLine.prefix(300)), subtitle: "\(Self.relative(item.date))\(lines > 1 ? " · \(lines) lines" : "") · \(item.text.count) chars",
                                      accessory: nil, accessoryColor: nil, positions: m.positions, payload: item.text)
                }
            },
            onAccept: { [weak pane] item, mods in
                guard let pane, let text = item.payload as? String else { return }
                if mods.contains(.command) || !pane.editorUsable { pane.surfaceView.sendText(text) } else { pane.insertIntoEditor(text) }
            },
            onCopy: { $0.payload as? String },
            onDelete: { item in if let t = item.payload as? String { clip.remove(t) } }), pane: pane)
    }

    func showTabSwitcher(for pane: PaneView) {
        presentPicker(PickerPanel.Config(
            title: "Switch to Tab",
            placeholder: "Search by tab name, folder, branch, or SSH host…",
            scopes: ["This Window", "All Windows"],
            hint: "Return · Switch to tab   ⇥ Change scope",
            provider: { [weak self] query, scope in
                guard let self else { return [] }
                let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let windows = scope == 0 ? [self] : AppDelegate.shared.tabWindows
                var results: [(item: PickerItem, score: Int)] = []
                for (windowIndex, wc) in windows.enumerated() {
                    let windowName = wc === self ? "This Window" : "Window \(windowIndex + 1) · \(wc.window?.title ?? "Terminal")"
                    for (index, tab) in wc.tabs.enumerated() {
                        let title = wc.title(of: tab)
                        let tabPane = tab.focusedPane ?? wc.panes(inTab: index).first
                        let location = tabPane?.tabLocation ?? ""
                        let session = tabPane?.session
                        let path = session?.isRemote == true ? session?.remoteCwd : session?.cwd
                        let titleMatch = Fuzzy.match(query, title)
                        let context = [title, location, path ?? "", scope == 0 ? "" : windowName].joined(separator: " ")
                        guard let match = titleMatch ?? Fuzzy.match(query, context) else { continue }
                        let details = scope == 0 ? location : [windowName, location].filter { !$0.isEmpty }.joined(separator: " · ")
                        let number = "Tab \(index + 1)"
                        let item = PickerItem(title: title, subtitle: details.isEmpty ? nil : details,
                                              accessory: wc === self && index == self.selectedIndex ? number + " · Current" : number,
                                              accessoryColor: nil, positions: titleMatch?.positions ?? [],
                                              payload: tab.id, proportional: true)
                        results.append((item, match.score))
                    }
                }
                return results.sorted { $0.score > $1.score }.map(\.item)
            },
            onAccept: { item, _ in
                guard let id = item.payload as? UUID else { return }
                for wc in AppDelegate.shared.tabWindows {
                    guard let index = wc.tabs.firstIndex(where: { $0.id == id }) else { continue }
                    wc.selectTab(index, focus: false)
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = wc.window {
                        if window.isMiniaturized { window.deminiaturize(nil) }
                        window.makeKeyAndOrderFront(nil)
                    }
                    wc.focusedPane?.focus()
                    return
                }
            },
            onCopy: nil,
            onDelete: nil), pane: pane)
    }

    func showCommandPalette(for pane: PaneView) {
        let notebook = Services.shared.notebookEntries
        let workspaces = Workspace.ordered((try? Workspace.load()) ?? [])
        let shortcuts = AppDelegate.shared.shortcutLabels
        let pluginActions = PluginHost.shared.actions(for: pane)
        presentPicker(PickerPanel.Config(
            title: "Commands",
            placeholder: "Search every action and saved command (try “typo”, “port”, “record”)…",
            scopes: [],
            hint: "Choose an action or a saved command",
            provider: { query, _ in
                var out: [(PickerItem, Int)] = []
                let recent = Self.recentActions
                let words = query.lowercased().split(separator: " ").map(String.init)
                for a in AnserAction.allCases where a != .commandPalette {
                    // Match the title first; else what it's for (category and other words people use).
                    var m = Fuzzy.match(query, a.title)
                    var viaKeywords = false
                    if m == nil, !words.isEmpty {
                        let hay = (a.category + " " + a.keywords).lowercased()
                        if words.allSatisfy({ w in hay.split(separator: " ").contains { $0.hasPrefix(w) } }) {
                            m = Fuzzy.match("", a.title); viaKeywords = true
                        }
                    }
                    guard let m else { continue }
                    // Recently used actions float to the top.
                    let boost = recent.firstIndex(of: a.rawValue).map { 400 - $0 * 40 } ?? 0
                    let subtitle = boost > 0 && query.isEmpty ? a.category + " · recently used" : a.category
                    out.append((PickerItem(title: a.title, subtitle: subtitle, accessory: shortcuts[a],
                                           accessoryColor: nil, positions: viaKeywords ? [] : m.positions, payload: a), (viaKeywords ? 2 : m.score + 5) + boost))
                }
                for (i, pa) in pluginActions.enumerated() {
                    if let m = Fuzzy.match(query, pa.action.title) {
                        out.append((PickerItem(title: pa.action.title, subtitle: pa.action.run ?? pa.plugin.manifest.name, accessory: "plugin",
                                               accessoryColor: .systemTeal, positions: m.positions, payload: PluginPick(index: i)), m.score + 3))
                    }
                }
                for e in notebook {
                    if let m = Fuzzy.match(query, e.displayTitle) ?? Fuzzy.match(query, e.command) {
                        out.append((PickerItem(title: e.displayTitle, subtitle: e.command, accessory: "notebook", accessoryColor: .systemYellow,
                                               positions: Fuzzy.match(query, e.displayTitle)?.positions ?? [], payload: e), m.score))
                    }
                }
                for (index, workspace) in workspaces.enumerated() {
                    guard !query.isEmpty || workspace.pinned == true || workspace.lastOpened != nil,
                          let match = Fuzzy.match(query, workspace.name) else { continue }
                    let boost = query.isEmpty ? 500 - min(index, 99) : 0
                    let row = PickerItem(title: workspace.name, subtitle: "Open workspace",
                                         accessory: workspace.badge, accessoryColor: nil,
                                         positions: match.positions, payload: workspace, proportional: true)
                    out.append((row, match.score + boost))
                }
                return out.sorted { $0.1 > $1.1 }.map(\.0)
            },
            onAccept: { [weak pane] item, _ in
                guard let pane else { return }
                if let a = item.payload as? AnserAction { Self.noteRecentAction(a); AppDelegate.shared.perform(a, pane: pane) }
                if let e = item.payload as? Notebook.Entry { pane.insertIntoEditor(e.command) }
                if let workspace = item.payload as? Workspace { pane.windowController?.openWorkspace(workspace.name) }
                if let pick = item.payload as? PluginPick, pick.index < pluginActions.count { PluginHost.shared.perform(pluginActions[pick.index], in: pane) }
            },
            onCopy: { item in (item.payload as? Notebook.Entry)?.command },
            onDelete: nil,
            selectionHint: { item in
                if let action = item.payload as? AnserAction { return "Return · " + action.title }
                if item.payload is PluginPick { return "Return · Run plugin action" }
                if let workspace = item.payload as? Workspace {
                    return Self.openWindow(forWorkspace: workspace.name) == nil
                        ? "Return · Open workspace" : "Return · Focus open window"
                }
                return "Return · Insert into editor"
            }), pane: pane)
    }

    static var recentActions: [String] { UserDefaults.standard.stringArray(forKey: "AnserRecentActions") ?? [] }

    static func noteRecentAction(_ a: AnserAction) {
        guard ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil else { return }
        var list = recentActions.filter { $0 != a.rawValue }
        list.insert(a.rawValue, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: "AnserRecentActions")
    }

    func showPicker(_ config: PickerPanel.Config, pane: PaneView) { presentPicker(config, pane: pane) }

    /// Like presentPicker, but returns the panel (for live updates).
    @discardableResult
    func presentPickerReturning(_ config: PickerPanel.Config, pane: PaneView) -> PickerPanel? {
        presentPicker(config, pane: pane)
        return picker
    }

    private func presentPicker(_ config: PickerPanel.Config, pane: PaneView) {
        picker?.close()
        guard let window else { return }
        let p = PickerPanel(config: config)
        p.onClose = { [weak self, weak pane] in
            self?.picker = nil
            pane?.focus()
        }
        picker = p
        p.present(over: window)
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func relative(_ d: Date) -> String {
        if d.timeIntervalSince1970 < 1 { return "imported" }
        return RelativeTime.format(d)
    }

    static func shortPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

}

/// A plugin action in the command palette.
struct PluginPick { let index: Int }
