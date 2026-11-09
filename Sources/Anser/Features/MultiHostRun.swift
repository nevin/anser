import AppKit
import AnserCore

/// Tools → Run on Several Servers…: one command on many ssh hosts at once,
/// results side by side with failures first.
final class MultiHostWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = MultiHostWindowController()

    private(set) var hosts: [String] = []
    private var checked: Set<String> = []
    private(set) var results: [String: MultiHost.Result] = [:]
    private var running: Set<String> = []
    private var started: [String: Date] = [:]

    private let groupPopup = NSPopUpButton()
    private let hostTable = NSTableView()
    private let commandField = NSTextField()
    private let runButton = NSButton()
    private let resultTable = NSTableView()
    private let detail = NSTextView()
    private let summary = NSTextField(labelWithString: "")
    /// Tests run a local command instead of ssh.
    var argvOverride: ((String, String) -> [String])?
    static let parallel = 8

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Run on Several Servers"
        w.minSize = NSSize(width: 640, height: 380)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(command: String = "") {
        reloadHosts()
        if !command.isEmpty { commandField.stringValue = command }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Services.shared.record("multihost.open")
    }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }
        groupPopup.target = self
        groupPopup.action = #selector(groupPicked)
        let saveGroup = NSButton(title: "Save as Group…", target: self, action: #selector(saveGroupTapped))
        saveGroup.controlSize = .small
        saveGroup.bezelStyle = .rounded
        let addHost = NSButton(title: "Add Host…", target: self, action: #selector(addHostTapped))
        addHost.controlSize = .small
        addHost.bezelStyle = .rounded

        let hc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        hc.title = "Hosts"
        hostTable.addTableColumn(hc)
        hostTable.headerView = nil
        hostTable.dataSource = self
        hostTable.delegate = self
        hostTable.rowHeight = 22
        let hostScroll = NSScrollView()
        hostScroll.documentView = hostTable
        hostScroll.hasVerticalScroller = true
        hostScroll.borderType = .bezelBorder
        let left = NSStackView(views: [groupPopup, hostScroll, NSStackView(views: [addHost, saveGroup])])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        left.translatesAutoresizingMaskIntoConstraints = false
        hostScroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        groupPopup.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true

        commandField.placeholderString = "Command to run on each host, e.g. uptime  or  df -h /"
        commandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandField.target = self
        commandField.action = #selector(runTapped)
        runButton.title = "Run"
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"
        runButton.target = self
        runButton.action = #selector(runTapped)
        let cmdRow = NSStackView(views: [commandField, runButton])
        cmdRow.spacing = 8

        for (id, title, width) in [("host", "Host", 160.0), ("status", "Result", 110.0), ("time", "Time", 60.0), ("first", "Output", 340.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            resultTable.addTableColumn(c)
        }
        resultTable.dataSource = self
        resultTable.delegate = self
        resultTable.rowHeight = 22
        resultTable.usesAlternatingRowBackgroundColors = true
        resultTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let resultScroll = NSScrollView()
        resultScroll.documentView = resultTable
        resultScroll.hasVerticalScroller = true
        resultScroll.borderType = .bezelBorder

        detail.isEditable = false
        detail.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detail.textContainerInset = NSSize(width: 6, height: 6)
        let detailScroll = NSScrollView()
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detail.autoresizingMask = [.width]
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        let note = NSTextField(labelWithString: "Runs with ssh in the background (key or ssh-agent needed; no password prompts), up to \(Self.parallel) hosts at a time.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(resultScroll)
        split.addArrangedSubview(detailScroll)
        let right = NSStackView(views: [cmdRow, split, summary, note])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 6
        right.translatesAutoresizingMaskIntoConstraints = false
        for v in [cmdRow, split] { v.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        content.addSubview(left)
        content.addSubview(right)
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            left.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            left.widthAnchor.constraint(equalToConstant: 200),
            right.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 12),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            right.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
    }

    // MARK: Hosts and groups

    func reloadHosts() {
        let groups = Services.shared.config.hostGroups
        var all = SSHConfig.load().map(\.alias)
        for g in groups.values { for h in g where !all.contains(h) { all.append(h) } }
        for h in hosts where !all.contains(h) { all.append(h) }
        hosts = all
        groupPopup.removeAllItems()
        groupPopup.addItem(withTitle: "Pick hosts below")
        for name in groups.keys.sorted() { groupPopup.addItem(withTitle: "Group: \(name) (\(groups[name]?.count ?? 0))") }
        hostTable.reloadData()
    }

    @objc private func groupPicked() {
        let i = groupPopup.indexOfSelectedItem - 1
        let names = Services.shared.config.hostGroups.keys.sorted()
        guard names.indices.contains(i) else { return }
        checked = Set(Services.shared.config.hostGroups[names[i]] ?? [])
        hostTable.reloadData()
    }

    func setChecked(_ list: [String]) {
        for h in list where !hosts.contains(h) { hosts.append(h) }
        checked = Set(list)
        hostTable.reloadData()
    }

    @objc private func addHostTapped() {
        let a = NSAlert()
        a.messageText = "Add a host"
        a.informativeText = "An ssh host: an alias from ~/.ssh/config, or user@host."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        a.accessoryView = f
        a.window.initialFirstResponder = f
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        guard let w = window else { return }
        a.beginSheetModal(for: w) { [weak self] r in
            let h = f.stringValue.trimmingCharacters(in: .whitespaces)
            guard let self, r == .alertFirstButtonReturn, MultiHost.argv(host: h, command: "true") != nil else { return }
            if !self.hosts.contains(h) { self.hosts.append(h) }
            self.checked.insert(h)
            self.hostTable.reloadData()
        }
    }

    @objc private func saveGroupTapped() {
        guard !checked.isEmpty, let w = window else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "Save \(checked.count) hosts as a group"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        f.placeholderString = "e.g. web servers"
        a.accessoryView = f
        a.window.initialFirstResponder = f
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            let name = f.stringValue.trimmingCharacters(in: .whitespaces)
            guard let self, r == .alertFirstButtonReturn, !name.isEmpty else { return }
            var groups = Services.shared.config.hostGroups
            groups[name] = self.hosts.filter { self.checked.contains($0) }
            SettingsWindowController.setValue(["hostGroups"], groups)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.reloadHosts() }
        }
    }

    // MARK: Running

    @objc func runTapped() {
        let cmd = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = hosts.filter { checked.contains($0) }
        guard !cmd.isEmpty, !targets.isEmpty else { NSSound.beep(); summary.stringValue = cmd.isEmpty ? "Type a command" : "Tick at least one host"; return }
        run(cmd, on: targets)
    }

    var order: [String] {
        // Failures first, then the rest in host order.
        let done = results.keys
        let list = hosts.filter { done.contains($0) || running.contains($0) }
        return list.sorted { a, b in
            let fa = results[a].map { !$0.ok } ?? false, fb = results[b].map { !$0.ok } ?? false
            if fa != fb { return fa }
            return (hosts.firstIndex(of: a) ?? 0) < (hosts.firstIndex(of: b) ?? 0)
        }
    }

    func run(_ cmd: String, on targets: [String], done: (() -> Void)? = nil) {
        results = [:]
        running = Set(targets)
        Services.shared.record("multihost.run")
        Diagnostics.shared.log("run on \(targets.count) hosts")
        resultTable.reloadData()
        summary.stringValue = "Running on \(targets.count) host\(targets.count == 1 ? "" : "s")…"
        var queue = targets
        let env = AppDelegate.shared.currentPane?.session.env ?? ShellEnvironment()
        func next() {
            guard !queue.isEmpty else { return }
            let host = queue.removeFirst()
            guard let argv = argvOverride?(host, cmd) ?? MultiHost.argv(host: host, command: cmd) else {
                finish(host, MultiHost.Result(host: host, exit: 255, output: "not a valid host name", seconds: 0)); next(); return
            }
            started[host] = Date()
            Task { @MainActor in
                let (out, status) = await ScriptRunner.shared.runWithStatus(argv: argv, cwd: NSHomeDirectory(), env: env, timeout: 120)
                finish(host, MultiHost.Result(host: host, exit: status, output: out, seconds: Date().timeIntervalSince(self.started[host] ?? Date())))
                next()
            }
        }
        func finish(_ host: String, _ r: MultiHost.Result) {
            results[host] = r
            running.remove(host)
            resultTable.reloadData()
            summary.stringValue = MultiHost.summary(Array(results.values)) + (running.isEmpty ? "" : " · \(running.count) running")
            if running.isEmpty { done?() }
        }
        for _ in 0..<min(Self.parallel, targets.count) { next() }
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === hostTable ? hosts.count : order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === hostTable {
            let h = hosts[row]
            let b = NSButton(checkboxWithTitle: h, target: self, action: #selector(hostToggled(_:)))
            b.state = checked.contains(h) ? .on : .off
            b.identifier = NSUserInterfaceItemIdentifier(h)
            return b
        }
        let host = order[row]
        let r = results[host]
        let id = tableColumn?.identifier.rawValue ?? ""
        let f = NSTextField(labelWithString: "")
        f.lineBreakMode = .byTruncatingTail
        f.font = .systemFont(ofSize: 12)
        switch id {
        case "host": f.stringValue = host; f.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        case "status":
            if let r {
                f.stringValue = r.ok ? "✓ ok" : (r.exit == 255 ? "✗ unreachable" : "✗ exit \(r.exit.map(String.init) ?? "?")")
                f.textColor = r.ok ? .systemGreen : .systemRed
            } else { f.stringValue = "running…"; f.textColor = .secondaryLabelColor }
        case "time": f.stringValue = r.map { Services.formatDuration($0.seconds) } ?? ""
        default: f.stringValue = r?.firstLine ?? ""; f.font = .monospacedSystemFont(ofSize: 11, weight: .regular); f.toolTip = r?.output
        }
        return f
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === resultTable else { return }
        let r = resultTable.selectedRow
        guard order.indices.contains(r), let res = results[order[r]] else { detail.string = ""; return }
        detail.string = res.output.isEmpty ? "(no output)" : res.output
    }

    @objc private func hostToggled(_ b: NSButton) {
        guard let h = b.identifier?.rawValue else { return }
        if b.state == .on { checked.insert(h) } else { checked.remove(h) }
    }
}
