import Foundation

/// Plugins: small folders in ~/.config/anser/plugins that add status-row
/// chips, palette actions, sidebar sections and hooks that run after
/// commands. Each folder has a `plugin.json`:
///
///     {
///       "name": "node-version",
///       "description": "Shows the Node version in JavaScript projects",
///       "chips": [{ "id": "node", "script": "node --version", "when": ["package.json"], "interval": 60 }],
///       "actions": [{ "title": "Open coverage report", "run": "open coverage/index.html" }],
///       "sidebar": [{ "title": "Todos", "script": "./todos.sh" }],
///       "hooks": { "commandFinished": "./notify.sh", "minSeconds": 30 }
///     }
///
/// A plugin does nothing until you turn it on in Settings → Plugins. Scripts
/// run in the pane's folder with a 5-second limit; they get ANSER_CWD,
/// ANSER_BRANCH, ANSER_LAST_COMMAND, ANSER_LAST_EXIT and ANSER_PLUGIN_DIR.
public struct PluginManifest: Codable, Sendable, Equatable {
    public struct Chip: Codable, Sendable, Equatable {
        public var id: String
        /// A command line, or a script in the plugin folder ("./branch-age.sh").
        public var script: String
        /// Refresh every N seconds while the pane is in front (at least 10); otherwise after each command.
        public var interval: Double?
        /// Only in folders containing one of these files (e.g. "package.json", ".git").
        public var when: [String]?
    }

    public struct Action: Codable, Sendable, Equatable {
        public var title: String
        /// A command to run in the pane, like a saved command.
        public var run: String?
        /// Or a script to run in the background; its output is shown.
        public var script: String?
    }

    public struct Section: Codable, Sendable, Equatable {
        public var title: String
        public var script: String
        public var interval: Double?
        public var when: [String]?
    }

    public struct Hooks: Codable, Sendable, Equatable {
        /// Runs after every command (ANSER_COMMAND, ANSER_EXIT, ANSER_DURATION, ANSER_CWD set).
        public var commandFinished: String?
        /// Only after commands that took at least this long.
        public var minSeconds: Double?
        /// Only after failures.
        public var onlyFailures: Bool?
    }

    /// A value you set in Settings → Plugins, given to scripts as ANSER_SETTING_<KEY>.
    public struct Setting: Codable, Sendable, Equatable {
        public var key: String
        public var title: String
        public var `default`: String?
        public var placeholder: String?
        /// Kept in the Keychain instead of the config file (API tokens).
        public var secret: Bool?

        public init(key: String, title: String, default: String? = nil, placeholder: String? = nil, secret: Bool? = nil) {
            self.key = key; self.title = title; self.default = `default`; self.placeholder = placeholder; self.secret = secret
        }

        /// The environment variable scripts read it from.
        public var envName: String {
            "ANSER_SETTING_" + String(key.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        }
    }

    public var name: String
    public var description: String?
    public var version: String?
    public var chips: [Chip]?
    public var actions: [Action]?
    public var sidebar: [Section]?
    public var hooks: Hooks?
    public var settings: [Setting]?

    public init(name: String, description: String? = nil, version: String? = nil, chips: [Chip]? = nil,
                actions: [Action]? = nil, sidebar: [Section]? = nil, hooks: Hooks? = nil, settings: [Setting]? = nil) {
        self.name = name; self.description = description; self.version = version
        self.chips = chips; self.actions = actions; self.sidebar = sidebar; self.hooks = hooks; self.settings = settings
    }

    /// One line on what it adds ("2 chips · 1 action · after commands").
    public var summary: String {
        var parts: [String] = []
        func n(_ c: Int, _ w: String) { if c > 0 { parts.append("\(c) \(w)\(c == 1 ? "" : "s")") } }
        n(chips?.count ?? 0, "chip")
        n(actions?.count ?? 0, "action")
        n(sidebar?.count ?? 0, "sidebar section")
        if hooks?.commandFinished != nil { parts.append("runs after commands") }
        n(settings?.count ?? 0, "setting")
        return parts.isEmpty ? "adds nothing yet" : parts.joined(separator: " · ")
    }
}

public struct Plugin: Sendable, Equatable {
    public var manifest: PluginManifest
    public var directory: String
    /// Personal (~/.config/anser/plugins) or from a repo's .anser/plugins.
    public var source: Workflow.Source = .personal

    public init(manifest: PluginManifest, directory: String, source: Workflow.Source = .personal) {
        self.manifest = manifest; self.directory = directory; self.source = source
    }

    /// Folder name; what Settings and the config use to turn it on.
    public var id: String { (directory as NSString).lastPathComponent }
    /// Unique across personal and project plugins (used for chip keys and settings).
    public var key: String { source == .project ? "project:" + directory : id }
}

public enum PluginRegistry {
    public static var defaultDirectory: String { AnserConfig.directory.appendingPathComponent("plugins").path }

