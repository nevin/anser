import AppKit
import AnserCore

// MARK: Compare with previous run

extension PaneView {
    /// The most recent block with output (for the menu and palette actions).
    var lastBlockIndexWithOutput: Int? {
        session.blocks.indices.last { !session.blocks[$0].command.isEmpty }
    }

    func compareWithPreviousRun(block i: Int) {
        guard session.blocks.indices.contains(i) else { NSSound.beep(); return }
        let b = session.blocks[i]
        let current = output(ofBlock: i) ?? (b.historyID > 0 ? Services.shared.history.output(forHistoryID: b.historyID) : nil) ?? ""
        // An earlier run in this tab first, then history.
        var previous: (output: String, started: Date, exit: Int?)?
        if let j = session.blocks.indices.last(where: { $0 < i && session.blocks[$0].command == b.command }), let out = output(ofBlock: j) {
            previous = (out, session.blocks[j].started, session.blocks[j].exitCode)
        } else if let hit = Services.shared.history.previousRun(of: b.command, beforeID: b.historyID > 0 ? b.historyID : 0),
                  hit.entry.id != b.historyID {
            previous = (hit.output, hit.entry.started, hit.entry.exitCode)
        }
        guard let prev = previous else {
            flash("No earlier run of this command with saved output")
            return
        }
        Services.shared.record("output.compare")
        DiffViewer(command: b.command, old: prev.output, new: current, oldDate: prev.started, oldExit: prev.exit, newExit: b.exitCode).show(over: window)
    }

    func viewOutputAsData(block i: Int) {
        guard session.blocks.indices.contains(i) else { NSSound.beep(); return }
        let b = session.blocks[i]
        let out = output(ofBlock: i) ?? (b.historyID > 0 ? Services.shared.history.output(forHistoryID: b.historyID) : nil) ?? ""
        guard let kind = StructuredOutput.detect(out) else {
            flash("This output isn't JSON, CSV or a table")
            return
        }
        Services.shared.record("output.data")
        DataViewer(command: b.command, kind: kind).show(over: window)
    }
}

/// Two runs of a command side by side as one list: removed lines in red, added in green.
final class DiffViewer: NSPanel {
    private static var open: [DiffViewer] = []
    private let textView = NSTextView()
    private let summary = NSTextField(labelWithString: "")
    private let ignoreNumbers = NSButton(checkboxWithTitle: "Ignore numbers and times", target: nil, action: nil)
    private let changesOnly = NSButton(checkboxWithTitle: "Changes only", target: nil, action: nil)
    private let old: String, new: String
    private let oldDate: Date
    private(set) var lastSummary = LineDiff.Summary()

    init(command: String, old: String, new: String, oldDate: Date, oldExit: Int?, newExit: Int?) {
        self.old = old; self.new = new; self.oldDate = oldDate
        super.init(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable, .utilityWindow], backing: .buffered, defer: false)
        title = "Compare: " + command.replacingOccurrences(of: "\n", with: " ")
        isReleasedWhenClosed = false
        let t = GhosttyRuntime.shared.theme
        appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        for b in [ignoreNumbers, changesOnly] { b.target = self; b.action = #selector(reload); b.font = .systemFont(ofSize: 11) }
        ignoreNumbers.state = .on
        let exitNote: (Int?) -> String = { $0.map { $0 == 0 ? "ok" : "exit \($0)" } ?? "?" }
        let when = RelativeDateTimeFormatter().localizedString(for: oldDate, relativeTo: Date())
        let header = NSTextField(labelWithString: "Previous run \(when) (\(exitNote(oldExit)))  →  this run (\(exitNote(newExit)))")
        header.font = .systemFont(ofSize: 11, weight: .medium)
        let top = NSStackView(views: [header, NSView(), changesOnly, ignoreNumbers])
        top.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 12)
        let bottom = NSStackView(views: [summary, NSView()])
        bottom.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 8, right: 12)

        textView.isEditable = false
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = t.background
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let stack = NSStackView(views: [top, scroll, bottom])
        stack.orientation = .vertical
        stack.spacing = 0
        contentView = stack
        reload()
    }

    @objc private func reload() {
        let t = GhosttyRuntime.shared.theme
        let lines = LineDiff.diff(old, new, ignoreNumbers: ignoreNumbers.state == .on)
        lastSummary = LineDiff.summary(lines)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        let only = changesOnly.state == .on
        var skipped = 0
        for (n, l) in lines.enumerated() {
            if only, l.kind == .same {
                // Keep one line of context around changes.
                let near = (n > 0 && lines[n - 1].kind != .same) || (n + 1 < lines.count && lines[n + 1].kind != .same)
                if !near { skipped += 1; continue }
            }
            if skipped > 0 {
                out.append(NSAttributedString(string: "   ⋯ \(skipped) unchanged line\(skipped == 1 ? "" : "s")\n",
                                              attributes: [.font: font, .foregroundColor: t.dim]))
                skipped = 0
            }
            let (mark, fg, bg): (String, NSColor, NSColor?) = {
                switch l.kind {
                case .same: return ("  ", t.foreground.withAlphaComponent(0.75), nil)
                case .removed: return ("− ", t.red, t.red.withAlphaComponent(0.12))
                case .added: return ("+ ", t.green, t.green.withAlphaComponent(0.12))
                }
            }()
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
            if let bg { attrs[.backgroundColor] = bg }
            out.append(NSAttributedString(string: mark + l.text + "\n", attributes: attrs))
        }
        if skipped > 0 {
            out.append(NSAttributedString(string: "   ⋯ \(skipped) unchanged line\(skipped == 1 ? "" : "s")\n", attributes: [.font: font, .foregroundColor: t.dim]))
        }
        textView.textStorage?.setAttributedString(out)
        let s = lastSummary
        summary.stringValue = s.identical ? "Same output as the previous run" : "\(s.added) line\(s.added == 1 ? "" : "s") added · \(s.removed) removed"
    }

    func show(over parent: NSWindow?) {
        Self.open.append(self)
        if let f = parent?.frame { setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY - frame.height / 2)) } else { center() }
        makeKeyAndOrderFront(nil)
    }

    override func close() { super.close(); Self.open.removeAll { $0 === self } }
    override func cancelOperation(_ sender: Any?) { close() }
    static var openViewers: [DiffViewer] { open }
}

