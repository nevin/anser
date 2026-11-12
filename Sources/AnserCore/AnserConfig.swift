import Foundation

/// User settings from ~/.config/anser/config.json. Every field is optional in
/// the file; missing fields keep their defaults.
public struct AnserConfig: Codable, Sendable {
    public struct Snippet: Codable, Sendable, Hashable {
        public var name: String
        /// Command text. `{{placeholder}}` marks fields you Tab between.
        public var command: String
        public var description: String?
    }

    public struct Editor: Codable, Sendable {
        /// Show the completion popup automatically while typing.
        public var autoPopup: Bool = true
        /// Show the best history match as gray "ghost" text.
        public var ghostText: Bool = true
        /// Color the command line (commands, flags, strings, paths).
        public var syntaxHighlighting: Bool = true
        /// Ask before running a command pasted with several lines.
        public var confirmMultilinePaste: Bool = true
        public var fontSize: Double = 13
        public var fontFamily: String?
        /// Delay before the popup appears (ms).
        public var popupDelayMs: Int = 60
        /// Underline mistakes (unknown commands, open quotes and brackets) and warn about risky commands.
        public var lint: Bool = true
        /// vi keys in the editor: Esc for normal mode, i to type again.
        public var vimMode: Bool = false

        public init() {}
        public init(from decoder: Decoder) throws {
            let d = Editor()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            autoPopup = try c.decodeIfPresent(Bool.self, forKey: .autoPopup) ?? d.autoPopup
            ghostText = try c.decodeIfPresent(Bool.self, forKey: .ghostText) ?? d.ghostText
            syntaxHighlighting = try c.decodeIfPresent(Bool.self, forKey: .syntaxHighlighting) ?? d.syntaxHighlighting
            confirmMultilinePaste = try c.decodeIfPresent(Bool.self, forKey: .confirmMultilinePaste) ?? d.confirmMultilinePaste
            fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
            fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
            popupDelayMs = try c.decodeIfPresent(Int.self, forKey: .popupDelayMs) ?? d.popupDelayMs
            lint = try c.decodeIfPresent(Bool.self, forKey: .lint) ?? d.lint
            vimMode = try c.decodeIfPresent(Bool.self, forKey: .vimMode) ?? d.vimMode
        }
    }

    /// Terminal look. Empty fields keep your Ghostty config (or Ghostty's defaults).
    public struct Appearance: Codable, Sendable {
        public var fontFamily: String?
        public var fontSize: Double?
        /// A Ghostty theme name, e.g. "Catppuccin Mocha", "GitHub Dark".
        /// Without `mode` this is the one theme always used (and the window follows macOS).
        public var theme: String?
        /// "system" (follow macOS), "dark" or "light". Sets the window chrome and
        /// picks `darkTheme` / `lightTheme` for the terminal. nil keeps the old single-theme behavior.
        public var mode: String?
        /// Terminal theme in dark mode (falls back to `theme`, then Ghostty's default).
        public var darkTheme: String?
        /// Terminal theme in light mode (falls back to "Xcode Light").
        public var lightTheme: String?

        public static let defaultLightTheme = "Xcode Light"

        public init(mode: String?) { self.mode = mode }

        /// Whether the dark look applies, given whether macOS itself is in dark mode.
        public func usesDark(systemIsDark: Bool) -> Bool {
            switch mode {
            case "dark": true
            case "light": false
            default: systemIsDark
            }
        }

        /// The terminal theme to use right now, or nil for whatever Ghostty would pick.
        public func themeName(systemIsDark: Bool) -> String? {
            func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
            guard mode != nil else { return nonEmpty(theme) }
            if usesDark(systemIsDark: systemIsDark) { return nonEmpty(darkTheme) ?? nonEmpty(theme) }
            return nonEmpty(lightTheme) ?? Self.defaultLightTheme
        }
        /// 0.3–1.0
        public var backgroundOpacity: Double?
        /// "block", "bar", "underline", "block_hollow"
        public var cursorStyle: String?
        public var cursorBlink: Bool?
        public var padding: Double?
        /// false turns off programming ligatures (=> != ->) in fonts that have them.
        public var ligatures: Bool?

        public init() {}

        /// The Ghostty config lines for these settings (dark macOS assumed when not given).
        public var ghosttyLines: [String] { ghosttyLines(systemIsDark: true) }

