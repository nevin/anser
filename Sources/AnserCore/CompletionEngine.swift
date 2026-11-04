import Foundation

public struct Completion: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case history, command, alias, builtin, function, subcommand, option, file, folder
        case branch, argument, variable, snippet
    }

    public var kind: Kind
    /// Text that replaces `replaceRange` (already shell-escaped).
    public var insert: String
    /// What the popup shows.
    public var display: String
    public var detail: String?
    public var score: Double
    public var positions: [Int]
    /// Add a space after accepting (false for folders and `--opt=`).
    public var appendSpace: Bool
    /// Replace the whole command line instead of just the current word.
    public var replacesLine: Bool

    public init(kind: Kind, insert: String, display: String? = nil, detail: String? = nil, score: Double = 0, positions: [Int] = [], appendSpace: Bool = true, replacesLine: Bool = false) {
        self.kind = kind; self.insert = insert; self.display = display ?? insert; self.detail = detail
        self.score = score; self.positions = positions; self.appendSpace = appendSpace; self.replacesLine = replacesLine
    }
}

public final class CompletionEngine: @unchecked Sendable {
    public let specs: SpecRegistry
    public let history: HistoryStore?
    public var snippets: [(name: String, command: String)] = []
    public var maxResults = 60

    public init(specs: SpecRegistry, history: HistoryStore?) {
        self.specs = specs
        self.history = history
    }

    public func complete(_ ctx: CompletionContext, env: ShellEnvironment) async -> [Completion] {
        var results: [Completion] = []
        let prefix = ctx.prefix

        // $VARIABLE
        if prefix.hasPrefix("$"), ctx.openQuote != "'" {
            let q = String(prefix.dropFirst()).replacingOccurrences(of: "{", with: "")
            for name in ProcessInfo.processInfo.environment.keys {
                if let m = Fuzzy.match(q, name) {
                    results.append(Completion(kind: .variable, insert: "$" + name, detail: ProcessInfo.processInfo.environment[name].map { String($0.prefix(60)) }, score: Double(m.score), positions: m.positions.map { $0 + 1 }))
                }
            }
            return finish(results, query: prefix)
        }

        if ctx.isCommandPosition {
            results += historyLines(ctx)
            if prefix.contains("/") || prefix.hasPrefix(".") || prefix.hasPrefix("~") {
                results += paths(ctx, env: env, foldersOnly: false, executablesOnly: true)
            } else {
                results += commandNames(prefix, env: env)
            }
            return finish(results, query: prefix)
        }

        if ctx.afterRedirect {
            return finish(paths(ctx, env: env, foldersOnly: false))
        }

        // Expand an alias in command position (g → git).
        var words = ctx.words
        if let first = words.first, let expansion = env.aliases[first] {
            let expanded = ShellLexer.tokenize(expansion).filter { $0.kind == .word }.map(\.value)
            if let cmd = expanded.first, cmd != first { words = expanded + words.dropFirst() }
        }
        guard let command = words.first else { return finish(paths(ctx, env: env, foldersOnly: false)) }

        // Whole-line history matches are useful even mid-command.
        results += historyLines(ctx)

        if let spec = specs.spec(for: command) ?? specs.spec(for: (command as NSString).lastPathComponent) {
            results += await fromSpec(spec, words: Array(words.dropFirst()), ctx: ctx, env: env, commandName: command)
        } else if prefix.hasPrefix("-"), !env.isRemote {
            let opts = await HelpParser.shared.options(for: command, env: env)
            results += optionCompletions(opts, used: Set(words), ctx: ctx)
        } else {
            results += paths(ctx, env: env, foldersOnly: false)
        }
        return finish(results, query: prefix)
    }

    // MARK: Hints

    /// What the word under the cursor means, for the editor's hint line.
    public struct Hint: Equatable, Sendable {
        /// e.g. "git commit" or "git commit -m ‹message›"
        public var title: String
        public var detail: String?
    }