    /// Every plugin folder with a readable plugin.json, plus problems found.
    public static func load(from dir: String = defaultDirectory) -> (plugins: [Plugin], errors: [String]) {
        let fm = FileManager.default
        var plugins: [Plugin] = [], errors: [String] = []
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for name in names {
            let folder = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { continue }
            let file = (folder as NSString).appendingPathComponent("plugin.json")
            guard let data = fm.contents(atPath: file) else { continue }
            do {
                var m = try JSONDecoder().decode(PluginManifest.self, from: data)
                if m.name.isEmpty { m.name = name }
                plugins.append(Plugin(manifest: m, directory: folder))
            } catch {
                errors.append("\(name)/plugin.json: \(Self.describe(error))")
            }
        }
        return (plugins, errors)
    }

    /// The `.anser/plugins` folder of the git repo containing `cwd`.
    public static func projectDirectory(for cwd: String) -> String? {
        WorkflowStore.projectDirectory(for: cwd).map { $0.deletingLastPathComponent().appendingPathComponent("plugins").path }
    }

    /// Plugins that come with the repo containing `cwd` (they still need trusting before they run).
    public static func loadProject(cwd: String) -> (plugins: [Plugin], errors: [String]) {
        guard let dir = projectDirectory(for: cwd), FileManager.default.fileExists(atPath: dir) else { return ([], []) }
        var (p, e) = load(from: dir)
        for i in p.indices { p[i].source = .project }
        return (p, e)
    }

    static func describe(_ e: Error) -> String {
        if case DecodingError.keyNotFound(let k, _) = e { return "missing \"\(k.stringValue)\"" }
        if case DecodingError.typeMismatch(_, let c) = e { return "wrong type at \(c.codingPath.map(\.stringValue).joined(separator: "."))" }
        if case DecodingError.dataCorrupted(let c) = e { return c.debugDescription }
        return e.localizedDescription
    }

    /// The command line for a script: a file in the plugin folder runs directly; anything else runs with /bin/sh -c.
    public static func argv(for script: String, in folder: String) -> [String] {
        let t = script.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("./"), !t.contains(" ") {
            let path = (folder as NSString).appendingPathComponent(String(t.dropFirst(2)))
            // Stay inside the plugin folder.
            let resolved = (path as NSString).standardizingPath
            if resolved.hasPrefix((folder as NSString).standardizingPath + "/") { return [resolved] }
        }
        return ["/bin/sh", "-c", t]
    }

    /// Whether a `when` list allows this folder.
    public static func applies(_ when: [String]?, cwd: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard let when, !when.isEmpty else { return true }
        // Look in the folder and its parents, like git does for .git.
        var d = cwd
        for _ in 0..<12 {
            if when.contains(where: { exists((d as NSString).appendingPathComponent($0)) }) { return true }
            if d == "/" || d.isEmpty { break }
            d = (d as NSString).deletingLastPathComponent
        }
        return false
    }
}

/// What plugin scripts print.
public enum PluginOutput {
    public struct Chip: Sendable, Equatable {
        public var text: String
        public var color: String?
        public var tooltip: String?
        /// Clicking runs this in the pane.
        public var run: String?
        /// Or opens this link or file.
        public var open: String?
        public init(text: String, color: String? = nil, tooltip: String? = nil, run: String? = nil, open: String? = nil) {
            self.text = text; self.color = color; self.tooltip = tooltip; self.run = run; self.open = open
        }
    }

    public struct Row: Sendable, Equatable {
        public var text: String
        public var detail: String?
        public var color: String?
        public var run: String?
        public var open: String?
    }

    /// A chip from the first line of plain text, or a JSON object
    /// {"text", "color", "tooltip", "run", "open"}. Empty output hides the chip.
    public static func chip(_ output: String) -> Chip? {
        let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] {
            guard let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return Chip(text: String(text.prefix(60)), color: obj["color"] as? String, tooltip: obj["tooltip"] as? String,
                        run: obj["run"] as? String, open: obj["open"] as? String)
        }
        let first = t.split(separator: "\n").first.map(String.init) ?? t
        return Chip(text: String(first.prefix(60)))
    }

    /// Sidebar rows from a JSON array of {"text", "detail", "color", "run", "open"},
    /// or lines of `text<TAB>detail<TAB>command`.
    public static func rows(_ output: String, limit: Int = 50) -> [Row] {
        let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        if t.hasPrefix("["), let arr = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [[String: Any]] {
            return arr.prefix(limit).compactMap { o in
                guard let text = o["text"] as? String, !text.isEmpty else { return nil }
                return Row(text: text, detail: o["detail"] as? String, color: o["color"] as? String, run: o["run"] as? String, open: o["open"] as? String)
            }
        }
        return t.split(separator: "\n").prefix(limit).compactMap { line in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let text = p.first, !text.isEmpty else { return nil }
            func at(_ i: Int) -> String? { i < p.count && !p[i].isEmpty ? p[i] : nil }
            return Row(text: text, detail: at(1), color: nil, run: at(2), open: nil)
        }
    }

