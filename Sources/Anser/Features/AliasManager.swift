import AppKit
import AnserCore

/// Saves aliases and hands changes to every open shell (new ones load the file).
enum AliasManager {
    /// Tests use their own file.
    static var fileURL: URL = AliasStore.fileURL

    static func load() -> AliasBook { AliasStore.load(from: fileURL) }

    /// Saves `book`, then applies what changed to open tabs (now if idle, else at their next prompt).
    @discardableResult
    static func save(_ book: AliasBook) -> Bool {
        let old = load()
        do { try AliasStore.save(book, to: fileURL) } catch {
            Diagnostics.shared.log("aliases: couldn't save: \(error.localizedDescription)")
            return false
        }
        guard old.aliases != book.aliases else { return true }
        for pane in AppDelegate.shared.allPanes where !pane.session.isRemote && pane.session.capabilities.contains("load") {
            let script = AliasStore.changes(from: old.aliases, to: book.aliases, shell: ProjectEnv.Shell(pane.session.env.shell))
            guard !script.isEmpty else { continue }
            if pane.session.atPrompt, pane.session.running == nil { _ = pane.sendToShell(script) }
            else { pane.pendingShellScript = (pane.pendingShellScript ?? "") + script }
        }
        NotificationCenter.default.post(name: .anserAliasesChanged, object: nil)
        return true
    }

    /// The add/edit form, checking the name as you type.
    static func form(_ existing: AnserAlias?, suggestedName: String = "", command: String = "", pane: PaneView?) -> FormSheet {
        let book = load()
        let f = FormSheet(title: existing == nil ? "New alias" : "Edit alias",
                          message: "Type the short name in any tab and the shell runs the command. It works in every open tab right away.",
                          fields: [
                            .init("name", "Name", .text(placeholder: "e.g. glog", mono: true), value: existing?.name ?? suggestedName),
                            .init("command", "Command", .text(placeholder: "e.g. git log --oneline --graph --all", mono: true), value: existing?.command ?? command),
                            .init("group", "Group", .combo(options: book.groups, placeholder: "Optional, e.g. git"), value: existing?.group ?? ""),
                          ], ok: existing == nil ? "Add" : "Save")
        f.validate = { v in
            let name = v["name", default: ""].trimmingCharacters(in: .whitespaces)
            if let p = AliasStore.problem(name: name, command: v["command", default: ""]) { return p }
            if name != existing?.name, book[name] != nil { return "You already have an alias “\(name)”." }
            return nil
        }
        f.warn = { v in
            let name = v["name", default: ""].trimmingCharacters(in: .whitespaces)
            guard name != existing?.name, let env = pane?.session.env else { return nil }
            if CommandIndex.shared.contains(name, env: env) { return "“\(name)” is already a command; the alias will run instead (use “command \(name)” for the original)." }
            if let shell = env.aliases[name] { return "Your shell setup has “\(name)” = \(shell); this one replaces it in Anser's tabs." }
            return nil
        }
        f.preview = { v in
            let name = v["name", default: ""].trimmingCharacters(in: .whitespaces)
            let cmd = v["command", default: ""].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !cmd.isEmpty else { return nil }
            return "$ \(name) …  →  $ \(cmd) …"
        }
        return f
    }

    /// Saves what the form returned. Returns the alias, or nil when it wasn't saved.
    @discardableResult
    static func apply(_ v: [String: String], replacing existing: AnserAlias?) -> AnserAlias? {
        let alias = AnserAlias(name: v["name", default: ""].trimmingCharacters(in: .whitespaces),
                               command: v["command", default: ""].trimmingCharacters(in: .whitespaces), group: v["group"])
        guard AliasStore.problem(name: alias.name, command: alias.command) == nil else { return nil }
        var book = load()
        book.set(alias, replacing: existing?.name)
        book.dismissed.removeAll { $0 == alias.command }
        guard save(book) else { return nil }
        Services.shared.record(existing == nil ? "alias.add" : "alias.edit")
        return alias
    }

    /// The add/edit form as a sheet. `done` gets the saved alias.
    static func edit(_ existing: AnserAlias?, suggestedName: String = "", command: String = "", over window: NSWindow?, pane: PaneView?,
                     done: ((AnserAlias) -> Void)? = nil) {
        let f = form(existing, suggestedName: suggestedName, command: command, pane: pane)
        f.present(over: window, focus: existing == nil ? (suggestedName.isEmpty ? "name" : "name") : "command") { v in
            guard let v, let a = apply(v, replacing: existing) else { return }
            done?(a)
        }
    }
}

extension Notification.Name {
    static let anserAliasesChanged = Notification.Name("AnserAliasesChanged")
}

