import Foundation
import CryptoKit

/// A Markdown document with runnable steps: deploys, onboarding, incident
/// checklists. Every shell code block is a step you can run with one click,
/// and Anser marks each one done (or failed) as you go.
///
/// Personal runbooks live in ~/.config/anser/runbooks; a repo's runbooks in
/// `.anser/runbooks` are shared with the team and run only after you trust them.
public struct Runbook: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        /// The nearest heading above the code block.
        public var title: String
        /// Text between the previous step and this one.
        public var text: String
        /// What runs, as written (placeholders like {{tag}} still in it).
        public var command: String
    }

    public var title: String
    /// Text before the first step.
    public var intro: String
    public var steps: [Step]
    /// Text after the last step (with its heading).
    public var outro: String = ""
    public var file: URL?
    public var source: Workflow.Source = .personal

    /// Code block languages that are shell steps (an unlabeled block counts too).
    static let shellLanguages: Set<String> = ["", "sh", "bash", "zsh", "shell", "console", "fish", "shell-session", "terminal"]

    public static func parse(_ markdown: String, fallbackTitle: String) -> Runbook {
        var title: String?
        var intro: [String] = []
        var steps: [Step] = []
        var text: [String] = []
        var heading = ""
        var inFence: (marker: String, lang: String, lines: [String])?
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var f = inFence {
                if line.hasPrefix(f.marker), line.trimmingCharacters(in: CharacterSet(charactersIn: f.marker.prefix(1) + " ")).isEmpty {
                    inFence = nil
                    if shellLanguages.contains(f.lang), let cmd = command(from: f.lines, lang: f.lang) {
                        let t = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        steps.append(Step(title: heading.isEmpty ? "Step \(steps.count + 1)" : heading, text: t, command: cmd))
                        text = []
                    } else {
                        // Other code (JSON, YAML…) is part of the text.
                        text.append("```" + f.lang); text += f.lines; text.append("```")
                    }
                } else {
                    f.lines.append(raw)
                    inFence = f
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix { $0 == "`" || $0 == "~" })
                let lang = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { String($0).lowercased() } ?? ""
                inFence = (marker, lang, [])
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let h = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level == 1, title == nil, steps.isEmpty { title = h; continue }
                if steps.isEmpty, heading.isEmpty { intro = text; text = [] }
                heading = h
                continue
            }
            text.append(raw)
        }
        var outro = ""
        if steps.isEmpty { intro += text } else {
            let rest = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { outro = (heading != steps.last?.title ? "## \(heading)\n\n" : "") + rest }
        }
        let introText = intro.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var r = Runbook(title: title ?? fallbackTitle, intro: introText, steps: steps)
        r.outro = outro
        return r
    }

    /// The command in a code block. `console` blocks keep only "$ " lines (the rest is sample output).
    static func command(from lines: [String], lang: String) -> String? {
        var ls = lines
        let prompted = ls.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("$ ") }
        if lang == "console" || lang == "shell-session" || lang == "terminal" || (!prompted.isEmpty && prompted.count == ls.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count) {
            ls = prompted.map { String($0.trimmingCharacters(in: .whitespaces).dropFirst(2)) }
        }
        let kept = ls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !kept.isEmpty else { return nil }
        // Continued lines and heredocs run as written; separate commands stop at the first failure.
        if ls.contains(where: { $0.hasSuffix("\\") || $0.contains("<<") }) {
            return ls.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return kept.joined(separator: " && ")
    }

    /// Placeholders used by any step, as a workflow would ask for them.
    public var params: [Workflow.Param] { Workflow(name: title, steps: steps.map(\.command)).allParams }

    /// A step's command with values filled in.
    public func render(step i: Int, values: [String: String]) -> String {
        guard steps.indices.contains(i) else { return "" }
        return Workflow(name: title, steps: [steps[i].command], params: params).render(values)
    }

    // MARK: Files

    public static var personalDirectory: URL { AnserConfig.directory.appendingPathComponent("runbooks") }

    /// The `.anser/runbooks` folder of the git repo containing `cwd`.
    public static func projectDirectory(for cwd: String) -> URL? {
        WorkflowStore.projectDirectory(for: cwd).map { $0.deletingLastPathComponent().appendingPathComponent("runbooks") }
    }

    /// This project's runbooks first, then yours.
    public static func load(cwd: String) -> [Runbook] {
        var out: [Runbook] = []
        if let p = projectDirectory(for: cwd) { out += load(directory: p, source: .project) }
        out += load(directory: personalDirectory, source: .personal)
        return out
    }

    static func load(directory: URL, source: Workflow.Source) -> [Runbook] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            var r = parse(text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
            r.file = url
            r.source = source
            return r
        }.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    /// Writes a starter runbook and returns its file.
    public static func create(in directory: URL, title: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let slug = Workflow(name: title, steps: []).slug
        var url = directory.appendingPathComponent(slug.isEmpty ? "runbook" : slug).appendingPathExtension("md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(slug)-\(n)").appendingPathExtension("md"); n += 1
        }
        try template(title: title).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    public static func template(title: String) -> String {
        """
        # \(title)

        What this runbook is for, and when to use it. Every shell code block
        below is a step: Anser shows a Run button next to it and ticks it off
        when it succeeds. `{{name}}` asks for a value the first time it's used.

        ## Check where you are

        ```sh
        git status --short --branch
        ```

        ## Build

        ```sh
        echo "Building {{version:dev}}"
        ```

        ## Finish

        Notes for the last step. Code blocks in other languages (JSON, YAML)
        are shown, not run.
        """
    }
}

