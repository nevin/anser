import AppKit

/// A small table you edit in place (double-click a cell), with + and −
/// buttons. Used in Settings for abbreviations, keybindings and profiles.
/// Rows are dictionaries keyed by column id; extra keys are kept as they are.
final class EditableTable: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let columns: [(id: String, title: String, width: CGFloat)]
    private let onChange: ([[String: Any]]) -> Void
    let table = NSTableView()

    var rows: [[String: Any]] = [] { didSet { table.reloadData() } }

    init(columns: [(String, String, CGFloat)], onChange: @escaping ([[String: Any]]) -> Void) {
        self.columns = columns.map { (id: $0.0, title: $0.1, width: $0.2) }
        self.onChange = onChange
        super.init()
        for c in self.columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    }

    /// The table in a scroll view, with + / − under it.
    func view(height: CGFloat) -> NSView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 600).isActive = true
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: self, action: #selector(addRow))
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: self, action: #selector(removeRow))
        for b in [add, remove] { b.bezelStyle = .smallSquare; b.widthAnchor.constraint(equalToConstant: 24).isActive = true }
        let buttons = NSStackView(views: [add, remove])
        buttons.spacing = 0
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        return stack
    }

    @objc func addRow() {
        rows.append(Dictionary(uniqueKeysWithValues: columns.map { ($0.id, "" as Any) }))
        let r = rows.count - 1
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.editColumn(0, row: r, with: nil, select: true)
    }

    @objc func removeRow() {
        let r = table.selectedRow
        guard rows.indices.contains(r) else { NSSound.beep(); return }
        rows.remove(at: r)
        onChange(rows)
    }

    /// Sets one cell and saves (for tests and programmatic edits).
    func set(row: Int, column: String, to value: String) {
        guard rows.indices.contains(row) else { return }
        rows[row][column] = value
        onChange(rows)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let field = NSTextField(string: rows[row][id] as? String ?? "")
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.tag = row
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let id = f.identifier?.rawValue, rows.indices.contains(f.tag) else { return }
        guard (rows[f.tag][id] as? String) != f.stringValue else { return }
        rows[f.tag][id] = f.stringValue
        onChange(rows)
    }
}