    public func hint(line: String, cursor: Int, cwd: String, env: ShellEnvironment) -> Hint? {
        let ctx = CompletionContext(line: line, cursor: cursor, cwd: cwd)
        let ns = line as NSString
        let lo = min(ctx.replaceRange.lowerBound, ns.length), hi = min(ctx.replaceRange.upperBound, ns.length)
        let current = ns.substring(with: NSRange(location: lo, length: hi - lo))

        var words = ctx.words
        if let first = words.first, let expansion = env.aliases[first] {
            let expanded = ShellLexer.tokenize(expansion).filter { $0.kind == .word }.map(\.value)
            if let cmd = expanded.first, cmd != first { words = expanded + words.dropFirst() }
        }
        // The command word itself.
        if ctx.isCommandPosition {
            guard !current.isEmpty else { return nil }
            if let a = env.aliases[current] { return Hint(title: current, detail: "alias for " + a) }
            if let d = ShellBuiltins.all[current] { return Hint(title: current, detail: d) }
            if let d = specs.describe(current) { return Hint(title: current, detail: d) }
            return nil
        }
        guard let command = words.first, let root = specs.spec(for: command) else { return nil }

        var node = root
        var path = [command]
        var persistent = root.options.filter(\.isPersistent)
        var argIndex = 0
        var pending: (OptionSpec, [ArgSpec])?
        for w in words.dropFirst() {
            if let p = pending, !p.1.isEmpty { pending = p.1.count > 1 ? (p.0, Array(p.1.dropFirst())) : nil; continue }
            if w.hasPrefix("-"), w.count > 1 {
                let name = String(w.split(separator: "=").first ?? "")
                if let opt = (node.options + persistent).first(where: { $0.names.contains(name) }), !w.contains("=") {
                    let required = opt.args.filter { !$0.isOptional }
                    pending = required.isEmpty ? nil : (opt, required)
                }
                continue
            }
            if argIndex == 0, let sub = node.subcommand(named: w) {
                node = sub; path.append(w); persistent += sub.options.filter(\.isPersistent); continue
            }
            argIndex += 1
        }
        let pathText = path.joined(separator: " ")
        func argLabel(_ a: ArgSpec) -> String { "‹\(a.name ?? "value")›" }

        if current.hasPrefix("-"), current.count > 1 {
            let name = String(current.split(separator: "=").first ?? "")
            let opts = node.options + persistent
            if let opt = opts.first(where: { $0.names.contains(name) }) ?? opts.first(where: { $0.names.contains { $0.hasPrefix(name) } }) {
                let args = opt.args.map(argLabel).joined(separator: " ")
                return Hint(title: "\(pathText) \(opt.names.joined(separator: ", "))\(args.isEmpty ? "" : " " + args)", detail: opt.description)
            }
        }
        if argIndex == 0, !current.isEmpty, let sub = node.subcommand(named: current) {
            return Hint(title: "\(pathText) \(current)", detail: sub.description)
        }
        if let (opt, args) = pending, let a = args.first {
            return Hint(title: "\(pathText) \(opt.names.first ?? "") \(argLabel(a))", detail: a.description ?? opt.description)
        }
        // Still choosing a subcommand: describe the command itself.
        if argIndex == 0, !node.subcommands.isEmpty { return Hint(title: pathText, detail: node.description) }
        let a = argIndex < node.args.count ? node.args[argIndex] : (node.args.last?.isVariadic == true ? node.args.last : nil)
        if let a, a.name != nil || a.description != nil {
            return Hint(title: "\(pathText) \(argLabel(a))", detail: a.description ?? node.description)
        }
        return Hint(title: pathText, detail: node.description)
    }

    // MARK: Spec walking

