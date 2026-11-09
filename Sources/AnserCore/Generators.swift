import Foundation
import os

/// What the completion engine knows about the shell a pane is running.
public struct ShellEnvironment: Sendable {
    public var path: [String]
    public var aliases: [String: String]
    public var functions: Set<String>
    public var home: String
    public var shell: String
    /// Set while the shell is an ssh session on another host: completion then
    /// avoids anything that reads this Mac (files, git, man pages).
    public var remoteHost: String?
    public var isRemote: Bool { remoteHost != nil }

    public init(path: [String] = ShellEnvironment.defaultPath, aliases: [String: String] = [:], functions: Set<String> = [], home: String = NSHomeDirectory(), shell: String = "zsh") {
        self.path = path; self.aliases = aliases; self.functions = functions; self.home = home; self.shell = shell
    }

    public static let defaultPath = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public var pathString: String { path.joined(separator: ":") }

    /// Parses `alias` output from zsh (`name=value`) or bash (`alias name='value'`).
    public static func parseAliases(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for var line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("alias ") { line.removeFirst(6) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq])
            var value = String(line[line.index(after: eq)...])
            if let tok = ShellLexer.tokenize(value).first, tok.kind == .word, tok.raw == value { value = tok.value }
            out[name] = value
        }
        return out
    }
}

/// Runs short helper commands with a timeout and caches their output.
public final class ScriptRunner: Sendable {
    public static let shared = ScriptRunner()
    private let cache = OSAllocatedUnfairLock(initialState: [String: (Date, String)]())

    public func run(_ script: String, cwd: String, env: ShellEnvironment, timeout: TimeInterval = 2.0, cacheSeconds: Double = 0) async -> String? {
        let key = cwd + "\u{0}" + script
        if cacheSeconds > 0, let hit = cache.withLock({ $0[key] }), Date().timeIntervalSince(hit.0) < cacheSeconds {
            return hit.1
        }
        let out = await Self.execute(["/bin/sh", "-c", script], cwd: cwd, env: env, timeout: timeout)
        if cacheSeconds > 0, let out {
            cache.withLock { $0[key] = (Date(), out) }
        }
        return out
    }

    /// Drops cached output for one folder (after something like `git fetch` changed it).
    /// Drops every cached result (when memory is short).
    public func forgetAll() { cache.withLock { $0.removeAll() } }

    public func forget(cwd: String) {
        cache.withLock { c in c = c.filter { !$0.key.hasPrefix(cwd + "\u{0}") } }
    }

    public func run(argv: [String], cwd: String, env: ShellEnvironment, timeout: TimeInterval = 2.0) async -> String? {
        await Self.execute(argv, cwd: cwd, env: env, timeout: timeout)
    }

    /// Runs with extra environment variables (plugins get ANSER_CWD and friends).
    public func run(argv: [String], cwd: String, env: ShellEnvironment, extra: [String: String], timeout: TimeInterval) async -> String? {
        await Self.execute(argv, cwd: cwd, env: env, timeout: timeout, extra: extra)
    }

