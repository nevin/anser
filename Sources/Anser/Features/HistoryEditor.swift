import AppKit
import AnserCore

/// Tools → Edit History…: every command in your history, with typos and
/// mistakes spotted for you. Select many (⌘-click, ⇧-click, ⌘A) and delete,
/// or compact the whole history.
final class HistoryEditorWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = HistoryEditorWindowController()

    struct Row { var c: HistoryCommand; var issue: HistoryCleanup.Issue?; var deleted: Date? = nil; var meant: String? = nil }

    enum Filter: Int, CaseIterable {
        case all, folder, mistakes, basic, failed, old, trash
        var title: String {
            switch self {
            case .all: "All commands"
            case .folder: "Used in this folder"
            case .mistakes: "Mistakes and typos"
            case .basic: "Basic commands (ls, pwd…)"
            case .failed: "Last run failed"
            case .old: "Not used for 6 months"
            case .trash: "Recently deleted (7 days)"
            }
        }
    }

    private(set) var all: [Row] = []
    private(set) var shown: [Row] = []
    private let table = HistoryTable()
    private let search = NSSearchField()
    private let filterPopup = NSPopUpButton()
    private let deleteButton = NSButton()
    private let notebookButton = NSButton()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    let insights = HistoryInsightsPanel()
    private var mainSplit: NSSplitView?
    private var placedDividers = false
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    weak var pane: PaneView?
    /// History to edit (tests use their own).
    var store: HistoryStore { storeOverride ?? Services.shared.history }
    var storeOverride: HistoryStore?
    private var loadTask: Task<Void, Never>?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "History"
        w.setFrameAutosaveName("AnserHistoryEditor")
        w.minSize = NSSize(width: 660, height: 440)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(for pane: PaneView?, select command: String? = nil) {
        self.pane = pane ?? AppDelegate.shared.currentPane
        if window?.isVisible != true, window?.frame.origin == .zero { window?.center() }
        if let w = window { LibraryTabs.host(w, pane: self.pane) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        placeDividersOnce()
        if let command { search.stringValue = "" }
        reload { [weak self] in
            guard let self, let command else { return }
            self.select(where: { $0.c.command == command }, add: false)
            self.updateDetails()
        }
        Services.shared.record("history.editor")
    }

    // MARK: Layout

    /// First time (no saved sizes): the list takes the window's height, the inspector about 370 points on the right.
    private func placeDividersOnce() {
        guard !placedDividers, let main = mainSplit else { return }
        placedDividers = true
        window?.contentView?.layoutSubtreeIfNeeded()
        let saved = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames AnserHistorySplit3") != nil
        if !saved || main.arrangedSubviews[1].frame.width < 300 || main.arrangedSubviews[0].frame.width < 300 {
            main.setPosition(max(320, main.bounds.width - 370), ofDividerAt: 0)
        }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "Search commands"
        search.delegate = self
        for f in Filter.allCases { filterPopup.addItem(withTitle: f.title) }
        filterPopup.target = self
        filterPopup.action = #selector(applyFilter)
        deleteButton.title = "Delete"
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.isEnabled = false
        deleteButton.toolTip = "Delete the selected commands (⌫)"
        let compact = NSButton(title: "Compact…", target: self, action: #selector(compactTapped))
        compact.toolTip = "Shrink history: trim old runs, forget unused commands, drop old saved output"
        notebookButton.title = "Save to Notebook"
        notebookButton.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        notebookButton.imagePosition = .imageLeading
        notebookButton.target = self
        notebookButton.action = #selector(saveToNotebookTapped)
        notebookButton.isEnabled = false
        notebookButton.toolTip = "Save the selected commands to the Command Notebook (⌘S)"
        for b in [deleteButton, compact, notebookButton] { b.bezelStyle = .rounded }
        let top = NSStackView(views: [search, filterPopup, NSView(), notebookButton, deleteButton, compact])
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        // The folder and every run are in the inspector; the list stays narrow enough to sit beside it.
        for (id, title, width, key) in [("command", "Command", 300.0, "command"), ("runs", "Runs", 50.0, "runs"),
                                        ("last", "Last used", 88.0, "last"), ("issue", "Notes", 110.0, "issue")] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: key == "command" || key == "issue")
            if id == "command" { c.resizingMask = .autoresizingMask }
            table.addTableColumn(c)
        }
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.sortDescriptors = [NSSortDescriptor(key: "last", ascending: false)]
        table.onDelete = { [weak self] in self?.deleteTapped() }
        table.onReturn = { [weak self] run in if run { self?.runSelected() } else { self?.putInEditor() } }
        table.onSave = { [weak self] in self?.saveToNotebookTapped() }
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Put in Editor (⏎)") { [weak self] in self?.putInEditor() })
        menu.addItem(ClosureMenuItem(title: "Run (⌘⏎)") { [weak self] in self?.runSelected() })
        menu.addItem(ClosureMenuItem(title: "Save to Notebook… (⌘S)") { [weak self] in self?.saveToNotebookTapped() })
        menu.addItem(ClosureMenuItem(title: "Edit Command…") { [weak self] in self?.editSelected() })
        menu.addItem(ClosureMenuItem(title: "Copy") { [weak self] in self?.copySelected() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Delete…") { [weak self] in self?.deleteTapped() })
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -60),
        ])

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let foot = NSStackView(views: [spinner, status])
        foot.spacing = 6
        foot.translatesAutoresizingMaskIntoConstraints = false
        // The list on the left, and one inspector on the right: an overview, one command's
        // track record and actions, or a breakdown of several.
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "AnserHistorySplit3"
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(insights)
        split.translatesAutoresizingMaskIntoConstraints = false
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        insights.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        mainSplit = split
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        content.addSubview(top); content.addSubview(split); content.addSubview(foot)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            split.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            foot.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 6),
            foot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            foot.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            foot.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    // MARK: Data

    static let builtins: Set<String> = ["cd", "echo", "export", "source", ".", "alias", "unalias", "type", "which", "set", "unset", "eval", "exec", "exit",
                                        "pushd", "popd", "dirs", "history", "fc", "jobs", "fg", "bg", "kill", "wait", "read", "printf", "test", "true",
                                        "false", "time", "umask", "ulimit", "hash", "rehash", "bindkey", "setopt", "unsetopt", "autoload", "zle",
                                        "builtin", "command", "functions", "where", "whence", "local", "declare", "typeset", "shopt", "complete"]

    /// Finds issues for every command, off the main thread (thousands of rows).
    func reload(done: (() -> Void)? = nil) {
        loadTask?.cancel()
        spinner.startAnimation(nil)
        status.stringValue = "Reading history…"
        let commands = store.allCommands()
        let env = pane?.session.env ?? ShellEnvironment()
        let frequency = store.commandNameFrequency()
        loadTask = Task { @MainActor [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { () -> [Row] in
                let names = CommandIndex.shared.commands(env: env) + Array(env.aliases.keys) + Array(env.functions) + Array(Self.builtins)
                let known = Set(names)
                var nearCache: [String: String?] = [:]
                func near(_ prog: String) -> String? {
                    if let hit = nearCache[prog] { return hit }
                    let n = HistoryCleanup.closest(to: prog, in: names, frequency: frequency)
                    nearCache[prog] = n
                    return n
                }
                return commands.map { c in
                    let issue = HistoryCleanup.issue(for: c, isKnown: { known.contains($0) }, closest: near)
                    // What a mistyped program probably was, for the side panel's Fix Typo.
                    var meant: String?
                    if case .typo(let p)? = issue { meant = p }
                    else if issue == .notFound, let prog = c.command.split(separator: " ").first.map(String.init), !known.contains(prog) { meant = near(prog) }
                    return Row(c: c, issue: issue, meant: meant)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.all = rows
            self.spinner.stopAnimation(nil)
            self.updateFilterTitles()
            self.applyFilter()
            done?()
        }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    var showingTrash: Bool { filterPopup.indexOfSelectedItem == Filter.trash.rawValue }

    func setFilterForTests(_ f: Filter) { filterPopup.selectItem(at: f.rawValue); applyFilter() }

    private var trashRows: [Row] {
        store.trashed().map { t in
            Row(c: HistoryCommand(command: t.command, count: t.runs, lastUsed: t.lastUsed, lastCwd: nil, lastExit: nil, cwds: []), issue: nil, deleted: t.deleted)
        }
    }

    /// How many commands each filter would show, in the filter menu ("Mistakes and typos (3)").
    func count(for f: Filter) -> Int? {
        let cutoff = Date().addingTimeInterval(-182 * 86400)
        let here = pane?.session.cwd ?? ""
        switch f {
        case .all: return all.count
        case .folder: return all.filter { $0.c.cwds.contains(here) || $0.c.lastCwd == here }.count
        case .mistakes: return all.filter { $0.issue?.isMistake == true }.count
        case .basic: return all.filter { $0.issue == .trivial }.count
        case .failed: return all.filter { ($0.c.lastExit ?? 0) != 0 }.count
        case .old: return all.filter { $0.c.lastUsed < cutoff }.count
        case .trash: return store.trashed().count
        }
    }

    private func updateFilterTitles() {
        for f in Filter.allCases {
            guard let item = filterPopup.item(at: f.rawValue) else { continue }
            item.title = count(for: f).map { "\(f.title) (\($0))" } ?? f.title
        }
    }

    var filterTitlesForTests: [String] { filterPopup.itemTitles }

    @objc func applyFilter() {
        let words = search.stringValue.lowercased().split(separator: " ").map(String.init)
        let filter = Filter(rawValue: filterPopup.indexOfSelectedItem) ?? .all
        let oldCutoff = Date().addingTimeInterval(-182 * 86400)
        let here = pane?.session.cwd ?? ""
        let keepSelected = Set(selectedCommands)
        let source = filter == .trash ? trashRows : all
        shown = source.filter { r in
            switch filter {
            case .all: break
            case .folder: guard r.c.cwds.contains(here) || r.c.lastCwd == here else { return false }
            case .mistakes: guard r.issue?.isMistake == true else { return false }
            case .basic: guard r.issue == .trivial else { return false }
            case .failed: guard let e = r.c.lastExit, e != 0 else { return false }
            case .old: guard r.c.lastUsed < oldCutoff else { return false }
            case .trash: break
            }
            if words.isEmpty { return true }
            let hay = r.c.command.lowercased()
            return words.allSatisfy(hay.contains)
        }
        sortShown()
        table.reloadData()
        select(where: { keepSelected.contains($0.c.command) }, add: false)
        updateStatus()
        emptyLabel.isHidden = !shown.isEmpty
        emptyLabel.stringValue = emptyText
        if table.selectedRowIndexes.isEmpty { updateDetails() }
    }

    /// What an empty list says.
    var emptyText: String {
        if !search.stringValue.isEmpty { return "Nothing matches “\(search.stringValue)”." }
        switch Filter(rawValue: filterPopup.indexOfSelectedItem) ?? .all {
        case .all: return "No history yet. Commands you run show up here."
        case .folder: return "Nothing has run in this folder yet."
        case .mistakes: return "No typos or mistakes found. Nice."
        case .basic: return "No basic commands like ls or pwd in your history."
        case .failed: return "No commands whose last run failed."
        case .old: return "Everything here was used in the last 6 months."
        case .trash: return "Nothing deleted in the last 7 days."
        }
    }

    private func sortShown() {
        guard let d = table.sortDescriptors.first, let key = d.key else { return }
        let asc = d.ascending
        shown.sort { a, b in
            let r: Bool
            switch key {
            case "runs": r = a.c.count == b.c.count ? a.c.lastUsed < b.c.lastUsed : a.c.count < b.c.count
            case "issue": r = (a.issue?.label ?? "~") < (b.issue?.label ?? "~")
            case "command": r = a.c.command.lowercased() < b.c.command.lowercased()
            case "folder": r = (a.c.lastCwd ?? "~") < (b.c.lastCwd ?? "~")
            default: r = a.c.lastUsed < b.c.lastUsed
            }
            return asc ? r : !r
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let keep = Set(selectedCommands)
        sortShown()
        table.reloadData()
        select(where: { keep.contains($0.c.command) }, add: false)
    }

    private func updateStatus() {
        let sel = table.selectedRowIndexes.count
        let mistakes = all.filter { $0.issue?.isMistake == true }.count
        let size = ByteCountFormatter.string(fromByteCount: store.sizeOnDisk, countStyle: .file)
        var parts = ["\(all.count) commands", "\(store.runCount) runs", size]
        if mistakes > 0 { parts.append("\(mistakes) look like mistakes") }
        if shown.count != all.count { parts.append("showing \(shown.count)") }
        if sel > 0 { parts.append("\(sel) selected") }
        if showingTrash { parts = ["\(shown.count) recently deleted (kept 7 days)"] + (sel > 0 ? ["\(sel) selected"] : []) }
        status.stringValue = parts.joined(separator: " · ")
        let verb = showingTrash ? "Restore" : "Delete"
        deleteButton.title = sel > 0 ? "\(verb) \(sel)" : verb
        deleteButton.isEnabled = sel > 0
        notebookButton.isEnabled = sel > 0 && !showingTrash
        notebookButton.title = sel > 1 ? "Save \(sel) to Notebook" : "Save to Notebook"
        deleteButton.toolTip = showingTrash ? "Put the selected commands back in history" : "Delete the selected commands (⌫)"
    }

    var selectedCommands: [String] { table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0].c.command : nil } }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableViewSelectionDidChange(_ notification: Notification) { updateStatus(); updateDetails() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        let r = shown[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let f = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell-" + id), owner: nil) as? NSTextField) ?? {
            let l = NSTextField(labelWithString: "")
            l.identifier = NSUserInterfaceItemIdentifier("cell-" + id)
            l.lineBreakMode = .byTruncatingTail
            return l
        }()
        f.textColor = .labelColor
        f.font = .systemFont(ofSize: 12)
        switch id {
        case "command":
            f.stringValue = r.c.command.replacingOccurrences(of: "\n", with: " ⏎ ")
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.toolTip = r.c.command + (r.c.lastCwd.map { "\nLast in \(PathDisplay.short($0))" } ?? "")
        case "runs":
            f.stringValue = "\(r.c.count)"
            f.alignment = .right
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case "last":
            f.stringValue = r.deleted.map { "deleted " + RelativeTime.format($0) } ?? RelativeTime.format(r.c.lastUsed)
            f.textColor = .secondaryLabelColor
        default:
            // Mistakes first; "basic command" only where you asked for them, so it doesn't read as a warning.
            let basicFilter = Filter(rawValue: filterPopup.indexOfSelectedItem) == .basic
            if let issue = r.issue, issue.isMistake || basicFilter {
                f.stringValue = issue.label
                f.textColor = issue.isMistake ? .systemOrange : .secondaryLabelColor
            } else if let e = r.c.lastExit, e != 0, e != 130 {
                f.stringValue = "failed (exit \(e))"
                f.textColor = .systemRed.withAlphaComponent(0.85)
            } else {
                f.stringValue = ""
            }
        }
        return f
    }

    // MARK: Selecting

    func select(where pick: (Row) -> Bool, add: Bool) {
        let idx = IndexSet(shown.indices.filter { pick(shown[$0]) })
        table.selectRowIndexes(idx, byExtendingSelection: add)
        if let first = idx.first { table.scrollRowToVisible(first) }
        updateStatus()
    }

    @objc func selectMistakesTapped() {
        select(where: { $0.issue?.isMistake == true }, add: false)
        if table.selectedRowIndexes.isEmpty { NSSound.beep(); status.stringValue = "No mistakes found" + (shown.count != all.count ? " in this list" : "") }
        Services.shared.record("history.selectMistakes")
    }

    @objc func selectBasicTapped() {
        select(where: { $0.issue == .trivial }, add: false)
        if table.selectedRowIndexes.isEmpty { NSSound.beep() }
    }

    @objc private func doubleClicked() { putInEditor() }

    // MARK: Details

    /// The inspector's text (for tests).
    var detailsText: String { insights.textForTests }

    func updateDetails() { updateInsights() }

    // MARK: Using commands

    func runSelected() {
        guard let cmd = selectedCommands.first, let pane else { NSSound.beep(); return }
        guard pane.session.atPrompt else { pane.flash("Wait for the running command to finish"); return }
        pane.submitFromEditor(cmd)
        pane.window?.makeKeyAndOrderFront(nil)
    }

    @objc func saveToNotebookTapped() {
        let list = selectedCommands
        guard !list.isEmpty, !showingTrash else { NSSound.beep(); return }
        NotebookSaver.save(list, over: window) { [weak self] n in
            guard let self else { return }
            self.status.stringValue = n == 0 ? "Already in the Notebook" : "Saved \(n) to the Notebook (⌥⌘N opens it)"
        }
    }

    /// Fixes a command's text in every run (a typo, a secret pasted by mistake).
    func editSelected() {
        guard let cmd = selectedCommands.first, !showingTrash, let w = window else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "Edit this command in history"
        a.informativeText = "Changes it in all \(shown.first { $0.c.command == cmd }?.c.count ?? 1) runs. If the new text is already in history, they're merged."
        let f = NSTextField(string: cmd)
        f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        f.frame = NSRect(x: 0, y: 0, width: 460, height: 24)
        a.accessoryView = f
        a.window.initialFirstResponder = f
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            let new = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, r == .alertFirstButtonReturn, !new.isEmpty, new != cmd else { return }
            self.rename(cmd, to: new)
        }
    }

    func rename(_ cmd: String, to new: String) {
        store.rename(command: cmd, to: new)
        Services.shared.record("history.rename")
        reload { [weak self] in
            self?.select(where: { $0.c.command == new }, add: false)
            self?.updateDetails()
        }
    }

    func putInEditor() {
        guard let cmd = selectedCommands.first, let pane else { return }
        pane.insertIntoEditor(cmd)
        pane.window?.makeKeyAndOrderFront(nil)
    }

    func copySelected() { TerminalWindowController.copy(selectedCommands.joined(separator: "\n")) }

    // MARK: Deleting and compacting

    @objc func deleteTapped() {
        let list = selectedCommands
        guard !list.isEmpty, let w = window else { NSSound.beep(); return }
        if showingTrash { restore(list); return }
        let runs = shown.filter { list.contains($0.c.command) }.reduce(0) { $0 + $1.c.count }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = list.count == 1 ? "Delete this command from history?" : "Delete \(list.count) commands from history?"
        a.informativeText = (list.count == 1 ? list[0].prefix(200) + "\n\n" : "")
            + "All \(runs) run\(runs == 1 ? "" : "s") are removed and \(list.count == 1 ? "it stops" : "they stop") appearing in suggestions. You can restore \(list.count == 1 ? "it" : "them") from Recently Deleted for 7 days (saved output isn't kept)."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        let forever = NSButton(checkboxWithTitle: "Delete permanently (for commands with secrets in them)", target: nil, action: nil)
        a.accessoryView = forever
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.delete(list, permanently: forever.state == .on)
        }
    }

    func restore(_ list: [String]) {
        store.restore(commands: list)
        Services.shared.record("history.restore")
        table.deselectAll(nil)
        reload { [weak self] in self?.status.stringValue = "Restored \(list.count) command\(list.count == 1 ? "" : "s") · " + (self?.status.stringValue ?? "") }
    }

    /// Deletes without asking (the button asks first). Goes to Recently Deleted unless `permanently`.
    func delete(_ list: [String], permanently: Bool = false) {
        store.delete(commands: list, permanently: permanently)
        let gone = Set(list)
        all.removeAll { gone.contains($0.c.command) }
        updateFilterTitles()
        table.deselectAll(nil)
        applyFilter()
        Services.shared.record("history.delete")
        Diagnostics.shared.log("history editor: deleted \(list.count) commands")
        status.stringValue = "Deleted \(list.count) command\(list.count == 1 ? "" : "s") · " + status.stringValue
    }

    @objc func compactTapped() {
        guard let w = window else { return }
        if showingTrash {
            let a = NSAlert()
            a.messageText = "Empty Recently Deleted?"
            a.informativeText = "The \(shown.count) commands here are removed for good."
            a.addButton(withTitle: "Empty")
            a.addButton(withTitle: "Cancel")
            a.beginSheetModal(for: w) { [weak self] r in
                guard let self, r == .alertFirstButtonReturn else { return }
                self.store.purgeTrash(commands: self.shown.map(\.c.command))
                self.applyFilter()
            }
            return
        }
        let mistakes = all.filter { $0.issue?.isMistake == true }.map(\.c.command)
        let basic = all.filter { $0.issue == .trivial }.map(\.c.command)
        let a = NSAlert()
        a.messageText = "Compact history"
        a.informativeText = "Now \(all.count) commands, \(store.runCount) runs, \(ByteCountFormatter.string(fromByteCount: store.sizeOnDisk, countStyle: .file)). Choose what to remove; nothing else changes."
        let mistakesBox = NSButton(checkboxWithTitle: "Delete the \(mistakes.count) mistakes and typos found", target: nil, action: nil)
        mistakesBox.state = mistakes.isEmpty ? .off : .on
        mistakesBox.isEnabled = !mistakes.isEmpty
        let basicBox = NSButton(checkboxWithTitle: "Delete \(basic.count) basic commands (ls, pwd, clear…)", target: nil, action: nil)
        basicBox.state = .off
        basicBox.isEnabled = !basic.isEmpty
        let keepBox = NSButton(checkboxWithTitle: "Keep only the newest runs of each command:", target: nil, action: nil)
        keepBox.state = .on
        let keepPopup = NSPopUpButton()
        keepPopup.addItems(withTitles: ["5", "10", "20", "50"])
        keepPopup.selectItem(at: 2)
        let oldBox = NSButton(checkboxWithTitle: "Forget commands not used for:", target: nil, action: nil)
        oldBox.state = .off
        let oldPopup = NSPopUpButton()
        oldPopup.addItems(withTitles: ["3 months", "6 months", "1 year", "2 years"])
        oldPopup.selectItem(at: 2)
        let outBox = NSButton(checkboxWithTitle: "Remove saved output older than:", target: nil, action: nil)
        outBox.state = .on
        let outPopup = NSPopUpButton()
        outPopup.addItems(withTitles: ["1 week", "30 days", "90 days"])
        outPopup.selectItem(at: 1)
        let note = NSTextField(wrappingLabelWithString: "Keeping fewer runs makes history smaller; suggestions still know every command, but count at most that many uses of each. Deleted mistakes and basic commands stay in Recently Deleted for 7 days.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 400
        let grid = NSGridView(views: [[mistakesBox, NSView()], [basicBox, NSView()], [keepBox, keepPopup], [oldBox, oldPopup], [outBox, outPopup], [note, NSView()]])
        grid.rowSpacing = 6
        grid.row(at: 5).mergeCells(in: NSRange(location: 0, length: 2))
        grid.frame = NSRect(x: 0, y: 0, width: 440, height: 190)
        a.accessoryView = grid
        a.addButton(withTitle: "Compact")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard let self, r == .alertFirstButtonReturn else { return }
            var o = HistoryStore.CompactOptions()
            if mistakesBox.state == .on { o.removeCommands += mistakes }
            if basicBox.state == .on { o.removeCommands += basic }
            if keepBox.state == .on { o.keepRunsPerCommand = [5, 10, 20, 50][keepPopup.indexOfSelectedItem] }
            if oldBox.state == .on { o.unusedForDays = [91, 182, 365, 730][oldPopup.indexOfSelectedItem] }
            if outBox.state == .on { o.outputOlderThanDays = [7, 30, 90][outPopup.indexOfSelectedItem] }
            self.compact(o)
        }
    }

    func compact(_ o: HistoryStore.CompactOptions, done: ((HistoryStore.CompactResult) -> Void)? = nil) {
        spinner.startAnimation(nil)
        status.stringValue = "Compacting…"
        let store = self.store
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { store.compact(o) }.value
            Services.shared.record("history.compact")
            Diagnostics.shared.log("history compact: -\(result.runsRemoved) runs, -\(result.commandsRemoved) commands, \(result.bytesBefore)→\(result.bytesAfter) bytes")
            guard let self else { done?(result); return }
            self.reload {
                let f = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
                self.status.stringValue = "Removed \(result.runsRemoved) runs and \(result.commandsRemoved) commands · \(f(result.bytesBefore)) → \(f(result.bytesAfter))"
                done?(result)
            }
        }
    }

    func windowWillClose(_ notification: Notification) { loadTask?.cancel() }
}

