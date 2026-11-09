import AppKit
import AnserCore

/// Settings window. It edits ~/.config/anser/config.json in place (keeping
/// every other key as is); the app reloads that file automatically, so
/// changes apply live.
final class SettingsWindowController: NSWindowController, NSComboBoxDelegate {
    static let shared = SettingsWindowController()

    private struct Toggle {
        enum Section { case editor, notifications, helpers, privacy, sessions }
        let section: Section
        let path: [String]
        let title: String
        let defaultValue: Bool
    }

    private let toggles: [Toggle] = [
        Toggle(section: .editor, path: ["editorFollowsOutput"], title: "Move the input bar up to follow short output", defaultValue: false),
        Toggle(section: .editor, path: ["editor", "autoPopup"], title: "Show completions while typing", defaultValue: true),
        Toggle(section: .editor, path: ["editor", "ghostText"], title: "Suggest from history as gray text", defaultValue: true),
        Toggle(section: .editor, path: ["aiCompletions"], title: "When history has nothing, ask a local AI model (Ollama) for the gray text", defaultValue: false),
        Toggle(section: .editor, path: ["editor", "syntaxHighlighting"], title: "Color the command line", defaultValue: true),
        Toggle(section: .editor, path: ["editor", "lint"], title: "Underline mistakes and warn about risky commands", defaultValue: true),
        Toggle(section: .editor, path: ["editor", "vimMode"], title: "Vim keys (Esc for normal mode, i to type)", defaultValue: false),
        Toggle(section: .helpers, path: ["commandBlocks"], title: "Show command blocks (✓/✗ marks, colored bars, hover actions)", defaultValue: true),
        Toggle(section: .sessions, path: ["editor", "confirmMultilinePaste"], title: "Ask before multi-line pastes into running programs", defaultValue: true),
        Toggle(section: .sessions, path: ["copyOnSelect"], title: "Copy terminal text as soon as it's selected", defaultValue: false),
        Toggle(section: .sessions, path: ["restoreSession"], title: "Reopen windows, tabs and splits on launch", defaultValue: true),
        Toggle(section: .sessions, path: ["restoreDrafts"], title: "Remember unfinished local commands when reopening windows", defaultValue: true),
        Toggle(section: .helpers, path: ["previewFilesOnHover"], title: "Preview a file when the mouse rests on its path in the output", defaultValue: true),
        Toggle(section: .sessions, path: ["keepShellsRunning"], title: "Keep shells running when Anser quits or updates (⌥ Quit ends them)", defaultValue: true),
        Toggle(section: .sessions, path: ["showLoginMessage"], title: "Show macOS's \u{201C}Last login\u{201D} line in new tabs", defaultValue: false),
        Toggle(section: .privacy, path: ["saveOutput"], title: "Remember command output so History → Output can search it (on this Mac, secrets removed)", defaultValue: true),
        Toggle(section: .helpers, path: ["showPullRequests"], title: "Show the branch's pull request and checks (uses the GitHub CLI, gh)", defaultValue: true),
        Toggle(section: .notifications, path: ["waitAlerts"], title: "Mark the tab and notify when a program waits for an answer (y/n, password, an AI agent)", defaultValue: true),
        Toggle(section: .helpers, path: ["serverChips"], title: "Show servers a tab started (open, copy link, stop)", defaultValue: true),
        Toggle(section: .helpers, path: ["sshAutoReconnect"], title: "Reconnect dropped ssh sessions by myself", defaultValue: true),
        Toggle(section: .helpers, path: ["offerProjectEnvironment"], title: "Offer to load a project's .env, virtualenv and Node version when I cd into it", defaultValue: true),
        Toggle(section: .privacy, path: ["autoCleanHistory"], title: "Once a week, move typos in my history to Recently Deleted", defaultValue: false),
        Toggle(section: .helpers, path: ["suggestAliases"], title: "Suggest an alias for long commands I keep typing", defaultValue: true),
        Toggle(section: .helpers, path: ["testFailureList"], title: "List failed tests after a test run (open one, re-run just that test)", defaultValue: true),
        Toggle(section: .privacy, path: ["syncHistory"], title: "Share command history between my Macs (iCloud Drive or the notebook's folder)", defaultValue: false),
        Toggle(section: .privacy, path: ["usageStats"], title: "Count which features I use, only on this Mac (Help → Your Feature Usage)", defaultValue: false),
    ]
    private let tabView = NSTabView()
    private let searchField = NSSearchField()
    private let pluginsList = NSStackView()
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
    // Options that used to live only in config.json.
    private let cloudPopup = NSPopUpButton()
    static let cloudModes = [("auto", "When I type kubectl, aws, terraform…"), ("always", "Always"), ("off", "Never")]
    private let openWithBox = NSComboBox()
    static let openWithChoices = ["", "cursor", "code", "zed", "subl", "nvim", "vim"]
    private let quickHeight = NSSlider(value: 0.45, minValue: 0.2, maxValue: 0.9, target: nil, action: nil)
    private let quickHeightLabel = NSTextField(labelWithString: "45%")
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
        rebuildPlugins()
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
        for (_, t) in Self.cloudModes { cloudPopup.addItem(withTitle: t) }
        cloudPopup.target = self
        cloudPopup.action = #selector(cloudChanged)
        openWithBox.addItems(withObjectValues: Self.openWithChoices.map { $0.isEmpty ? "Automatic (first editor found)" : $0 })
        openWithBox.completes = true
        openWithBox.widthAnchor.constraint(equalToConstant: 230).isActive = true
        openWithBox.target = self
        openWithBox.action = #selector(openWithChanged)
        openWithBox.delegate = self
        openWithBox.toolTip = "The editor ⌘-clicked file paths open in: cursor, code, zed, subl, nvim… (openFilesWith)"
        quickHeight.target = self
        quickHeight.action = #selector(quickHeightChanged)
        quickHeight.widthAnchor.constraint(equalToConstant: 160).isActive = true
        func column(_ views: [NSView]) -> NSStackView {
            let st = NSStackView(views: views)
            st.orientation = .vertical
            st.alignment = .leading
            st.spacing = 8
            return st
        }
        func checks(_ section: Toggle.Section) -> [NSView] { toggles.indices.filter { toggles[$0].section == section }.map { checkboxes[$0] } }
        let notificationsPage = page([column(
            [NSStackView(views: [notifyToggle, notifyField, NSTextField(labelWithString: "seconds")])] + checks(.notifications)
            + [note("Watched commands (Shell → Run and Watch) notify when their output changes; stop one from the sidebar's Watching section. macOS can silence Anser in System Settings → Notifications.")])])
        let helpersPage = page([column(checks(.helpers) + [
            NSStackView(views: [NSTextField(labelWithString: "Show the cloud context chip:"), cloudPopup]),
            NSStackView(views: [NSTextField(labelWithString: "Open ⌘-clicked files with:"), openWithBox]),
        ])])
        let privacyPage = page([column(checks(.privacy) + [
            NSStackView(views: [NSTextField(labelWithString: "Keep the Command Notebook in:"), notebookPopup]),
            note("History and output stay on this Mac unless you turn on sharing. Commands that look like secrets are never saved."),
        ])])
        let sessionsPage = page([column(checks(.sessions) + [
            NSStackView(views: [NSTextField(labelWithString: "Scrollback per tab:"), scrollbackPopup]),
            NSStackView(views: [quickToggle, quickField]), quickStatus,
            NSStackView(views: [NSTextField(labelWithString: "Quick terminal height:"), quickHeight, quickHeightLabel]),
            updatesToggle,
        ])])

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
        let advanced = page([note("Everything else lives in the config file: history filters, completion helpers, profile environment variables and any Ghostty option. Changes there apply as soon as you save."),
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
            note("A profile applies where its pattern matches: an ssh host (prod-*, *.example.com), a folder starting with ~ or / (~/work/payments), a Kubernetes context (kube:prod-*) or an AWS profile (aws:prod*). It colors the tab, shows a badge, and can ask before running commands there."),
            profilesTable.view(height: 230),
            note("Tab colors: red, orange, yellow, green, blue, purple, teal. Ask before running: * for every command, or patterns like *rm -rf*, *drop table*, separated by commas. Extra environment variables (\"env\") can be added in the config file."),
        ])