    /// Runs and also returns the exit status (nil when it couldn't start or was stopped).
    public func runWithStatus(argv: [String], cwd: String, env: ShellEnvironment, extra: [String: String] = [:], timeout: TimeInterval) async -> (output: String, status: Int32?) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : env.home
                var e = ProcessInfo.processInfo.environment
                e["PATH"] = env.pathString
                for (k, v) in GitSafety.environment { e[k] = v }
                e["NO_COLOR"] = "1"
                for (k, v) in extra { e[k] = v }
                guard let r = ProcessRunner.run(argv, cwd: dir, environment: e, timeout: timeout) else { cont.resume(returning: ("couldn't start \(argv.first ?? "")", nil)); return }
                cont.resume(returning: (String(decoding: r.output, as: UTF8.self), r.exitStatus))
            }
        }
    }

    static func execute(_ argv: [String], cwd: String, env: ShellEnvironment, timeout: TimeInterval, extra: [String: String] = [:]) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : env.home
                var e = ProcessInfo.processInfo.environment
                e["PATH"] = env.pathString
                // Neutralize repo config that would make git run programs.
                for (k, v) in GitSafety.environment { e[k] = v }
                e["NO_COLOR"] = "1"
                e["PAGER"] = "cat"
                e["MANPAGER"] = "cat"
                e["TERM"] = "dumb"
                for (k, v) in extra { e[k] = v }
                guard let r = ProcessRunner.run(argv, cwd: dir, environment: e, timeout: timeout) else {
                    cont.resume(returning: nil); return
                }
                if r.timedOut { Self.timeouts.withLock { $0 += 1 } }
                cont.resume(returning: String(decoding: r.output, as: UTF8.self))
            }
        }
    }

    /// How many helper commands hit their time limit (shown in problem reports and tests).
    static let timeouts = OSAllocatedUnfairLock(initialState: 0)
    public static var timeoutCount: Int { timeouts.withLock { $0 } }
}

/// Native generators that specs can reference by name.
public enum Generators {
    public static let names = [
        "git_branches", "git_local_branches", "git_remote_branches", "git_switch_branches", "git_remotes", "git_tags",
        "git_changed_files", "git_staged_files", "git_stashes", "git_commits", "git_aliases",
        "npm_scripts", "make_targets", "ssh_hosts", "processes", "env_vars", "commands",
        "brew_installed", "docker_containers", "docker_images", "just_recipes",
    ]

    public static func forgetCache(cwd: String) { ScriptRunner.shared.forget(cwd: cwd) }