/// MARK: Weekly clean-up

enum HistoryAutoClean {
    static let key = "lastAutoClean"

    /// At launch: empty Recently Deleted of anything older than 7 days, and once a week (if you turned it on) move typos there.
    static func runIfDue(store: HistoryStore = Services.shared.history, now: Date = Date(), force: Bool = false) -> Int {
        store.purgeTrash(olderThan: now.addingTimeInterval(-7 * 86400))
        guard force || Services.shared.config.autoCleanHistory else { return 0 }
        let last = store.syncValue(key).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        guard force || now.timeIntervalSince(last) > 7 * 86400 else { return 0 }
        store.setSyncValue(key, String(now.timeIntervalSince1970))
        let env = ShellEnvironment()
        let names = CommandIndex.shared.commands(env: env) + Array(HistoryEditorWindowController.builtins)
        let known = Set(names)
        let freq = store.commandNameFrequency()
        // Only clear-cut mistakes: typos and "command not found" (not one-off failures).
        let mistakes = store.allCommands().filter { c in
            switch HistoryCleanup.issue(for: c, isKnown: { known.contains($0) }, closest: { HistoryCleanup.closest(to: $0, in: names, frequency: freq) }) {
            case .typo?, .notFound?: return true
            default: return false
            }
        }.map(\.command)
        if !mistakes.isEmpty { store.delete(commands: mistakes, permanently: false, now: now) }
        Diagnostics.shared.log("history auto-clean: moved \(mistakes.count) mistakes to Recently Deleted")
        return mistakes.count
    }
}

