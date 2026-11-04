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
        }
    }

    /// Terminal look. Empty fields keep your Ghostty config (or Ghostty's defaults).
    public struct Appearance: Codable, Sendable {
        public var fontFamily: String?
        public var fontSize: Double?
        /// A Ghostty theme name, e.g. "Catppuccin Mocha", "GitHub Dark".
        public var theme: String?
        /// 0.3–1.0
        public var backgroundOpacity: Double?
        /// "block", "bar", "underline", "block_hollow"
        public var cursorStyle: String?
        public var cursorBlink: Bool?
        public var padding: Double?
        /// false turns off programming ligatures (=> != ->) in fonts that have them.
        public var ligatures: Bool?

        public init() {}

        /// The Ghostty config lines for these settings.
        public var ghosttyLines: [String] {
            var l: [String] = []
            if let f = fontFamily, !f.isEmpty { l += ["font-family = \"\"", "font-family = \(f)"] }
            if let s = fontSize { l.append("font-size = \(s)") }
            if let t = theme, !t.isEmpty { l.append("theme = \(t)") }
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
    /// Optional AI help (explain errors, generate commands) via the Claude API.
    /// Off until you turn it on; the API key lives in the Keychain.
    public var aiEnabled: Bool = false
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
    /// Extra commands that may be run with `--help` to learn their flags.
    public var helpCommands: [String] = []
    /// Commands matching any of these patterns (* and ? wildcards, case-insensitive)
    /// are never saved to history.
    public var historyIgnore: [String] = AnserConfig.defaultHistoryIgnore
    /// Reopen windows, tabs, splits and their folders on launch.
    public var restoreSession: Bool = true
    /// Replace the shell's prompt with a short "❯", since the bar already shows folder and branch.
    public var compactPrompt: Bool = false
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
        abbreviations = try c.decodeIfPresent([String: String].self, forKey: .abbreviations) ?? [:]
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        keybindings = try c.decodeIfPresent([String: String].self, forKey: .keybindings) ?? [:]
        notifyAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .notifyAfterSeconds) ?? d.notifyAfterSeconds
        copyOnSelect = try c.decodeIfPresent(Bool.self, forKey: .copyOnSelect) ?? d.copyOnSelect
        ghostty = try c.decodeIfPresent([String].self, forKey: .ghostty) ?? []
        clipboardHistorySize = try c.decodeIfPresent(Int.self, forKey: .clipboardHistorySize) ?? d.clipboardHistorySize
        helpCommands = try c.decodeIfPresent([String].self, forKey: .helpCommands) ?? []
        historyIgnore = try c.decodeIfPresent([String].self, forKey: .historyIgnore) ?? d.historyIgnore
        restoreSession = try c.decodeIfPresent(Bool.self, forKey: .restoreSession) ?? d.restoreSession
        compactPrompt = try c.decodeIfPresent(Bool.self, forKey: .compactPrompt) ?? d.compactPrompt
        shellPrompt = try c.decodeIfPresent(String.self, forKey: .shellPrompt) ?? (compactPrompt ? "compact" : d.shellPrompt)
        fullscreenApps = try c.decodeIfPresent([String].self, forKey: .fullscreenApps) ?? d.fullscreenApps
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
      "snippets": [
        { "name": "Kill process on port", "command": "lsof -ti tcp:{{port}} | xargs kill" },
        { "name": "Find files by name", "command": "find . -name '{{pattern}}' -not -path '*/node_modules/*'" },
        { "name": "Undo last commit (keep changes)", "command": "git reset --soft HEAD~1" },
        { "name": "New branch from main", "command": "git switch main && git pull && git switch -c {{branch}}" }
      ],
      "keybindings": {
        "ctrl+g": "insert:git ",
        "cmd+shift+o": "action:copyLastOutput"
      },
      "historyIgnore": ["*password=*", "*token=*", "*secret=*", "*api_key=*", "export *secret*"],
      "helpCommands": [],
      "restoreSession": true,
      "shellPrompt": "hidden",
      "appearance": {
        "fontFamily": null,
        "fontSize": null,
        "theme": null,
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
    case newTab, newWindow, splitRight, splitDown, closePane, focusNextPane, focusPreviousPane
    case clearScreen, toggleEditor, rerunLastCommand, openConfig, reloadConfig, jumpToPreviousPrompt, jumpToNextPrompt
    case increaseFontSize, decreaseFontSize, resetFontSize
    case findInTerminal, blockNavigator, pauseHistory, openSettings
    case expandEditor, formatCommand, externalEditor
    case renameTab, nextTab, previousTab, closeTab
    case jumpToFolder, switchBranch, changedFiles, showShortcuts
    case moveTabLeft, moveTabRight, moveTabToNewWindow
    case zoomPane, toggleSidebar
    case runWorkflow, saveWorkflow, exportMarkdown, copyMarkdown, reportProblem
    case explainError, askClaude

    public var title: String {
        switch self {
        case .historySearch: "Search History"
        case .clipboardHistory: "Clipboard History"
        case .commandPalette: "Command Palette"
        case .copyLastOutput: "Copy Last Output"
        case .copyLastCommand: "Copy Last Command"
        case .newTab: "New Tab"
        case .newWindow: "New Window"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .closePane: "Close Pane"
        case .focusNextPane: "Next Pane"
        case .focusPreviousPane: "Previous Pane"
        case .clearScreen: "Clear Screen"
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
        case .blockNavigator: "Command Blocks in This Tab"
        case .pauseHistory: "Pause History for This Tab"
        case .openSettings: "Settings"
        case .expandEditor: "Expand Command Editor"
        case .formatCommand: "Split / Join Command Lines"
        case .externalEditor: "Edit Command in $EDITOR"
        case .renameTab: "Rename Tab"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .closeTab: "Close Tab"
        case .jumpToFolder: "Jump to Folder"
        case .switchBranch: "Git: Switch or Create Branch"
        case .changedFiles: "Git: Changed Files"
        case .showShortcuts: "Keyboard Shortcuts"
        case .moveTabLeft: "Move Tab Left"
        case .moveTabRight: "Move Tab Right"
        case .moveTabToNewWindow: "Move Tab to New Window"
        case .zoomPane: "Zoom Pane / Restore Split"
        case .toggleSidebar: "Toggle Sidebar"
        case .runWorkflow: "Run Workflow"
        case .saveWorkflow: "Save Commands as Workflow"
        case .exportMarkdown: "Export Tab as Markdown"
        case .copyMarkdown: "Copy Tab as Markdown"
        case .reportProblem: "Report a Problem"
        case .explainError: "Explain Last Error with Claude"
        case .askClaude: "Ask Claude for a Command"
        }
    }
}