        public func ghosttyLines(systemIsDark: Bool) -> [String] {
            var l: [String] = []
            if let f = fontFamily, !f.isEmpty { l += ["font-family = \"\"", "font-family = \(f)"] }
            if let s = fontSize { l.append("font-size = \(s)") }
            if let t = themeName(systemIsDark: systemIsDark) { l.append("theme = \(t)") }
            if let o = backgroundOpacity { l.append("background-opacity = \(min(1, max(0.2, o)))") }
            if let c = cursorStyle, !c.isEmpty { l.append("cursor-style = \(c)") }
            if let b = cursorBlink { l.append("cursor-style-blink = \(b)") }
            if let p = padding { l += ["window-padding-x = \(Int(p))", "window-padding-y = \(Int(max(0, p - 2)))"] }
            if ligatures == false { l += ["font-feature = -calt", "font-feature = -liga", "font-feature = -dlig"] }
            return l
        }
    }

    public var appearance = Appearance()
    /// The shell's own prompt while the editor is on: "hidden" (the editor is
    /// the only input; commands stay in scrollback as "❯ command"),
    /// "compact" (a short ❯) or "full" (your prompt, unchanged).
    public var shellPrompt: String = "hidden"
    /// Editor for ⌘-clicked file paths: "code", "cursor", "zed", "nvim"…
    /// Empty picks the first GUI editor found on PATH, else the default app.
    public var openFilesWith: String?
    /// Colored bars beside each command's output, with hover actions.
    public var commandBlocks: Bool = true
    /// Optional AI help (explain errors, generate commands) via Claude or GitHub Copilot (`aiProvider`).
    /// Off until you turn it on; the API key lives in the Keychain.
    public var aiEnabled: Bool = false
    /// Which AI answers: "claude" (Claude API, your key) or "copilot" (GitHub Copilot CLI, your GitHub sign-in).
    public var aiProvider: String = "claude"
    /// Optional Copilot model (e.g. "claude-sonnet-4.5", "gpt-5"); empty lets Copilot choose.
    public var copilotModel: String?
    /// Ollama model for local AI (e.g. "qwen2.5-coder:7b"); empty uses the first installed model.
    public var ollamaModel: String?
    /// Where Ollama listens (default http://localhost:11434).
    public var ollamaURL: String?
    /// A key that shows or hides a drop-down terminal from any app, e.g. "ctrl+`" or "alt+space". nil = off.
    public var quickTerminalHotkey: String?
    /// Height of the drop-down terminal as a share of the screen (0.2–0.9).
    public var quickTerminalHeight: Double = 0.45
    /// Per-folder / per-ssh-host settings: tab color, a badge, extra environment.
    public var profiles: [Profile] = []
    /// Hovering a file path printed in the output shows a Quick Look preview.
    public var previewFilesOnHover: Bool = true
    /// Shells keep running when Anser quits, restarts or updates, and come back
    /// with their tabs (needs `restoreSession`). Closing a tab or pane still ends its shell.
    public var keepShellsRunning: Bool = true
    /// Show the branch's pull request and its checks next to the branch (needs the GitHub CLI, `gh`).
    public var showPullRequests: Bool = true
    /// Keep each command's output (secrets removed) so History → Output can search it. Stays on this Mac.
    public var saveOutput: Bool = true
    /// Count which features you use, only on this Mac (Help → Usage). Off until you turn it on.
    public var usageStats: Bool = false
    /// Where the Command Notebook lives: nil = ~/.config/anser/notebook.json, "icloud" = iCloud Drive/Anser,
    /// or a folder path (e.g. a git repo you sync yourself).
    public var notebookLocation: String?
    public var editor = Editor()
    /// Expanded when you press space after them, fish-style: "gco" → "git checkout".
    public var abbreviations: [String: String] = [:]
    public var snippets: [Snippet] = []
    /// Key → action. Keys look like "cmd+shift+k", "ctrl+g".
    /// Actions: "run:<command>", "insert:<text>", "snippet:<name>",
    /// "action:<name>" (see `AnserAction`), "ghostty:<ghostty binding action>".
    public var keybindings: [String: String] = [:]
    /// Notify when a command that ran longer than this finishes in the background (seconds; 0 = off).
    public var notifyAfterSeconds: Double = 10
    /// Copy terminal text as soon as it's selected.
    public var copyOnSelect: Bool = false
    /// Extra lines appended to the generated Ghostty config (font, theme, etc.).
    public var ghostty: [String] = []
    /// Number of clipboard items to remember.
    public var clipboardHistorySize: Int = 50
    /// Scrollback each tab keeps, in MB (the terminal drops the oldest lines past this).
    public var scrollbackMB: Int = 10
    /// Extra commands that may be run with `--help` to learn their flags.
    public var helpCommands: [String] = []
    /// Commands matching any of these patterns (* and ? wildcards, case-insensitive)
    /// are never saved to history.
    public var historyIgnore: [String] = AnserConfig.defaultHistoryIgnore
    /// Reopen windows, tabs, splits and their folders on launch.
    public var restoreSession: Bool = true
    /// Restore unfinished local commands with the window layout.
    public var restoreDrafts: Bool = true
    /// Replace the shell's prompt with a short "❯", since the bar already shows folder and branch.
    public var compactPrompt: Bool = false
    /// The editor sits right under the last output line until the screen
    /// fills, instead of at the bottom of the window.
    public var editorFollowsOutput: Bool = false
    /// Show macOS's "Last login: …" line when a tab opens.
    public var showLoginMessage: Bool = false
    /// A thin line after each command in the scrollback with who ran it, on which Mac, and when:
    /// "dotted", "line" or "none".
    public var commandSeparator: String = "dotted"
    /// Keyboard tips in the hints row under the editor. "auto" shows them while you're new
    /// (your first few hundred commands), then hides them.
    public var keyTips: String = "always"
    /// Mark the tab and notify when a running program waits for an answer (y/n, password, an AI agent's approval).
    public var waitAlerts: Bool = true
    /// Show servers a tab started (anything listening on a port) as a chip.
    public var serverChips: Bool = true
    /// The cloud context chip: "auto" (when a command uses kubectl, aws, docker…), "always" or "off".
    public var showCloudContext: String = "auto"
    /// Reconnect a dropped ssh session by itself (otherwise Anser only offers to).
    public var sshAutoReconnect: Bool = true
    /// Share command history between your Macs, through `syncFolder` (or iCloud Drive/Anser).
    public var syncHistory: Bool = false
    /// Folder for history sync; nil = the notebook's synced folder, else iCloud Drive/Anser.
    public var syncFolder: String?
    /// Plugins (folders in ~/.config/anser/plugins) that are turned on.
    public var enabledPlugins: [String] = []
    /// Values for plugin settings: plugin id → key → value (secret ones are in the Keychain).
    public var pluginSettings: [String: [String: String]] = [:]
    /// Offer to load a project's environment (.env, virtualenv, Node version) when you cd into it.
    public var offerProjectEnvironment: Bool = true
    /// ssh port forwards Anser keeps open in the background.
    public var tunnels: [SSHTunnel] = []
    /// After a test command fails, list the failed tests (open, re-run one).
    public var testFailureList: Bool = true
    /// Suggest an alias for long commands you keep typing.
    public var suggestAliases: Bool = true
    /// Once a week, move typos and commands that were never found to Recently Deleted.
    public var autoCleanHistory: Bool = false
    /// Grey inline completions from a local Ollama model when history has none.
    public var aiCompletions: Bool = false
    /// Named groups of ssh hosts for Run on Servers ("web": ["web1", "web2"]).
    public var hostGroups: [String: [String]] = [:]
    /// Hide the command bar while these full-screen programs run.
    public var fullscreenApps: [String] = AnserConfig.defaultFullscreenApps

