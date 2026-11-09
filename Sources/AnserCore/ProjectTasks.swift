import Foundation

/// The things you can run in a project, for one-click buttons: package.json
/// scripts (with the right package manager), Make targets, just recipes,
/// Taskfile tasks, Cargo, Swift and Go basics, and Procfile processes.
public enum ProjectTasks {
    public struct Task: Sendable, Equatable, Hashable {
        public var group: String        // "npm", "make", "just", "task", "cargo"…
        public var name: String
        public var command: String
        public var detail: String?
        public init(group: String, name: String, command: String, detail: String? = nil) {
            self.group = group; self.name = name; self.command = command; self.detail = detail
        }
    }

    public struct Project: Sendable, Equatable {
        public var root: String
        public var tasks: [Task]
    }

    /// Looks from `cwd` up to the nearest folder with a project file (stops at `home`).
    public static func find(from cwd: String, home: String = NSHomeDirectory(),
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                            read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Project? {
        var d = cwd
        let markers = ["package.json", "Makefile", "makefile", "GNUmakefile", "justfile", "Justfile", ".justfile",
                       "Taskfile.yml", "Taskfile.yaml", "Cargo.toml", "Package.swift", "go.mod", "Procfile", "pyproject.toml"]
        var steps = 0
        while steps < 30 {
            if markers.contains(where: { exists(d + "/" + $0) }) {
                let tasks = tasks(in: d, exists: exists, read: read)
                return tasks.isEmpty ? nil : Project(root: d, tasks: tasks)
            }
            if d == "/" || d == home || d.isEmpty { return nil }
            d = (d as NSString).deletingLastPathComponent
            steps += 1
        }
        return nil
    }

    public static func tasks(in dir: String, exists: (String) -> Bool, read: (String) -> String?) -> [Task] {
        var out: [Task] = []
        func has(_ f: String) -> Bool { exists(dir + "/" + f) }
        if let text = read(dir + "/package.json"),
           let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any] {
            let pm = has("bun.lockb") || has("bun.lock") ? "bun" : has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : "npm"
            let order = ["dev", "start", "build", "test", "lint", "format", "typecheck"]
            let names = scripts.keys.sorted { a, b in
                let ia = order.firstIndex(of: a) ?? 99, ib = order.firstIndex(of: b) ?? 99
                return ia != ib ? ia < ib : a < b
            }
            // `pretest` / `postbuild` run on their own around another script.
            func isHook(_ n: String) -> Bool {
                (n.hasPrefix("pre") && scripts[String(n.dropFirst(3))] != nil) || (n.hasPrefix("post") && scripts[String(n.dropFirst(4))] != nil)
            }
            for n in names where !isHook(n) {
                let cmd = pm == "npm" ? (["start", "test"].contains(n) ? "npm \(n)" : "npm run \(n)") : "\(pm) \(n)"
                out.append(Task(group: pm, name: n, command: cmd, detail: scripts[n] as? String))
            }
        }
        if let mk = ["GNUmakefile", "makefile", "Makefile"].first(where: has), let text = read(dir + "/" + mk) {
            out += makeTargets(text).map { Task(group: "make", name: $0.0, command: "make \($0.0)", detail: $0.1) }
        }
        if let jf = ["justfile", "Justfile", ".justfile"].first(where: has), let text = read(dir + "/" + jf) {
            out += justRecipes(text).map { Task(group: "just", name: $0.0, command: "just \($0.0)", detail: $0.1) }
        }
        if let tf = ["Taskfile.yml", "Taskfile.yaml"].first(where: has), let text = read(dir + "/" + tf) {
            out += taskfileTasks(text).map { Task(group: "task", name: $0.0, command: "task \($0.0)", detail: $0.1) }
        }
        if has("Cargo.toml") {
            for n in ["build", "run", "test", "check", "clippy"] { out.append(Task(group: "cargo", name: n, command: "cargo \(n)")) }
        }
        if has("Package.swift") {
            for n in ["build", "test", "run"] { out.append(Task(group: "swift", name: n, command: "swift \(n)")) }
        }
        if has("go.mod") {
            out.append(Task(group: "go", name: "build", command: "go build ./..."))
            out.append(Task(group: "go", name: "test", command: "go test ./..."))
            out.append(Task(group: "go", name: "run", command: "go run ."))
        }
        if let text = read(dir + "/Procfile") {
            for line in text.split(separator: "\n") {
                let p = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2, !p[0].hasPrefix("#"), !p[0].isEmpty { out.append(Task(group: "procfile", name: p[0], command: p[1])) }
            }
        }
        return out
    }

    /// `target: deps ## description` and a `# comment` line above count as descriptions.
    static func makeTargets(_ text: String) -> [(String, String?)] {
        var res: [(String, String?)] = []
        var seen = Set<String>()
        var lastComment: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") { lastComment = line.drop(while: { $0 == "#" || $0 == " " }).description; continue }
            defer { lastComment = nil }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix("."), !line.hasPrefix(" "),
                  line[line.index(after: colon)...].first != "=", !line[..<colon].contains("=") else { continue }
            let desc = line.range(of: "##").map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? lastComment
            for t in line[..<colon].split(separator: " ") where !t.contains("$") && !t.contains("%") && !t.contains("/") {
                if seen.insert(String(t)).inserted { res.append((String(t), desc)) }
            }
        }
        return res
    }

    static func justRecipes(_ text: String) -> [(String, String?)] {
        var res: [(String, String?)] = []
        var lastComment: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") { lastComment = line.drop(while: { $0 == "#" || $0 == " " }).description; continue }
            defer { lastComment = nil }
            guard let first = line.first, first.isLetter || first == "_" || first == "@", let colon = line.firstIndex(of: ":"),
                  line[line.index(after: colon)...].first != "=" else { continue }
            let head = line[..<colon].split(separator: " ")
            guard var name = head.first.map(String.init), !line.hasPrefix("set "), !line.hasPrefix("export "),
                  !line.hasPrefix("alias "), !line.hasPrefix("import "), !line.hasPrefix("mod ") else { continue }
            if name.hasPrefix("@") { name.removeFirst() }
            if name.hasPrefix("_") { continue }          // private recipes
            res.append((name, lastComment))
        }
        return res
    }

    static func taskfileTasks(_ text: String) -> [(String, String?)] {
        var res: [(String, String?)] = []
        var inTasks = false
        var current: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if !line.hasPrefix(" ") && !line.isEmpty { inTasks = line.hasPrefix("tasks:"); continue }
            guard inTasks else { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            let t = line.trimmingCharacters(in: .whitespaces)
            if indent == 2, t.hasSuffix(":"), !t.hasPrefix("#") {
                current = CloudContext.unquote(t.dropLast())
                if let c = current, !c.hasPrefix("_") { res.append((c, nil)) }
            } else if indent == 4, t.hasPrefix("desc:"), let c = current, let i = res.lastIndex(where: { $0.0 == c }) {
                res[i].1 = CloudContext.unquote(t.dropFirst(5))
            }
        }
        return res
    }
}