    private func fromSpec(_ root: CompletionSpec, words: [String], ctx: CompletionContext, env: ShellEnvironment, commandName: String) async -> [Completion] {
        var node = root
        var persistent: [OptionSpec] = root.options.filter(\.isPersistent)
        var argIndex = 0
        var pendingArgs: [ArgSpec] = []
        var endOfOptions = false
        var used = Set<String>()
        var idx = 0

        while idx < words.count {
            let w = words[idx]
            idx += 1
            if !pendingArgs.isEmpty {
                pendingArgs.removeFirst()
                continue
            }
            if w == "--" { endOfOptions = true; continue }
            if w.hasPrefix("-"), !endOfOptions, w.count > 1 {
                let name = w.split(separator: "=", maxSplits: 1).first.map(String.init) ?? w
                used.insert(name)
                if let opt = findOption(name, node: node, persistent: persistent) {
                    opt.names.forEach { used.insert($0) }
                    if !w.contains("=") { pendingArgs = opt.args.filter { !$0.isOptional } }
                }
                continue
            }
            if argIndex == 0, let sub = node.subcommand(named: w) {
                node = sub
                persistent += sub.options.filter(\.isPersistent)
                used.removeAll()
                continue
            }
            // A positional argument that is itself a command (sudo/xargs style)
            if let arg = argAt(node, argIndex), arg.isCommand {
                let rest = Array(words[(idx - 1)...])
                if let s = specs.spec(for: w) { return await fromSpec(s, words: Array(rest.dropFirst()), ctx: ctx, env: env, commandName: w) }
                return paths(ctx, env: env, foldersOnly: false)
            }
            argIndex += 1
        }

        let prefix = ctx.prefix
        var out: [Completion] = []

        // Value for an option that takes an argument: --branch <TAB>
        if let pending = pendingArgs.first {
            return await argCompletions(pending, ctx: ctx, env: env)
        }

        // --opt=value
        if prefix.hasPrefix("--"), let eq = prefix.firstIndex(of: "=") {
            let name = String(prefix[..<eq])
            if let opt = findOption(name, node: node, persistent: persistent), let arg = opt.args.first {
                var sub = ctx
                sub.prefix = String(prefix[prefix.index(after: eq)...])
                let lead = name + "="
                return await argCompletions(arg, ctx: sub, env: env).map { c in
                    var c = c; c.insert = lead + c.insert; c.positions = c.positions.map { $0 + lead.count }; c.display = c.display; return c
                }
            }
        }

        if prefix.hasPrefix("-"), !endOfOptions {
            var opts = node.options + persistent.filter { p in !node.options.contains { $0.names == p.names } }
            if opts.isEmpty || (node === root && root.parseHelp) {
                opts += await HelpParser.shared.options(for: commandName, env: env)
            }
            return optionCompletions(opts, used: used, ctx: ctx)
        }

        if argIndex == 0 {
            for sub in node.subcommands {
                guard let best = sub.names.compactMap({ n in Fuzzy.match(prefix, n).map { (n, $0) } }).max(by: { $0.1.score < $1.1.score }) else { continue }
                out.append(Completion(kind: .subcommand, insert: best.0, detail: sub.description, score: Double(best.1.score) + 20, positions: best.1.positions))
            }
        }

        if let arg = argAt(node, argIndex) {
            if arg.isCommand {
                out += commandNames(prefix, env: env)
            } else {
                out += await argCompletions(arg, ctx: ctx, env: env)
            }
        } else if node.subcommands.isEmpty || argIndex > 0 {
            // No declared args: most commands take files.
            out += paths(ctx, env: env, foldersOnly: false)
        }
        return out
    }

    private func argAt(_ node: CompletionSpec, _ i: Int) -> ArgSpec? {
        if i < node.args.count { return node.args[i] }
        if let last = node.args.last, last.isVariadic { return last }
        return nil
    }

    private func findOption(_ name: String, node: CompletionSpec, persistent: [OptionSpec]) -> OptionSpec? {
        node.options.first { $0.names.contains(name) } ?? persistent.first { $0.names.contains(name) }
    }

