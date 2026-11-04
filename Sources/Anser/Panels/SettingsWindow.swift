import AppKit
import AnserCore

/// Settings window. It edits ~/.config/anser/config.json in place (keeping
/// every other key as is); the app reloads that file automatically, so
/// changes apply live.
final class SettingsWindowController: NSWindowController, NSComboBoxDelegate {
    static let shared = SettingsWindowController()

    private struct Toggle {
        let path: [String]
        let title: String
        let defaultValue: Bool
    }

    private let toggles: [Toggle] = [
        Toggle(path: ["editor", "autoPopup"], title: "Show completions while typing", defaultValue: true),
        Toggle(path: ["editor", "ghostText"], title: "Suggest from history as gray text", defaultValue: true),
        Toggle(path: ["editor", "syntaxHighlighting"], title: "Color the command line", defaultValue: true),
        Toggle(path: ["editor", "confirmMultilinePaste"], title: "Ask before multi-line pastes into running programs", defaultValue: true),
        Toggle(path: ["commandBlocks"], title: "Show command blocks (colored bars and hover actions)", defaultValue: true),
        Toggle(path: ["copyOnSelect"], title: "Copy terminal text as soon as it's selected", defaultValue: false),
        Toggle(path: ["restoreSession"], title: "Reopen windows, tabs and splits on launch", defaultValue: true),
    ]

    private var checkboxes: [NSButton] = []
    private let fontPopup = NSPopUpButton()
    private let termSize = NSTextField()
    private let termSizeStepper = NSStepper()
    private let editorSize = NSTextField()
    private let editorSizeStepper = NSStepper()
    private let themeBox = NSComboBox()
    private let opacity = NSSlider(value: 1, minValue: 0.4, maxValue: 1, target: nil, action: nil)
    private let opacityLabel = NSTextField(labelWithString: "100%")
    private let cursorPopup = NSPopUpButton()
    private let cursorBlink = NSButton(checkboxWithTitle: "Blink", target: nil, action: nil)
    private let ligatures = NSButton(checkboxWithTitle: "Ligatures (=> != ->)", target: nil, action: nil)
    private let padding = NSTextField()
    private let paddingStepper = NSStepper()
    private let promptPopup = NSPopUpButton()
    private let notifyField = NSTextField()
    private let aiToggle = NSButton(checkboxWithTitle: "Turn on AI help (explain failed commands, write commands from a description)", target: nil, action: nil)
    private let aiKey = NSSecureTextField()
    private var themes: [String] = []

