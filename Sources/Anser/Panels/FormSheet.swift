import AppKit

/// A small form shown as a sheet: fields, a live check (Save stays off with a
/// red note until the values are valid), an optional yellow warning, and a
/// preview of what will happen.
final class FormSheet: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {
    enum Kind {
        case text(placeholder: String, mono: Bool)
        case secure(placeholder: String)
        case combo(options: [String], placeholder: String)
        case popup(options: [String])
        case check(title: String)
    }

    struct Field {
        var key: String
        var label: String
        var kind: Kind
        var value: String = ""
        var help: String? = nil
        init(_ key: String, _ label: String, _ kind: Kind, value: String = "", help: String? = nil) {
            self.key = key; self.label = label; self.kind = kind; self.value = value; self.help = help
        }
    }

    /// Checked as you type: return an error to keep Save off.
    var validate: ([String: String]) -> String? = { _ in nil }
    /// A note that doesn't block saving ("this name is already a command").
    var warn: ([String: String]) -> String? = { _ in nil }
    /// What will happen, in one or two lines.
    var preview: (([String: String]) -> String?)?

    private let panel: NSPanel
    private var controls: [String: NSView] = [:]
    private let fields: [Field]
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let warnLabel = NSTextField(wrappingLabelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let okButton: NSButton
    private var done: (([String: String]?) -> Void)?
    private static var open: [FormSheet] = []

    init(title: String, message: String? = nil, fields: [Field], ok: String = "Save", width: CGFloat = 440) {
        self.fields = fields
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        okButton = NSButton(title: ok, target: nil, action: nil)
        super.init()
        build(title: title, message: message, width: width)
    }

    private func build(title: String, message: String?, width: CGFloat) {
        let content = NSView()
        panel.contentView = content
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        var rows: [NSView] = [titleLabel]
        if let message {
            let m = NSTextField(wrappingLabelWithString: message)
            m.font = .systemFont(ofSize: 12)
            m.textColor = .secondaryLabelColor
            m.preferredMaxLayoutWidth = width - 40
            rows.append(m)
        }
        var gridRows: [[NSView]] = []
        for f in fields {
            let control: NSView
            switch f.kind {
            case let .text(ph, mono):
                let t = NSTextField(string: f.value)
                t.placeholderString = ph
                if mono { t.font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
                t.delegate = self
                control = t
            case let .secure(ph):
                let t = NSSecureTextField(string: f.value)
                t.placeholderString = ph
                t.delegate = self
                control = t
            case let .combo(options, ph):
                let c = NSComboBox()
                c.addItems(withObjectValues: options)
                c.stringValue = f.value
                c.placeholderString = ph
                c.completes = true
                c.delegate = self
                control = c
            case let .popup(options):
                let p = NSPopUpButton()
                p.addItems(withTitles: options)
                if let i = options.firstIndex(of: f.value) { p.selectItem(at: i) }
                p.target = self
                p.action = #selector(changed)
                control = p
            case let .check(title):
                let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(changed))
                b.state = f.value == "1" ? .on : .off
                control = b
            }
            control.toolTip = f.help
            if !(control is NSButton) { control.widthAnchor.constraint(equalToConstant: width - 150).isActive = true }
            controls[f.key] = control
            let label = NSTextField(labelWithString: f.label.isEmpty ? "" : f.label + ":")
            label.alignment = .right
            gridRows.append([label, control])
        }
        let grid = NSGridView(views: gridRows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        rows.append(grid)
        for (l, color) in [(previewLabel, NSColor.secondaryLabelColor), (warnLabel, NSColor.systemOrange), (errorLabel, NSColor.systemRed)] {
            l.font = l === previewLabel ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
            l.textColor = color
            l.preferredMaxLayoutWidth = width - 40
            l.isSelectable = l === previewLabel
            rows.append(l)
        }
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        okButton.target = self
        okButton.action = #selector(okTapped)
        okButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, okButton])
        buttons.spacing = 8
        rows.append(buttons)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: width),
        ])
    }

    // MARK: Values

    var values: [String: String] {
        var out: [String: String] = [:]
        for f in fields {
            switch controls[f.key] {
            case let p as NSPopUpButton: out[f.key] = p.titleOfSelectedItem ?? ""
            case let b as NSButton: out[f.key] = b.state == .on ? "1" : ""
            case let t as NSTextField: out[f.key] = t.stringValue
            default: break
            }
        }
        return out
    }

    func set(_ key: String, _ value: String) {
        switch controls[key] {
        case let p as NSPopUpButton: p.selectItem(withTitle: value)
        case let b as NSButton: b.state = value == "1" ? .on : .off
        case let t as NSTextField: t.stringValue = value
        default: break
        }
        changed()
    }

    var errorText: String { errorLabel.stringValue }
    var warningText: String { warnLabel.stringValue }
    var previewText: String { previewLabel.stringValue }
    var canSave: Bool { okButton.isEnabled }

    @objc func changed() {
        let v = values
        let err = validate(v)
        errorLabel.stringValue = err ?? ""
        errorLabel.isHidden = err == nil
        let w = err == nil ? warn(v) : nil
        warnLabel.stringValue = w.map { "⚠︎ " + $0 } ?? ""
        warnLabel.isHidden = w == nil
        let p = preview?(v)
        previewLabel.stringValue = p ?? ""
        previewLabel.isHidden = p == nil
        okButton.isEnabled = err == nil
        panel.contentView?.layoutSubtreeIfNeeded()
        if let size = panel.contentView?.fittingSize { panel.setContentSize(size) }
    }

    func controlTextDidChange(_ obj: Notification) { changed() }
    func comboBoxSelectionDidChange(_ notification: Notification) { DispatchQueue.main.async { self.changed() } }

    // MARK: Showing

    /// Shows as a sheet on `window` (or on its own); `done` gets the values, or nil on Cancel.
    func present(over window: NSWindow?, focus key: String? = nil, done: @escaping ([String: String]?) -> Void) {
        self.done = done
        Self.open.append(self)
        changed()
        if let key, let c = controls[key] { panel.initialFirstResponder = c }
        else { panel.initialFirstResponder = fields.first.flatMap { controls[$0.key] } }
        if let window { window.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }

    private func finish(_ v: [String: String]?) {
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.orderOut(nil) }
        Self.open.removeAll { $0 === self }
        done?(v)
        done = nil
    }

    @objc private func okTapped() {
        changed()
        guard okButton.isEnabled else { NSSound.beep(); return }
        finish(values)
    }

    @objc private func cancelTapped() { finish(nil) }

    /// Tests press Save without showing the sheet.
    func saveForTests() -> [String: String]? { changed(); return okButton.isEnabled ? values : nil }
}
