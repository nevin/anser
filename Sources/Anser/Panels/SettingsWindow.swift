import AppKit
import AnserCore

/// Settings window. It edits ~/.config/anser/config.json in place (keeping
/// every other key as is); the app reloads that file automatically, so
/// changes apply live.
final class SettingsWindowController: NSWindowController, NSComboBoxDelegate {
    static let shared = SettingsWindowController()

    private struct Toggle {
        enum Section { case editor, behavior }
        let section: Section
        let path: [String]
        let title: String
        let defaultValue: Bool
    }

    private let toggles: [Toggle] = [
        Toggle(section: .editor, path: ["editorFollowsOutput"], title: "Keep the editor right under the output (until the screen fills)", defaultValue: true),
        Toggle(section: .editor, path: ["editor", "autoPopup"], title: "Show completions while typing", defaultValue: true),
        Toggle(section: .editor, path: ["editor", "ghostText"], title: "Suggest from history as gray text", defaultValue: true),
        Toggle(section: .editor, path: ["editor", "syntaxHighlighting"], title: "Color the command line", defaultValue: true),
        Toggle(section: .editor, path: ["editor", "lint"], title: "Underline mistakes and warn about risky commands", defaultValue: true),
        Toggle(section: .editor, path: ["editor", "vimMode"], title: "Vim keys (Esc for normal mode, i to type)", defaultValue: false),
        Toggle(section: .behavior, path: ["commandBlocks"], title: "Show command blocks (✓/✗ marks, colored bars, hover actions)", defaultValue: true),
        Toggle(section: .behavior, path: ["editor", "confirmMultilinePaste"], title: "Ask before multi-line pastes into running programs", defaultValue: true),
        Toggle(section: .behavior, path: ["copyOnSelect"], title: "Copy terminal text as soon as it's selected", defaultValue: false),
        Toggle(section: .behavior, path: ["restoreSession"], title: "Reopen windows, tabs and splits on launch", defaultValue: true),
        Toggle(section: .behavior, path: ["previewFilesOnHover"], title: "Preview a file when the mouse rests on its path in the output", defaultValue: true),
        Toggle(section: .behavior, path: ["keepShellsRunning"], title: "Keep shells running when Anser quits or updates (⌥ Quit ends them)", defaultValue: true),
        Toggle(section: .behavior, path: ["showLoginMessage"], title: "Show macOS's \u{201C}Last login\u{201D} line in new tabs", defaultValue: false),
        Toggle(section: .behavior, path: ["saveOutput"], title: "Remember command output so History → Output can search it (on this Mac, secrets removed)", defaultValue: true),
        Toggle(section: .behavior, path: ["showPullRequests"], title: "Show the branch's pull request and checks (uses the GitHub CLI, gh)", defaultValue: true),
        Toggle(section: .behavior, path: ["usageStats"], title: "Count which features I use, only on this Mac (Help → Your Feature Usage)", defaultValue: false),
    ]
    private let tabView = NSTabView()
    private let preview = ThemePreviewView()
    private let notifyToggle = NSButton(checkboxWithTitle: "Notify when a command in a background tab takes longer than", target: nil, action: nil)
    private let tipsPopup = NSPopUpButton()
    private static let tipModes: [(String, String)] = [("auto", "While I'm new (first 300 commands)"), ("always", "Always"), ("never", "Never")]

    private var checkboxes: [NSButton] = []
    private let fontPopup = NSPopUpButton()
    private let termSize = NSTextField()
    private let termSizeStepper = NSStepper()
    private let editorSize = NSTextField()
    private let editorSizeStepper = NSStepper()
    private let themeBox = NSComboBox()      // dark-mode theme
    private let lightThemeBox = NSComboBox()
    private let modePopup = NSPopUpButton()
    static let appearanceModes = [("system", "System (follow macOS)"), ("dark", "Dark"), ("light", "Light")]
    /// Which theme box the preview shows (the one last touched, else the active one).
    private var previewLight = false
    private let opacity = NSSlider(value: 1, minValue: 0.4, maxValue: 1, target: nil, action: nil)
    private let opacityLabel = NSTextField(labelWithString: "100%")
    private let cursorPopup = NSPopUpButton()
    private let cursorBlink = NSButton(checkboxWithTitle: "Blink", target: nil, action: nil)
    private let ligatures = NSButton(checkboxWithTitle: "Ligatures (=> != ->)", target: nil, action: nil)
    private let padding = NSTextField()
    private let paddingStepper = NSStepper()
    private let promptPopup = NSPopUpButton()
    private let notifyField = NSTextField()
    private let aiPopup = NSPopUpButton()
    static let aiChoices = [("off", "Off"), ("claude", "Claude (Anthropic API key)"), ("copilot", "GitHub Copilot (your GitHub sign-in)"),
                            ("ollama", "Local AI with Ollama (nothing leaves this Mac)")]
    private let ollamaBox = NSStackView()
    private let ollamaStatus = NSTextField(wrappingLabelWithString: "")
    private let ollamaModelPopup = NSPopUpButton()
    private let ollamaInstall = NSButton(title: "Install Ollama…", target: nil, action: nil)
    private let ollamaStart = NSButton(title: "Start Ollama", target: nil, action: nil)
    private let ollamaPull = NSButton(title: "Get a Model…", target: nil, action: nil)
    private let ollamaTest = NSButton(title: "Test", target: nil, action: nil)
    static let suggestedOllamaModel = "qwen2.5-coder:7b"
    private let quickToggle = NSButton(checkboxWithTitle: "Quick terminal: drop down from the top of the screen in any app with", target: nil, action: nil)
    private let quickField = NSTextField()
    private let quickStatus = NSTextField(labelWithString: "")
    private let updatesToggle = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let notebookPopup = NSPopUpButton()
    private let scrollbackPopup = NSPopUpButton()
    static let scrollbackChoices = [(2, "2 MB (lightest)"), (10, "10 MB (default)"), (50, "50 MB"), (100, "100 MB")]
    private var abbreviationsTable: EditableTable!
    private var keybindingsTable: EditableTable!
    private var profilesTable: EditableTable!
    private let aiKey = NSSecureTextField()
    private let claudeBox = NSStackView()
    private let copilotBox = NSStackView()
    private let copilotStatus = NSTextField(wrappingLabelWithString: "")
    private let copilotModel = NSTextField()
    private let copilotInstall = NSButton(title: "Install…", target: nil, action: nil)
    private let copilotSignIn = NSButton(title: "Sign In…", target: nil, action: nil)
    private let copilotTest = NSButton(title: "Test", target: nil, action: nil)
    private var themes: [String] = []