    public static let defaultHistoryIgnore = [
        "*password=*", "*passwd=*", "*secret=*", "*token=*", "*api_key=*", "*apikey=*",
        "*_key=*", "*authorization: bearer*", "export *secret*", "export *token*", "export *password*",
    ]
    public static let defaultFullscreenApps = [
        "vim", "nvim", "vi", "nano", "emacs", "micro", "hx", "helix", "less", "more", "man", "htop", "btop", "top",
        "tmux", "screen", "lazygit", "tig", "ranger", "yazi", "nnn", "mc", "k9s", "watch",
    ]

    /// True when a command should stay out of history.
    public func shouldIgnoreInHistory(_ command: String) -> Bool {
        let c = command.lowercased()
        return historyIgnore.contains { AnserConfig.glob($0.lowercased(), c) }
    }

    /// Minimal glob: `*` any run, `?` one character.
    public static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] { pi += 1; ti += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = AnserConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        editor = try c.decodeIfPresent(Editor.self, forKey: .editor) ?? d.editor
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        openFilesWith = try c.decodeIfPresent(String.self, forKey: .openFilesWith)
        commandBlocks = try c.decodeIfPresent(Bool.self, forKey: .commandBlocks) ?? d.commandBlocks
        aiEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? d.aiEnabled
        aiProvider = try c.decodeIfPresent(String.self, forKey: .aiProvider) ?? d.aiProvider
        copilotModel = try c.decodeIfPresent(String.self, forKey: .copilotModel)
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel)
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL)
        quickTerminalHotkey = try c.decodeIfPresent(String.self, forKey: .quickTerminalHotkey)
        quickTerminalHeight = try c.decodeIfPresent(Double.self, forKey: .quickTerminalHeight) ?? d.quickTerminalHeight
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        saveOutput = try c.decodeIfPresent(Bool.self, forKey: .saveOutput) ?? d.saveOutput
        showPullRequests = try c.decodeIfPresent(Bool.self, forKey: .showPullRequests) ?? d.showPullRequests
        keepShellsRunning = try c.decodeIfPresent(Bool.self, forKey: .keepShellsRunning) ?? d.keepShellsRunning
        previewFilesOnHover = try c.decodeIfPresent(Bool.self, forKey: .previewFilesOnHover) ?? d.previewFilesOnHover
        usageStats = try c.decodeIfPresent(Bool.self, forKey: .usageStats) ?? d.usageStats
        notebookLocation = try c.decodeIfPresent(String.self, forKey: .notebookLocation)
        abbreviations = try c.decodeIfPresent([String: String].self, forKey: .abbreviations) ?? [:]
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        keybindings = try c.decodeIfPresent([String: String].self, forKey: .keybindings) ?? [:]
        notifyAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .notifyAfterSeconds) ?? d.notifyAfterSeconds
        copyOnSelect = try c.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? d.copyOnSelect
        ghostty = try c.decodeIfPresent([String].self, forKey: .ghostty) ?? []
        clipboardHistorySize = try c.decodeIfPresent(Int.self, forKey: .clipboardHistorySize) ?? d.clipboardHistorySize
        scrollbackMB = min(1000, max(1, try c.decodeIfPresent(Int.self, forKey: .scrollbackMB) ?? d.scrollbackMB))
        helpCommands = try c.decodeIfPresent([String].self, forKey: .helpCommands) ?? []
        historyIgnore = try c.decodeIfPresent([String].self, forKey: .historyIgnore) ?? d.historyIgnore
        restoreSession = try c.decodeIfPresent(Bool.self, forKey: .restoreSession) ?? d.restoreSession
        restoreDrafts = try c.decodeIfPresent(Bool.self, forKey: .restoreDrafts) ?? d.restoreDrafts
        compactPrompt = try c.decodeIfPresent(Bool.self, forKey: .compactPrompt) ?? d.compactPrompt
        shellPrompt = try c.decodeIfPresent(String.self, forKey: .shellPrompt) ?? (compactPrompt ? "compact" : d.shellPrompt)
        fullscreenApps = try c.decodeIfPresent([String].self, forKey: .fullscreenApps) ?? d.fullscreenApps
        editorFollowsOutput = try c.decodeIfPresent(Bool.self, forKey: .editorFollowsOutput) ?? d.editorFollowsOutput
        showLoginMessage = try c.decodeIfPresent(Bool.self, forKey: .showLoginMessage) ?? d.showLoginMessage
        if let on = try? c.decodeIfPresent(Bool.self, forKey: .commandSeparator) { commandSeparator = on ? "line" : "none" }
        else {
            let v = (try? c.decodeIfPresent(String.self, forKey: .commandSeparator)) ?? nil
            commandSeparator = ["line", "dotted", "none"].contains(v ?? "") ? v! : d.commandSeparator
        }
        keyTips = try c.decodeIfPresent(String.self, forKey: .keyTips) ?? d.keyTips
        waitAlerts = try c.decodeIfPresent(Bool.self, forKey: .waitAlerts) ?? d.waitAlerts
        serverChips = try c.decodeIfPresent(Bool.self, forKey: .serverChips) ?? d.serverChips
        showCloudContext = try c.decodeIfPresent(String.self, forKey: .showCloudContext) ?? d.showCloudContext
        sshAutoReconnect = try c.decodeIfPresent(Bool.self, forKey: .sshAutoReconnect) ?? d.sshAutoReconnect
        syncHistory = try c.decodeIfPresent(Bool.self, forKey: .syncHistory) ?? d.syncHistory
        syncFolder = try c.decodeIfPresent(String.self, forKey: .syncFolder)
        enabledPlugins = try c.decodeIfPresent([String].self, forKey: .enabledPlugins) ?? []
        pluginSettings = try c.decodeIfPresent([String: [String: String]].self, forKey: .pluginSettings) ?? [:]
        offerProjectEnvironment = try c.decodeIfPresent(Bool.self, forKey: .offerProjectEnvironment) ?? d.offerProjectEnvironment
        tunnels = (try? c.decodeIfPresent([SSHTunnel].self, forKey: .tunnels)) ?? []
        testFailureList = try c.decodeIfPresent(Bool.self, forKey: .testFailureList) ?? d.testFailureList
        suggestAliases = try c.decodeIfPresent(Bool.self, forKey: .suggestAliases) ?? d.suggestAliases
        autoCleanHistory = try c.decodeIfPresent(Bool.self, forKey: .autoCleanHistory) ?? d.autoCleanHistory
        aiCompletions = try c.decodeIfPresent(Bool.self, forKey: .aiCompletions) ?? d.aiCompletions
        hostGroups = try c.decodeIfPresent([String: [String]].self, forKey: .hostGroups) ?? [:]
    }

    public static var directory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("anser")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/anser")
    }

    public static var fileURL: URL { directory.appendingPathComponent("config.json") }
    public static var completionsDirectory: URL { directory.appendingPathComponent("completions") }

    /// Loads the config, writing a starter file the first time.
    public static func load() -> (AnserConfig, String?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: completionsDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            try? starterConfig.write(to: fileURL, atomically: true, encoding: .utf8)
            let example = completionsDirectory.appendingPathComponent("example.json.disabled")
            try? starterSpec.write(to: example, atomically: true, encoding: .utf8)
        }
        guard let data = fm.contents(atPath: fileURL.path) else { return (AnserConfig(), nil) }
        do {
            return (try JSONDecoder().decode(AnserConfig.self, from: data), nil)
        } catch {
            return (AnserConfig(), "config.json: \(error.localizedDescription)")
        }
    }

    /// Normalizes "Cmd+Shift+K" → "cmd+shift+k" with modifiers in a fixed order.
    public static func normalizeKey(_ s: String) -> String {
        let parts = s.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last else { return s }
        let order = ["ctrl", "alt", "shift", "cmd"]
        let alias = ["control": "ctrl", "option": "alt", "opt": "alt", "command": "cmd", "super": "cmd"]
        let mods = Set(parts.dropLast().map { alias[$0] ?? $0 })
        return (order.filter(mods.contains) + [key]).joined(separator: "+")
    }

    public static let starterConfig = """
    {
      "editor": {
        "autoPopup": true,
        "ghostText": true,
        "syntaxHighlighting": true,
        "confirmMultilinePaste": true,
        "fontSize": 13
      },
      "abbreviations": {
        "gst": "git status",
        "gco": "git checkout",
        "gcm": "git commit -m",
        "gp": "git push",
        "gl": "git log --oneline --graph -20"
      },
      "profiles": [
        { "host": "prod-*", "tabColor": "red", "badge": "PROD" }
      ],
      "keybindings": {
        "ctrl+g": "insert:git ",
        "cmd+shift+o": "action:copyLastOutput"
      },
      "historyIgnore": ["*password=*", "*token=*", "*secret=*", "*api_key=*", "export *secret*"],
      "helpCommands": [],
      "restoreSession": true,
      "restoreDrafts": true,
      "shellPrompt": "hidden",
      "editorFollowsOutput": false,
      "showLoginMessage": false,
      "commandSeparator": "dotted",
      "keyTips": "always",
      "appearance": {
        "fontFamily": null,
        "fontSize": null,
        "mode": "system",
        "darkTheme": null,
        "lightTheme": null,
        "backgroundOpacity": null,
        "cursorStyle": null
      },
      "notifyAfterSeconds": 10,
      "copyOnSelect": false,
      "clipboardHistorySize": 50,
      "ghostty": [
        "font-size = 13",
        "window-padding-x = 8",
        "window-padding-y = 6"
      ]
    }

    """

    public static let starterSpec = """
    {
      "name": "deploy",
      "description": "Example custom completion. Rename to deploy.json to enable.",
      "subcommands": [
        { "name": "staging", "description": "Deploy to staging" },
        { "name": "production", "description": "Deploy to production" }
      ],
      "options": [
        { "name": ["-f", "--force"], "description": "Skip safety checks" },
        { "name": "--service", "description": "Which service",
          "args": { "generators": { "script": "ls services", "cacheSeconds": 10 } } }
      ]
    }

    """
}