    public static func run(_ name: String, cwd: String, env: ShellEnvironment) async -> [Suggestion] {
        // Don't run git automatically in a repo whose config could run programs.
        if name.hasPrefix("git_"), GitSafety.isRisky(cwd: cwd) { return [] }
        let r = ScriptRunner.shared
        func lines(_ s: String?) -> [String] {
            (s ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        switch name {
        case "git_branches", "git_local_branches", "git_remote_branches":
            let refs = name == "git_local_branches" ? "refs/heads" : name == "git_remote_branches" ? "refs/remotes" : "refs/heads refs/remotes"
            let out = await r.run("git for-each-ref --sort=-committerdate --format='%(refname:short)\t%(committerdate:unix)\t%(subject)' \(refs)", cwd: cwd, env: env, cacheSeconds: 3)
            var seen = Set<String>()
            var res: [Suggestion] = []
            for l in lines(out) {
                let parts = l.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard let n = parts.first, !n.hasSuffix("/HEAD"), n != "origin", seen.insert(n).inserted else { continue }
                let when = parts.count > 1 ? RelativeTime.format(unix: parts[1]) : nil
                let desc = [when, parts.count > 2 ? parts[2] : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                res.append(Suggestion(name: n, description: desc.isEmpty ? nil : String(desc.prefix(80))))
            }
            return res
        case "git_switch_branches":
            // `git switch` takes "feature", not "origin/feature": remote-only branches go in by their short name.
            let locals = await run("git_local_branches", cwd: cwd, env: env)
            var have = Set(locals.map(\.name))
            var res = locals
            for b in await run("git_remote_branches", cwd: cwd, env: env) {
                guard let slash = b.name.firstIndex(of: "/") else { continue }
                let short = String(b.name[b.name.index(after: slash)...])
                guard !short.isEmpty, have.insert(short).inserted else { continue }
                res.append(Suggestion(name: short, description: ["remote", b.description].compactMap { $0 }.joined(separator: " · ")))
            }
            return res
        case "git_remotes":
            return lines(await r.run("git remote -v", cwd: cwd, env: env, cacheSeconds: 10)).compactMap { l -> Suggestion? in
                let p = l.split(whereSeparator: { $0 == "\t" || $0 == " " })
                guard p.count >= 2, l.hasSuffix("(fetch)") else { return nil }
                return Suggestion(name: String(p[0]), description: String(p[1]))
            }
        case "git_tags":
            return lines(await r.run("git tag --sort=-creatordate", cwd: cwd, env: env, cacheSeconds: 10)).prefix(100).map { Suggestion(name: $0, description: "tag") }
        case "git_changed_files", "git_staged_files":
            let out = await r.run("git status --porcelain=v1 -uall", cwd: cwd, env: env, cacheSeconds: 1)
            var res: [Suggestion] = []
            for l in (out ?? "").split(separator: "\n") where l.count > 3 {
                let x = l[l.startIndex], y = l[l.index(after: l.startIndex)]
                var file = String(l.dropFirst(3))
                if let arrow = file.range(of: " -> ") { file = String(file[arrow.upperBound...]) }
                if file.hasPrefix("\""), file.hasSuffix("\""), let tok = ShellLexer.tokenize(file).first { file = tok.value }
                let staged = x != " " && x != "?"
                let unstaged = y != " " || x == "?"
                if name == "git_staged_files" ? staged : unstaged {
                    let desc: String = x == "?" ? "untracked" : (name == "git_staged_files" ? describeStatus(x) : describeStatus(y))
                    res.append(Suggestion(name: relativize(file, repoCwd: cwd), description: desc))
                }
            }
            return res
        case "git_stashes":
            return lines(await r.run("git stash list --format='%gd\t%s'", cwd: cwd, env: env)).map { l in
                let p = l.split(separator: "\t", maxSplits: 1).map(String.init)
                return Suggestion(name: p[0], description: p.count > 1 ? p[1] : nil)
            }
        case "git_commits":
            return lines(await r.run("git log --format='%h\t%ct\t%s' -40", cwd: cwd, env: env, cacheSeconds: 3)).map { l in
                let p = l.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                let when = p.count > 1 ? RelativeTime.format(unix: p[1]) : nil
                let desc = [p.count > 2 ? p[2] : nil, when].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                return Suggestion(name: p[0], description: desc.isEmpty ? nil : String(desc.prefix(80)))
            }
        case "git_aliases":
            return lines(await r.run("git config --get-regexp '^alias\\.'", cwd: cwd, env: env, cacheSeconds: 30)).compactMap { l in
                let p = l.split(separator: " ", maxSplits: 1).map(String.init)
                guard let k = p.first, k.hasPrefix("alias.") else { return nil }
                return Suggestion(name: String(k.dropFirst(6)), description: "alias: " + (p.count > 1 ? p[1] : ""))
            }
        case "npm_scripts":
            guard let pkg = findUp("package.json", from: cwd),
                  let data = FileManager.default.contents(atPath: pkg),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let scripts = json["scripts"] as? [String: String] else { return [] }
            return scripts.sorted { $0.key < $1.key }.map { Suggestion(name: $0.key, description: $0.value) }
        case "make_targets":
            guard let mk = ["GNUmakefile", "makefile", "Makefile"].map({ cwd + "/" + $0 }).first(where: FileManager.default.fileExists),
                  let text = try? String(contentsOfFile: mk, encoding: .utf8) else { return [] }
            var res: [Suggestion] = []
            var seen = Set<String>()
            var lastComment: String?
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("#") { lastComment = line.drop(while: { $0 == "#" || $0 == " " }).description; continue }
                defer { if !line.hasPrefix("#") { lastComment = nil } }
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix("."),
                      line[line.index(after: colon)...].first != "=" else { continue }
                // `target: deps ## description` convention
                let desc = line.range(of: "##").map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? lastComment
                for t in line[..<colon].split(separator: " ") where !t.contains("$") && !t.contains("%") {
                    if seen.insert(String(t)).inserted { res.append(Suggestion(name: String(t), description: desc)) }
                }
            }
            return res
        case "just_recipes":
            return lines(await r.run("just --summary", cwd: cwd, env: env, cacheSeconds: 5)).flatMap { $0.split(separator: " ").map { Suggestion(name: String($0), description: "recipe") } }
        case "ssh_hosts":
            var hosts: [Suggestion] = []
            var seen = Set<String>()
            if let cfg = try? String(contentsOfFile: env.home + "/.ssh/config", encoding: .utf8) {
                for line in cfg.split(separator: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard t.lowercased().hasPrefix("host ") else { continue }
                    for h in t.dropFirst(5).split(separator: " ") where !h.contains("*") && !h.contains("?") {
                        if seen.insert(String(h)).inserted { hosts.append(Suggestion(name: String(h), description: "~/.ssh/config")) }
                    }
                }
            }
            if let known = try? String(contentsOfFile: env.home + "/.ssh/known_hosts", encoding: .utf8) {
                for line in known.split(separator: "\n") {
                    guard let first = line.split(separator: " ").first, !first.hasPrefix("|") else { continue }
                    for h in first.split(separator: ",") {
                        var host = String(h)
                        if host.hasPrefix("["), let end = host.firstIndex(of: "]") { host = String(host[host.index(after: host.startIndex)..<end]) }
                        if seen.insert(host).inserted { hosts.append(Suggestion(name: host, description: "known host")) }
                    }
                }
            }
            return hosts
        case "processes":
            return lines(await r.run("ps -axco pid=,comm=", cwd: cwd, env: env)).compactMap { l in
                let p = l.split(separator: " ", maxSplits: 1).map(String.init)
                guard p.count == 2 else { return nil }
                return Suggestion(name: p[0], description: p[1])
            }
        case "env_vars":
            return ProcessInfo.processInfo.environment.keys.sorted().map { Suggestion(name: $0, description: nil) }
        case "commands":
            return CommandIndex.shared.commands(env: env).map { Suggestion(name: $0, description: nil) }
        case "brew_installed":
            return lines(await r.run("brew list -1", cwd: cwd, env: env, timeout: 4, cacheSeconds: 60)).map { Suggestion(name: $0, description: "installed") }
        case "docker_containers":
            return lines(await r.run("docker ps -a --format '{{.Names}}\t{{.Image}} · {{.Status}}'", cwd: cwd, env: env, cacheSeconds: 3)).map { l in
                let p = l.split(separator: "\t", maxSplits: 1).map(String.init)
                return Suggestion(name: p[0], description: p.count > 1 ? p[1] : nil)
            }
        case "docker_images":
            return lines(await r.run("docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}'", cwd: cwd, env: env, cacheSeconds: 10)).map { l in
                let p = l.split(separator: "\t", maxSplits: 1).map(String.init)
                return Suggestion(name: p[0], description: p.count > 1 ? p[1] : nil)
            }
        default:
            return []
        }
    }

    static func describeStatus(_ c: Character) -> String {
        switch c {
        case "M": "modified"
        case "A": "added"
        case "D": "deleted"
        case "R": "renamed"
        case "C": "copied"
        case "U": "conflict"
        case "?": "untracked"
        default: "changed"
        }
    }

    /// git status paths are relative to the repo root; make them relative to cwd.
    static func relativize(_ file: String, repoCwd: String) -> String {
        guard let root = findUp(".git", from: repoCwd).map({ ($0 as NSString).deletingLastPathComponent }) else { return file }
        let abs = (root as NSString).appendingPathComponent(file)
        let cwd = repoCwd.hasSuffix("/") ? repoCwd : repoCwd + "/"
        if abs.hasPrefix(cwd) { return String(abs.dropFirst(cwd.count)) }
        // Walk up with ../
        var base = repoCwd
        var ups = ""
        while !abs.hasPrefix(base.hasSuffix("/") ? base : base + "/"), base != "/" {
            base = (base as NSString).deletingLastPathComponent
            ups += "../"
        }
        let b = base.hasSuffix("/") ? base : base + "/"
        return ups + String(abs.dropFirst(b.count))
    }

    static func findUp(_ name: String, from dir: String) -> String? {
        var d = dir
        while true {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: p) { return p }
            if d == "/" || d.isEmpty { return nil }
            d = (d as NSString).deletingLastPathComponent
        }
    }
}

/// One line of `git status`.
public struct GitChange: Sendable, Equatable {
    /// Two-letter porcelain code, e.g. " M", "M ", "??", "A ".
    public var code: String
    public var path: String
    public var staged: Bool { let x = code.first ?? " "; return x != " " && x != "?" }
    public var untracked: Bool { code == "??" }