/// ⌫ deletes the selected rows.
final class HistoryTable: NSTableView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "s" {
            onSave?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    var onDelete: (() -> Void)?
    /// Return puts the command in the editor; ⌘Return runs it.
    var onReturn: ((Bool) -> Void)?
    var onSave: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?(event.modifierFlags.contains(.command)); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" { onSave?(); return }
        super.keyDown(with: event)
    }
}

// MARK: Side panel

extension HistoryEditorWindowController {
    /// Switches the list to one filter (from the side panel's “Show” buttons).
    func showFilter(_ f: Filter) {
        search.stringValue = ""
        filterPopup.selectItem(at: f.rawValue)
        table.deselectAll(nil)
        applyFilter()
    }

    /// Selects one command, showing everything first if it's filtered out.
    func focus(command: String) {
        if !shown.contains(where: { $0.c.command == command }) { showFilter(.all) }
        select(where: { $0.c.command == command }, add: false)
        updateDetails()
    }

    /// A typo's corrected text: the first word swapped for what it probably meant.
    static func fixedTypo(_ cmd: String, to program: String) -> String {
        let t = cmd.trimmingCharacters(in: .whitespaces)
        guard let space = t.firstIndex(of: " ") else { return program }
        return program + t[space...]
    }

    func updateInsights() {
        let p = insights
        p.reset()
        let sel = selectedCommands
        if showingTrash { trashInsights(sel) }
        else if sel.count == 1, let row = shown.first(where: { $0.c.command == sel[0] }) { commandInsights(row) }
        else if sel.count > 1 { selectionInsights(sel) }
        else { overviewInsights() }
        p.finish()
    }