    /// Links a plugin may open: web pages and files only.
    public static func safeToOpen(_ s: String) -> URL? {
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) { return u }
        if s.hasPrefix("/") || s.hasPrefix("~") { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        return nil
    }
}

/// The example plugin Settings can create, to start from.
public enum PluginTemplate {
    public static let manifest = """
    {
      "name": "Example",
      "description": "Shows how long ago the last commit was, and adds two actions. Edit plugin.json to make it yours.",
      "chips": [
        { "id": "last-commit", "script": "./last-commit.sh", "when": [".git"] }
      ],
      "actions": [
        { "title": "Show disk space", "run": "df -h ." },
        { "title": "Count lines of Swift", "script": "find . -name '*.swift' -not -path './.build/*' | xargs wc -l | tail -1" }
      ],
      "sidebar": [
        { "title": "Recent commits", "script": "git log -8 --pretty='%s\\t%cr\\tgit show --stat %h' 2>/dev/null", "when": [".git"] }
      ],
      "hooks": { "commandFinished": "./finished.sh", "minSeconds": 60 }
    }
    """

    public static let lastCommit = """
    #!/bin/sh
    # Prints a chip: plain text, or JSON with text, color, tooltip, run or open.
    when=$(git log -1 --format=%cr 2>/dev/null) || exit 0
    printf '{"text":"committed %s","color":"blue","tooltip":"Last commit on this branch","run":"git log -5 --oneline"}\\n' "$when"
    """

    public static let finished = """
    #!/bin/sh
    # Runs after commands that took 60 seconds or more (see plugin.json).
    # ANSER_COMMAND, ANSER_EXIT, ANSER_DURATION and ANSER_CWD describe the command.
    echo "$(date '+%F %T') exit=$ANSER_EXIT ${ANSER_DURATION}s $ANSER_COMMAND" >> "$ANSER_PLUGIN_DIR/long-commands.log"
    """
}

extension FileTrust {
    public static var plugins: FileTrust { FileTrust("trustedProjectPlugins") }

    /// Project plugins run only after you've seen what they run; any change to their files asks again.
    public func isTrusted(_ p: Plugin) -> Bool {
        guard p.source == .project else { return true }
        return isTrusted(path: p.directory, fingerprint: FileTrust.fingerprint(folder: URL(fileURLWithPath: p.directory)))
    }

    public func trust(_ p: Plugin) {
        trust(path: p.directory, fingerprint: FileTrust.fingerprint(folder: URL(fileURLWithPath: p.directory)))
    }
}

extension Plugin {
    /// Everything a plugin runs, for the trust prompt.
    public var scriptsSummary: String {
        var lines: [String] = []
        let m = manifest
        for c in m.chips ?? [] { lines.append("chip “\(c.id)”: \(c.script)") }
        for a in m.actions ?? [] { lines.append("action “\(a.title)”: \(a.run ?? a.script ?? "")") }
        for s in m.sidebar ?? [] { lines.append("sidebar “\(s.title)”: \(s.script)") }
        if let h = m.hooks?.commandFinished { lines.append("after commands: \(h)") }
        return lines.joined(separator: "\n")
    }
}

/// Ready-made plugins you can add from Settings → Plugins.
public enum PluginGallery {
    public struct Item: Sendable {
        public var id: String
        public var name: String
        public var description: String
        /// File name → contents; always includes plugin.json. Files ending in .sh are made executable.
        public var files: [String: String]
    }