        // Plugins: found in ~/.config/anser/plugins, each off until turned on here.
        pluginsList.orientation = .vertical
        pluginsList.alignment = .leading
        pluginsList.spacing = 10
        let pluginButtons = NSStackView(views: [
            ClosureButton(title: "Open Plugins Folder") { PluginHost.openFolder() },
            ClosureButton(title: "New Example Plugin") { [weak self] in
                if let dir = PluginHost.createExample() { PluginHost.shared.reload(); self?.rebuildPlugins(); NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
            },
            ClosureButton(title: "Reload") { [weak self] in PluginHost.shared.reload(); self?.rebuildPlugins() },
        ])
        let starter = NSPopUpButton(frame: .zero, pullsDown: true)
        starter.addItem(withTitle: "Add Starter Plugin")
        for item in PluginGallery.items {
            let mi = ClosureMenuItem(title: item.name) { [weak self] in
                if PluginHost.shared.installStarter(item) { self?.rebuildPlugins() }
            }
            mi.toolTip = item.description
            starter.menu?.addItem(mi)
        }
        pluginButtons.insertArrangedSubview(starter, at: 0)
        let pluginsPage = page([
            note("Plugins add status-row chips, command palette actions, sidebar sections and scripts that run after commands. Each is a folder with a plugin.json in ~/.config/anser/plugins (see docs/PLUGINS.md)."),
            note("Plugins run scripts on your Mac with your permissions. Turn on only plugins you wrote or trust. A repo can also ship plugins in .anser/plugins: they show as a chip and run only after you review and trust them."),
            pluginsList,
            pluginButtons,
        ])

        // Each section: a title and one line on what's in it, above its settings.
        func titled(_ title: String, _ page: NSView) -> NSView {
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 18, weight: .semibold)
            let d = NSTextField(wrappingLabelWithString: Self.sectionDescriptions[title] ?? "")
            d.font = .systemFont(ofSize: 12)
            d.textColor = .secondaryLabelColor
            d.preferredMaxLayoutWidth = 560
            let head = NSStackView(views: [t, d])
            head.orientation = .vertical
            head.alignment = .leading
            head.spacing = 3
            head.edgeInsets = NSEdgeInsets(top: 16, left: 22, bottom: 0, right: 22)
            let container = NSView()
            for v in [head, page] { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
            NSLayoutConstraint.activate([
                head.topAnchor.constraint(equalTo: container.topAnchor),
                head.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                head.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
                page.topAnchor.constraint(equalTo: head.bottomAnchor, constant: -6),
                page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                page.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            return container
        }
        for (title, view) in [("Appearance", appearance), ("Editor", editorPage), ("Notifications", notificationsPage),
                              ("Suggestions & Helpers", helpersPage), ("Privacy & History", privacyPage), ("Sessions & Windows", sessionsPage), ("AI", aiPage),
                              ("Shortcuts", shortcutsPage), ("Profiles", profilesPage), ("Plugins", pluginsPage), ("Advanced", advanced)] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = titled(title, view)
            tabView.addTabViewItem(item)
        }
        // A sidebar instead of tabs.
        let sideW: CGFloat = 180, pageW: CGFloat = 680, h: CGFloat = 640
        tabView.tabViewType = .noTabsNoBorder
        tabView.delegate = sidebar
        tabView.frame = NSRect(x: sideW, y: 0, width: pageW, height: h)
        tabView.autoresizingMask = [.width, .height]
        let root = NSView(frame: NSRect(x: 0, y: 0, width: sideW + pageW, height: h))
        let side = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: sideW, height: h))
        side.material = .sidebar
        side.blendingMode = .behindWindow
        side.autoresizingMask = [.height]
        sidebar.titles = tabView.tabViewItems.map(\.label)
        sidebar.onSelect = { [weak self] i in self?.tabView.selectTabViewItem(at: i) }
        sidebar.table.frame = NSRect(x: 0, y: 0, width: sideW, height: h - 52)
        let sideScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: sideW, height: h - 52))
        sideScroll.documentView = sidebar.table
        sideScroll.drawsBackground = false
        sideScroll.autoresizingMask = [.height]
        side.addSubview(sideScroll)
        // Search every section: Enter jumps to the matching setting.
        searchField.placeholderString = "Search settings"
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(searchSettings)
        searchField.frame = NSRect(x: 10, y: h - 40, width: sideW - 20, height: 24)
        searchField.autoresizingMask = [.minYMargin]
        side.addSubview(searchField)
        root.addSubview(side)
        root.addSubview(tabView)
        window?.contentView = root
        window?.setContentSize(NSSize(width: sideW + pageW, height: h))
        sidebar.table.reloadData()
        sidebar.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private let sidebar = SettingsSidebar()

    static let sectionDescriptions: [String: String] = [
        "Appearance": "The terminal's theme, font and colors.",
        "Editor": "How the command editor completes, suggests and highlights as you type.",
        "Notifications": "When Anser gets your attention: long commands finishing and programs waiting for an answer.",
        "Suggestions & Helpers": "Chips and helpers that appear while you work: servers, pull requests, project environments, alias tips, failed tests.",
        "Privacy & History": "What Anser keeps, where, and whether it's shared between your Macs. Nothing is ever sent anywhere else.",
        "Sessions & Windows": "What happens when you quit, reopen or paste, how much each tab keeps, and the quick terminal.",
        "AI": "Which AI helps (Claude, GitHub Copilot or a model on this Mac). Off until you turn it on; nothing is sent until you ask.",
        "Shortcuts": "Change any keyboard shortcut. Every action is also in the command palette (⇧⌘P).",
        "Profiles": "Settings for certain folders or servers: a tab color, a badge, and asking before risky commands.",
        "Plugins": "Add status-row chips, palette actions and sidebar sections with small scripts.",
        "Advanced": "The config file, Ghostty options and other settings most people never need.",
    ]

    // MARK: Plugins

    func rebuildPlugins() {
        pluginsList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let host = PluginHost.shared
        if host.plugins.isEmpty {
            let l = NSTextField(wrappingLabelWithString: "No plugins yet. “New Example Plugin” makes one to start from.")
            l.textColor = .secondaryLabelColor
            pluginsList.addArrangedSubview(l)
        }
        let on = Set(host.enabledIDs)
        for p in host.plugins {
            let box = NSButton(checkboxWithTitle: p.manifest.name, target: nil, action: nil)
            box.state = on.contains(p.id) ? .on : .off
            box.font = .systemFont(ofSize: 13, weight: .medium)
            let id = p.id
            box.target = self
            box.action = #selector(pluginToggled(_:))
            box.identifier = NSUserInterfaceItemIdentifier(id)
            let detail = NSTextField(wrappingLabelWithString: (p.manifest.description.map { $0 + "\n" } ?? "") + p.manifest.summary + " · folder \(id)")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 580
            var views: [NSView] = [box, detail]
            if !(p.manifest.settings ?? []).isEmpty {
                let b = ClosureButton(title: "Settings…") { [weak self] in PluginHost.shared.editSettings(p, over: self?.window) }
                b.controlSize = .small
                views.append(b)
            }
            let v = NSStackView(views: views)
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 2
            pluginsList.addArrangedSubview(v)
        }
        for e in host.errors {
            let l = NSTextField(wrappingLabelWithString: "⚠︎ " + e)
            l.textColor = .systemOrange
            l.font = .systemFont(ofSize: 11)
            pluginsList.addArrangedSubview(l)
        }
    }

    @objc private func pluginToggled(_ b: NSButton) {
        guard let id = b.identifier?.rawValue else { return }
        var list = PluginHost.shared.enabledIDs.filter { $0 != id }
        if b.state == .on { list.append(id) }
        set(["enabledPlugins"], list.isEmpty ? nil : list)
        Services.shared.record("plugin.toggle")
    }

    // MARK: Search

    struct SearchHit { let section: String; let text: String; weak var view: NSView? }

    /// Settings whose label or title contains every word of `query`.
    func searchHits(_ query: String) -> [SearchHit] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var hits: [SearchHit] = []
        func walk(_ v: NSView, _ section: String) {
            var text: String?
            if let b = v as? NSButton, !b.title.isEmpty, b.title.count > 2 { text = b.title }
            else if let f = v as? NSTextField, !f.isEditable, !f.stringValue.isEmpty { text = f.stringValue }
            if let t = text {
                let l = t.lowercased()
                if words.allSatisfy(l.contains), !hits.contains(where: { $0.text == t }) { hits.append(SearchHit(section: section, text: t, view: v)) }
            }
            v.subviews.forEach { walk($0, section) }
        }
        for item in tabView.tabViewItems { if let v = item.view { walk(v, item.label) } }
        return hits
    }

    @objc private func searchSettings() {
        let hits = searchHits(searchField.stringValue)
        guard !hits.isEmpty else { if !searchField.stringValue.isEmpty { NSSound.beep() }; return }
        if hits.count == 1 { reveal(hits[0]); return }
        let m = NSMenu()
        for h in hits.prefix(14) {
            let short = h.text.count > 70 ? String(h.text.prefix(68)) + "…" : h.text
            m.addItem(ClosureMenuItem(title: "\(h.section) › \(short)") { [weak self] in self?.reveal(h) })
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: searchField)
    }

    func reveal(_ h: SearchHit) {
        tabView.selectTabViewItem(withIdentifier: h.section)
        guard let v = h.view else { return }
        v.scrollToVisible(v.bounds)
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { v.layer?.backgroundColor = nil }
        if let b = v as? NSButton { window?.makeFirstResponder(b) }
    }

    /// Shows one section (0 Appearance … 11 Advanced).
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
        out["host"] = nil; out["folder"] = nil; out["kubeContext"] = nil; out["awsProfile"] = nil
        let lower = match.lowercased()
        if lower.hasPrefix("kube:") { out["kubeContext"] = String(match.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        else if lower.hasPrefix("aws:") { out["awsProfile"] = String(match.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        else if match.hasPrefix("~") || match.hasPrefix("/") { out["folder"] = match } else { out["host"] = match }
        for k in ["badge", "tabColor"] {
            let v = (r[k] as? String ?? "").trimmingCharacters(in: .whitespaces)
            out[k] = v.isEmpty ? nil : v
        }
        let confirm = (r["confirm"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        out["confirm"] = confirm.isEmpty ? nil : confirm
        return out
    }

    static func profileRow(_ j: [String: Any]) -> [String: Any] {
        ["match": (j["host"] as? String) ?? (j["folder"] as? String) ?? (j["kubeContext"] as? String).map { "kube:" + $0 }
            ?? (j["awsProfile"] as? String).map { "aws:" + $0 } ?? "", "badge": j["badge"] as? String ?? "",
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
        let cloud = (value(json, ["showCloudContext"]) as? String) ?? "auto"
        cloudPopup.selectItem(at: Self.cloudModes.firstIndex { $0.0 == cloud } ?? 0)
        let openWith = (value(json, ["openFilesWith"]) as? String) ?? ""
        openWithBox.stringValue = openWith.isEmpty ? "Automatic (first editor found)" : openWith
        let qh = (value(json, ["quickTerminalHeight"]) as? Double) ?? 0.45
        quickHeight.doubleValue = qh
        quickHeightLabel.stringValue = "\(Int((qh * 100).rounded()))%"
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
            if box === openWithBox { openWithChanged(); return }
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
    @objc private func cloudChanged() { set(["showCloudContext"], Self.cloudModes[max(0, cloudPopup.indexOfSelectedItem)].0) }
    @objc private func openWithChanged() {
        let v = openWithBox.stringValue.trimmingCharacters(in: .whitespaces)
        set(["openFilesWith"], v.isEmpty || v.hasPrefix("Automatic") ? nil : v)
    }
    @objc private func quickHeightChanged() {
        let v = (quickHeight.doubleValue * 20).rounded() / 20
        quickHeightLabel.stringValue = "\(Int((v * 100).rounded()))%"
        set(["quickTerminalHeight"], v)
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

/// The list of sections down the left of Settings.
final class SettingsSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate {
    let table = NSTableView()
    var titles: [String] = []
    var onSelect: ((Int) -> Void)?
    static let symbols: [String: String] = ["Appearance": "paintbrush", "Editor": "character.cursor.ibeam", "Notifications": "bell", "Suggestions & Helpers": "lightbulb",
                                            "Privacy & History": "hand.raised", "Sessions & Windows": "macwindow.on.rectangle",
                                            "AI": "sparkles", "Shortcuts": "keyboard", "Profiles": "person.crop.rectangle.stack",
                                            "Plugins": "puzzlepiece.extension", "Advanced": "wrench.and.screwdriver"]

    override init() {
        super.init()
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("s"))
        table.addTableColumn(c)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 28
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
    }

    func numberOfRows(in tableView: NSTableView) -> Int { titles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let icon = NSImageView(image: NSImage(systemSymbolName: Self.symbols[titles[row]] ?? "circle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        let l = NSTextField(labelWithString: titles[row])
        let v = NSStackView(views: [icon, l])
        v.spacing = 7
        v.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0 { onSelect?(table.selectedRow) }
    }

    // Keeps the list in step when a section is chosen another way (search, show(section:)).
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let item = tabViewItem, let i = titles.firstIndex(of: item.label), table.selectedRow != i else { return }
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
    }
}