/// Tools → Aliases…: your Anser aliases (add, edit, delete), the ones from
/// your shell setup, and suggestions from commands you keep typing.
final class AliasesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = AliasesWindowController()

    enum Row { case header(String), mine(AnserAlias), shell(String, String), suggestion(HabitSuggestions.Suggestion), note(String) }

    private let table = NSTableView()
    private let search = NSSearchField()
    private(set) var rows: [Row] = []
    weak var pane: PaneView?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Aliases"
        w.minSize = NSSize(width: 460, height: 320)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
        NotificationCenter.default.addObserver(forName: .anserAliasesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(for pane: PaneView?) {
        self.pane = pane ?? AppDelegate.shared.currentPane
        reload()
        if window?.isVisible != true { window?.center() }
        if let w = window { LibraryTabs.host(w, pane: self.pane) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Services.shared.record("alias.window")
    }

    private func build() {
        guard let content = window?.contentView else { return }
        search.placeholderString = "Search aliases"
        search.delegate = self
        let add = NSButton(title: "Add Alias…", target: self, action: #selector(addTapped))
        add.bezelStyle = .rounded
        add.keyEquivalent = "n"
        add.keyEquivalentModifierMask = .command
        let importButton = NSButton(title: "Import from Shell…", target: self, action: #selector(importTapped))
        importButton.bezelStyle = .rounded
        importButton.toolTip = "Copy the aliases from your .zshrc/.bashrc here, so you can edit them in one place"
        let top = NSStackView(views: [search, importButton, add])
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false

        for (id, title, width) in [("name", "Name", 140.0), ("command", "Command", 380.0), ("action", "", 90.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            if id == "command" { c.resizingMask = .autoresizingMask }
            table.addTableColumn(c)
        }
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = false
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString: "Anser aliases are saved in ~/.config/anser/aliases.json and load in every new tab (zsh, bash and fish). Aliases from your shell setup are shown so you can see what's taken; edit those in your .zshrc or .bashrc.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(top); content.addSubview(scroll); content.addSubview(note)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            note.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    /// Suggestions for this Mac's history (exposed for tests).
    static func suggestions(book: AliasBook, shellAliases: [String: String], env: ShellEnvironment?) -> [HabitSuggestions.Suggestion] {
        var all = shellAliases
        for a in book.aliases { all[a.name] = a.command }
        return HabitSuggestions.suggest(Services.shared.history.frequentCommands(), aliases: all, dismissed: Set(book.dismissed),
                                        isTaken: { name in env.map { CommandIndex.shared.contains(name, env: $0) } ?? false })
    }

    func reload() {
        let book = AliasManager.load()
        let mineNames = Set(book.aliases.map(\.name))
        let shellAliases = (pane?.session.env.aliases ?? [:]).filter { !mineNames.contains($0.key) }
        let q = search.stringValue.lowercased().split(separator: " ").map(String.init)
        func matches(_ parts: String...) -> Bool { q.isEmpty || q.allSatisfy { w in parts.contains { $0.lowercased().contains(w) } } }
        var r: [Row] = [.header("Your aliases")]
        if book.aliases.isEmpty { r.append(.note("None yet. Add one, import yours from the shell, or pick a suggestion below.")) }
        for (group, list) in book.grouped {
            let hits = list.filter { matches($0.name, $0.command, $0.group ?? "") }
            guard !hits.isEmpty else { continue }
            if let group { r.append(.header(group)) }
            r += hits.map { .mine($0) }
        }
        let sugg = Self.suggestions(book: book, shellAliases: pane?.session.env.aliases ?? [:], env: pane?.session.env).filter { matches($0.name, $0.command) }
        if !sugg.isEmpty {
            r.append(.header("Suggested: commands you keep typing"))
            r += sugg.map { .suggestion($0) }
        }
        let fromShell = shellAliases.sorted { $0.key < $1.key }.filter { matches($0.key, $0.value) }
        if !fromShell.isEmpty {
            r.append(.header("From your shell setup"))
            r += fromShell.map { .shell($0.key, $0.value) }
        }
        rows = r
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .header = rows[row] { return true } else { return false } }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] { case .header, .note: return false; default: return true }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        func label(_ s: String, mono: Bool = false, color: NSColor = .labelColor, bold: Bool = false) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.font = mono ? .monospacedSystemFont(ofSize: 12, weight: bold ? .semibold : .regular) : .systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
            f.textColor = color
            f.lineBreakMode = .byTruncatingTail
            f.toolTip = s
            return f
        }
        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.controlSize = .small
            b.bezelStyle = .rounded
            b.tag = row
            return b
        }
        switch rows[row] {
        case .header(let t): return tableColumn == nil || id == "name" ? label(t.uppercased(), color: .secondaryLabelColor, bold: true) : nil
        case .note(let t): return id == "command" ? label(t, color: .secondaryLabelColor) : nil
        case .mine(let a):
            switch id {
            case "name": return label(a.name, mono: true, bold: true)
            case "command": return label(a.command, mono: true)
            default: return button("Edit", #selector(editTapped(_:)))
            }
        case .shell(let n, let v):
            switch id {
            case "name": return label(n, mono: true, color: .secondaryLabelColor)
            case "command": return label(v, mono: true, color: .secondaryLabelColor)
            default: return nil
            }
        case .suggestion(let s):
            switch id {
            case "name": return label(s.name, mono: true, color: .systemBlue)
            case "command":
                let l = label(s.command, mono: true)
                l.toolTip = "\(s.command)\nTyped \(s.count) times · saves \(s.saves) characters each time"
                return l
            default: return button("Add", #selector(addSuggestionTapped(_:)))
            }
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { nil }

    // MARK: Actions

    @objc private func addTapped() { AliasManager.edit(nil, over: window, pane: pane) }

    @objc private func importTapped() {
        guard let w = window else { return }
        let book = AliasManager.load()
        let shell = (pane?.session.env.aliases ?? [:]).filter { book[$0.key] == nil }
        guard !shell.isEmpty else {
            let a = NSAlert(); a.messageText = "Nothing to import"; a.informativeText = "Your shell has no aliases that aren't already here."
            a.beginSheetModal(for: w); return
        }
        let a = NSAlert()
        a.messageText = "Import \(shell.count) alias\(shell.count == 1 ? "" : "es") from your shell?"
        a.informativeText = "They're copied here into the group “Imported”, so you can edit, group and delete them in Anser. Anser's copies load after your .zshrc, so changes you make here win. You can then remove them from your .zshrc or .bashrc."
        a.addButton(withTitle: "Import")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn else { return }
            _ = self.importFromShell(shell)
        }
    }

    /// Copies shell aliases into Anser's book. Returns how many were added.
    @discardableResult
    func importFromShell(_ shell: [String: String]) -> Int {
        var book = AliasManager.load()
        let n = book.importAliases(shell)
        if n > 0, AliasManager.save(book) { Services.shared.record("alias.import") }
        reload()
        return n
    }

    @objc private func editTapped(_ b: NSButton) {
        guard rows.indices.contains(b.tag), case let .mine(a) = rows[b.tag] else { return }
        AliasManager.edit(a, over: window, pane: pane)
    }

    @objc private func addSuggestionTapped(_ b: NSButton) {
        guard rows.indices.contains(b.tag), case let .suggestion(s) = rows[b.tag] else { return }
        AliasManager.edit(nil, suggestedName: s.name, command: s.command, over: window, pane: pane)
    }

    @objc private func doubleClicked() {
        let r = table.clickedRow
        guard rows.indices.contains(r) else { return }
        switch rows[r] {
        case .mine(let a): AliasManager.edit(a, over: window, pane: pane)
        case .suggestion(let s): AliasManager.edit(nil, suggestedName: s.name, command: s.command, over: window, pane: pane)
        case .shell(let n, let v): pane?.insertIntoEditor(n); _ = v
        default: break
        }
    }

    func delete(_ name: String) {
        var book = AliasManager.load()
        book.remove(name)
        if AliasManager.save(book) { Services.shared.record("alias.delete") }
    }

    func dismiss(_ command: String) {
        var book = AliasManager.load()
        if !book.dismissed.contains(command) { book.dismissed.append(command) }
        AliasManager.save(book)
        reload()
    }
}

extension AliasesWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard rows.indices.contains(r) else { return }
        switch rows[r] {
        case .mine(let a):
            menu.addItem(ClosureMenuItem(title: "Edit…") { [weak self] in AliasManager.edit(a, over: self?.window, pane: self?.pane) })
            menu.addItem(ClosureMenuItem(title: "Put in Editor") { [weak self] in self?.pane?.insertIntoEditor(a.name + " ") })
            menu.addItem(ClosureMenuItem(title: "Copy Definition") { TerminalWindowController.copy("alias \(a.name)='\(a.command)'") })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Delete") { [weak self] in self?.delete(a.name) })
        case .suggestion(let s):
            menu.addItem(ClosureMenuItem(title: "Add as “\(s.name)”…") { [weak self] in
                AliasManager.edit(nil, suggestedName: s.name, command: s.command, over: self?.window, pane: self?.pane)
            })
            menu.addItem(ClosureMenuItem(title: "Don't Suggest This") { [weak self] in self?.dismiss(s.command) })
        case .shell(let n, let v):
            menu.addItem(ClosureMenuItem(title: "Copy to Anser Aliases (to edit here)…") { [weak self] in
                AliasManager.edit(nil, suggestedName: n, command: v, over: self?.window, pane: self?.pane)
            })
        default: break
        }
    }
}

// MARK: Habit tips in the status row

extension PaneView {
    /// Commands the tip was already shown for (once per launch each).
    private static var tipped: Set<String> = []

    func commandStartedForHabits(_ command: String) {
        if aliasTip != nil { aliasTip = nil }
        recorder?.mark(command)
    }

    /// After a command: offer an alias for a long command you keep typing, or remind you of the one you have.
    func checkHabit(_ b: ShellSession.Block) {
        guard Services.shared.config.suggestAliases, !session.isRemote, (b.exitCode ?? 0) == 0, session.running == nil else { return }
        let cmd = b.command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty, !Self.tipped.contains(cmd) else { return }
        let book = AliasManager.load()
        var all = session.env.aliases
        for a in book.aliases { all[a.name] = a.command }
        // You already have an alias for exactly this.
        if cmd.count >= 12, let name = all.first(where: { $0.value.trimmingCharacters(in: .whitespaces) == cmd })?.key {
            Self.tipped.insert(cmd)
            aliasTip = (cmd, name, true)
            refreshBar()
            return
        }
        guard let stats = Services.shared.history.stats(for: cmd), stats.count >= HabitSuggestions.minCount + 1,
              HabitSuggestions.qualifies(stats, aliasValues: Set(all.values), dismissed: Set(book.dismissed)) else { return }
        Self.tipped.insert(cmd)
        let env = session.env
        let name = HabitSuggestions.name(for: cmd) { all[$0] != nil || CommandIndex.shared.contains($0, env: env) }
        aliasTip = (cmd, name, false)
        Services.shared.record("alias.tip")
        refreshBar()
    }

    func refreshHabitChips() {
        let t = theme
        let dim = t.foreground.withAlphaComponent(0.55)
        if let tip = aliasTip, session.atPrompt {
            aliasChip.set(role: .suggestion, symbol: "text.badge.plus", text: tip.existing ? "Tip: alias \(tip.name) does this" : "Make it an alias: \(tip.name)", filled: true, theme: t)
            aliasChip.set(symbol: "text.badge.plus", text: aliasChip.text, color: ChipRole.suggestion.color(t),
                          tooltip: tip.existing ? "You have an alias for “\(tip.command)”: just type \(tip.name)"
                              : "You've typed “\(tip.command)” many times. Click to make “\(tip.name)” run it.")
        } else {
            aliasChip.filled = nil
            aliasChip.set(symbol: nil, text: "", color: dim)
        }
        if let r = session.running, LogLines.isFollowCommand(r.command) {
            logChip.set(role: .suggestion, symbol: "list.bullet.rectangle", text: "Log view", tooltip: "Open these logs with levels in color, filters, pretty JSON and jump-to-error", filled: true, theme: t)
        } else {
            logChip.filled = nil
            logChip.set(symbol: nil, text: "", color: dim)
        }
        if let rec = recorder {
            recChip.filled = t.red
            recChip.set(symbol: "record.circle", text: "REC " + Services.formatDuration(rec.elapsed), color: t.red,
                        tooltip: "Recording this tab. Click to stop and replay, or discard.")
        } else {
            recChip.filled = nil
            recChip.set(symbol: nil, text: "", color: dim)
        }
    }

    func showAliasTipMenu() {
        guard let tip = aliasTip else { return }
        let m = NSMenu()
        if tip.existing {
            m.addItem(ClosureMenuItem(title: "Put “\(tip.name)” in the Editor") { [weak self] in self?.insertIntoEditor(tip.name + " ") })
        } else {
            m.addItem(ClosureMenuItem(title: "Make “\(tip.name)” an Alias…") { [weak self] in
                guard let self else { return }
                AliasManager.edit(nil, suggestedName: tip.name, command: tip.command, over: self.window, pane: self) { [weak self] a in
                    self?.aliasTip = nil
                    self?.refreshBar()
                    self?.flash("Type \(a.name) to run it")
                }
            })
            m.addItem(ClosureMenuItem(title: "Don't Suggest This Command") { [weak self] in
                var book = AliasManager.load()
                book.dismissed.append(tip.command)
                AliasManager.save(book)
                self?.aliasTip = nil
                self?.refreshBar()
            })
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Open Aliases…") { [weak self] in AliasesWindowController.shared.show(for: self) })
        m.addItem(ClosureMenuItem(title: "Hide") { [weak self] in self?.aliasTip = nil; self?.refreshBar() })
        m.popUp(positioning: nil, at: NSPoint(x: aliasChip.frame.minX, y: aliasChip.frame.maxY + 2), in: bar)
    }

    func flushPendingShellScript() {
        guard let s = pendingShellScript, session.atPrompt, session.running == nil else { return }
        pendingShellScript = nil
        _ = sendToShell(s)
    }
}