    public var summary: String {
        if untracked { return "new file" }
        let c = staged ? code.first! : code.last!
        let word = Generators.describeStatus(c)
        return staged ? word + ", staged" : word
    }

    /// Parses `git status --porcelain=v1` output.
    public static func parse(_ text: String) -> [GitChange] {
        text.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            let code = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            if path.hasPrefix("\""), let tok = ShellLexer.tokenize(path).first { path = tok.value }
            return GitChange(code: code, path: path)
        }
    }
}

extension Generators {
    /// Changed files in the repo containing `cwd`, with paths relative to `cwd`.
    public static func gitChanges(cwd: String, env: ShellEnvironment) async -> [GitChange] {
        if GitSafety.isRisky(cwd: cwd) { return [] }
        let out = await ScriptRunner.shared.run("git status --porcelain=v1 -uall", cwd: cwd, env: env, timeout: 3)
        return GitChange.parse(out ?? "").map { c in
            var c = c
            c.path = relativize(c.path, repoCwd: cwd)
            return c
        }
    }
}

/// Executables on PATH, cached briefly.
public final class CommandIndex: Sendable {
    public static let shared = CommandIndex()
    private let cache = OSAllocatedUnfairLock(initialState: [String: (Date, [String], Set<String>)]())

    private func load(_ env: ShellEnvironment) -> ([String], Set<String>) {
        let key = env.pathString
        if let hit = cache.withLock({ $0[key] }), Date().timeIntervalSince(hit.0) < 30 { return (hit.1, hit.2) }
        var set = Set<String>()
        let fm = FileManager.default
        for dir in env.path {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where !item.hasPrefix(".") {
                if fm.isExecutableFile(atPath: dir + "/" + item) { set.insert(item) }
            }
        }
        let list = set.sorted(), found = set
        cache.withLock { $0[key] = (Date(), list, found) }
        return (list, found)
    }

