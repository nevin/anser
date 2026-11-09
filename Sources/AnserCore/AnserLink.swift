import Foundation

/// `anser://` links, for Shortcuts, Raycast, Alfred and scripts:
///
///   anser://new?dir=~/code/app            new tab in a folder
///   anser://new?dir=~/code/app&window=1   new window
///   anser://run?dir=~/code/app&cmd=make   new tab that runs a command (asks first)
///
/// Anything a web page could open is checked: a folder must exist, and a
/// command always shows a confirmation before it runs.
public struct AnserLink: Sendable, Equatable {
    public enum Action: String, Sendable { case new, run }
    public var action: Action
    public var dir: String?
    public var command: String?
    public var newWindow: Bool

    public init(action: Action, dir: String? = nil, command: String? = nil, newWindow: Bool = false) {
        self.action = action; self.dir = dir; self.command = command; self.newWindow = newWindow
    }

    public static func parse(_ url: URL, home: String = NSHomeDirectory()) -> AnserLink? {
        guard url.scheme?.lowercased() == "anser", let host = url.host?.lowercased(), let action = Action(rawValue: host),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name.lowercased()] = item.value ?? "" }
        var dir = q["dir"].flatMap { $0.isEmpty ? nil : $0 }
        if let d = dir, d.hasPrefix("~") { dir = home + d.dropFirst() }
        if let d = dir, !d.hasPrefix("/") { return nil }
        let cmd = q["cmd"].flatMap { $0.isEmpty ? nil : $0 }
        if action == .run, cmd == nil { return nil }
        if let c = cmd, c.count > 4000 || c.contains("\u{0}") { return nil }
        let win = ["1", "true", "yes"].contains((q["window"] ?? "").lowercased())
        return AnserLink(action: action, dir: dir, command: action == .run ? cmd : nil, newWindow: win)
    }
}

/// What's new in each version, shown once after an update.
public enum WhatsNew {
    public struct Item: Sendable, Equatable {
        public var symbol: String
        public var title: String
        public var detail: String
    }

    /// Changes when there's a new set of items to show (not the app's version number).
    public static let featureSet = "2026-11-ux-review"

    public static let items: [Item] = [
        Item(symbol: "magnifyingglass", title: "One search",
             detail: "⌘R searches history, this tab, command output, every open tab and your saved commands; ⇥ changes where. ⌘B, ⇧⌘F and ⌥⇧⌘F open it on their scope."),
        Item(symbol: "book.closed", title: "Workflows live in the Notebook",
             detail: "A workflow is a notebook entry with several steps. Tools → Run from Notebook (⌥⌘R) runs any of them."),
        Item(symbol: "square.grid.2x2", title: "Fewer windows",
             detail: "Tools → Manage opens the Notebook, Aliases, History and Secrets as tabs of the Library window."),
        Item(symbol: "menubar.rectangle", title: "Tidier menus and shortcuts",
             detail: "A new Output menu (filter, logs, export, share, record). Shortcuts follow families: ⌥⌘ for saved things, ⌃⌘ for panels. Filter Output is now ⌃⌘O, and next match in the editor ⌥⌘G."),
        Item(symbol: "gearshape", title: "Settings by purpose",
             detail: "Behavior is split into Notifications, Suggestions & Helpers, Privacy & History, and Sessions & Windows, with the editor for ⌘-clicked files and the quick terminal height added."),
        Item(symbol: "clock.arrow.circlepath", title: "Remembers your fixes",
             detail: "When a command fails again, Anser shows what you ran to fix it last time, from your own history."),
        Item(symbol: "eye", title: "Watch a command's output",
             detail: "Runs a command every few minutes and notifies you only when its output changes or it fails."),
        Item(symbol: "server.rack", title: "Run on several servers",
             detail: "One command on many ssh hosts at once, failures first, with saved host groups."),
        Item(symbol: "arrow.down.left.circle", title: "Open server ports here",
             detail: "When a program in an ssh tab starts listening, one click forwards the port and opens it on your Mac."),
        Item(symbol: "clock.arrow.circlepath", title: "History editor",
             detail: "Tools → Manage → History…: find typos and mistakes in one click, see each command's track record, delete many at once, and compact history."),
        Item(symbol: "text.badge.plus", title: "Alias manager",
             detail: "Tools → Aliases…: add, edit and delete aliases that work in every tab at once, with suggestions from commands you keep typing."),
        Item(symbol: "list.bullet.rectangle", title: "Log viewer",
             detail: "Logs with levels in color, level filters, search, pretty JSON and jump-to-error (Shell → Log Viewer)."),
        Item(symbol: "record.circle", title: "Record and replay a tab",
             detail: "Record a session, replay it at any speed, and share it as an HTML player or asciinema file."),
        Item(symbol: "xmark.octagon", title: "Failed tests, one click away",
             detail: "After a test run fails, open each failed test at its line or re-run just that one (pytest, Jest, Vitest, go, swift, cargo, RSpec)."),
        Item(symbol: "eye", title: "Re-run when files change",
             detail: "Shell → Re-run When Files Change repeats the last command on every save, ignoring build output and dependencies."),
        Item(symbol: "bell", title: "When this finishes…",
             detail: "While a command runs: notify me, run the next command, or run it only if this one works."),
        Item(symbol: "leaf", title: "Project environments",
             detail: "cd into a project and Anser offers to load its .env, virtualenv and Node version, and unloads them when you leave."),
        Item(symbol: "list.bullet.clipboard", title: "Runbooks",
             detail: "Markdown checklists whose code blocks run with one click and get ticked off. Share them in a repo's .anser/runbooks."),
        Item(symbol: "shippingbox", title: "Containers, pods and tunnels",
             detail: "Docker containers and Kubernetes pods in the sidebar, ssh tunnels kept open, and drag-and-drop uploads to ssh tabs."),
        Item(symbol: "sparkles", title: "AI tasks, step by step",
             detail: "Describe a goal; the AI proposes one command at a time, you approve each, and it learns from every result."),
        Item(symbol: "puzzlepiece.extension", title: "More from plugins",
             detail: "Starter plugins, plugin settings, and project plugins a repo can ship (they run once you trust them)."),
    ]
}