    public static let items: [Item] = [
        Item(id: "node-version", name: "Node version", description: "Shows the Node.js version in JavaScript projects.", files: [
            "plugin.json": """
            {
              "name": "Node version",
              "description": "Shows the Node.js version in JavaScript projects.",
              "chips": [{ "id": "node", "script": "./node.sh", "when": ["package.json", ".nvmrc", ".node-version"] }]
            }
            """,
            "node.sh": """
            #!/bin/sh
            v=$(node --version 2>/dev/null) || exit 0
            want=$(cat .nvmrc .node-version 2>/dev/null | head -1 | tr -d 'v \\r')
            color=green
            case "$want" in ''|lts*|node|stable) ;; *) case "${v#v}" in "$want"*) ;; *) color=orange ;; esac ;; esac
            tip="Node $v"; [ -n "$want" ] && tip="$tip (project wants $want)"
            printf '{"text":"node %s","color":"%s","tooltip":"%s"}\\n' "${v#v}" "$color" "$tip"
            """,
        ]),
        Item(id: "python-env", name: "Python environment", description: "Shows the active virtualenv and Python version in Python projects.", files: [
            "plugin.json": """
            {
              "name": "Python environment",
              "description": "Shows the active virtualenv and Python version in Python projects.",
              "chips": [{ "id": "python", "script": "./python.sh", "when": ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", ".python-version"] }]
            }
            """,
            "python.sh": """
            #!/bin/sh
            py=python3; [ -n "$VIRTUAL_ENV" ] && py="$VIRTUAL_ENV/bin/python"
            v=$("$py" --version 2>/dev/null | cut -d' ' -f2) || exit 0
            [ -z "$v" ] && exit 0
            if [ -n "$VIRTUAL_ENV" ]; then
              printf '{"text":"py %s · %s","color":"green","tooltip":"virtualenv %s"}\\n' "$v" "$(basename "$VIRTUAL_ENV")" "$VIRTUAL_ENV"
            else
              printf '{"text":"py %s","tooltip":"No virtualenv active"}\\n' "$v"
            fi
            """,
        ]),
        Item(id: "pull-requests", name: "Pull requests", description: "Lists the repo's open pull requests in the sidebar (needs the GitHub CLI, gh).", files: [
            "plugin.json": """
            {
              "name": "Pull requests",
              "description": "Lists the repo's open pull requests in the sidebar (needs the GitHub CLI, gh).",
              "sidebar": [{ "title": "Pull requests", "script": "./prs.sh", "when": [".git"], "interval": 300 }],
              "actions": [{ "title": "Open pull requests on GitHub", "run": "gh pr list --web" }],
              "settings": [{ "key": "limit", "title": "How many to show", "default": "10" }]
            }
            """,
            "prs.sh": """
            #!/bin/sh
            command -v gh >/dev/null || exit 0
            limit=${ANSER_SETTING_LIMIT:-10}
            case "$limit" in ''|*[!0-9]*) limit=10 ;; esac
            gh pr list --limit "$limit" --json number,title,url,isDraft,author \\
              --jq '[.[] | {text: ("#\\(.number) " + .title), detail: (if .isDraft then "draft" else .author.login end), open: .url}]' 2>/dev/null
            """,
        ]),
        Item(id: "todo-count", name: "TODO count", description: "Counts TODO and FIXME comments in the repo; click to list them.", files: [
            "plugin.json": """
            {
              "name": "TODO count",
              "description": "Counts TODO and FIXME comments in the repo; click to list them.",
              "chips": [{ "id": "todos", "script": "./todos.sh", "when": [".git"] }],
              "settings": [{ "key": "pattern", "title": "Words to count", "default": "TODO|FIXME" }]
            }
            """,
            "todos.sh": """
            #!/bin/sh
            pat=$(printf '%s' "${ANSER_SETTING_PATTERN:-TODO|FIXME}" | tr -cd 'A-Za-z0-9_|')
            [ -n "$pat" ] || pat='TODO|FIXME'
            n=$(git grep -I -c -E -- "$pat" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
            [ "${n:-0}" -gt 0 ] || exit 0
            printf '{"text":"%s to do","color":"yellow","tooltip":"Lines matching %s","run":"git grep -n -I -E -- '"'"'%s'"'"'"}\\n' "$n" "$pat" "$pat"
            """,
        ]),
        Item(id: "long-commands", name: "Long command log", description: "Keeps a log of every command that took over 30 seconds, with an action to show it.", files: [
            "plugin.json": """
            {
              "name": "Long command log",
              "description": "Keeps a log of every command that took over 30 seconds, with an action to show it.",
              "hooks": { "commandFinished": "./log.sh", "minSeconds": 30 },
              "actions": [{ "title": "Show long command log", "script": "tail -40 \\"$ANSER_PLUGIN_DIR/long-commands.log\\" 2>/dev/null || echo 'Nothing logged yet'" }]
            }
            """,
            "log.sh": """
            #!/bin/sh
            printf '%s  exit %s  %ss  %s  (%s)\\n' "$(date '+%F %T')" "$ANSER_EXIT" "$ANSER_DURATION" "$ANSER_COMMAND" "$ANSER_CWD" >> "$ANSER_PLUGIN_DIR/long-commands.log"
            """,
        ]),
    ]

    /// Writes a gallery plugin into `directory` (keeping your copy if one is already there). Returns its folder.
    @discardableResult
    public static func install(_ item: Item, into directory: String) throws -> String {
        let fm = FileManager.default
        let dir = (directory as NSString).appendingPathComponent(item.id)
        if fm.fileExists(atPath: (dir as NSString).appendingPathComponent("plugin.json")) { return dir }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, text) in item.files {
            let path = (dir as NSString).appendingPathComponent(name)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            if name.hasSuffix(".sh") { chmod(path, 0o755) }
        }
        return dir
    }
}