    public func commands(env: ShellEnvironment) -> [String] { load(env).0 }

    public func contains(_ name: String, env: ShellEnvironment) -> Bool { load(env).1.contains(name) }

    /// "Did you mean…" for a mistyped command: close names (edit distance ≤ 2),
    /// favoring ones you use often.
    public func suggestions(for name: String, env: ShellEnvironment, frequency: [String: Int] = [:], limit: Int = 3) -> [String] {
        guard name.count >= 2, !name.contains("/") else { return [] }
        let maxDist = name.count <= 3 ? 1 : 2
        var pool = Set(load(env).1)
        pool.formUnion(env.aliases.keys)
        pool.formUnion(env.functions)
        pool.formUnion(ShellBuiltins.all.keys)
        var scored: [(String, Int, Int)] = []
        for cand in pool where abs(cand.count - name.count) <= maxDist && cand != name && !cand.hasPrefix("_") {
            let d = Self.editDistance(name, cand)
            if d <= maxDist { scored.append((cand, d, frequency[cand] ?? 0)) }
        }
        return scored.sorted { ($0.1, -$0.2, $0.0) < ($1.1, -$1.2, $1.0) }.prefix(limit).map(\.0)
    }

    /// Damerau–Levenshtein distance (adjacent swaps count as one edit).
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }

    public func exists(_ name: String, env: ShellEnvironment) -> Bool {
        if name.contains("/") {
            let p = name.hasPrefix("~") ? env.home + name.dropFirst() : name
            return FileManager.default.isExecutableFile(atPath: p)
        }
        return contains(name, env: env) || env.aliases[name] != nil || env.functions.contains(name) || ShellBuiltins.all[name] != nil
    }
}