/// Named actions that keybindings and the command palette can trigger.
public enum AnserAction: String, CaseIterable, Sendable {
    case historySearch, clipboardHistory, commandPalette, copyLastOutput, copyLastCommand
    case newTab, newWindow, splitRight, splitDown, splitLeft, splitUp, closePane, focusNextPane, focusPreviousPane
    case clearScreen, toggleEditor, rerunLastCommand, openConfig, reloadConfig, jumpToPreviousPrompt, jumpToNextPrompt
    case increaseFontSize, decreaseFontSize, resetFontSize
    case findInTerminal, blockNavigator, pauseHistory, openSettings
    case expandEditor, formatCommand, externalEditor
    case renameTab, nextTab, previousTab, closeTab, switchToTab
    case jumpToFolder, switchBranch, changedFiles, showShortcuts
    case moveTabLeft, moveTabRight, moveTabToNewWindow
    case saveWorkspace, openWorkspace
    case zoomPane, toggleSidebar
    case runWorkflow, saveWorkflow, exportMarkdown, copyMarkdown, reportProblem
    case explainError, askClaude
    case notebook, editNotebook, saveToNotebook, exportLastOutput, openWorkflowsFolder
    case gitHistory, gitStashes, gitFetch, gitPull, gitPush
    case quickTerminal, broadcastInput, searchOutput, resolveConflicts, openPullRequest
    case importSettings, checkForUpdates, showUsage
    case gitBlame, searchAllTabs, shareTab, deepClean
    case filterOutput, killPort, compareLastRun, viewOutputAsData, manageSecrets, whatsNew, syncHistoryNow
    case managePlugins, shareCommand
    case watchAndRerun, whenDone, failedTests, projectEnvironment, runbooks, newRunbook, aiTask
    case uploadToServer, downloadFromServer, addTunnel
    case aliases, logViewer, recordTab, openRecording, editHistory
    case watchOutput, runOnServers, forwardRemotePort, library, tour, searchSaved

