import AppKit
import AnserCore

/// "Save to Notebook" for commands picked from history (History Editor, history search).
@MainActor
enum NotebookSaver {
    /// Asks for a title (one command) and a group, then saves. `done` gets how many were added.
    static func save(_ commands: [String], over window: NSWindow?, done: ((Int) -> Void)? = nil) {
        let list = commands.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !list.isEmpty else { NSSound.beep(); return }
        let notebook = (try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook.starter
        let already = list.filter { notebook.contains(command: $0) }
        let a = NSAlert()
        a.messageText = list.count == 1 ? "Save to Notebook" : "Save \(list.count) commands to the Notebook"
        a.informativeText = list.count == 1 ? list[0].prefix(300) + "" : "Each becomes a notebook entry, titled with its command (rename them in the Notebook)."
            + (already.isEmpty ? "" : "\n\(already.count) \(already.count == 1 ? "is" : "are") already in the notebook and will be skipped.")
        let title = NSTextField()
        title.placeholderString = "Title (optional), e.g. Deploy to staging"
        let group = NSComboBox()
        group.addItems(withObjectValues: notebook.groups.map(\.name))
        group.stringValue = notebook.groups.first?.name ?? "General"
        group.completes = true
        group.toolTip = "Pick a group, or type a new name to make one"
        for v in [title, group] as [NSView] { v.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        var rows: [[NSView]] = []
        if list.count == 1 { rows.append([NSTextField(labelWithString: "Title:"), title]) }
        rows.append([NSTextField(labelWithString: "Group:"), group])
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 380, height: CGFloat(rows.count) * 32)
        a.accessoryView = grid
        a.window.initialFirstResponder = list.count == 1 ? title : group
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let handle = { (r: NSApplication.ModalResponse) in
            guard r == .alertFirstButtonReturn else { return }
            let t = title.stringValue.trimmingCharacters(in: .whitespaces)
            let n = add(list.map { (command: $0, title: list.count == 1 ? t : "") }, group: group.stringValue)
            done?(n)
        }
        if let window { a.beginSheetModal(for: window, completionHandler: handle) } else { handle(a.runModal()) }
    }

    /// Saves without asking. Returns how many were added (commands already saved are skipped).
    @discardableResult
    static func add(_ items: [(command: String, title: String)], group: String) -> Int {
        var nb = (try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook.starter
        let n = nb.addFromHistory(items, toGroupNamed: group)
        guard n > 0 else { return 0 }
        do { try nb.save(to: NotebookWindow.fileURL) } catch { NSSound.beep(); return 0 }
        NotebookWindow.shared.reloadFromDisk()
        NotificationCenter.default.post(name: .anserNotebookChanged, object: nil)
        Services.shared.record("notebook.fromHistory")
        return n
    }
}