/// Learns a command's options from its man page, or from `--help` for
/// commands known to handle `--help` safely.
public final class HelpParser: Sendable {
    public static let shared = HelpParser()
    private struct State: Sendable {
        var cache: [String: [OptionSpec]] = [:]
        var inFlight: Set<String> = []
        var allowlist = HelpParser.defaultAllowlist
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Commands it's safe to run with `--help`. Anything else only gets its
    /// man page read, because an unknown script might ignore `--help` and run.
    public var helpAllowlist: Set<String> { state.withLock { $0.allowlist } }
    static let defaultAllowlist: Set<String> = [
        "git", "npm", "npx", "node", "deno", "bun", "yarn", "pnpm", "python3", "python", "pip", "pip3", "uv",
        "cargo", "rustc", "rustup", "go", "swift", "xcodebuild", "xcrun", "docker", "kubectl", "helm", "brew", "gh",
        "curl", "wget", "rg", "fd", "bat", "eza", "lsd", "jq", "yq", "fzf", "terraform", "aws", "gcloud", "az",
        "ffmpeg", "tsc", "eslint", "prettier", "cmake", "ninja", "rsync", "zip", "unzip", "http", "httpie",
        "code", "cursor", "zed", "nvim", "vim", "tmux", "just", "poetry", "pipx", "ruby", "gem", "bundle",
        "java", "mvn", "gradle", "kotlin", "dotnet", "php", "composer", "flutter", "dart", "claude",
    ]

    /// Returns cached options immediately if known.
    public func cached(_ command: String) -> [OptionSpec]? {
        state.withLock { $0.cache[command] }
    }

    public func options(for command: String, env: ShellEnvironment) async -> [OptionSpec] {
        if let c = cached(command) { return c }
        // Only plain command names that exist; never arbitrary paths.
        guard !command.contains("/"), CommandIndex.shared.contains(command, env: env) else { return [] }
        let started = state.withLock { $0.inFlight.insert(command).inserted }
        if !started { return [] }

        // The man page is always safe to read.
        var opts = await fromMan(command, env: env)
        if opts.count < 3, helpAllowlist.contains(command) {
            let help = HelpParser.parse(await ScriptRunner.shared.run(argv: ["/usr/bin/env", command, "--help"], cwd: NSTemporaryDirectory(), env: env, timeout: 1.5) ?? "")
            if help.count > opts.count { opts = help }
        }
        let found = opts
        state.withLock { $0.cache[command] = found; $0.inFlight.remove(command) }
        return opts
    }

    public func allow(_ commands: [String]) {
        state.withLock { $0.allowlist.formUnion(commands) }
    }

    private func fromMan(_ command: String, env: ShellEnvironment) async -> [OptionSpec] {
        let out = await ScriptRunner.shared.run("man -P cat \(ShellLexer.escape(command)) 2>/dev/null | col -bx", cwd: NSTemporaryDirectory(), env: env, timeout: 3)
        return HelpParser.parse(out ?? "")
    }

