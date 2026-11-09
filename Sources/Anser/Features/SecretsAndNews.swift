import AppKit
import AnserCore

// MARK: Secrets window

/// Tools → Manage Secrets…: the Keychain secrets commands can use as
/// `{{secret:name}}`. Values are never shown; you can replace or delete them.
final class SecretsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SecretsWindowController()
    private let table = NSTableView()
    private var names: [String] = []

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                        backing: .buffered, defer: false)
        w.title = "Secrets"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        let intro = NSTextField(wrappingLabelWithString:
            "Use a secret in any command or saved command as {{secret:name}}. Anser fills it in only as the command runs: it never shows on screen or in history. Values stay in your login Keychain. For 1Password, write {{op://vault/item/field}} instead.")
        intro.font = .systemFont(ofSize: 11.5)
        intro.textColor = .secondaryLabelColor
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = "Name"
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let add = ClosureButton(title: "Add…") { [weak self] in
            SecretsWindowController.askForValue(name: nil, in: self?.window) { _ in self?.reload() }
        }
        let replace = ClosureButton(title: "Replace Value…") { [weak self] in
            guard let self, let n = self.selected else { return }
            SecretsWindowController.askForValue(name: n, in: self.window) { _ in self.reload() }
        }
        let copyRef = ClosureButton(title: "Copy {{secret:…}}") { [weak self] in
            guard let n = self?.selected else { return }
            TerminalWindowController.copy("{{secret:\(n)}}")
        }
        let del = ClosureButton(title: "Delete…") { [weak self] in self?.deleteSelected() }
        let buttons = NSStackView(views: [add, replace, copyRef, NSView(), del])
        let stack = NSStackView(views: [intro, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.spacing = 10
        for v in [intro, scroll, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        w.contentView = stack
    }

    required init?(coder: NSCoder) { fatalError() }

    private var selected: String? { table.selectedRow >= 0 && table.selectedRow < names.count ? names[table.selectedRow] : nil }

    func show() {
        reload()
        if window?.isVisible != true { window?.center() }
        if let w = window { LibraryTabs.host(w, pane: nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() {
        names = SecretStore.names()
        table.reloadData()
    }

    private func deleteSelected() {
        guard let n = selected, let w = window else { return }
        let a = NSAlert()
        a.messageText = "Delete the secret “\(n)”?"
        a.informativeText = "Commands that use {{secret:\(n)}} will ask for it again. This can't be undone."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            SecretStore.delete(n)
            self?.reload()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { names.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let f = NSTextField(labelWithString: names[row] + "    ••••••••")
        f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        return f
    }

    /// Asks for a secret's value (and its name when `name` is nil), then saves it in the Keychain.
    static func askForValue(name: String?, in window: NSWindow?, done: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = name.map { "Add the secret “\($0)”" } ?? "Add a secret"
        a.informativeText = "It's kept in your Keychain. Commands use it as {{secret:\(name ?? "name")}}; the value never shows in history or on screen."
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.placeholderString = "name, e.g. github-token"
        let value = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        value.placeholderString = "value"
        if name == nil { box.addArrangedSubview(nameField) }
        box.addArrangedSubview(value)
        for f in [nameField, value] { f.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        box.frame = NSRect(x: 0, y: 0, width: 260, height: name == nil ? 54 : 24)
        a.accessoryView = box
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = name == nil ? nameField : value
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { done(false); return }
            let n = (name ?? nameField.stringValue).trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, n.count <= 64, n.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }), !value.stringValue.isEmpty else {
                NSSound.beep(); done(false); return
            }
            let ok = SecretStore.set(n, value.stringValue)
            Services.shared.record("secret.add")
            done(ok)
        }
        if let window { a.beginSheetModal(for: window, completionHandler: handle) } else { handle(a.runModal()) }
    }
}

// MARK: What's New

/// Shown once after an update that brings new features (Help → What's New brings it back).
final class WhatsNewWindowController: NSWindowController {
    static let shared = WhatsNewWindowController()
    static let seenKey = "whatsNewSeen"

    private init() {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560), styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        w.title = "What's New in Anser"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let title = NSTextField(labelWithString: "What's new in Anser \(version)")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        for item in WhatsNew.items {
            let icon = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .controlAccentColor
            icon.symbolConfiguration = .init(pointSize: 16, weight: .medium)
            icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
            let head = NSTextField(labelWithString: item.title)
            head.font = .systemFont(ofSize: 13, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString: item.detail)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 440
            let text = NSStackView(views: [head, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            let row = NSStackView(views: [icon, text])
            row.alignment = .top
            row.spacing = 10
            list.addArrangedSubview(row)
        }
        let scroll = NSScrollView()
        let doc = NSView()
        doc.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([list.topAnchor.constraint(equalTo: doc.topAnchor), list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
                                     list.trailingAnchor.constraint(equalTo: doc.trailingAnchor), list.bottomAnchor.constraint(equalTo: doc.bottomAnchor)])
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let ok = ClosureButton(title: "Continue") { [weak w] in w?.close() }
        ok.keyEquivalent = "\r"
        let tour = ClosureButton(title: "Take the Tour") { [weak w] in w?.close(); TourWindowController.shared.show() }
        let buttons = NSStackView(views: [NSView(), tour, ok])
        let stack = NSStackView(views: [title, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 24, bottom: 18, right: 24)
        for v in [scroll, buttons] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true }
        w.contentView = stack
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        UserDefaults.standard.set(WhatsNew.featureSet, forKey: Self.seenKey)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// After an update: once per feature version. New users get the welcome card instead.
    static func showIfUpdated() {
        guard !Services.isSelfTest else { return }
        let seen = UserDefaults.standard.string(forKey: seenKey)
        // Someone who has used Anser before (history exists) but hasn't seen this version.
        let returning = UserDefaults.standard.bool(forKey: "AnserWelcomeShown") || Services.shared.history.entries(session: nil, limit: 20).count >= 20
        if seen != WhatsNew.featureSet {
            if returning { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { shared.show() } }
            else { UserDefaults.standard.set(WhatsNew.featureSet, forKey: seenKey) }
        }
    }
}