    public var title: String {
        switch self {
        case .historySearch: "Search (history, this tab, output, all tabs, saved)"
        case .clipboardHistory: "Clipboard History"
        case .commandPalette: "Command Palette"
        case .copyLastOutput: "Copy Last Output"
        case .copyLastCommand: "Copy Last Command"
        case .newTab: "New Tab"
        case .newWindow: "New Window"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .splitLeft: "Split Left"
        case .splitUp: "Split Up"
        case .closePane: "Close Pane"
        case .focusNextPane: "Next Pane"
        case .focusPreviousPane: "Previous Pane"
        case .clearScreen: "Clear"
        case .toggleEditor: "Toggle Command Editor"
        case .rerunLastCommand: "Re-run Last Command"
        case .openConfig: "Open Config File"
        case .reloadConfig: "Reload Config"
        case .jumpToPreviousPrompt: "Jump to Previous Prompt"
        case .jumpToNextPrompt: "Jump to Next Prompt"
        case .increaseFontSize: "Bigger Text"
        case .decreaseFontSize: "Smaller Text"
        case .resetFontSize: "Reset Text Size"
        case .findInTerminal: "Find in Terminal"
        case .blockNavigator: "Search This Tab's Commands"
        case .pauseHistory: "Pause History for This Tab"
        case .openSettings: "Settings"
        case .expandEditor: "Expand Command Editor"
        case .formatCommand: "Split / Join Command Lines"
        case .externalEditor: "Edit Command in $EDITOR"
        case .renameTab: "Rename Tab"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .closeTab: "Close Tab"
        case .switchToTab: "Switch to Tab"
        case .jumpToFolder: "Jump to Folder"
        case .switchBranch: "Git: Switch or Create Branch"
        case .changedFiles: "Git: Changed Files"
        case .showShortcuts: "Keyboard Shortcuts"
        case .moveTabLeft: "Move Tab Left"
        case .moveTabRight: "Move Tab Right"
        case .moveTabToNewWindow: "Move Tab to New Window"
        case .saveWorkspace: "Save Window as Workspace"
        case .openWorkspace: "Open Workspace"
        case .zoomPane: "Zoom Pane / Restore Split"
        case .toggleSidebar: "Toggle Sidebar"
        case .runWorkflow: "Run from Notebook (commands and workflows)"
        case .saveWorkflow: "Save Several Commands to Notebook (a workflow)"
        case .exportMarkdown: "Export Tab (Markdown, JSON, PDF…)"
        case .copyMarkdown: "Copy Tab as Markdown"
        case .reportProblem: "Report a Problem"
        case .explainError: "Explain Last Error with AI"
        case .askClaude: "Ask AI for a Command"
        case .notebook: "Saved Panel (notebook and runbooks)"
        case .editNotebook: "Manage Notebook"
        case .saveToNotebook: "Save Command to Notebook"
        case .exportLastOutput: "Export Last Command's Output"
        case .openWorkflowsFolder: "Open Workflows Folder"
        case .gitHistory: "Git: Commit History"
        case .gitStashes: "Git: Stashes"
        case .gitFetch: "Git: Fetch"
        case .gitPull: "Git: Pull"
        case .gitPush: "Git: Push"
        case .quickTerminal: "Show / Hide Quick Terminal"
        case .broadcastInput: "Type in All Panes of This Tab"
        case .searchOutput: "Search Command Output"
        case .resolveConflicts: "Git: Resolve Conflicts"
        case .openPullRequest: "Git: Open Pull Request"
        case .importSettings: "Import from iTerm2 or Warp"
        case .checkForUpdates: "Check for Updates"
        case .showUsage: "Your Feature Usage"
        case .gitBlame: "Git: Blame File"
        case .searchAllTabs: "Search All Tabs"
        case .shareTab: "Share This Tab (Read-Only)"
        case .deepClean: "Deep Clean (reset and forget this tab's output)"
        case .filterOutput: "Filter Output (search, errors only, fold repeats)"
        case .killPort: "Kill Process on Port…"
        case .compareLastRun: "Compare Last Command with Its Previous Run"
        case .viewOutputAsData: "View Last Output as Table / JSON"
        case .manageSecrets: "Manage Secrets…"
        case .whatsNew: "What's New in Anser"
        case .syncHistoryNow: "Sync History Now"
        case .managePlugins: "Plugins…"
        case .shareCommand: "Share Last Command and Output…"
        case .watchAndRerun: "Re-run Last Command When Files Change"
        case .whenDone: "When This Command Finishes… (notify, run next)"
        case .failedTests: "Failed Tests (open, re-run one)"
        case .projectEnvironment: "Project Environment (.env, virtualenv, Node)"
        case .runbooks: "Runbooks"
        case .newRunbook: "New Runbook…"
        case .aiTask: "Do a Task with AI, Step by Step…"
        case .uploadToServer: "Upload Files to Server…"
        case .downloadFromServer: "Download File from Server…"
        case .addTunnel: "Add SSH Tunnel…"
        case .aliases: "Aliases (add, edit, suggestions)…"
        case .logViewer: "Log Viewer (levels, filters, pretty JSON)"
        case .recordTab: "Record This Tab / Stop Recording"
        case .openRecording: "Open a Tab Recording…"
        case .editHistory: "Edit History (delete mistakes, compact)…"
        case .watchOutput: "Watch a Command's Output (notify on change)…"
        case .runOnServers: "Run on Several Servers…"
        case .forwardRemotePort: "Open a Server Port on This Mac…"
        case .library: "Library (notebook, runbooks, aliases, history, recordings)"
        case .tour: "Take the Tour"
        case .searchSaved: "Search Saved Commands (notebook, workflows, runbooks)"
        }
    }
}