    private func overviewInsights() {
        let p = insights
        let now = Date()
        let filter = Filter(rawValue: filterPopup.indexOfSelectedItem) ?? .all
        // A filtered list ("Show Mistakes"): selecting everything shown is the next step.
        if filter != .all, filter != .trash, !shown.isEmpty {
            p.heading(filter.title, first: true)
            p.action("\(shown.count) command\(shown.count == 1 ? "" : "s") in this list", button: "Select All") { [weak self] in
                guard let self else { return }
                self.table.selectAll(nil)
                self.updateStatus()
            }
            p.action("Back to every command", button: "Show All") { [weak self] in self?.showFilter(.all) }
        }
        let dates = store.runDates(since: now.addingTimeInterval(-30 * 86400))
        p.heading("Last 30 days", first: filter == .all || filter == .trash || shown.isEmpty)
        if dates.isEmpty {
            p.line("Nothing ran in the last 30 days.", color: .secondaryLabelColor)
        } else {
            let days = HistoryInsights.perDay(dates, days: 30, now: now)
            let active = days.filter { $0 > 0 }.count
            p.chart(days, caption: "\(dates.count) runs on \(active) day\(active == 1 ? "" : "s") · busiest day \(days.max() ?? 0) · today \(days.last ?? 0)")
        }

        let top = HistoryInsights.topCommands(all.map(\.c), limit: 6)
        if !top.isEmpty {
            p.heading("Most used")
            for t in top { p.bar(t.name, t.count, max: top[0].count, tip: "Select “\(t.name)”") { [weak self] in self?.focus(command: t.name) } }
        }

        let folders = store.recentDirectories(limit: 300).sorted { $0.count > $1.count }.prefix(5)
        if let most = folders.first?.count {
            p.heading("Busiest folders")
            for f in folders { p.bar(PathDisplay.short(f.path, max: 40), f.count, max: most, mono: false, tip: f.path) }
        }

        p.heading("Tidy up")
        let mistakes = all.filter { $0.issue?.isMistake == true }.count
        let basic = all.filter { $0.issue == .trivial }.count
        let failed = all.filter { ($0.c.lastExit ?? 0) != 0 }.count
        let cutoff = now.addingTimeInterval(-182 * 86400)
        let old = all.filter { $0.c.lastUsed < cutoff }.count
        let trash = store.trashed().count
        func plural(_ n: Int, _ s: String) -> String { "\(n) \(s)\(n == 1 ? "" : "s")" }
        p.action(mistakes == 0 ? "No typos or mistakes" : (mistakes == 1 ? "1 typo or mistake" : "\(mistakes) typos or mistakes"),
                 button: "Show Mistakes", enabled: mistakes > 0) { [weak self] in self?.showFilter(.mistakes) }
        p.action(plural(basic, "basic command"), button: "Show Basic", enabled: basic > 0) { [weak self] in self?.showFilter(.basic) }
        p.action(plural(failed, "command") + " whose last run failed", button: "Show Failed", enabled: failed > 0) { [weak self] in self?.showFilter(.failed) }
        p.action(plural(old, "command") + " unused for 6 months", button: "Show Old", enabled: old > 0) { [weak self] in self?.showFilter(.old) }
        p.action(plural(trash, "command") + " in Recently Deleted", button: "Show Deleted", enabled: trash > 0) { [weak self] in self?.showFilter(.trash) }
        let size = ByteCountFormatter.string(fromByteCount: store.sizeOnDisk, countStyle: .file)
        p.action("History uses \(size) for \(store.runCount) runs", button: "Compact…") { [weak self] in self?.compactTapped() }

        p.heading("Keys")
        for (k, v) in [("⏎", "put in the editor"), ("⌘⏎", "run it"), ("⌘S", "save to the Notebook"), ("⌫", "delete (kept 7 days)"), ("⌘A", "select everything shown")] {
            p.runLine(ok: nil, when: k, detail: v)
        }
    }