/// Trust for files that come with a repo you cloned (workflows, runbooks,
/// plugins): tied to the exact contents, so any change asks again.
public struct FileTrust {
    let defaults: UserDefaults
    let key: String

    /// Self-tests keep trust here instead of in the app's real settings.
    nonisolated(unsafe) public static var testDefaults: UserDefaults?

    public init(_ key: String, defaults: UserDefaults? = nil) { self.key = key; self.defaults = defaults ?? FileTrust.testDefaults ?? .standard }

    public static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A fingerprint of every file in a folder (names and contents; files over 1 MB by size only).
    public static func fingerprint(folder: URL) -> String? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
        var parts: [(String, Data)] = []
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            if rel.hasSuffix(".log") || rel.hasPrefix("/.") && rel.contains("/.DS_Store") { continue }
            if (v?.fileSize ?? 0) > 1 << 20 { parts.append((rel, Data("size:\(v?.fileSize ?? 0)".utf8))) }
            else { parts.append((rel, (try? Data(contentsOf: url)) ?? Data())) }
        }
        var all = Data()
        for (rel, data) in parts.sorted(by: { $0.0 < $1.0 }) { all += Data(rel.utf8) + Data([0]) + Data(fingerprint(data).utf8) }
        return fingerprint(all)
    }

    public func isTrusted(path: String, fingerprint fp: String?) -> Bool {
        guard let fp else { return false }
        return (defaults.dictionary(forKey: key) as? [String: String])?[path] == fp
    }

    public func trust(path: String, fingerprint fp: String?) {
        guard let fp else { return }
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[path] = fp
        defaults.set(all, forKey: key)
    }

    public func forget(path: String) {
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[path] = nil
        defaults.set(all, forKey: key)
    }

    // Runbooks

    public static var runbooks: FileTrust { FileTrust("trustedProjectRunbooks") }

    public func isTrusted(_ r: Runbook) -> Bool {
        guard r.source == .project else { return true }
        guard let f = r.file, let d = try? Data(contentsOf: f) else { return false }
        return isTrusted(path: f.standardizedFileURL.path, fingerprint: Self.fingerprint(d))
    }

    public func trust(_ r: Runbook) {
        guard let f = r.file, let d = try? Data(contentsOf: f) else { return }
        trust(path: f.standardizedFileURL.path, fingerprint: Self.fingerprint(d))
    }
}
