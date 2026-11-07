import Foundation

/// Short tips shown once, at the moment they help ("you pressed ↑ six
/// times: ⌘R searches all your history"). Pure logic: the app feeds it
/// events and shows what comes back.
public struct TipEngine: Sendable {
    public struct Tip: Equatable, Sendable {
        public let id: String
        public let text: String
    }

    public struct State: Codable, Sendable, Equatable {
        public var counts: [String: Int] = [:]
        public var shown: Set<String> = []
        public var lastShown: Date?
        public init() {}
    }

    public var state: State
    /// At most one tip in this many seconds.
    public var spacing: TimeInterval = 600

    public init(state: State = State()) { self.state = state }

    /// A command just started.
    public mutating func commandStarted(_ command: String, aiEnabled: Bool, now: Date = Date()) -> Tip? {
        let c = command.trimmingCharacters(in: .whitespaces)
        let lower = c.lowercased()
        let words = lower.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        if lower.hasPrefix("history") && lower.contains("grep") {
            return offer("history-grep", "Tip: ⌘R searches all your history (filter by folder, tab or failed).", now)
        }
        if first == "clear" { return offer("clear", "Tip: ⌘K clears the screen without running a command.", now) }
        if first == "cd" {
            if bump("cd") >= 8 { return offer("cd", "Tip: ⌘J jumps to any recent folder. Click the folder in the status row too.", now) }
        }
        if words.count >= 2, first == "git" {
            switch words[1] {
            case "checkout", "switch":
                if bump("git-switch") >= 3 { return offer("git-switch", "Tip: ⇧⌘B switches branches (or click the branch in the status row).", now) }
            case "status":
                if bump("git-status") >= 5 { return offer("git-status", "Tip: ⇧⌘G lists changed files with diffs; stage or open them from there.", now) }
            case "log":
                if bump("git-log") >= 3 { return offer("git-log", "Tip: ⇧⌘L shows commit history with a diff preview.", now) }
            default: break
            }
        }
        if first == "ssh", bump("ssh") >= 3 {
            return offer("ssh-profile", "Tip: give production hosts a red tab and a badge: Settings → Profiles.", now)
        }
        if c.count >= 18 {
            let key = "repeat:" + String(lower.prefix(120))
            if bump(key) >= 4 { return offer("save-notebook", "Tip: you run this one often. ⌥⌘S saves it to your Command Notebook.", now) }
        }
        return nil
    }

    /// A command finished.
    public mutating func commandFinished(exitCode: Int, aiEnabled: Bool, now: Date = Date()) -> Tip? {
        guard exitCode != 0, exitCode != 130 else { return nil }
        guard bump("failed") >= 3 else { return nil }
        return aiEnabled
            ? offer("explain", "Tip: ⌥⌘I asks AI why the last command failed.", now)
            : offer("explain-off", "Tip: AI help can explain failures. Turn it on in Settings → AI (Claude, Copilot or a local model).", now)
    }

    /// ↑ pressed in the editor to step through history.
    public mutating func historyArrow(now: Date = Date()) -> Tip? {
        bump("arrow") >= 6 ? offer("arrow", "Tip: ⌘R searches all your history instead of stepping with ↑.", now) : nil
    }

    /// Text copied from the terminal with the mouse.
    public mutating func mouseCopy(now: Date = Date()) -> Tip? {
        bump("mouse-copy") >= 3 ? offer("mouse-copy", "Tip: ⇧⌘C copies the last command's whole output, no selecting needed.", now) : nil
    }

    /// A second pane or tab opened.
    public mutating func splitOpened(now: Date = Date()) -> Tip? {
        bump("split") >= 3 ? offer("broadcast", "Tip: Shell → Type in All Panes sends what you type to every pane in the tab.", now) : nil
    }

    private mutating func bump(_ key: String) -> Int {
        state.counts[key, default: 0] += 1
        return state.counts[key]!
    }

    private mutating func offer(_ id: String, _ text: String, _ now: Date) -> Tip? {
        guard !state.shown.contains(id) else { return nil }
        if let last = state.lastShown, now.timeIntervalSince(last) < spacing { return nil }
        state.shown.insert(id)
        state.lastShown = now
        // Repeat counters aren't needed once their tip is shown.
        if id == "save-notebook" { state.counts = state.counts.filter { !$0.key.hasPrefix("repeat:") } }
        return Tip(id: id, text: text)
    }
}