    private func commandInsights(_ row: Row) {
        let p = insights
        let cmd = row.c.command
        let runs = store.runs(of: cmd, limit: 500)
        let s = HistoryInsights.summary(of: runs)
        // What you came to do first: the command and its actions.
        p.line(cmd, mono: true, bold: true, wrap: true)
        p.buttonsRow([("Put in Editor", "text.cursor", { [weak self] in self?.putInEditor() }),
                      ("Run", "play", { [weak self] in self?.runSelected() }),
                      ("Edit…", "pencil", { [weak self] in self?.editSelected() }),
                      ("Save to Notebook", "book.closed", { [weak self] in self?.saveToNotebookTapped() }),
                      ("Copy", "doc.on.doc", { [weak self] in self?.copySelected() }),
                      ("Delete…", "trash", { [weak self] in self?.deleteTapped() })])
        if (try? Notebook.load(from: NotebookWindow.fileURL))?.contains(command: cmd) == true {
            p.line("Already in the Notebook.", color: .secondaryLabelColor)
        }

        if let issue = row.issue, issue.isMistake {
            p.heading("Looks like a mistake")
            if let program = row.meant {
                let fixed = Self.fixedTypo(cmd, to: program)
                p.action("Probably meant “\(fixed)”", button: "Fix Typo") { [weak self] in self?.rename(cmd, to: fixed) }
            } else {
                p.line(issue.label.prefix(1).uppercased() + issue.label.dropFirst() + ". Deleting it keeps suggestions clean.", color: .secondaryLabelColor, wrap: true)
            }
        }

        p.heading("Track record")
        p.stats([("runs", "\(row.c.count)"),
                 ("worked", s.successRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"),
                 ("usually takes", s.typical.map(Services.formatDuration) ?? "–")])
        p.stats([("first used", s.first.map { RelativeTime.format($0) } ?? "–"),
                 ("last used", RelativeTime.format(row.c.lastUsed)),
                 ("folders", "\(row.c.cwds.count)")])

        // Recent runs: the folder only when it changes, so the list stays short.
        let recent = runs.prefix(8)
        if !recent.isEmpty {
            p.heading(runs.count > recent.count ? "Last \(recent.count) of \(row.c.count) runs" : (recent.count == 1 ? "1 run" : "\(recent.count) runs"))
            let manyFolders = Set(recent.compactMap(\.cwd)).count > 1
            var lastFolder: String?
            for r in recent {
                var bits: [String] = []
                if let d = r.duration { bits.append(Services.formatDuration(d)) }
                if let e = r.exitCode, e != 0 { bits.append(e == 130 ? "stopped" : "exit \(e)") }
                if let b = r.branch { bits.append(b) }
                if manyFolders, let c = r.cwd, c != lastFolder { bits.append(PathDisplay.short(c, max: 28)) }
                lastFolder = r.cwd ?? lastFolder
                p.runLine(ok: r.exitCode.map { $0 == 0 || $0 == 130 }, when: RelativeTime.format(r.started), detail: bits.joined(separator: " · "))
            }
            if !manyFolders, let only = recent.first?.cwd { p.line("in " + PathDisplay.short(only, max: 44), color: .tertiaryLabelColor) }
        }

        if let last = runs.first, let output = store.output(forHistoryID: last.id), !output.isEmpty {
            p.heading("Last output")
            let lines = output.components(separatedBy: "\n")
            p.codeBlock(lines.suffix(12).joined(separator: "\n").trimmingCharacters(in: .newlines))
        }

        let dates = store.runDates(command: cmd, since: Date().addingTimeInterval(-30 * 86400))
        p.heading("Last 30 days")
        if dates.isEmpty { p.line("Not run in the last 30 days.", color: .secondaryLabelColor) }
        else { p.chart(HistoryInsights.perDay(dates), caption: "\(dates.count) run\(dates.count == 1 ? "" : "s") in the last 30 days") }

        if s.folders.count > 1, let most = s.folders.first?.count {
            p.heading("Where it runs")
            for f in s.folders { p.bar(PathDisplay.short(f.name, max: 40), f.count, max: most, mono: false, tip: f.name) }
        }
        if let most = s.branches.first?.count {
            p.heading("Branches")
            for b in s.branches { p.bar(b.name, b.count, max: most) }
        }
    }

    private func selectionInsights(_ sel: [String]) {
        let p = insights
        let rows = shown.filter { sel.contains($0.c.command) }.sorted { $0.c.count > $1.c.count }
        let runs = rows.reduce(0) { $0 + $1.c.count }
        p.heading("\(sel.count) selected", first: true)
        p.stats([("commands", "\(sel.count)"), ("runs", "\(runs)"), ("look like mistakes", "\(rows.filter { $0.issue?.isMistake == true }.count)")])
        p.heading("Breakdown")
        let most = rows.first?.c.count ?? 1
        for r in rows.prefix(8) {
            p.bar(r.c.command, r.c.count, max: most, tip: "Select only “\(r.c.command)”") { [weak self] in self?.focus(command: r.c.command) }
        }
        if rows.count > 8 { p.line("and \(rows.count - 8) more", color: .secondaryLabelColor) }
        p.heading("Actions")
        p.buttonsRow([("Save \(sel.count) to Notebook", "book.closed", { [weak self] in self?.saveToNotebookTapped() }),
                      ("Copy All", "doc.on.doc", { [weak self] in self?.copySelected() }),
                      ("Delete \(sel.count)…", "trash", { [weak self] in self?.deleteTapped() })])
    }

    private func trashInsights(_ sel: [String]) {
        let p = insights
        p.heading("Recently deleted", first: true)
        p.line("Deleted commands wait here for 7 days, then go for good. Restore puts every run back.", color: .secondaryLabelColor, wrap: true)
        p.stats([("commands", "\(shown.count)"), ("runs", "\(shown.reduce(0) { $0 + $1.c.count })")])
        p.heading("Actions")
        var items: [(String, String, () -> Void)] = []
        if !sel.isEmpty { items.append(("Restore \(sel.count)", "arrow.uturn.backward", { [weak self] in self?.restore(sel) })) }
        if !shown.isEmpty { items.append(("Empty…", "trash.slash", { [weak self] in self?.compactTapped() })) }
        items.append(("Back to All", "list.bullet", { [weak self] in self?.showFilter(.all) }))
        p.buttonsRow(items)
    }
}