    private static let cursorStyles: [(String?, String)] = [(nil, "Default"), ("block", "Block"), ("bar", "Bar"), ("underline", "Underline"), ("block_hollow", "Hollow block")]
    private static let promptModes: [(String, String)] = [("hidden", "Hidden (the editor is the only input)"), ("compact", "Short ❯ prompt"), ("full", "My shell's own prompt")]

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
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

    /// Your own themes (imported from iTerm2 / Warp, or added by hand) live here; Ghostty reads them too.
    static var userThemesDir: String { NSHomeDirectory() + "/.config/ghostty/themes" }

    private static func loadThemes() -> [String] {
        var names = Set<String>()
        for dir in [GhosttyRuntime.shared.resourcesDir.map { $0 + "/themes" }, userThemesDir].compactMap({ $0 }) {
            for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where !n.hasPrefix(".") { names.insert(n) }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Reloads the theme list (after importing themes).
    func reloadThemes() {
        themes = Self.loadThemes()
        for box in [themeBox, lightThemeBox] {
            box.removeAllItems()
            box.addItems(withObjectValues: ["Default"] + themes)
        }
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
        fontPopup.addItem(withTitle: "\(Self.defaultFontName) (default)")
        fontPopup.menu?.addItem(.separator())
        for fam in Self.monospacedFamilies() {
            fontPopup.addItem(withTitle: fam)
            fontPopup.lastItem?.attributedTitle = NSAttributedString(string: fam, attributes: [.font: NSFont(name: fam, size: 13) ?? NSFont.systemFont(ofSize: 13)])
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged)
        ligatures.target = self
        ligatures.action = #selector(ligaturesChanged)

        for box in [themeBox, lightThemeBox] {
            box.usesDataSource = false
            box.addItems(withObjectValues: ["Default"] + themes)
            box.completes = true
            box.numberOfVisibleItems = 16
            box.delegate = self
            box.target = self
            box.action = #selector(themeChanged(_:))
            box.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        themeBox.setAccessibilityLabel("Dark mode theme")
        lightThemeBox.setAccessibilityLabel("Light mode theme")
        for (_, title) in Self.appearanceModes { modePopup.addItem(withTitle: title) }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)

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

        func grid(_ rows: [[NSView]]) -> NSGridView {
            let g = NSGridView(views: rows)
            g.rowSpacing = 10
            g.columnSpacing = 10
            g.column(at: 0).xPlacement = .trailing
            g.rowAlignment = .none
            for i in 0..<g.numberOfRows { g.row(at: i).yPlacement = .center }
            return g
        }
        func note(_ text: String) -> NSTextField {
            let n = NSTextField(wrappingLabelWithString: text)
            n.font = .systemFont(ofSize: 11)
            n.textColor = .secondaryLabelColor
            n.preferredMaxLayoutWidth = 560
            return n
        }
        func page(_ views: [NSView]) -> NSView {
            let st = NSStackView(views: views)
            st.orientation = .vertical
            st.alignment = .leading
            st.spacing = 12
            st.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
            let container = NSView()
            st.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(st)
            NSLayoutConstraint.activate([
                st.topAnchor.constraint(equalTo: container.topAnchor),
                st.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                st.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            ])
            return container
        }
        func checkbox(_ i: Int) -> NSButton {
            let b = NSButton(checkboxWithTitle: toggles[i].title, target: self, action: #selector(toggled(_:)))
            b.tag = i
            return b
        }
        checkboxes = toggles.indices.map(checkbox)

        // Appearance: font, theme (with a live preview), window.
        let themeNote = note("Type to search \(themes.count) themes. “Default” in light mode is \(AnserConfig.Appearance.defaultLightTheme).")
        let themeColumn = NSStackView(views: [lightThemeBox, themeNote])
        themeColumn.orientation = .vertical
        themeColumn.alignment = .leading
        themeColumn.spacing = 3
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 560).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 132).isActive = true
        let appearance = page([
            grid([
                [label("Font:"), NSStackView(views: [fontPopup, ligatures])],
                [label("Text size:"), stepperRow(termSize, termSizeStepper, min: 8, max: 36, action: #selector(termSizeChanged), unit: "pt")],
                [label("Appearance:"), modePopup],
                [label("Dark theme:"), themeBox],
                [label("Light theme:"), themeColumn],
                [label("Background opacity:"), NSStackView(views: [opacity, opacityLabel])],
                [label("Cursor:"), NSStackView(views: [cursorPopup, cursorBlink])],
                [label("Padding:"), stepperRow(padding, paddingStepper, min: 0, max: 40, action: #selector(paddingChanged), unit: "px")],
            ]),
            preview,
        ])

        // Editor.
        for (_, title) in Self.tipModes { tipsPopup.addItem(withTitle: title) }
        tipsPopup.target = self
        tipsPopup.action = #selector(tipsChanged)
        let editorToggles = NSStackView(views: toggles.indices.filter { toggles[$0].section == .editor }.map { checkboxes[$0] })
        editorToggles.orientation = .vertical
        editorToggles.alignment = .leading
        editorToggles.spacing = 6
        let editorPage = page([
            grid([
                [label("Editor text size:"), stepperRow(editorSize, editorSizeStepper, min: 9, max: 28, action: #selector(editorSizeChanged), unit: "pt")],
                [label("Shell prompt:"), promptPopup],
                [label("Keyboard tips:"), tipsPopup],
            ]),
            note("Shell prompt changes apply to new tabs."),
            editorToggles,
        ])

        // Behavior.
        notifyToggle.target = self
        notifyToggle.action = #selector(notifyToggled)
        notifyField.formatter = NumberFormatter()
        notifyField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        notifyField.target = self
        notifyField.action = #selector(notifyChanged)
        quickToggle.target = self
        quickToggle.action = #selector(quickChanged)
        quickField.placeholderString = "ctrl+`"
        quickField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        quickField.target = self
        quickField.action = #selector(quickChanged)
        quickStatus.font = .systemFont(ofSize: 11)
        quickStatus.textColor = .secondaryLabelColor
        updatesToggle.target = self
        updatesToggle.action = #selector(updatesChanged)
        for t in ["This Mac (~/.config/anser)", "iCloud Drive (syncs to your other Macs)", "A folder I choose (e.g. a git repo)…"] { notebookPopup.addItem(withTitle: t) }
        notebookPopup.target = self
        notebookPopup.action = #selector(notebookLocationChanged)
        for (_, t) in Self.scrollbackChoices { scrollbackPopup.addItem(withTitle: t) }
        scrollbackPopup.target = self
        scrollbackPopup.action = #selector(scrollbackChanged)
        scrollbackPopup.toolTip = "How much past output each tab keeps. Less uses less memory with many tabs; applies to new tabs."
        let behaviorViews: [NSView] = toggles.indices.filter { toggles[$0].section == .behavior }.map { checkboxes[$0] }
            + [NSStackView(views: [notifyToggle, notifyField, NSTextField(labelWithString: "seconds")]),
               NSStackView(views: [quickToggle, quickField]), quickStatus,
               NSStackView(views: [NSTextField(labelWithString: "Keep the Command Notebook in:"), notebookPopup]),
               NSStackView(views: [NSTextField(labelWithString: "Scrollback per tab:"), scrollbackPopup]),
               updatesToggle]
        let behaviorStack = NSStackView(views: behaviorViews)
        behaviorStack.orientation = .vertical
        behaviorStack.alignment = .leading
        behaviorStack.spacing = 8
        let behaviorPage = page([behaviorStack])

        // AI help.
        for (_, title) in Self.aiChoices { aiPopup.addItem(withTitle: title) }
        aiPopup.target = self
        aiPopup.action = #selector(aiChanged)
        aiKey.placeholderString = "Anthropic API key (sk-ant-…), stored in your Keychain"
        aiKey.target = self
        aiKey.action = #selector(aiKeyChanged)
        aiKey.widthAnchor.constraint(equalToConstant: 380).isActive = true
        for v in [aiKey, note("Uses Claude (\(AIHelp.model)). Usage is billed to your API key.")] as [NSView] { claudeBox.addArrangedSubview(v) }
        claudeBox.orientation = .vertical; claudeBox.alignment = .leading; claudeBox.spacing = 6

        copilotModel.placeholderString = "Model (optional, e.g. gpt-5): empty lets Copilot choose"
        copilotModel.target = self
        copilotModel.action = #selector(copilotModelChanged)
        copilotModel.widthAnchor.constraint(equalToConstant: 380).isActive = true
        copilotInstall.target = self; copilotInstall.action = #selector(installCopilot)
        copilotSignIn.target = self; copilotSignIn.action = #selector(signInCopilot)
        copilotTest.target = self; copilotTest.action = #selector(testCopilot)
        copilotStatus.font = .systemFont(ofSize: 12)
        copilotStatus.preferredMaxLayoutWidth = 520
        for v in [copilotStatus, NSStackView(views: [copilotInstall, copilotSignIn, copilotTest]), copilotModel,
                  note("Runs the GitHub Copilot CLI with every tool turned off, so it can only answer: it can't run commands or read your files. Each answer uses one premium request from your Copilot plan.")] as [NSView] {
            copilotBox.addArrangedSubview(v)
        }
        copilotBox.orientation = .vertical; copilotBox.alignment = .leading; copilotBox.spacing = 6

        for (b, sel) in [(ollamaInstall, #selector(installOllama)), (ollamaStart, #selector(startOllama)), (ollamaPull, #selector(pullOllama)), (ollamaTest, #selector(testOllama))] {
            b.target = self; b.action = sel
        }
        ollamaModelPopup.target = self
        ollamaModelPopup.action = #selector(ollamaModelChanged)
        ollamaStatus.font = .systemFont(ofSize: 12)
        ollamaStatus.preferredMaxLayoutWidth = 520
        for v in [ollamaStatus, NSStackView(views: [ollamaInstall, ollamaStart, ollamaPull, ollamaTest]),
                  NSStackView(views: [NSTextField(labelWithString: "Model:"), ollamaModelPopup]),
                  note("Runs a model on this Mac with Ollama. Nothing is sent over the internet. Answers are slower and less accurate than Claude's; a coding model such as \(Self.suggestedOllamaModel) (about 5 GB) works well.")] as [NSView] {
            ollamaBox.addArrangedSubview(v)
        }
        ollamaBox.orientation = .vertical; ollamaBox.alignment = .leading; ollamaBox.spacing = 6

        let aiPage = page([grid([[label("AI help:"), aiPopup]]), claudeBox, copilotBox, ollamaBox,
                           note("Explain a failed command (⌥⌘I) or ask for a command (⌘I). Nothing is sent until you click; secrets are removed from output first.")])

        // Advanced.
        let open = NSButton(title: "Open Config File", target: self, action: #selector(openConfig))
        let specs = NSButton(title: "Open Completions Folder", target: self, action: #selector(openCompletions))
        let importButton = NSButton(title: "Import from iTerm2 or Warp…", target: self, action: #selector(importOther))
        let advanced = page([note("Everything else lives in the config file: history filters, completion helpers, quick terminal height, profile environment variables and any Ghostty option. Changes there apply as soon as you save."),
                             NSStackView(views: [open, specs]),
                             note("Bring over themes, font and workflows from another terminal:"),
                             importButton])

        // Shortcuts: abbreviations and keybindings, edited in place.
        abbreviationsTable = EditableTable(columns: [("key", "Type", 110), ("value", "Expands to", 330)]) { [weak self] rows in
            self?.set(["abbreviations"], Dictionary(rows.compactMap { r -> (String, String)? in
                let k = (r["key"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                return k.isEmpty ? nil : (k, r["value"] as? String ?? "")
            }, uniquingKeysWith: { _, b in b }))
        }
        keybindingsTable = EditableTable(columns: [("key", "Keys", 130), ("value", "Does", 310)]) { [weak self] rows in
            self?.set(["keybindings"], Dictionary(rows.compactMap { r -> (String, String)? in
                let k = (r["key"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                return k.isEmpty ? nil : (k, r["value"] as? String ?? "")
            }, uniquingKeysWith: { _, b in b }))
        }
        let shortcutsPage = page([
            header("Abbreviations"),
            note("Type the short form, then Space: it expands (gco → git checkout)."),
            abbreviationsTable.view(height: 130),
            header("Keyboard shortcuts"),
            note("Keys like cmd+shift+k or ctrl+g. Does: run:<command>, insert:<text>, snippet:<notebook entry title>, action:<name> (any palette action, e.g. action:searchOutput), or ghostty:<action>."),
            keybindingsTable.view(height: 130),
        ])

        // Profiles: per host / folder.
        profilesTable = EditableTable(columns: [("match", "Host or folder", 150), ("badge", "Badge", 80), ("tabColor", "Tab color", 80), ("confirm", "Ask before running", 140)]) { [weak self] rows in
            self?.set(["profiles"], rows.compactMap(Self.profileJSON))
        }
        let profilesPage = page([
            note("A profile applies where its pattern matches: an ssh host (prod-*, *.example.com) or a folder starting with ~ or / (~/work/payments). It colors the tab, shows a badge, and can ask before running commands there."),
            profilesTable.view(height: 230),
            note("Tab colors: red, orange, yellow, green, blue, purple, teal. Ask before running: * for every command, or patterns like *rm -rf*, *drop table*, separated by commas. Extra environment variables (\"env\") can be added in the config file."),
        ])

        for (title, view) in [("Appearance", appearance), ("Editor", editorPage), ("Behavior", behaviorPage), ("AI", aiPage),
                              ("Shortcuts", shortcutsPage), ("Profiles", profilesPage), ("Advanced", advanced)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = view
            tabView.addTabViewItem(item)
        }
        tabView.frame = NSRect(x: 0, y: 0, width: 680, height: 560)
        let root = NSView(frame: tabView.frame)
        tabView.autoresizingMask = [.width, .height]
        root.addSubview(tabView)
        window?.contentView = root
        window?.setContentSize(NSSize(width: 680, height: 560))
    }

    /// Shows one section (0 Appearance … 6 Advanced).
    func selectSection(_ i: Int) { tabView.selectTabViewItem(at: i) }

    /// Opens Settings at a section by name ("Profiles").
    func show(section: String) {
        show()
        tabView.selectTabViewItem(withIdentifier: section)
    }

    /// The section showing (for tests).
    var selectedSectionName: String? { tabView.selectedTabViewItem?.label }

    /// A profiles table row → config JSON ("~/x" or "/x" is a folder, anything else a host).
    static func profileJSON(_ r: [String: Any]) -> [String: Any]? {
        var out = (r["_raw"] as? [String: Any]) ?? [:]
        let match = (r["match"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !match.isEmpty else { return nil }
        out["host"] = nil; out["folder"] = nil
        if match.hasPrefix("~") || match.hasPrefix("/") { out["folder"] = match } else { out["host"] = match }
        for k in ["badge", "tabColor"] {
            let v = (r[k] as? String ?? "").trimmingCharacters(in: .whitespaces)
            out[k] = v.isEmpty ? nil : v
        }
        let confirm = (r["confirm"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        out["confirm"] = confirm.isEmpty ? nil : confirm
        return out
    }

    static func profileRow(_ j: [String: Any]) -> [String: Any] {
        ["match": (j["host"] as? String) ?? (j["folder"] as? String) ?? "", "badge": j["badge"] as? String ?? "",
         "tabColor": j["tabColor"] as? String ?? "", "confirm": (j["confirm"] as? [String] ?? []).joined(separator: ", "), "_raw": j]
    }

    /// The font the terminal really uses when "Default" is chosen.
    private static var defaultFontName: String {
        let files = [AnserConfig.directory.deletingLastPathComponent().appendingPathComponent("ghostty/config").path,
                     NSHomeDirectory() + "/.config/ghostty/config",
                     NSHomeDirectory() + "/Library/Application Support/com.mitchellh.ghostty/config"]
        var lines = Services.shared.config.ghostty
        for f in files { lines += ((try? String(contentsOfFile: f, encoding: .utf8)) ?? "").components(separatedBy: "\n") }
        for l in lines.reversed() {
            let parts = l.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "font-family", !parts[1].isEmpty, parts[1] != "\"\"" {
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return "JetBrains Mono"
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
    private func set(_ path: [String], _ v: Any?) { Self.setValue(path, v) }

    /// Changes one setting in config.json, keeping everything else as written.
    static func setValue(_ path: [String], _ v: Any?) {
        _ = AnserConfig.load()
        var json: [String: Any] = (try? Data(contentsOf: AnserConfig.fileURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
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
        let mode = value(json, ["appearance", "mode"]) as? String
        modePopup.selectItem(at: Self.appearanceModes.firstIndex { $0.0 == mode } ?? 0)
        // Without a mode, the single "theme" is the dark one.
        themeBox.stringValue = (value(json, ["appearance", "darkTheme"]) as? String) ?? (value(json, ["appearance", "theme"]) as? String) ?? "Default"
        lightThemeBox.stringValue = (value(json, ["appearance", "lightTheme"]) as? String) ?? "Default"
        previewLight = !(AnserConfig.Appearance(mode: mode).usesDark(systemIsDark: GhosttyRuntime.systemIsDark))
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
        let notify = (value(json, ["notifyAfterSeconds"]) as? Double) ?? 10
        notifyToggle.state = notify > 0 ? .on : .off
        notifyField.doubleValue = notify > 0 ? notify : 10
        notifyField.isEnabled = notify > 0
        let tips = (value(json, ["keyTips"]) as? String) ?? "auto"
        tipsPopup.selectItem(at: Self.tipModes.firstIndex { $0.0 == tips } ?? 0)
        updatePreview()
        let aiOn = (value(json, ["aiEnabled"]) as? Bool) ?? false
        let provider = (value(json, ["aiProvider"]) as? String) ?? "claude"
        aiPopup.selectItem(at: aiOn ? (Self.aiChoices.firstIndex { $0.0 == provider } ?? 1) : 0)
        copilotModel.stringValue = (value(json, ["copilotModel"]) as? String) ?? ""
        updateAIBoxes()
        let quick = value(json, ["quickTerminalHotkey"]) as? String
        quickToggle.state = (quick?.isEmpty == false) ? .on : .off
        quickField.stringValue = quick ?? "ctrl+`"
        quickField.isEnabled = quickToggle.state == .on
        updateQuickStatus()
        updatesToggle.isEnabled = Updater.shared.isConfigured
        updatesToggle.state = Updater.shared.automaticallyChecks ? .on : .off
        if !Updater.shared.isConfigured { updatesToggle.title = "Check for updates automatically (not set up in this build)" }
        let loc = (value(json, ["notebookLocation"]) as? String) ?? ""
        notebookPopup.selectItem(at: loc.isEmpty ? 0 : (loc.lowercased() == "icloud" ? 1 : 2))
        if notebookPopup.indexOfSelectedItem == 2 { notebookPopup.item(at: 2)?.title = "Folder: " + (loc as NSString).abbreviatingWithTildeInPath }
        notebookPopup.item(at: 1)?.isEnabled = Services.iCloudAvailable
        let sb = (value(json, ["scrollbackMB"]) as? Int) ?? 10
        scrollbackPopup.selectItem(at: Self.scrollbackChoices.firstIndex { $0.0 == sb } ?? 1)
        abbreviationsTable.rows = ((value(json, ["abbreviations"]) as? [String: String]) ?? [:]).sorted { $0.key < $1.key }.map { ["key": $0.key, "value": $0.value] }
        keybindingsTable.rows = ((value(json, ["keybindings"]) as? [String: String]) ?? [:]).sorted { $0.key < $1.key }.map { ["key": $0.key, "value": $0.value] }
        profilesTable.rows = ((value(json, ["profiles"]) as? [[String: Any]]) ?? []).map(Self.profileRow)
        aiKey.stringValue = KeychainStore.get() == nil ? "" : "••••••••••••"
    }

    // MARK: Actions

    @objc private func toggled(_ b: NSButton) { set(toggles[b.tag].path, b.state == .on) }

    @objc private func fontChanged() {
        defer { updatePreview() }
        set(["appearance", "fontFamily"], fontPopup.indexOfSelectedItem <= 0 ? nil : fontPopup.titleOfSelectedItem)
    }

    @objc private func termSizeChanged(_ sender: Any?) {
        let v = (sender as? NSStepper) != nil ? termSizeStepper.doubleValue : termSize.doubleValue
        termSize.doubleValue = v; termSizeStepper.doubleValue = v
        set(["appearance", "fontSize"], v)
        updatePreview()
    }

    @objc private func editorSizeChanged(_ sender: Any?) {
        let v = (sender as? NSStepper) != nil ? editorSizeStepper.doubleValue : editorSize.doubleValue
        editorSize.doubleValue = v; editorSizeStepper.doubleValue = v
        set(["editor", "fontSize"], v)
    }

    @objc private func modeChanged() {
        let mode = Self.appearanceModes[max(0, modePopup.indexOfSelectedItem)].0
        // Keep the current single theme as the dark theme when switching to modes.
        let json = readJSON()
        if value(json, ["appearance", "darkTheme"]) == nil, let old = value(json, ["appearance", "theme"]) as? String {
            set(["appearance", "darkTheme"], old)
        }
        set(["appearance", "mode"], mode)
        previewLight = !AnserConfig.Appearance(mode: mode).usesDark(systemIsDark: GhosttyRuntime.systemIsDark)
        updatePreview()
    }

    @objc private func themeChanged(_ sender: Any?) {
        let box = (sender as? NSComboBox) ?? themeBox
        let light = box === lightThemeBox
        previewLight = light
        defer { updatePreview() }
        if value(readJSON(), ["appearance", "mode"]) == nil { set(["appearance", "mode"], "system") }
        let key = light ? "lightTheme" : "darkTheme"
        let name = box.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == "Default" {
            set(["appearance", key], nil)
            if !light { set(["appearance", "theme"], nil) }
            return
        }
        // Only accept real theme names (case-insensitive match).
        if let match = themes.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            box.stringValue = match
            set(["appearance", key], match)
        } else {
            NSSound.beep()
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let box = notification.object as? NSComboBox else { return }
        DispatchQueue.main.async { [self] in
            if let v = box.objectValueOfSelectedItem as? String { box.stringValue = v }
            themeChanged(box)
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

    @objc private func aiChanged() {
        let choice = Self.aiChoices[max(0, aiPopup.indexOfSelectedItem)].0
        set(["aiEnabled"], choice != "off")
        if choice != "off" { set(["aiProvider"], choice) }
        updateAIBoxes()
    }

    /// Shows the settings for the chosen provider, and Copilot's install/sign-in state.
    private func updateAIBoxes() {
        let choice = Self.aiChoices[max(0, aiPopup.indexOfSelectedItem)].0
        claudeBox.isHidden = choice != "claude"
        copilotBox.isHidden = choice != "copilot"
        ollamaBox.isHidden = choice != "ollama"
        if choice == "ollama" { refreshOllama() }
        let path = AIHelp.findCopilot()
        copilotInstall.isHidden = path != nil
        copilotSignIn.isHidden = path == nil
        copilotTest.isHidden = path == nil
        copilotStatus.stringValue = path.map { "✓ GitHub Copilot CLI found at \($0). If answers fail with a sign-in error, click Sign In…" }
            ?? "The GitHub Copilot CLI isn't installed. Install… runs brew install --cask copilot-cli in a new tab (needs a paid Copilot plan)."
    }

    @objc private func copilotModelChanged() {
        let v = copilotModel.stringValue.trimmingCharacters(in: .whitespaces)
        set(["copilotModel"], v.isEmpty ? nil : v)
    }

    @objc private func installCopilot() { AppDelegate.shared.runInNewTab("brew install --cask copilot-cli") }
    @objc private func signInCopilot() {
        guard let path = AIHelp.findCopilot() else { updateAIBoxes(); return }
        AppDelegate.shared.runInNewTab(ShellLexer.escape(path) + " login")
    }

    /// Asks Copilot for a tiny answer, to check install, sign-in and plan in one go.
    @objc private func testCopilot() {
        copilotTest.isEnabled = false
        copilotStatus.stringValue = "Asking GitHub Copilot…"
        let model = copilotModel.stringValue
        Task { @MainActor [weak self] in
            let ai = AIHelp(model: model)
            do {
                let a = try await ai.generateCommand("print the current folder", context: .init(shell: "zsh", os: "macOS", cwdName: "test", gitBranch: nil))
                self?.copilotStatus.stringValue = "✓ Working (\(a.model ?? "GitHub Copilot")): \(a.commands.first ?? a.text.prefix(60).description)"
            } catch {
                self?.copilotStatus.stringValue = "✗ " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.copilotTest.isEnabled = true
        }
    }
    // MARK: Ollama

    private var ollamaURL: URL? { (Services.shared.config.ollamaURL).flatMap(URL.init(string:)) }

    /// Shows whether Ollama is installed and running, and its models.
    private func refreshOllama() {
        let installed = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app"].contains { FileManager.default.fileExists(atPath: $0) }
        ollamaInstall.isHidden = installed
        ollamaStatus.stringValue = installed ? "Checking Ollama…" : "Ollama isn't installed. Install Ollama… runs brew install ollama in a new tab."
        let base = ollamaURL ?? AIHelp.defaultOllamaURL
        let chosen = Services.shared.config.ollamaModel
        Task { @MainActor [weak self] in
            let models = await AIHelp.ollamaModels(base: base)
            guard let self else { return }
            self.ollamaStart.isHidden = !installed || models != nil
            self.ollamaPull.isHidden = models == nil
            self.ollamaTest.isHidden = models?.isEmpty ?? true
            self.ollamaModelPopup.removeAllItems()
            self.ollamaModelPopup.addItem(withTitle: "First installed model")
            for m in models ?? [] { self.ollamaModelPopup.addItem(withTitle: m) }
            if let chosen, self.ollamaModelPopup.item(withTitle: chosen) == nil { self.ollamaModelPopup.addItem(withTitle: chosen) }
            if let chosen { self.ollamaModelPopup.selectItem(withTitle: chosen) } else { self.ollamaModelPopup.selectItem(at: 0) }
            guard installed else { return }
            switch models {
            case nil: self.ollamaStatus.stringValue = "Ollama is installed but not running. Start Ollama runs it in the background."
            case let m? where m.isEmpty: self.ollamaStatus.stringValue = "Ollama is running but has no models. Get a Model… downloads \(Self.suggestedOllamaModel)."
            case let m?: self.ollamaStatus.stringValue = "✓ Ollama is running with \(m.count) model\(m.count == 1 ? "" : "s")."
            }
        }
    }

    @objc private func installOllama() { AppDelegate.shared.runInNewTab("brew install ollama") }
    @objc private func startOllama() {
        AppDelegate.shared.runInNewTab("brew services start ollama")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.refreshOllama() }
    }
    @objc private func pullOllama() { AppDelegate.shared.runInNewTab("ollama pull \(Self.suggestedOllamaModel)") }
    @objc private func ollamaModelChanged() {
        set(["ollamaModel"], ollamaModelPopup.indexOfSelectedItem <= 0 ? nil : ollamaModelPopup.titleOfSelectedItem)
    }
    @objc private func testOllama() {
        ollamaTest.isEnabled = false
        ollamaStatus.stringValue = "Asking the local model (the first answer can take a while as it loads)…"
        let model = ollamaModelPopup.indexOfSelectedItem <= 0 ? nil : ollamaModelPopup.titleOfSelectedItem
        let base = ollamaURL
        Task { @MainActor [weak self] in
            let ai = AIHelp(ollamaURL: base, ollamaModel: model)
            do {
                let a = try await ai.generateCommand("print the current folder", context: .init(shell: "zsh", os: "macOS", cwdName: "test", gitBranch: nil))
                self?.ollamaStatus.stringValue = "✓ Working (\(a.model ?? "Local AI")): \(a.commands.first ?? a.text.prefix(60).description)"
            } catch {
                self?.ollamaStatus.stringValue = "✗ " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.ollamaTest.isEnabled = true
        }
    }

    // MARK: Behavior extras

    @objc private func quickChanged() {
        quickField.isEnabled = quickToggle.state == .on
        let text = quickField.stringValue.trimmingCharacters(in: .whitespaces)
        set(["quickTerminalHotkey"], quickToggle.state == .on ? (text.isEmpty ? "ctrl+`" : text) : nil)
        QuickTerminal.shared.configure(quickToggle.state == .on ? (text.isEmpty ? "ctrl+`" : text) : nil)
        updateQuickStatus()
    }

    private func updateQuickStatus() {
        if let p = QuickTerminal.shared.problem { quickStatus.stringValue = "⚠︎ " + p; quickStatus.textColor = .systemRed }
        else if let hk = QuickTerminal.shared.hotKey { quickStatus.stringValue = "Press \(hk.display) in any app to show or hide it."; quickStatus.textColor = .secondaryLabelColor }
        else { quickStatus.stringValue = "Examples: ctrl+` · alt+space · cmd+shift+t · f12"; quickStatus.textColor = .secondaryLabelColor }
    }

    @objc private func updatesChanged() { Updater.shared.automaticallyChecks = updatesToggle.state == .on }

    @objc private func importOther() { AppDelegate.shared.importSettings() }

    @objc private func scrollbackChanged() {
        let mb = Self.scrollbackChoices[max(0, scrollbackPopup.indexOfSelectedItem)].0
        set(["scrollbackMB"], mb == 10 ? nil : mb)
    }

    /// Moves the notebook: an existing notebook at the new place is merged with yours, never overwritten.
    @objc private func notebookLocationChanged() {
        var loc: String?
        switch notebookPopup.indexOfSelectedItem {
        case 0: loc = nil
        case 1: loc = "icloud"
        default:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Use This Folder"
            panel.message = "The notebook is saved here as notebook.json. Pick a synced folder or a git repository to share it."
            guard panel.runModal() == .OK, let url = panel.url else { load(); return }
            loc = (url.path as NSString).abbreviatingWithTildeInPath
        }
        Self.moveNotebook(to: loc)
        set(["notebookLocation"], loc)
        AppDelegate.shared.reloadConfig(nil)
        Services.shared.watchNotebook()
        NotificationCenter.default.post(name: .anserNotebookChanged, object: nil)
        load()
    }

    /// Copies the notebook to a new location, merging with one already there.
    static func moveNotebook(to location: String?) {
        let from = NotebookWindow.fileURL, to = Services.notebookURL(for: location)
        guard from.standardizedFileURL != to.standardizedFileURL else { return }
        let mine = (try? Notebook.load(from: from)) ?? Notebook()
        let theirs = FileManager.default.fileExists(atPath: to.path) ? (try? Notebook.load(from: to)) : nil
        let merged = theirs.map { $0.merged(with: mine) } ?? mine
        try? merged.save(to: to)
    }

    @objc private func aiKeyChanged() {
        let v = aiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.hasPrefix("••") else { return }
        KeychainStore.set(v.isEmpty ? nil : v)
        aiKey.stringValue = v.isEmpty ? "" : "••••••••••••"
    }

    @objc private func notifyChanged() { set(["notifyAfterSeconds"], max(1, notifyField.doubleValue)) }
    @objc private func notifyToggled() {
        notifyField.isEnabled = notifyToggle.state == .on
        set(["notifyAfterSeconds"], notifyToggle.state == .on ? max(1, notifyField.doubleValue) : 0)
    }
    @objc private func tipsChanged() { set(["keyTips"], Self.tipModes[max(0, tipsPopup.indexOfSelectedItem)].0) }

    /// Redraws the sample terminal with the chosen theme, font and size.
    private func updatePreview() {
        var name = (previewLight ? lightThemeBox : themeBox).stringValue.trimmingCharacters(in: .whitespaces)
        if previewLight, name.isEmpty || name == "Default" { name = AnserConfig.Appearance.defaultLightTheme }
        let user = Self.userThemesDir + "/" + name
        let file = FileManager.default.fileExists(atPath: user) ? user : GhosttyRuntime.shared.resourcesDir.map { $0 + "/themes/" + name }
        preview.palette = (name.isEmpty || name == "Default") ? nil : file.flatMap(ThemePreviewView.Palette.load)
        let fam = fontPopup.indexOfSelectedItem <= 0 ? Self.defaultFontName : (fontPopup.titleOfSelectedItem ?? "")
        preview.font = NSFont(name: fam, size: CGFloat(termSize.doubleValue)) ?? NSFont.monospacedSystemFont(ofSize: CGFloat(termSize.doubleValue), weight: .regular)
        preview.needsDisplay = true
    }
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

/// A small fake terminal drawn with a theme's colors, so you can judge a
/// theme before applying it.
final class ThemePreviewView: NSView {
    struct Palette {
        var background: NSColor
        var foreground: NSColor
        var colors: [Int: NSColor]

        static func load(_ path: String) -> Palette? {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            var p = Palette(background: .black, foreground: .white, colors: [:])
            for line in text.components(separatedBy: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "background": p.background = color(kv[1]) ?? p.background
                case "foreground": p.foreground = color(kv[1]) ?? p.foreground
                case "palette":
                    let pv = kv[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if pv.count == 2, let i = Int(pv[0]), let c = color(pv[1]) { p.colors[i] = c }
                default: break
                }
            }
            return p
        }

        static func color(_ hex: String) -> NSColor? {
            var h = hex.trimmingCharacters(in: .whitespaces)
            if h.hasPrefix("#") { h.removeFirst() }
            guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
    }

    /// nil: the theme the terminal uses now.
    var palette: Palette?
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        let t = GhosttyRuntime.shared.theme
        let bg = palette?.background ?? t.background
        let fg = palette?.foreground ?? t.foreground
        func c(_ i: Int, _ fallback: NSColor) -> NSColor { palette?.colors[i] ?? fallback }
        let green = c(2, t.green), red = c(1, t.red), blue = c(4, t.blue), yellow = c(3, t.yellow), dim = fg.withAlphaComponent(0.5)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        bg.setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.stroke()
        let lines: [[(String, NSColor)]] = [
            [("❯ ", green), ("git status", fg)],
            [("On branch ", fg), ("main", blue)],
            [("  modified:   ", red), ("src/app.swift", red), ("     ✗ exit 1 · 0.3s", red)],
            [("❯ ", green), ("ls", fg), ("                       ", fg), ("✓ 12ms", dim)],
            [("README.md  ", fg), ("src/  ", blue), ("build.sh  ", green), ("notes.txt", yellow)],
        ]
        let lh = ceil(font.ascender - font.descender + font.leading) + 3
        var y = bounds.height - 12 - lh
        for line in lines {
            var x: CGFloat = 14
            for (text, color) in line {
                let a = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                a.draw(at: NSPoint(x: x, y: y))
                x += a.size().width
            }
            y -= lh
            if y < 4 { break }
        }
    }
}