    /// Extracts options from help text. Handles GNU style (`-a, --all  desc`),
    /// BSD man pages (`-a      desc`) and `--flag=VALUE` forms.
    public static func parse(_ text: String) -> [OptionSpec] {
        var out: [OptionSpec] = []
        var seen = Set<String>()
        let lines = text.components(separatedBy: "\n")
        let optRe = try! NSRegularExpression(pattern: #"^\s{0,12}((?:-{1,2}[A-Za-z0-9#?][\w\-\.]*(?:[= ]?\[?[<A-Z][\w\-<>\]]*\]?)?(?:,\s*|\s*\|\s*|\s+or\s+)?)+)(?:\s{2,}|\t)?(.*)$"#)
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            guard let m = optRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let optPart = ns.substring(with: m.range(at: 1))
            var desc = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces) : ""
            // BSD man pages often put the description on the next line.
            if desc.isEmpty, i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if !next.hasPrefix("-") { desc = next }
            }
            var names: [String] = []
            var takesArg = false
            for piece in optPart.components(separatedBy: CharacterSet(charactersIn: ", |")) {
                let p = piece.trimmingCharacters(in: .whitespaces)
                guard p.hasPrefix("-"), p.count >= 2 else {
                    if !p.isEmpty, p.first?.isUppercase == true || p.hasPrefix("<") || p.hasPrefix("[") { takesArg = true }
                    continue
                }
                var name = p
                if let eq = name.firstIndex(where: { $0 == "=" || $0 == "[" }) { takesArg = true; name = String(name[..<eq]) }
                if name == "-" || name == "--" { continue }
                names.append(name)
            }
            names = names.filter { seen.insert($0).inserted }
            guard !names.isEmpty else { continue }
            if desc.count > 120 { desc = String(desc.prefix(117)) + "…" }
            out.append(OptionSpec(names: names, description: desc.isEmpty ? nil : desc, args: takesArg ? [ArgSpec(name: "value", isOptional: true)] : []))
            if out.count > 300 { break }
        }
        return out
    }
}

public enum ShellBuiltins {
    /// zsh/bash builtins and keywords with short descriptions.
    public static let all: [String: String] = [
        "cd": "Change the current directory", "pwd": "Print the current directory",
        "echo": "Write arguments to output", "printf": "Formatted output", "print": "zsh print",
        "export": "Set an environment variable", "unset": "Remove a variable or function",
        "alias": "Define or list aliases", "unalias": "Remove an alias", "source": "Run a file in this shell",
        ".": "Run a file in this shell", "exit": "Exit the shell", "history": "Show command history",
        "fc": "Edit and re-run history", "jobs": "List background jobs", "fg": "Bring a job to the foreground",
        "bg": "Resume a job in the background", "kill": "Send a signal to a process", "wait": "Wait for jobs",
        "type": "Describe how a name is resolved", "which": "Locate a command", "whence": "zsh: locate a command",
        "eval": "Run arguments as a command", "exec": "Replace the shell with a command",
        "set": "Set shell options", "setopt": "zsh: set options", "unsetopt": "zsh: unset options",
        "read": "Read a line of input", "test": "Evaluate a condition", "true": "Do nothing, successfully",
        "false": "Do nothing, unsuccessfully", "trap": "Run a command on signal", "umask": "File creation mask",
        "ulimit": "Resource limits", "pushd": "Push a directory onto the stack", "popd": "Pop the directory stack",
        "dirs": "Show the directory stack", "hash": "Remember command locations", "rehash": "Rebuild command hash",
        "command": "Run a command, skipping functions", "builtin": "Run a builtin", "local": "Declare a local variable",
        "declare": "Declare variables", "typeset": "Declare variables", "readonly": "Make variables read-only",
        "shift": "Shift positional parameters", "return": "Return from a function", "times": "Show process times",
        "autoload": "zsh: autoload a function", "bindkey": "zsh: key bindings", "compdef": "zsh: completion definition",
        "if": "Conditional", "then": "Conditional body", "else": "Conditional alternative", "fi": "End conditional",
        "for": "Loop over values", "while": "Loop while true", "until": "Loop until true", "do": "Loop body",
        "done": "End loop", "case": "Pattern match", "esac": "End case", "function": "Define a function",
        "time": "Time a command", "disown": "Detach a job", "suspend": "Suspend the shell", "help": "bash: builtin help",
        "shopt": "bash: shell options", "complete": "bash: completion spec", "mapfile": "bash: read lines to array",
    ]
}
