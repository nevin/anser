import Foundation

/// Which file changes should re-run a watched command. Build output, caches,
/// dependencies and editor temp files don't count, so a build that writes
/// files can't trigger itself forever.
public enum WatchRules {
    public static let ignoredFolders: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", "build", "dist", "out", "target", "__pycache__",
        ".venv", "venv", ".tox", ".mypy_cache", ".pytest_cache", ".ruff_cache", "DerivedData", ".next", ".nuxt",
        ".cache", ".parcel-cache", ".turbo", "coverage", ".idea", ".vscode", ".gradle", "vendor", ".swiftpm", "Pods",
    ]
    static let ignoredSuffixes = ["~", ".swp", ".swx", ".tmp", ".temp", ".pyc", ".pyo", ".log", ".lock", ".DS_Store", ".orig", "4913"]

    /// `path` relative to the watched folder.
    public static func isIgnored(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let name = parts.last else { return true }
        if parts.dropLast().contains(where: { ignoredFolders.contains($0) }) || ignoredFolders.contains(name) { return true }
        if name.hasPrefix(".#") || (name.hasPrefix("#") && name.hasSuffix("#")) { return true }
        return ignoredSuffixes.contains { name.hasSuffix($0) }
    }

    /// Whether a changed file matches the patterns you gave ("*.py", "src/*", "Makefile"); no patterns = any file.
    public static func matches(_ relativePath: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return true }
        let name = (relativePath as NSString).lastPathComponent
        return patterns.contains { p in
            let pat = p.trimmingCharacters(in: .whitespaces)
            guard !pat.isEmpty else { return false }
            if pat.hasSuffix("/") { return relativePath.hasPrefix(pat) || relativePath.contains("/" + pat) }
            if pat.contains("/") { return AnserConfig.glob(pat.replacingOccurrences(of: "**/", with: "*"), relativePath) || AnserConfig.glob(pat, relativePath) }
            return AnserConfig.glob(pat, name)
        }
    }

    /// Patterns from what you typed: "*.py, *.toml" or "*.py *.toml".
    public static func parsePatterns(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    /// The folder to watch for a command run in `cwd`: the git repo, else the folder itself.
    public static func root(for cwd: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        var d = cwd
        for _ in 0..<20 {
            if exists((d as NSString).appendingPathComponent(".git")) { return d }
            if d == "/" || d.isEmpty || d == NSHomeDirectory() { break }
            d = (d as NSString).deletingLastPathComponent
        }
        return cwd
    }
}

/// A project's environment: `.env` files, a Python virtualenv, the Node
/// version from `.nvmrc`/`.node-version`, and `direnv`'s `.envrc`. Anser
/// offers to load it when you `cd` in and unloads it when you leave.
///
/// `.env` files are read by Anser, never run: their values are set with
/// `export`, so a `.env` can't run commands in your shell.
public enum ProjectEnv {
    public struct Found: Sendable, Equatable {
        public var root: String
        /// `.env` files, in load order (later ones win).
        public var dotenvFiles: [String] = []
        /// The virtualenv folder name (".venv", "venv").
        public var venv: String?
        /// From .nvmrc or .node-version.
        public var nodeVersion: String?
        public var nodeFile: String?
        public var envrc = false

        public init(root: String, dotenvFiles: [String] = [], venv: String? = nil, nodeVersion: String? = nil, nodeFile: String? = nil, envrc: Bool = false) {
            self.root = root; self.dotenvFiles = dotenvFiles; self.venv = venv; self.nodeVersion = nodeVersion; self.nodeFile = nodeFile; self.envrc = envrc
        }

        public var isEmpty: Bool { dotenvFiles.isEmpty && venv == nil && nodeVersion == nil && !envrc }

        /// ".env · .venv · node 20".
        public var summary: String {
            var p: [String] = dotenvFiles
            if let venv { p.append(venv) }
            if let nodeVersion { p.append("node " + nodeVersion.trimmingCharacters(in: CharacterSet(charactersIn: "v"))) }
            if envrc { p.append(".envrc") }
            return p.joined(separator: " · ")
        }
    }