    private func optionCompletions(_ opts: [OptionSpec], used: Set<String>, ctx: CompletionContext) -> [Completion] {
        var out: [Completion] = []
        for opt in opts {
            if !opt.isRepeatable, opt.names.contains(where: used.contains) { continue }
            // Prefer the long name when the user typed "--", else the first match.
            let candidates = opt.names.filter { ctx.prefix.hasPrefix("--") ? $0.hasPrefix("--") : true }
            guard let best = candidates.compactMap({ n in Fuzzy.match(ctx.prefix, n).map { (n, $0) } }).max(by: { $0.1.score < $1.1.score }) else { continue }
            let others = opt.names.filter { $0 != best.0 }.joined(separator: ", ")
            var detail = opt.description ?? ""
            if !others.isEmpty { detail = detail.isEmpty ? others : "\(detail)  (\(others))" }
            let takesValue = !opt.args.isEmpty && best.0.hasPrefix("--") && opt.args.first?.isOptional == false
            out.append(Completion(kind: .option, insert: best.0, detail: detail.isEmpty ? nil : detail, score: Double(best.1.score), positions: best.1.positions, appendSpace: !takesValue || true))
        }
        return out
    }

    private func argCompletions(_ arg: ArgSpec, ctx: CompletionContext, env: ShellEnvironment) async -> [Completion] {
        var out: [Completion] = []
        let prefix = ctx.prefix
        for s in arg.suggestions {
            if let m = Fuzzy.match(prefix, s.name) {
                out.append(Completion(kind: .argument, insert: ShellLexer.escape(s.name, insideQuote: ctx.openQuote), display: s.name, detail: s.description, score: Double(m.score) + 10, positions: m.positions))
            }
        }
        for g in arg.generators where !env.isRemote {
            var items: [Suggestion] = []
            if let b = g.builtin {
                items = await Generators.run(b, cwd: ctx.cwd, env: env)
            } else if let script = g.script {
                let text = await ScriptRunner.shared.run(script, cwd: ctx.cwd, env: env, cacheSeconds: g.cacheSeconds ?? 2) ?? ""
                for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let sep = g.descriptionSeparator, let r = line.range(of: sep) {
                        items.append(Suggestion(name: String(line[..<r.lowerBound]), description: String(line[r.upperBound...])))
                    } else {
                        items.append(Suggestion(name: String(line), description: nil))
                    }
                }
            }
            let kind: Completion.Kind = (g.builtin ?? "").contains("branch") ? .branch : .argument
            for s in items.prefix(500) {
                if let m = Fuzzy.match(prefix, s.name) {
                    out.append(Completion(kind: kind, insert: ShellLexer.escape(s.name, insideQuote: ctx.openQuote), display: s.name, detail: s.description, score: Double(m.score) + 15, positions: m.positions))
                }
            }
        }
        if arg.template.contains("filepaths") || arg.template.contains("folders") {
            out += paths(ctx, env: env, foldersOnly: !arg.template.contains("filepaths"))
        }
        // A bare, unnamed argument usually means "a file". Named free-text
        // args (a commit message, a new branch name) get no suggestions.
        if arg.suggestions.isEmpty, arg.generators.isEmpty, arg.template.isEmpty, arg.name == nil || arg.name == "value" {
            out += paths(ctx, env: env, foldersOnly: false)
        }
        return out
    }

    // MARK: Sources

    /// Commands, aliases, functions and builtins for the first word.
    func commandNames(_ prefix: String, env: ShellEnvironment) -> [Completion] {
        var out: [Completion] = []
        let freq = history?.commandNameFrequency() ?? [:]
        func boost(_ n: String) -> Double { log2(Double(freq[n] ?? 0) + 1) * 12 }
        var seen = Set<String>()
        func add(_ name: String, _ kind: Completion.Kind, _ detail: String?) {
            guard seen.insert(name).inserted, let m = Fuzzy.match(prefix, name) else { return }
            // Hide fuzzy-only matches for very short queries; too noisy.
            if prefix.count < 2, m.score < 500 { return }
            out.append(Completion(kind: kind, insert: name, detail: detail, score: Double(m.score) + boost(name), positions: m.positions))
        }
        for (name, value) in env.aliases { add(name, .alias, "alias → \(value)") }
        for name in env.functions where !name.hasPrefix("_") { add(name, .function, "function") }
        for (name, desc) in ShellBuiltins.all { add(name, .builtin, desc) }
        for name in CommandIndex.shared.commands(env: env) { add(name, .command, specs.describe(name)) }
        for s in snippets {
            if let m = Fuzzy.match(prefix, s.name) {
                out.append(Completion(kind: .snippet, insert: s.command, display: s.name, detail: s.command, score: Double(m.score) - 50, positions: m.positions, appendSpace: false, replacesLine: true))
            }
        }
        return out
    }

    /// Whole command lines from history that start with what's typed.
    func historyLines(_ ctx: CompletionContext) -> [Completion] {
        guard let history else { return [] }
        let typed = String(utf16CodeUnits: Array(ctx.line.utf16.prefix(ctx.cursor)), count: min(ctx.cursor, ctx.line.utf16.count))
        guard typed.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        let matches = history.recentCommands(withPrefix: typed, limit: 4)
        return matches.enumerated().map { i, cmd in
            Completion(kind: .history, insert: cmd, display: cmd, detail: "history", score: 1200 - Double(i) * 10, positions: Array(0..<typed.count), appendSpace: false, replacesLine: true)
        }
    }

    /// File and folder names for the current word.
    func paths(_ ctx: CompletionContext, env: ShellEnvironment, foldersOnly: Bool, executablesOnly: Bool = false) -> [Completion] {
        if env.isRemote { return [] }   // these would be this Mac's files
        let typed = ctx.prefix
        var dirPart = ""
        var namePart = typed
        if let slash = typed.lastIndex(of: "/") {
            dirPart = String(typed[...slash])
            namePart = String(typed[typed.index(after: slash)...])
        }
        var dirPath = dirPart
        if dirPath.hasPrefix("~") { dirPath = env.home + dirPath.dropFirst() }
        if !dirPath.hasPrefix("/") { dirPath = (ctx.cwd as NSString).appendingPathComponent(dirPath) }
        if dirPath.isEmpty { dirPath = ctx.cwd }

        // "~" alone should become "~/"
        if typed == "~" {
            return [Completion(kind: .folder, insert: "~/", detail: "home", score: 2000, appendSpace: false)]
        }

        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dirPath) else { return [] }
        let showHidden = namePart.hasPrefix(".")
        var out: [Completion] = []
        for item in items {
            if item.hasPrefix("."), !showHidden { continue }
            let full = (dirPath as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isDir)
            if foldersOnly, !isDir.boolValue { continue }
            if executablesOnly, !isDir.boolValue, !fm.isExecutableFile(atPath: full) { continue }
            guard let m = Fuzzy.match(namePart, item) else { continue }
            let value = dirPart + item + (isDir.boolValue ? "/" : "")
            let insert = ShellLexer.escape(value, insideQuote: ctx.openQuote)
            out.append(Completion(
                kind: isDir.boolValue ? .folder : .file,
                insert: insert,
                display: item + (isDir.boolValue ? "/" : ""),
                detail: nil,
                score: Double(m.score) + (isDir.boolValue && foldersOnly ? 5 : 0),
                positions: m.positions,
                appendSpace: !isDir.boolValue))
            if out.count > 400 { break }
        }
        return out
    }

    private func finish(_ items: [Completion], query: String = "") -> [Completion] {
        var items = items
        // For 1–2 letter queries, prefix/word-start matches are what you want;
        // hide scattered mid-word matches when there are enough good ones.
        if (1...2).contains(query.count) {
            let strong = items.filter { $0.kind == .history || $0.score >= 650 }
            if strong.count >= 3 { items = strong }
        }
        var seen = Set<String>()
        var out: [Completion] = []
        for c in items.sorted(by: { $0.score > $1.score || ($0.score == $1.score && $0.display < $1.display) }) {
            let key = (c.replacesLine ? "L:" : "W:") + c.insert
            if seen.insert(key).inserted { out.append(c) }
            if out.count >= maxResults { break }
        }
        return out
    }
}
