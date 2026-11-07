import AppKit
import AnserCore

extension Notification.Name {
    static let anserNotebookChanged = Notification.Name("AnserNotebookChanged")
}

/// Tools → Command Notebook (⌥⌘N): saved commands in groups. Pick one and
/// paste it into the terminal you were using, run it, or copy it.
/// Floats above the terminal windows so it stays handy while you work.
@MainActor
final class NotebookWindow: NSPanel, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSSearchFieldDelegate {
    static let shared = NotebookWindow()

    /// Where the notebook is saved (a test can point it elsewhere).
    /// Read and changed only on the main thread (Services points it at the chosen location).
    nonisolated(unsafe) static var fileURL = Notebook.defaultURL

    private(set) var notebook = Notebook()
    private var loadError: String?

    /// Outline rows need stable objects; rebuilt on every reload.
    final class Node {
        let group: UUID
        let entry: UUID?
        var children: [Node] = []
        init(group: UUID, entry: UUID?) { self.group = group; self.entry = entry }
    }
    private var roots: [Node] = []

    private let search = NSSearchField()
    private let outline = NSOutlineView()
    private let titleField = NSTextField()
    private let groupPopup = NSPopUpButton()
    private let commandView = NSTextView()
    private let noteField = NSTextField()
    private let pasteButton = NSButton(title: "Paste into Terminal", target: nil, action: nil)
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let detail = NSView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let groupNameField = NSTextField()
    private var saveTimer: Timer?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        title = "Command Notebook"
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 560, height: 320)
        setFrameAutosaveName("AnserNotebook")
        build()
        reloadFromDisk()
    }

    // MARK: Opening

    static func toggle() {
        let w = shared
        if w.isVisible && w.isKeyWindow { w.close() } else { w.show() }
    }

    func show() {
        if !isVisible { reloadFromDisk(); if frameAutosaveName.isEmpty || frame.origin == .zero { center() } }
        makeKeyAndOrderFront(nil)
        if selectedEntryID == nil, let first = roots.first?.children.first { select(first) }
    }

    /// Saves `command` as a new entry and opens the notebook with its title ready to type.
    func add(command: String, title: String = "") {
        reloadFromDisk()
        let group = selectedGroupID ?? notebook.groups.first?.id
        let id = notebook.add(.init(title: title, command: command), to: group)
        changed()
        saveNow()   // show() reloads from disk when the window was closed
        show()
        selectEntry(id)
        makeFirstResponder(titleField)
    }

    // MARK: Layout

    private func build() {
        let root = NSView()
        contentView = root

        search.placeholderString = "Search commands"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        let col = NSTableColumn(identifier: .init("c"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(pasteSelected)
        outline.setAccessibilityLabel("Saved commands")
        let listScroll = NSScrollView()
        listScroll.documentView = outline
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: self, action: #selector(addMenu(_:)))
        add.toolTip = "New command or group"
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Delete")!, target: self, action: #selector(deleteSelected))
        remove.toolTip = "Delete the selected command or group"
        let openFile = NSButton(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Open file")!, target: self, action: #selector(revealFile))
        openFile.toolTip = "Show notebook.json in Finder"
        for b in [add, remove, openFile] { b.bezelStyle = .smallSquare; b.isBordered = false }

        let left = NSStackView(views: [search, listScroll, NSStackView(views: [add, remove, NSView(), openFile])])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        left.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 8, right: 6)
        for v in left.arrangedSubviews { v.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -16).isActive = true }

        // Right side: the selected command.
        titleField.placeholderString = "Name (e.g. Deploy to staging)"
        titleField.delegate = self
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        groupPopup.target = self
        groupPopup.action = #selector(moveToGroup(_:))
        groupPopup.toolTip = "Group"
        commandView.isRichText = false
        commandView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        commandView.isAutomaticQuoteSubstitutionEnabled = false
        commandView.isAutomaticDashSubstitutionEnabled = false
        commandView.isAutomaticTextReplacementEnabled = false
        commandView.isContinuousSpellCheckingEnabled = false
        commandView.allowsUndo = true
        commandView.delegate = self
        commandView.textContainerInset = NSSize(width: 6, height: 6)
        commandView.setAccessibilityLabel("Command")
        let cmdScroll = NSScrollView()
        cmdScroll.documentView = commandView
        cmdScroll.hasVerticalScroller = true
        cmdScroll.borderType = .bezelBorder
        commandView.autoresizingMask = [.width]
        commandView.isVerticallyResizable = true
        noteField.placeholderString = "Note (optional): when to use it, what it needs"
        noteField.delegate = self
        let tip = NSTextField(labelWithString: "{{name}} marks a value to fill in: Tab jumps between them in the editor.")
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor

        pasteButton.target = self; pasteButton.action = #selector(pasteSelected)
        pasteButton.keyEquivalent = "\r"; pasteButton.keyEquivalentModifierMask = .command
        pasteButton.bezelStyle = .rounded
        pasteButton.toolTip = "Put it in the command editor of the terminal you were using (⌘↩)"
        runButton.target = self; runButton.action = #selector(runSelected)
        runButton.keyEquivalent = "\r"; runButton.keyEquivalentModifierMask = [.command, .shift]
        runButton.toolTip = "Run it in that terminal now (⇧⌘↩)"
        copyButton.target = self; copyButton.action = #selector(copySelected)
        copyButton.toolTip = "Copy to the clipboard"

        let header = NSStackView(views: [titleField, groupPopup])
        header.spacing = 8
        let actions = NSStackView(views: [copyButton, NSView(), runButton, pasteButton])
        actions.spacing = 8
        let form = NSStackView(views: [header, cmdScroll, tip, noteField, actions])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        for v in form.arrangedSubviews { v.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        cmdScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        cmdScroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        // Shown when a group (not a command) is selected.
        groupNameField.delegate = self
        groupNameField.font = .systemFont(ofSize: 14, weight: .semibold)
        groupNameField.placeholderString = "Group name"
        emptyLabel.textColor = .secondaryLabelColor

        for v in [form, groupNameField, emptyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detail.addSubview(v)
        }
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: detail.topAnchor, constant: 12),
            form.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 8),
            form.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -14),
            form.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -12),
            groupNameField.topAnchor.constraint(equalTo: detail.topAnchor, constant: 12),
            groupNameField.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 8),
            groupNameField.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -14),
            emptyLabel.topAnchor.constraint(equalTo: groupNameField.bottomAnchor, constant: 10),
            emptyLabel.leadingAnchor.constraint(equalTo: groupNameField.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: groupNameField.trailingAnchor),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(detail)
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            left.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        left.widthAnchor.constraint(equalToConstant: 260).priority = .defaultLow
        showDetail()
    }

    // MARK: Data

    func reloadFromDisk() {
        do {
            notebook = try Notebook.load(from: Self.fileURL)
            loadError = nil
        } catch {
            // Never overwrite a file we couldn't read; say so instead.
            loadError = "Couldn't read \(Self.fileURL.lastPathComponent): \(error.localizedDescription)"
        }
        rebuildTree()
    }

    private func rebuildTree(keep: UUID? = nil) {
        let keepID = keep ?? selectedEntryID ?? selectedGroupID
        roots = notebook.filtered(search.stringValue).map { g in
            let n = Node(group: g.id, entry: nil)
            n.children = g.entries.map { Node(group: g.id, entry: $0.id) }
            return n
        }
        outline.reloadData()
        roots.forEach { outline.expandItem($0) }
        if let keepID, let node = node(for: keepID) { select(node) } else { showDetail() }
        groupPopup.removeAllItems()
        for g in notebook.groups { groupPopup.addItem(withTitle: g.name); groupPopup.lastItem?.representedObject = g.id }
    }

    private func node(for id: UUID) -> Node? {
        for r in roots {
            if r.group == id { return r }
            if let c = r.children.first(where: { $0.entry == id }) { return c }
        }
        return nil
    }

    /// Unsaved edits (so a sync from elsewhere never overwrites them, and an
    /// untouched notebook is never written back over a newer synced copy).
    private var dirty = false

    /// The file changed outside Anser (iCloud, git, another Mac): show the new contents unless mid-edit.
    func reloadIfIdle() {
        guard isVisible, !dirty else { return }
        reloadFromDisk()
    }

    /// Something changed: save soon, and let the sidebar update.
    private func changed() {
        dirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        NotificationCenter.default.post(name: .anserNotebookChanged, object: nil)
    }

    func saveNow() {
        saveTimer?.invalidate()
        guard loadError == nil, dirty else { return }
        dirty = false
        do {
            try notebook.save(to: Self.fileURL)
            Services.shared.notebookSaved()
        } catch {
            NSAlert(error: error).beginSheetModal(for: self)
        }
    }

    override func close() { saveNow(); super.close() }

    // MARK: Selection

    private var selectedNode: Node? { outline.item(atRow: outline.selectedRow) as? Node }
    var selectedEntryID: UUID? { selectedNode?.entry }
    var selectedGroupID: UUID? { selectedNode?.group }
    var selectedEntry: Notebook.Entry? { selectedEntryID.flatMap(notebook.entry) }

    private func select(_ node: Node) {
        let row = outline.row(forItem: node)
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row) }
        showDetail()
    }

    func selectEntry(_ id: UUID) { if let n = node(for: id) { select(n) } }

    func outlineViewSelectionDidChange(_ notification: Notification) { showDetail() }

    private func showDetail() {
        let form = detail.subviews.first { $0 is NSStackView }
        if let e = selectedEntry {
            form?.isHidden = false
            groupNameField.isHidden = true
            emptyLabel.isHidden = true
            if titleField.stringValue != e.title { titleField.stringValue = e.title }
            if commandView.string != e.command { commandView.string = e.command }
            if noteField.stringValue != e.note { noteField.stringValue = e.note }
            if let g = selectedGroupID, let i = notebook.groupIndex(g) { groupPopup.selectItem(at: i) }
        } else {
            form?.isHidden = true
            groupNameField.isHidden = selectedGroupID == nil
            emptyLabel.isHidden = false
            if let g = selectedGroupID, let i = notebook.groupIndex(g) {
                groupNameField.stringValue = notebook.groups[i].name
                let n = notebook.groups[i].entries.count
                emptyLabel.stringValue = n == 0
                    ? "No commands here yet. Click + → New Command, or save one from a terminal with Tools → Save Command to Notebook (⌥⌘S)."
                    : "\(n) command\(n == 1 ? "" : "s"). Rename the group above, or pick a command to edit it."
            } else {
                emptyLabel.stringValue = loadError ?? (notebook.entryCount == 0
                    ? "Save commands you reuse, in groups.\n\nClick + to add one, or use Tools → Save Command to Notebook (⌥⌘S) from a terminal."
                    : "Pick a command.")
            }
        }
    }

    // MARK: Editing

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === search { rebuildTree(); return }
        if field === groupNameField, let g = selectedGroupID {
            notebook.renameGroup(g, to: field.stringValue)
            outline.reloadItem(selectedNode)
            groupPopup.item(at: notebook.groupIndex(g) ?? 0)?.title = field.stringValue
            changed()
            return
        }
        guard var e = selectedEntry else { return }
        if field === titleField { e.title = field.stringValue }
        if field === noteField { e.note = field.stringValue }
        notebook.update(e)
        outline.reloadItem(selectedNode)
        changed()
    }

    func textDidChange(_ notification: Notification) {
        guard var e = selectedEntry else { return }
        e.command = commandView.string
        notebook.update(e)
        outline.reloadItem(selectedNode)
        changed()
    }

    @objc private func addMenu(_ sender: NSButton) {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "New Command") { [weak self] in self?.newCommand() })
        m.addItem(ClosureMenuItem(title: "New Group") { [weak self] in self?.newGroup() })
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    func newCommand() {
        let id = notebook.add(.init(title: "", command: ""), to: selectedGroupID)
        search.stringValue = ""
        changed()
        rebuildTree(keep: id)
        makeFirstResponder(commandView)
    }

    func newGroup() {
        let id = notebook.addGroup(named: "New group")
        search.stringValue = ""
        changed()
        rebuildTree(keep: id)
        makeFirstResponder(groupNameField)
        groupNameField.currentEditor()?.selectAll(nil)
    }

    @objc private func moveToGroup(_ sender: NSPopUpButton) {
        guard let e = selectedEntryID, let g = sender.selectedItem?.representedObject as? UUID else { return }
        notebook.move(e, to: g)
        changed()
        rebuildTree(keep: e)
    }

    @objc func deleteSelected() {
        if let e = selectedEntryID {
            notebook.removeEntry(e)
            changed()
            rebuildTree()
        } else if let g = selectedGroupID, let i = notebook.groupIndex(g) {
            let group = notebook.groups[i]
            let remove = { [weak self] in
                guard let self else { return }
                self.notebook.removeGroup(g)
                self.changed()
                self.rebuildTree()
            }
            if group.entries.isEmpty { remove(); return }
            let a = NSAlert()
            a.messageText = "Delete the group “\(group.name)”?"
            a.informativeText = "Its \(group.entries.count) command\(group.entries.count == 1 ? "" : "s") move to “\(notebook.groups.first { $0.id != g }?.name ?? "General")”."
            a.addButton(withTitle: "Delete Group")
            a.addButton(withTitle: "Cancel")
            a.beginSheetModal(for: self) { if $0 == .alertFirstButtonReturn { remove() } }
        }
    }

    @objc private func revealFile() {
        saveNow()
        NSWorkspace.shared.activateFileViewerSelecting([Self.fileURL])
    }

    // MARK: Using a command

    /// The terminal pane the notebook acts on: the focused pane of the front terminal window.
    private var targetPane: PaneView? { AppDelegate.shared.currentPane }

    @objc func pasteSelected() {
        guard let cmd = selectedEntry?.command, !cmd.isEmpty, let pane = targetPane else { NSSound.beep(); return }
        pane.insertIntoEditor(cmd)
        pane.window?.makeKeyAndOrderFront(nil)
        pane.focus()
    }

    @objc private func runSelected() {
        guard let e = selectedEntry, !e.command.isEmpty, let pane = targetPane else { NSSound.beep(); return }
        pane.window?.makeKeyAndOrderFront(nil)
        // Values to fill in ({{name}}) are asked for first, like a workflow.
        pane.windowController?.runNotebookEntry(e, in: pane)
    }

    @objc private func copySelected() {
        guard let cmd = selectedEntry?.command, !cmd.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51, firstResponder === outline { deleteSelected(); return }   // ⌫ in the list
        super.keyDown(with: event)
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.entry == nil }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        if let id = n.entry, let e = notebook.entry(id) {
            icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            label.stringValue = e.displayTitle
            label.font = e.title.isEmpty ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 13)
            cell.toolTip = e.command
        } else if let i = notebook.groupIndex(n.group) {
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            label.stringValue = "\(notebook.groups[i].name)  ·  \(notebook.groups[i].entries.count)"
            label.font = .systemFont(ofSize: 12, weight: .semibold)
        }
        for v in [icon, label] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: For tests

    var titles: [String] { roots.flatMap { r in r.children.compactMap { $0.entry.flatMap(notebook.entry)?.displayTitle } } }
    func setSearch(_ q: String) { search.stringValue = q; rebuildTree() }
    func selectFirstEntry() { if let n = roots.first(where: { !$0.children.isEmpty })?.children.first { select(n) } }
}