    /// What Anser loaded into a shell, so it can unload it again.
    public struct Loaded: Sendable, Equatable {
        public var root: String
        public var keys: [String]
        public var venv: Bool
        public var node: Bool
        public var direnv: Bool
        public var summary: String
        public init(root: String, keys: [String], venv: Bool, node: Bool, direnv: Bool, summary: String) {
            self.root = root; self.keys = keys; self.venv = venv; self.node = node; self.direnv = direnv; self.summary = summary
        }
    }

    public static let dotenvNames = [".env", ".env.local", ".env.development", ".env.development.local"]
    static let venvNames = [".venv", "venv"]

    /// The nearest folder (up to the git repo or your home folder) with something to load.
    public static func find(from cwd: String, home: String = NSHomeDirectory(),
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                            read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Found? {
        var d = cwd
        for _ in 0..<12 {
            if d == home || d == "/" || d.isEmpty { return nil }
            func p(_ n: String) -> String { (d as NSString).appendingPathComponent(n) }
            var f = Found(root: d)
            f.dotenvFiles = dotenvNames.filter { exists(p($0)) }
            f.venv = venvNames.first { exists(p($0 + "/bin/activate")) }
            for n in [".nvmrc", ".node-version"] {
                if let v = read(p(n))?.split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }), !v.isEmpty, isSafeVersion(v) {
                    f.nodeVersion = v; f.nodeFile = n; break
                }
            }
            f.envrc = exists(p(".envrc"))
            if !f.isEmpty { return f }
            if exists(p(".git")) { return nil }
            d = (d as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func isSafeVersion(_ v: String) -> Bool {
        v.count < 40 && v.allSatisfy { $0.isLetter || $0.isNumber || ".-_/*".contains($0) }
    }

    /// Variables a `.env` may not change: they'd break the shell or let a file change what programs run.
    static let protectedKeys: Set<String> = ["PATH", "HOME", "SHELL", "USER", "LOGNAME", "ZDOTDIR", "PS1", "PS2", "PROMPT", "RPROMPT", "IFS",
                                             "PROMPT_COMMAND", "BASH_ENV", "ENV", "TERM", "TERM_PROGRAM", "TMPDIR", "SSH_AUTH_SOCK", "fish_function_path"]

    public static func isAllowedKey(_ k: String) -> Bool {
        guard let first = k.first, first == "_" || first.isLetter, k.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }), k.allSatisfy(\.isASCII) else { return false }
        if protectedKeys.contains(k) || k.hasPrefix("ANSER_") || k.hasPrefix("DYLD_") || k.hasPrefix("LD_") || k.hasPrefix("GHOSTTY_") { return false }
        return true
    }