extension AnserAction {
    /// A short heading for the command palette ("History", "Git"…).
    public var category: String {
        switch self {
        case .historySearch, .pauseHistory, .searchOutput, .editHistory, .searchSaved: "History"
        case .clipboardHistory, .copyLastOutput, .copyLastCommand, .exportMarkdown, .copyMarkdown, .exportLastOutput, .shareCommand, .shareTab: "Copy & share"
        case .newTab, .newWindow, .closeTab, .renameTab, .nextTab, .previousTab, .switchToTab, .moveTabLeft, .moveTabRight, .moveTabToNewWindow,
             .saveWorkspace, .openWorkspace, .quickTerminal: "Tabs & windows"
        case .splitRight, .splitDown, .splitLeft, .splitUp, .closePane, .focusNextPane, .focusPreviousPane, .zoomPane, .broadcastInput: "Panes"
        case .clearScreen, .deepClean, .findInTerminal, .searchAllTabs, .blockNavigator, .jumpToPreviousPrompt, .jumpToNextPrompt,
             .filterOutput, .compareLastRun, .viewOutputAsData, .logViewer, .recordTab, .openRecording: "Output"
        case .toggleEditor, .expandEditor, .formatCommand, .externalEditor, .increaseFontSize, .decreaseFontSize, .resetFontSize: "Editor"
        case .rerunLastCommand, .whenDone, .watchAndRerun, .watchOutput, .failedTests, .killPort, .projectEnvironment: "Run"
        case .jumpToFolder: "Folders"
        case .switchBranch, .changedFiles, .gitHistory, .gitStashes, .gitFetch, .gitPull, .gitPush, .resolveConflicts, .openPullRequest, .gitBlame: "Git"
        case .notebook, .editNotebook, .saveToNotebook, .runWorkflow, .saveWorkflow, .openWorkflowsFolder, .runbooks, .newRunbook, .aliases, .library: "Library"
        case .explainError, .askClaude, .aiTask: "AI"
        case .uploadToServer, .downloadFromServer, .addTunnel, .runOnServers, .forwardRemotePort: "Servers"
        case .manageSecrets, .managePlugins, .openConfig, .reloadConfig, .openSettings, .showShortcuts, .importSettings, .checkForUpdates,
             .showUsage, .reportProblem, .whatsNew, .syncHistoryNow, .toggleSidebar, .commandPalette, .tour: "Anser"
        }
    }