// MARK: Table / JSON viewer

/// JSON as a tree, or a table you can sort by any column and filter.
final class DataViewer: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    private static var open: [DataViewer] = []
    private var table: StructuredOutput.Table?
    private var json: StructuredOutput.JSON?
    private var rows: [[String]] = []
    private let tableView = NSTableView()
    private let outline = NSOutlineView()
    private let search = NSSearchField()
    private let info = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private var nodes: [ObjectIdentifier: Node] = [:]
    private var rootNode: Node?

    /// Outline items must be objects.
    final class Node {
        let key: String
        let value: StructuredOutput.JSON
        lazy var children: [Node] = value.children.map { Node(key: $0.0, value: $0.1) }
        init(key: String, value: StructuredOutput.JSON) { self.key = key; self.value = value }
    }

    init(command: String, kind: StructuredOutput.Kind) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable, .utilityWindow], backing: .buffered, defer: false)
        title = command.replacingOccurrences(of: "\n", with: " ")
        isReleasedWhenClosed = false
        let t = GhosttyRuntime.shared.theme
        appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        search.placeholderString = "Filter rows"
        search.delegate = self
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        let copy = ClosureButton(title: "Copy as CSV") { [weak self] in self?.copyCSV() }
        var topViews: [NSView] = [search, info, NSView()]
        switch kind {
        case .json(let j):
            json = j
            if let tbl = StructuredOutput.table(from: j) {
                table = tbl
                let toggle = ClosureButton(title: "Show as Tree") { [weak self] in self?.toggleTree() }
                topViews.append(toggle)
            }
        case .table(let tbl, _):
            table = tbl
        }
        if table != nil { topViews.append(copy) }
        let top = NSStackView(views: topViews)
        top.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let stack = NSStackView(views: [top, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        contentView = stack
        if table != nil { showTable() } else { showTree() }
    }

    private var showingTree = false

    private func toggleTree() { if showingTree { showTable() } else { showTree() } }

    private func showTable() {
        guard let table else { return }
        showingTree = false
        search.isHidden = false
        tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
        for (i, h) in table.headers.enumerated() {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            c.title = h
            c.width = max(70, min(320, CGFloat(max(h.count, table.rows.prefix(50).map { i < $0.count ? $0[i].count : 0 }.max() ?? 0)) * 7.5 + 16))
            c.sortDescriptorPrototype = NSSortDescriptor(key: "\(i)", ascending: true)
            tableView.addTableColumn(c)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = true
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .plain
        scroll.documentView = tableView
        filter()
    }

    private func showTree() {
        guard let json else { return }
        showingTree = true
        search.isHidden = true
        rootNode = Node(key: "", value: json)
        outline.tableColumns.forEach { outline.removeTableColumn($0) }
        let k = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key")); k.title = "Key"; k.width = 240
        let v = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value")); v.title = "Value"; v.width = 520
        outline.addTableColumn(k)
        outline.addTableColumn(v)
        outline.outlineTableColumn = k
        outline.dataSource = self
        outline.delegate = self
        outline.usesAlternatingRowBackgroundColors = true
        scroll.documentView = outline
        outline.reloadData()
        outline.expandItem(nil, expandChildren: false)
        if let first = rootNode?.children.first, rootNode!.children.count <= 50 { outline.expandItem(first) }
        info.stringValue = json.preview
    }

    private func filter() {
        guard let table else { return }
        let q = search.stringValue.lowercased().split(separator: " ").map(String.init)
        rows = q.isEmpty ? table.rows : table.rows.filter { r in let line = r.joined(separator: " ").lowercased(); return q.allSatisfy(line.contains) }
        if let sd = tableView.sortDescriptors.first, let col = Int(sd.key ?? "") { sortRows(col, ascending: sd.ascending) }
        tableView.reloadData()
        info.stringValue = rows.count == table.rows.count ? "\(rows.count) row\(rows.count == 1 ? "" : "s")" : "\(rows.count) of \(table.rows.count) rows"
    }

    /// Numbers (and sizes like 12Mi, 3.5G) sort as numbers.
    static func numeric(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "%", with: "")
        if let d = Double(t) { return d }
        let units: [(String, Double)] = [("Ki", 1024), ("Mi", 1_048_576), ("Gi", 1_073_741_824), ("K", 1e3), ("M", 1e6), ("G", 1e9), ("KB", 1e3), ("MB", 1e6), ("GB", 1e9)]
        for (u, m) in units.sorted(by: { $0.0.count > $1.0.count }) where t.hasSuffix(u) {
            if let d = Double(t.dropLast(u.count)) { return d * m }
        }
        return nil
    }

    private func sortRows(_ col: Int, ascending: Bool) {
        rows.sort { a, b in
            let x = col < a.count ? a[col] : "", y = col < b.count ? b[col] : ""
            if let nx = Self.numeric(x), let ny = Self.numeric(y), nx != ny { return ascending ? nx < ny : nx > ny }
            let r = x.localizedStandardCompare(y)
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }

    private func copyCSV() {
        guard let table else { return }
        func esc(_ s: String) -> String { s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        let sel = tableView.selectedRowIndexes
        let chosen = sel.isEmpty ? rows : sel.map { rows[$0] }
        let csv = ([table.headers] + chosen).map { $0.map(esc).joined(separator: ",") }.joined(separator: "\n")
        TerminalWindowController.copy(csv)
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    // Table
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, let col = Int(id.dropFirst()) else { return nil }
        let text = col < rows[row].count ? rows[row][col] : ""
        let f = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: nil) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = NSUserInterfaceItemIdentifier("cell")
            f.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        f.stringValue = text
        f.toolTip = text.count > 30 ? text : nil
        f.alignment = Self.numeric(text) != nil ? .right : .left
        return f
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { filter() }

    // Outline
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? Node) ?? rootNode)?.children.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Node) ?? rootNode)!.children[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let f = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "key" ? n.key : n.value.preview)
        f.font = .monospacedSystemFont(ofSize: 11.5, weight: tableColumn?.identifier.rawValue == "key" ? .medium : .regular)
        f.lineBreakMode = .byTruncatingTail
        if tableColumn?.identifier.rawValue == "value" {
            switch n.value {
            case .string: f.textColor = .systemGreen
            case .number: f.textColor = .systemBlue
            case .bool, .null: f.textColor = .systemPurple
            default: f.textColor = .secondaryLabelColor
            }
        }
        return f
    }

    func show(over parent: NSWindow?) {
        Self.open.append(self)
        if let f = parent?.frame { setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY - frame.height / 2)) } else { center() }
        makeKeyAndOrderFront(nil)
    }

    override func close() { super.close(); Self.open.removeAll { $0 === self } }
    override func cancelOperation(_ sender: Any?) { close() }
    static var openViewers: [DataViewer] { open }
    var rowCountForTest: Int { rows.count }
    func sortForTest(column: Int, ascending: Bool) { tableView.sortDescriptors = [NSSortDescriptor(key: "\(column)", ascending: ascending)] }
    var firstRowForTest: [String]? { rows.first }
    func filterForTest(_ q: String) { search.stringValue = q; filter() }
}
