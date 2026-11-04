import Foundation

/// A saved multi-step command with parameters. Stored as JSON:
///
/// {
///   "name": "Deploy branch to staging",
///   "description": "Build, push the image, roll out",
///   "steps": ["docker build -t app:{{tag}} .", "docker push app:{{tag}}", "kubectl -n {{namespace:staging}} rollout restart deploy/app"],
///   "params": [{ "name": "namespace", "options": ["staging", "qa"] }]
/// }
///
/// `{{name}}` asks for a value when run; `{{name:default}}` pre-fills it.
public struct Workflow: Codable, Sendable, Equatable {
    public struct Param: Codable, Sendable, Equatable {
        public var name: String
        public var description: String?
        public var `default`: String?
        public var options: [String]?
        public init(name: String, description: String? = nil, default: String? = nil, options: [String]? = nil) {
            self.name = name; self.description = description; self.default = `default`; self.options = options
        }
    }

    public var name: String
    public var description: String?
    public var steps: [String]
    public var params: [Param]?
    /// Stop at the first failing step (joins with &&). false runs every step (;).
    public var stopOnError: Bool?

    /// Where it was loaded from (not saved).
    public var source: Source = .personal
    public var file: URL?

    public enum Source: String, Codable, Sendable { case personal, project }

    enum CodingKeys: String, CodingKey { case name, description, steps, params, stopOnError }

    public init(name: String, description: String? = nil, steps: [String], params: [Param]? = nil, stopOnError: Bool? = nil) {
        self.name = name; self.description = description; self.steps = steps; self.params = params; self.stopOnError = stopOnError
    }

    static let placeholder = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_\-]+)\s*(?::([^}]*))?\}\}"#)

    /// Every parameter, in order of first use, merged with explicit `params`.
    public var allParams: [Param] {
        var out: [Param] = []
        var seen = Set<String>()
        let explicit = Dictionary((params ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for step in steps {
            let ns = step as NSString
            for m in Self.placeholder.matches(in: step, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                guard seen.insert(name).inserted else { continue }
                var p = explicit[name] ?? Param(name: name)
                if p.default == nil, m.range(at: 2).location != NSNotFound { p.default = ns.substring(with: m.range(at: 2)) }
                out.append(p)
            }
        }
        for p in params ?? [] where seen.insert(p.name).inserted { out.append(p) }
        return out
    }

    /// The command to run, with values filled in (shell-quoted when needed).
    public func render(_ values: [String: String]) -> String {
        let filled = steps.map { step -> String in
            let ns = step as NSString
            var result = step
            for m in Self.placeholder.matches(in: step, range: NSRange(location: 0, length: ns.length)).reversed() {
                let name = ns.substring(with: m.range(at: 1))
                let def = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
                let v = values[name] ?? allParams.first { $0.name == name }?.default ?? def
                result = (result as NSString).replacingCharacters(in: m.range, with: Self.quoteIfNeeded(v))
            }
            return result
        }
        return filled.joined(separator: (stopOnError ?? true) ? " && " : "; ")
    }

    static func quoteIfNeeded(_ v: String) -> String {
        if v.isEmpty { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,~"))
        return v.unicodeScalars.allSatisfy(safe.contains) ? v : ShellLexer.escape(v)
    }

    /// File-name friendly version of the name.
    public var slug: String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).split(separator: "-").joined(separator: "-")
    }
}

public enum WorkflowStore {
    public static var personalDirectory: URL { AnserConfig.directory.appendingPathComponent("workflows") }

    /// The `.anser/workflows` folder of the git repo containing `cwd`, if any.
    public static func projectDirectory(for cwd: String) -> URL? {
        var d = cwd
        while !d.isEmpty, d != "/" {
            if FileManager.default.fileExists(atPath: (d as NSString).appendingPathComponent(".git")) {
                return URL(fileURLWithPath: d).appendingPathComponent(".anser/workflows")
            }
            d = (d as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Project workflows first (shared with the team), then personal ones.
    public static func load(cwd: String) -> [Workflow] {
        var out: [Workflow] = []
        if let proj = projectDirectory(for: cwd) { out += load(directory: proj, source: .project) }
        out += load(directory: personalDirectory, source: .personal)
        return out
    }

    static func load(directory: URL, source: Workflow.Source) -> [Workflow] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url -> Workflow? in
            guard let data = try? Data(contentsOf: url), var w = try? JSONDecoder().decode(Workflow.self, from: data) else { return nil }
            w.source = source
            w.file = url
            return w
        }.sorted { ($0.name.lowercased(), $0.file?.lastPathComponent ?? "") < ($1.name.lowercased(), $1.file?.lastPathComponent ?? "") }
    }

    /// Saves a workflow as `<slug>.json`, never overwriting another file.
    @discardableResult
    public static func save(_ w: Workflow, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent(w.slug.isEmpty ? "workflow" : w.slug).appendingPathExtension("json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(w.slug)-\(n)").appendingPathExtension("json")
            n += 1
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(w).write(to: url)
        return url
    }
}

/// Turns a tab's commands (and their output) into a Markdown document.
public enum MarkdownExport {
    public struct Entry: Sendable {
        public var command: String
        public var cwd: String
        public var exitCode: Int?
        public var duration: Double?
        public var started: Date
        public var output: String?
        public init(command: String, cwd: String, exitCode: Int?, duration: Double?, started: Date, output: String?) {
            self.command = command; self.cwd = cwd; self.exitCode = exitCode; self.duration = duration; self.started = started; self.output = output
        }
    }

    public static func render(title: String, entries: [Entry], home: String = NSHomeDirectory(), maxOutputLines: Int = 400) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var md = ["# \(title)", ""]
        if let first = entries.first { md.append("_\(entries.count) command\(entries.count == 1 ? "" : "s") · \(df.string(from: first.started))_"); md.append("") }
        for e in entries {
            let ok = (e.exitCode ?? 0) == 0
            var dir = e.cwd
            if dir.hasPrefix(home) { dir = "~" + dir.dropFirst(home.count) }
            let dur = e.duration.map { $0 < 1 ? String(format: "%.0f ms", $0 * 1000) : String(format: "%.1f s", $0) } ?? ""
            md.append("## \(ok ? "✓" : "✗") `\(e.command.replacingOccurrences(of: "`", with: "'"))`")
            md.append("")
            md.append("\(dir)\(dur.isEmpty ? "" : " · " + dur)\(ok ? "" : " · exit \(e.exitCode ?? 0)")")
            md.append("")
            if let out = e.output?.trimmingCharacters(in: .newlines), !out.isEmpty {
                var lines = out.components(separatedBy: "\n")
                var note = ""
                if lines.count > maxOutputLines {
                    note = "\n… \(lines.count - maxOutputLines) more lines"
                    lines = Array(lines.prefix(maxOutputLines))
                }
                let fence = lines.contains { $0.hasPrefix("```") } ? "~~~" : "```"
                md.append(fence)
                md.append(lines.joined(separator: "\n") + note)
                md.append(fence)
            } else if e.output == nil {
                md.append("_(output no longer in the scrollback)_")
            } else {
                md.append("_(no output)_")
            }
            md.append("")
        }
        return md.joined(separator: "\n")
    }
}