    /// Other words people use for it, so the palette finds it ("typo" → Edit History).
    public var keywords: String {
        switch self {
        case .editHistory: "typo mistakes delete clean compact remove forget"
        case .historySearch: "find previous ctrl-r recall search everything"
        case .aliases: "shortcut abbreviation short name"
        case .library: "saved snippets everything"
        case .notebook, .editNotebook: "snippets saved commands bookmarks workflows runbooks"
        case .watchOutput: "monitor poll notify change cron every minutes"
        case .watchAndRerun: "watch files save rerun nodemon entr"
        case .whenDone: "notify after finish then chain"
        case .runOnServers: "ssh many hosts parallel fleet"
        case .forwardRemotePort: "tunnel port forward localhost ssh"
        case .addTunnel: "port forward ssh -L"
        case .uploadToServer: "scp copy send file"
        case .downloadFromServer: "scp copy get file"
        case .logViewer: "logs tail errors levels json"
        case .recordTab: "record screencast replay asciinema demo"
        case .openRecording: "replay asciinema"
        case .failedTests: "tests failing rerun pytest jest"
        case .projectEnvironment: "env dotenv venv virtualenv nvm node python"
        case .aiTask: "agent automate steps"
        case .explainError: "why failed error help"
        case .askClaude: "generate how do i"
        case .killPort: "port in use address already"
        case .deepClean: "reset forget wipe"
        case .filterOutput: "grep search errors only"
        case .compareLastRun: "diff previous"
        case .viewOutputAsData: "table csv json"
        case .manageSecrets: "password token keychain"
        case .runbooks, .newRunbook: "checklist steps markdown playbook"
        case .runWorkflow, .saveWorkflow: "macro steps script workflows notebook"
        case .searchSaved: "find notebook workflows runbooks snippets"
        case .searchAllTabs, .blockNavigator: "find search tabs commands"
        case .broadcastInput: "all panes sync type everywhere"
        case .quickTerminal: "dropdown hotkey visor"
        case .tour: "help introduction learn getting started"
        default: ""
        }
    }
}