    /// `KEY=value` pairs from a .env file: `export` prefixes, quotes, comments and `\n` in double quotes.
    public static func parseDotenv(_ text: String) -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            var line = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var raw = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard isAllowedKey(key) else { continue }
            var value: String
            if let q = raw.first, q == "\"" || q == "'" {
                raw.removeFirst()
                // Quoted values may span lines.
                while !containsClosing(raw, q), i < lines.count { raw += "\n" + lines[i]; i += 1 }
                if let end = closingIndex(raw, q) { raw = String(raw[..<end]) }
                value = raw
                if q == "\"" {
                    value = value.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                }
            } else {
                if let hash = raw.range(of: " #") { raw = String(raw[..<hash.lowerBound]) }
                value = raw.trimmingCharacters(in: .whitespaces)
            }
            out.append((key, value))
        }
        return out
    }

    private static func closingIndex(_ s: String, _ q: Character) -> String.Index? {
        var escaped = false
        for idx in s.indices {
            let c = s[idx]
            if escaped { escaped = false; continue }
            if c == "\\", q == "\"" { escaped = true; continue }
            if c == q { return idx }
        }
        return nil
    }
    private static func containsClosing(_ s: String, _ q: Character) -> Bool { closingIndex(s, q) != nil }

    public enum Shell: Sendable { case posix, fish
        public init(_ name: String) { self = name.hasSuffix("fish") ? .fish : .posix }
    }

    public struct Tools: Sendable {
        public var nvm = false, fnm = false, direnv = false
        public init(nvm: Bool = false, fnm: Bool = false, direnv: Bool = false) { self.nvm = nvm; self.fnm = fnm; self.direnv = direnv }
    }

    /// Shell code that loads `found`, plus what it loaded. `activeVenv` is $VIRTUAL_ENV (skip if it's already this one).
    public static func loadScript(_ found: Found, values: [(key: String, value: String)], shell: Shell, tools: Tools, activeVenv: String?) -> (script: String, loaded: Loaded) {
        var lines: [String] = []
        var keys: [String] = []
        let root = found.root
        var venv = false, node = false, direnv = false
        var parts: [String] = []
        if found.envrc, tools.direnv {
            lines.append(shell == .fish ? "direnv allow \(q(root, shell)) 2>/dev/null; direnv export fish 2>/dev/null | source"
                                        : "direnv allow \(q(root, shell)) 2>/dev/null; eval \"$(direnv export bash 2>/dev/null)\"")
            direnv = true
            parts.append(".envrc")
        }
        if let v = found.venv {
            let path = (root as NSString).appendingPathComponent(v)
            if activeVenv != path {
                let activate = path + (shell == .fish ? "/bin/activate.fish" : "/bin/activate")
                lines.append("source \(q(activate, shell)) >/dev/null 2>&1")
                venv = true
            }
            parts.append(v)
        }
        if let nv = found.nodeVersion {
            if tools.nvm { lines.append("nvm use \(q(nv, shell)) >/dev/null 2>&1"); node = true }
            else if tools.fnm { lines.append("fnm use \(q(nv, shell)) >/dev/null 2>&1"); node = true }
            if node { parts.append("node " + nv) }
        }
        var seen = Set<String>()
        for (k, _) in values where seen.insert(k).inserted { keys.append(k) }
        var latest: [String: String] = [:]
        for (k, v) in values { latest[k] = v }
        for k in keys {
            lines.append(shell == .fish ? "set -gx \(k) \(q(latest[k] ?? "", shell))" : "export \(k)=\(q(latest[k] ?? "", shell))")
        }
        if !keys.isEmpty { parts.insert("\(found.dotenvFiles.joined(separator: ", ")) (\(keys.count))", at: 0) }
        let loaded = Loaded(root: root, keys: keys, venv: venv, node: node, direnv: direnv, summary: parts.joined(separator: " · "))
        return (lines.joined(separator: "\n") + "\n", loaded)
    }

    /// Shell code that undoes `loaded` (variables unset, virtualenv deactivated).
    public static func unloadScript(_ loaded: Loaded, shell: Shell) -> String {
        var lines: [String] = []
        if loaded.venv { lines.append(shell == .fish ? "functions -q deactivate; and deactivate" : "type deactivate >/dev/null 2>&1 && deactivate") }
        if !loaded.keys.isEmpty { lines.append(shell == .fish ? "set -e " + loaded.keys.joined(separator: " ") : "unset " + loaded.keys.joined(separator: " ")) }
        if loaded.node { lines.append(shell == .fish ? "true" : "type nvm >/dev/null 2>&1 && nvm use default >/dev/null 2>&1") }
        // direnv undoes its own changes once you're outside the folder.
        if loaded.direnv { lines.append(shell == .fish ? "direnv export fish 2>/dev/null | source" : "eval \"$(direnv export bash 2>/dev/null)\"") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func q(_ s: String, _ shell: Shell) -> String {
        switch shell {
        case .posix: return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        case .fish: return "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
        }
    }
}
