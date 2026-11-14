import AppKit
import AnserCore

/// Tools → Library (⌥⌘O): your saved things in one window — notebook
/// (workflows included), runbooks, aliases, history, recordings and watches — with one
/// search across them all. Each item's main action is a double-click away;
/// "Manage…" opens the full editor for that kind.
final class LibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = LibraryWindowController()

    enum Section: Int, CaseIterable {
        case everything, notebook, runbooks, aliases, history, recordings, watches
        var title: String {
            switch self {
            case .everything: "Everything"
            case .notebook: "Notebook"
            case .runbooks: "Runbooks"
            case .aliases: "Aliases"
            case .history: "History"
            case .recordings: "Recordings"
            case .watches: "Watching"
            }
        }
        var symbol: String {
            switch self {
            case .everything: "square.grid.2x2"
            case .notebook: "book.closed"
            case .runbooks: "list.bullet.clipboard"
            case .aliases: "text.badge.plus"
            case .history: "clock.arrow.circlepath"
            case .recordings: "record.circle"
            case .watches: "eye"
            }
        }
        /// What the empty list says, and what its button does.
        var empty: String {
            switch self {
            case .everything: "Nothing matches."
            case .notebook: "Save commands you want to keep: right-click any command in the terminal → Save to Notebook. Commands with several steps (workflows) show here too."
            case .runbooks: "Runbooks are Markdown checklists whose code blocks run with one click."
            case .aliases: "Short names for long commands, working in every tab."
            case .history: "Commands you run show up here."
            case .recordings: "Record a tab (Shell → Record This Tab) to replay or share it."
            case .watches: "Watch a command's output and get told when it changes (Shell → Watch a Command's Output…)."
            }
        }
    }

    struct Item {
        var section: Section
        var title: String
        var detail: String
        var symbol: String
        var primaryTitle: String
        var primary: () -> Void
        var actions: [(title: String, run: () -> Void)] = []
    }

    weak var pane: PaneView?
    private let sourceList = NSTableView()
    private let table = NSTableView()
    private let search = NSSearchField()
    private let primaryButton = NSButton()
    private let manageButton = NSButton()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private(set) var section: Section = .everything
    private(set) var items: [Item] = []
    private var counts: [Section: Int] = [:]

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Library"
        w.minSize = NSSize(width: 660, height: 440)
        w.tabbingIdentifier = LibraryTabs.identifier
        w.tabbingMode = .preferred
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("AnserLibrary")
        super.init(window: w)
        w.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(for pane: PaneView?, section: Section? = nil) {
        self.pane = pane ?? AppDelegate.shared.currentPane
        if let section { select(section) }
        if window?.frame.origin == .zero { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
        reload()
        Services.shared.record("library.open")
    }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.translatesAutoresizingMaskIntoConstraints = false
        let sc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        sourceList.addTableColumn(sc)
        sourceList.headerView = nil
        sourceList.style = .sourceList
        sourceList.rowHeight = 26
        sourceList.dataSource = self
        sourceList.delegate = self
        sourceList.backgroundColor = .clear
        let sideScroll = NSScrollView()
        sideScroll.documentView = sourceList
        sideScroll.drawsBackground = false
        sideScroll.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(sideScroll)

        search.placeholderString = "Search everything you've saved"
        search.delegate = self
        search.setAccessibilityLabel("Search Library")
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        manageButton.title = "Manage…"
        manageButton.bezelStyle = .rounded
        manageButton.target = self
        manageButton.action = #selector(manageTapped)
        let top = NSStackView(views: [search, primaryButton, manageButton])
        top.alignment = .centerY
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false

        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(c)
        table.headerView = nil
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(primaryTapped)
        table.style = .inset
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyButton.bezelStyle = .rounded
        emptyButton.target = self
        emptyButton.action = #selector(manageTapped)
        emptyButton.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(side); content.addSubview(top); content.addSubview(scroll)
        content.addSubview(emptyLabel); content.addSubview(emptyButton); content.addSubview(countLabel)
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: content.topAnchor),
            side.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            side.widthAnchor.constraint(equalToConstant: 190),
            sideScroll.topAnchor.constraint(equalTo: side.topAnchor, constant: 8),
            sideScroll.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            sideScroll.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            sideScroll.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -4),
            countLabel.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 14),
            countLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -16),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -16),
            emptyButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 10),
            emptyButton.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
        ])
        sourceList.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    // MARK: Data

    func select(_ s: Section) {
        section = s
        sourceList.selectRowIndexes(IndexSet(integer: s.rawValue), byExtendingSelection: false)
        reload()
    }

    var searchIsBelowWindowTabs: Bool {
        guard let window, let content = window.contentView else { return false }
        content.layoutSubtreeIfNeeded()
        let frame = search.convert(search.bounds, to: nil)
        return frame.width > 100 && window.contentLayoutRect.contains(frame)
    }

    func setSearchForTests(_ q: String) { search.stringValue = q; reload() }

    func controlTextDidChange(_ obj: Notification) { reload() }

    /// Every item of a kind (search applied by the caller).
    private func load(_ s: Section) -> [Item] {
        guard let pane else { return [] }
        let cwd = pane.session.isRemote ? NSHomeDirectory() : pane.session.cwd
        switch s {
        case .everything:
            return []
        case .notebook:
            let nb = (try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook()
            return nb.groups.flatMap { g in g.entries.map { e in
                Item(section: .notebook, title: e.displayTitle, detail: (nb.groups.count > 1 ? g.name + " · " : "") + e.command.replacingOccurrences(of: "\n", with: " ⏎ "),
                     symbol: s.symbol, primaryTitle: "Put in Editor", primary: { [weak pane] in pane?.insertIntoEditor(e.command); pane?.window?.makeKeyAndOrderFront(nil) },
                     actions: [("Run", { [weak pane] in pane?.insertIntoEditor(e.command, run: true) }),
                               ("Edit in Notebook", { NotebookWindow.shared.show(); NotebookWindow.shared.selectEntry(e.id) }),
                               ("Copy", { TerminalWindowController.copy(e.command) })])
            } } + WorkflowStore.load(cwd: cwd).map { w in
                // Workflows are notebook entries with several steps.
                Item(section: .notebook, title: w.name, detail: (w.source == .project ? "This project" : "Workflows") + " · \(w.steps.count) step\(w.steps.count == 1 ? "" : "s") · " + (w.description ?? w.steps.first ?? ""),
                     symbol: "list.bullet.rectangle", primaryTitle: "Run…", primary: { [weak pane] in
                        guard let pane else { return }
                        pane.windowController?.startWorkflow(w, in: pane)
                        pane.window?.makeKeyAndOrderFront(nil)
                     },
                     actions: [("Put in Editor", { [weak pane] in if let pane { pane.windowController?.startWorkflow(w, in: pane, insertOnly: true) } }),
                               ("Show File", { if let f = w.file { NSWorkspace.shared.activateFileViewerSelecting([f]) } })])
            }
        case .runbooks:
            return Runbook.load(cwd: cwd).map { r in
                Item(section: .runbooks, title: r.title, detail: (r.source == .project ? "project · " : "") + "\(r.steps.count) step\(r.steps.count == 1 ? "" : "s")" + (r.intro.isEmpty ? "" : " · " + r.intro.prefix(80)),
                     symbol: s.symbol, primaryTitle: "Open", primary: { [weak pane] in if let pane { RunbookWindowController.show(r, pane: pane) } },
                     actions: [("Show File", { if let f = r.file { NSWorkspace.shared.activateFileViewerSelecting([f]) } })])
            }
        case .aliases:
            let book = AliasManager.load()
            var out = book.aliases.map { a in
                Item(section: .aliases, title: a.name, detail: (a.group.map { $0 + " · " } ?? "") + a.command, symbol: s.symbol, primaryTitle: "Put in Editor",
                     primary: { [weak pane] in pane?.insertIntoEditor(a.name + " "); pane?.window?.makeKeyAndOrderFront(nil) },
                     actions: [("Edit…", { [weak self, weak pane] in AliasManager.edit(a, over: self?.window, pane: pane) })])
            }
            let mine = Set(book.aliases.map(\.name))
            out += pane.session.env.aliases.filter { !mine.contains($0.key) }.sorted { $0.key < $1.key }.map { name, value in
                Item(section: .aliases, title: name, detail: "from your shell setup · " + value, symbol: s.symbol, primaryTitle: "Put in Editor",
                     primary: { [weak pane] in pane?.insertIntoEditor(name + " ") })
            }
            return out
        case .history:
            let q = search.stringValue.trimmingCharacters(in: .whitespaces)
            let hits = Services.shared.history.search(q, scope: .all, cwd: cwd, limit: 150).map(\.0)
            return hits.map { c in
                Item(section: .history, title: c.command.replacingOccurrences(of: "\n", with: " ⏎ "),
                     detail: "\(c.count)× · " + RelativeTime.format(c.lastUsed) + (c.lastCwd.map { " · " + PathDisplay.short($0, max: 30) } ?? ""),
                     symbol: s.symbol, primaryTitle: "Put in Editor", primary: { [weak pane] in pane?.insertIntoEditor(c.command); pane?.window?.makeKeyAndOrderFront(nil) },
                     actions: [("Run", { [weak pane] in pane?.insertIntoEditor(c.command, run: true) }),
                               ("Save to Notebook…", { [weak self] in NotebookSaver.save([c.command], over: self?.window) { _ in self?.reload() } }),
                               ("Open in History Editor", { [weak pane] in HistoryEditorWindowController.shared.show(for: pane, select: c.command) })])
            }
        case .recordings:
            let files = ((try? FileManager.default.contentsOfDirectory(at: RecordingStore.directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
                .filter { $0.pathExtension == "anserrec" }
                .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
            return files.map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0 ?? 0), countStyle: .file) } ?? ""
                return Item(section: .recordings, title: url.deletingPathExtension().lastPathComponent, detail: size, symbol: s.symbol, primaryTitle: "Replay",
                            primary: {
                                if let r = try? TabRecording.decode(Data(contentsOf: url)) { ReplayWindowController.show(r, file: url) }
                            },
                            actions: [("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
                                      ("Move to Trash", { [weak self] in NSWorkspace.shared.recycle([url]) { _, _ in DispatchQueue.main.async { self?.reload() } } })])
            }
        case .watches:
            return OutputWatchManager.shared.watches.map { w in
                Item(section: .watches, title: w.command, detail: "every \(Int(w.intervalMinutes)) min · \(w.runs) runs · \(w.changes) changes", symbol: s.symbol,
                     primaryTitle: "Show Output", primary: { [weak self] in OutputWatchManager.shared.showChange(w, over: self?.window) },
                     actions: [("Run Now", { OutputWatchManager.shared.run(w.id) }), ("Stop Watching", { [weak self] in OutputWatchManager.shared.remove(w.id); self?.reload() })])
            }
        }
    }

    func reload() {
        let words = search.stringValue.lowercased().split(separator: " ").map(String.init)
        func matches(_ i: Item) -> Bool {
            guard !words.isEmpty else { return true }
            let hay = (i.title + " " + i.detail).lowercased()
            return words.allSatisfy(hay.contains)
        }
        counts = [:]
        var all: [Item] = []
        for s in Section.allCases where s != .everything {
            // History only joins "Everything" when you search, so it doesn't swamp the rest.
            if section == .everything, s == .history, words.isEmpty { counts[s] = nil; continue }
            guard section == .everything || section == s else { continue }
            let list = load(s).filter(matches)
            counts[s] = list.count
            all += section == .everything && s == .history ? Array(list.prefix(20)) : list
        }
        items = all
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        sourceList.reloadData(forRowIndexes: IndexSet(integersIn: 0..<Section.allCases.count), columnIndexes: IndexSet(integer: 0))
        let isEmpty = items.isEmpty
        emptyLabel.isHidden = !isEmpty
        emptyButton.isHidden = !isEmpty || section == .everything
        emptyLabel.stringValue = words.isEmpty ? section.empty : "Nothing matches “\(search.stringValue)”."
        emptyButton.title = manageTitle
        manageButton.title = manageTitle
        manageButton.isHidden = section == .everything
        countLabel.stringValue = isEmpty ? "" : "\(items.count) item\(items.count == 1 ? "" : "s")" + (section == .everything && words.isEmpty ? " · type to search history too" : "")
        updateButtons()
    }

    private var manageTitle: String {
        switch section {
        case .notebook: "Open Notebook"
        case .runbooks: "New Runbook…"
        case .aliases: "Open Aliases"
        case .history: "Open History Editor"
        case .recordings: "Open Recordings Folder"
        case .watches: "Watch a Command…"
        case .everything: "Manage…"
        }
    }

    private func updateButtons() {
        let r = table.selectedRow
        if items.indices.contains(r) {
            primaryButton.title = items[r].primaryTitle
            primaryButton.isEnabled = true
        } else {
            primaryButton.title = "Open"
            primaryButton.isEnabled = false
        }
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === sourceList ? Section.allCases.count : items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sourceList {
            let s = Section.allCases[row]
            let icon = NSImageView(image: NSImage(systemSymbolName: s.symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .controlAccentColor
            let label = NSTextField(labelWithString: s.title)
            let count = NSTextField(labelWithString: counts[s].map { String($0) } ?? "")
            count.textColor = .secondaryLabelColor
            count.font = .systemFont(ofSize: 11)
            let v = NSStackView(views: [icon, label, NSView(), count])
            v.spacing = 6
            v.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
            return v
        }
        let it = items[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: it.symbol, accessibilityDescription: it.section.title) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: it.title)
        title.font = it.section == .history || it.section == .aliases || it.section == .watches ? .monospacedSystemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: (section == .everything ? it.section.title + " · " : "") + it.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let v = NSStackView(views: [icon, text])
        v.spacing = 10
        v.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        v.toolTip = it.title + "\n" + it.detail
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let t = notification.object as? NSTableView else { return }
        if t === sourceList {
            let r = sourceList.selectedRow
            guard let s = Section(rawValue: r), s != section else { return }
            section = s
            reload()
        } else {
            updateButtons()
        }
    }

    // MARK: Actions

    @objc func primaryTapped() {
        let r = table.selectedRow
        guard items.indices.contains(r) else { NSSound.beep(); return }
        Services.shared.record("library.use." + "\(items[r].section)")
        items[r].primary()
    }

    @objc private func manageTapped() {
        guard let pane else { return }
        switch section {
        case .notebook: NotebookWindow.shared.show()
        case .runbooks: pane.newRunbook()
        case .aliases: AliasesWindowController.shared.show(for: pane)
        case .history: HistoryEditorWindowController.shared.show(for: pane)
        case .recordings:
            try? FileManager.default.createDirectory(at: RecordingStore.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(RecordingStore.directory)
        case .watches: pane.promptOutputWatch()
        case .everything: break
        }
    }
}

extension LibraryWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard items.indices.contains(r) else { return }
        let it = items[r]
        menu.addItem(ClosureMenuItem(title: it.primaryTitle, action: it.primary))
        for a in it.actions { menu.addItem(ClosureMenuItem(title: a.title, action: a.run)) }
    }
}

/// The Library is the one window for managing saved things: the Notebook,
/// Aliases, History and Secrets editors open as its tabs instead of as
/// windows of their own.
@MainActor enum LibraryTabs {
    static let identifier = "AnserLibrary"

    /// Puts `w` in the Library window as a tab, opening the Library first if needed.
    static func host(_ w: NSWindow, pane: PaneView?) {
        w.tabbingIdentifier = identifier
        w.tabbingMode = .preferred
        let lib = LibraryWindowController.shared
        guard let lw = lib.window, lw !== w else { return }
        if lw.tabbedWindows?.contains(where: { $0 === w }) == true { return }
        if !lw.isVisible { lib.show(for: pane) }
        lw.addTabbedWindow(w, ordered: .above)
    }

    /// Whether `w` is a tab of the Library window (tests).
    static func isHosted(_ w: NSWindow?) -> Bool {
        guard let w, let lw = LibraryWindowController.shared.window else { return false }
        return lw.tabbedWindows?.contains { $0 === w } == true
    }
}