    private static let cursorStyles: [(String?, String)] = [(nil, "Default"), ("block", "Block"), ("bar", "Bar"), ("underline", "Underline"), ("block_hollow", "Hollow block")]
    private static let promptModes: [(String, String)] = [("hidden", "Hidden (the editor is the only input)"), ("compact", "Short ❯ prompt"), ("full", "My shell's own prompt")]

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Anser Settings"
        super.init(window: w)
        themes = Self.loadThemes()
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        load()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private static func loadThemes() -> [String] {
        guard let dir = GhosttyRuntime.shared.resourcesDir.map({ $0 + "/themes" }),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func monospacedFamilies() -> [String] {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies.filter { fam in
            guard let f = fm.font(withFamily: fam, traits: [], weight: 5, size: 12) else { return false }
            return f.isFixedPitch || fam.localizedCaseInsensitiveContains("mono") || fam.localizedCaseInsensitiveContains("code")
        }.sorted()
    }

    // MARK: Building

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func header(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func stepperRow(_ field: NSTextField, _ stepper: NSStepper, min: Double, max: Double, action: Selector, unit: String) -> NSView {
        field.formatter = NumberFormatter()
        field.widthAnchor.constraint(equalToConstant: 50).isActive = true
        field.target = self
        field.action = action
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = 1
        stepper.target = self
        stepper.action = action
        let u = NSTextField(labelWithString: unit)
        u.textColor = .secondaryLabelColor
        let row = NSStackView(views: [field, stepper, u])
        row.setHuggingPriority(.required, for: .vertical)
        return row
    }

    private func build() {
        // Appearance
        fontPopup.addItem(withTitle: "Default (Ghostty / system)")
        fontPopup.menu?.addItem(.separator())
        for fam in Self.monospacedFamilies() {
            fontPopup.addItem(withTitle: fam)
            fontPopup.lastItem?.attributedTitle = NSAttributedString(string: fam, attributes: [.font: NSFont(name: fam, size: 13) ?? NSFont.systemFont(ofSize: 13)])
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        ligatures.target = self
        ligatures.action = #selector(ligaturesChanged)

        themeBox.usesDataSource = false
        themeBox.addItems(withObjectValues: ["Default"] + themes)
        themeBox.completes = true
        themeBox.numberOfVisibleItems = 16
        themeBox.delegate = self
        themeBox.target = self
        themeBox.action = #selector(themeChanged)
        themeBox.widthAnchor.constraint(equalToConstant: 260).isActive = true

        opacity.target = self
        opacity.action = #selector(opacityChanged)
        opacity.isContinuous = false
        opacity.widthAnchor.constraint(equalToConstant: 180).isActive = true

        for (_, title) in Self.cursorStyles { cursorPopup.addItem(withTitle: title) }
        cursorPopup.target = self
        cursorPopup.action = #selector(cursorChanged)
        cursorBlink.target = self
        cursorBlink.action = #selector(cursorChanged)

        for (_, title) in Self.promptModes { promptPopup.addItem(withTitle: title) }
        promptPopup.target = self
        promptPopup.action = #selector(promptChanged)

        let grid = NSGridView(views: [
            [label("Font:"), NSStackView(views: [fontPopup, ligatures])],
            [label("Terminal text size:"), stepperRow(termSize, termSizeStepper, min: 8, max: 36, action: #selector(termSizeChanged), unit: "pt")],
            [label("Command editor size:"), stepperRow(editorSize, editorSizeStepper, min: 9, max: 28, action: #selector(editorSizeChanged), unit: "pt")],
            [label("Color theme:"), themeBox],
            [label("Background opacity:"), NSStackView(views: [opacity, opacityLabel])],
            [label("Cursor:"), NSStackView(views: [cursorPopup, cursorBlink])],
            [label("Padding:"), stepperRow(padding, paddingStepper, min: 0, max: 40, action: #selector(paddingChanged), unit: "px")],
            [label("Shell prompt:"), promptPopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .none
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }

        let themeNote = NSTextField(labelWithString: "Type to search \(themes.count) themes. Shell prompt changes apply to new tabs.")
        themeNote.font = .systemFont(ofSize: 11)
        themeNote.textColor = .secondaryLabelColor

        // Behavior
        let behavior = NSStackView()
        behavior.orientation = .vertical
        behavior.alignment = .leading
        behavior.spacing = 6
        for (i, t) in toggles.enumerated() {
            let b = NSButton(checkboxWithTitle: t.title, target: self, action: #selector(toggled(_:)))
            b.tag = i
            checkboxes.append(b)
            behavior.addArrangedSubview(b)
        }
        notifyField.formatter = NumberFormatter()
        notifyField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        notifyField.target = self
        notifyField.action = #selector(notifyChanged)
        behavior.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Notify when a command takes longer than"), notifyField, NSTextField(labelWithString: "seconds (0 = off)")]))

        aiToggle.target = self
        aiToggle.action = #selector(aiChanged)
        aiKey.placeholderString = "Anthropic API key (sk-ant-…), stored in your Keychain"
        aiKey.target = self
        aiKey.action = #selector(aiKeyChanged)
        aiKey.widthAnchor.constraint(equalToConstant: 360).isActive = true
        let aiNote = NSTextField(wrappingLabelWithString: "Uses Claude (claude-opus-5-5). Nothing is sent until you click Explain or Ask; secrets are removed from output first. Usage is billed to your API key.")
        aiNote.font = .systemFont(ofSize: 11)
        aiNote.textColor = .secondaryLabelColor
        aiNote.preferredMaxLayoutWidth = 540

        let open = NSButton(title: "Open Config File", target: self, action: #selector(openConfig))
        let specs = NSButton(title: "Open Completions Folder", target: self, action: #selector(openCompletions))
        let note = NSTextField(wrappingLabelWithString: "Abbreviations, snippets, keybindings, history filters and any Ghostty option live in the config file.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [header("Appearance"), grid, themeNote, NSBox.separator(), header("Behavior"), behavior, NSBox.separator(),
                                        header("AI help"), aiToggle, aiKey, aiNote, NSBox.separator(), note, NSStackView(views: [open, specs])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.setCustomSpacing(4, after: grid)
        stack.setHuggingPriority(.required, for: .vertical)
        window?.contentView = stack
        // Size the window to its contents so no row has to absorb spare space.
        window?.setContentSize(stack.fittingSize)
    }

    // MARK: Reading and writing config.json

    private func readJSON() -> [String: Any] {
        _ = AnserConfig.load()
        guard let data = try? Data(contentsOf: AnserConfig.fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func value(_ json: [String: Any], _ path: [String]) -> Any? {
        var cur: Any? = json
        for k in path { cur = (cur as? [String: Any])?[k] }
        return cur is NSNull ? nil : cur
    }

    /// Sets a value (nil removes it, meaning "default").
    private func set(_ path: [String], _ v: Any?) {
        var json = readJSON()
        func assign(_ dict: inout [String: Any], _ path: ArraySlice<String>) {
            guard let k = path.first else { return }
            if path.count == 1 { if let v { dict[k] = v } else { dict[k] = NSNull() }; return }
            var child = dict[k] as? [String: Any] ?? [:]
            assign(&child, path.dropFirst())
            dict[k] = child
        }
        assign(&json, path[...])
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? data.write(to: AnserConfig.fileURL, options: .atomic)
    }

    private func load() {
        let json = readJSON()
        for (i, t) in toggles.enumerated() {
            checkboxes[i].state = ((value(json, t.path) as? Bool) ?? t.defaultValue) ? .on : .off
        }
        if let fam = value(json, ["appearance", "fontFamily"]) as? String, fontPopup.item(withTitle: fam) != nil {
            fontPopup.selectItem(withTitle: fam)
        } else {
            fontPopup.selectItem(at: 0)
        }
        let ts = (value(json, ["appearance", "fontSize"]) as? Double) ?? 13
        termSize.doubleValue = ts; termSizeStepper.doubleValue = ts
        let es = (value(json, ["editor", "fontSize"]) as? Double) ?? 13
        editorSize.doubleValue = es; editorSizeStepper.doubleValue = es
        themeBox.stringValue = (value(json, ["appearance", "theme"]) as? String) ?? "Default"
        let op = (value(json, ["appearance", "backgroundOpacity"]) as? Double) ?? 1
        opacity.doubleValue = op
        opacityLabel.stringValue = "\(Int(op * 100))%"
        let cs = value(json, ["appearance", "cursorStyle"]) as? String
        cursorPopup.selectItem(at: Self.cursorStyles.firstIndex { $0.0 == cs } ?? 0)
        cursorBlink.state = ((value(json, ["appearance", "cursorBlink"]) as? Bool) ?? true) ? .on : .off
        ligatures.state = ((value(json, ["appearance", "ligatures"]) as? Bool) ?? true) ? .on : .off
        let pad = (value(json, ["appearance", "padding"]) as? Double) ?? 8
        padding.doubleValue = pad; paddingStepper.doubleValue = pad
        let pm = (value(json, ["shellPrompt"]) as? String) ?? "hidden"
        promptPopup.selectItem(at: Self.promptModes.firstIndex { $0.0 == pm } ?? 0)
        notifyField.doubleValue = (value(json, ["notifyAfterSeconds"]) as? Double) ?? 10
        aiToggle.state = ((value(json, ["aiEnabled"]) as? Bool) ?? false) ? .on : .off
        aiKey.stringValue = KeychainStore.get() == nil ? "" : "••••••••••••"
    }

    // MARK: Actions

    @objc private func toggled(_ b: NSButton) { set(toggles[b.tag].path, b.state == .on) }

    @objc private func fontChanged() {
        set(["appearance", "fontFamily"], fontPopup.indexOfSelectedItem <= 0 ? nil : fontPopup.titleOfSelectedItem)
    }

    @objc private func termSizeChanged(_ sender: Any?) {
        let v = (sender as? NSStepper) != nil ? termSizeStepper.doubleValue : termSize.doubleValue
        termSize.doubleValue = v; termSizeStepper.doubleValue = v
        set(["appearance", "fontSize"], v)
    }

    @objc private func editorSizeChanged(_ sender: Any?) {
        let v = (sender as? NSStepper) != nil ? editorSizeStepper.doubleValue : editorSize.doubleValue
        editorSize.doubleValue = v; editorSizeStepper.doubleValue = v
        set(["editor", "fontSize"], v)
    }

    @objc private func themeChanged() {
        let name = themeBox.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "Default" { set(["appearance", "theme"], nil); return }
        // Only accept real theme names (case-insensitive match).
        if let match = themes.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            themeBox.stringValue = match
            set(["appearance", "theme"], match)
        } else {
            NSSound.beep()
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [self] in
            if let v = themeBox.objectValueOfSelectedItem as? String { themeBox.stringValue = v }
            themeChanged()
        }
    }

    @objc private func opacityChanged() {
        let v = (opacity.doubleValue * 100).rounded() / 100
        opacityLabel.stringValue = "\(Int(v * 100))%"
        set(["appearance", "backgroundOpacity"], v >= 0.995 ? nil : v)
    }

    @objc private func ligaturesChanged() { set(["appearance", "ligatures"], ligatures.state == .on ? nil : false) }

    @objc private func cursorChanged() {
        set(["appearance", "cursorStyle"], Self.cursorStyles[max(0, cursorPopup.indexOfSelectedItem)].0)
        set(["appearance", "cursorBlink"], cursorBlink.state == .on)
    }

    @objc private func paddingChanged(_ sender: Any?) {
        let v = (sender as? NSStepper) != nil ? paddingStepper.doubleValue : padding.doubleValue
        padding.doubleValue = v; paddingStepper.doubleValue = v
        set(["appearance", "padding"], v)
    }

    @objc private func promptChanged() {
        set(["shellPrompt"], Self.promptModes[max(0, promptPopup.indexOfSelectedItem)].0)
    }

    @objc private func aiChanged() { set(["aiEnabled"], aiToggle.state == .on) }
    @objc private func aiKeyChanged() {
        let v = aiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.hasPrefix("••") else { return }
        KeychainStore.set(v.isEmpty ? nil : v)
        aiKey.stringValue = v.isEmpty ? "" : "••••••••••••"
    }

    @objc private func notifyChanged() { set(["notifyAfterSeconds"], notifyField.doubleValue) }
    @objc private func openConfig() { AppDelegate.shared.openConfig(nil) }
    @objc private func openCompletions() { NSWorkspace.shared.open(AnserConfig.completionsDirectory) }
}

extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 552).isActive = true
        return b
    }
}
