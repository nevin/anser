import Foundation

/// Optional AI help, from Claude (the Claude API over HTTPS; Swift has no
/// official Anthropic SDK), GitHub Copilot (the `copilot` command-line tool,
/// with every tool turned off so it can only answer) or a local model through
/// Ollama (nothing leaves the Mac). Nothing is sent unless the user asks:
/// "Explain this error" or "Generate a command".
public final class AIHelp: Sendable {
    public enum Provider: String, CaseIterable, Sendable {
        case claude, copilot, ollama
        public var displayName: String {
            switch self {
            case .claude: "Claude"
            case .copilot: "GitHub Copilot"
            case .ollama: "Local AI"
            }
        }
        /// Where the request goes, for the privacy note.
        public var destination: String {
            switch self {
            case .claude: "Sent to Anthropic"
            case .copilot: "Sent to GitHub Copilot"
            case .ollama: "Sent to Ollama on this Mac (nothing leaves it)"
            }
        }
    }

    /// Runs the Copilot CLI: (argv, timeout) → (exit status, output, timed out). Replaceable in tests.
    public typealias CopilotRunner = @Sendable ([String], TimeInterval) async -> (status: Int32?, output: String, timedOut: Bool)

    public enum AIError: Error, LocalizedError, Equatable {
        case noAPIKey
        case refused(String?)
        case http(Int, String)
        case badResponse
        case network(String)
        case copilotNotInstalled
        case copilotNotSignedIn
        case copilot(String)
        case ollamaNotRunning
        case ollamaNoModel
        case ollama(String)

        public var errorDescription: String? {
            switch self {
            case .noAPIKey: "Add your Anthropic API key in Settings → AI help."
            case .refused(let cat): "Claude declined this request\(cat.map { " (\($0))" } ?? "")."
            case .http(let code, let msg): "The Claude API returned an error (\(code)): \(msg)"
            case .badResponse: "Couldn't read the response from the Claude API."
            case .network(let m): "Couldn't reach the Claude API: \(m)"
            case .copilotNotInstalled: "GitHub Copilot CLI isn't installed. Install it with: brew install --cask copilot-cli"
            case .copilotNotSignedIn: "Sign in to GitHub Copilot first: Settings → AI → Sign In… (runs copilot login)."
            case .copilot(let m): "GitHub Copilot: \(m)"
            case .ollamaNotRunning: "Ollama isn't running. Install it (brew install ollama), then start it: Settings → AI → Start Ollama."
            case .ollamaNoModel: "Ollama has no models yet. Settings → AI → Get a Model… downloads one."
            case .ollama(let m): "Ollama: \(m)"
            }
        }
    }

    public struct Answer: Equatable, Sendable {
        /// Markdown text from Claude.
        public var text: String
        /// Shell commands from the answer's code blocks, ready to insert.
        public var commands: [String]
        public var model: String?
    }

    /// Sends a request and returns (status code, body). Replaceable in tests.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Int, Data)

    public static let model = "claude-opus-5-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public let provider: Provider
    private let apiKey: @Sendable () -> String?
    private let transport: Transport
    private let copilotPath: @Sendable () -> String?
    private let copilotModel: String?
    private let copilotRunner: CopilotRunner
    private let ollamaBase: URL
    private let ollamaModel: String?

    public static let defaultOllamaURL = URL(string: "http://localhost:11434")!

    /// Claude, through the Claude API with your key.
    public init(apiKey: @escaping @Sendable () -> String?, transport: Transport? = nil) {
        provider = .claude
        self.apiKey = apiKey
        self.transport = transport ?? { req in
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        copilotPath = { nil }
        copilotModel = nil
        copilotRunner = Self.runCopilot
        ollamaBase = Self.defaultOllamaURL
        ollamaModel = nil
    }

    /// A local model through Ollama's HTTP API. Requests stay on this Mac.
    public init(ollamaURL: URL? = nil, ollamaModel model: String?, transport: Transport? = nil) {
        provider = .ollama
        apiKey = { nil }
        self.transport = transport ?? Self.urlSession
        copilotPath = { nil }
        copilotModel = nil
        copilotRunner = Self.runCopilot
        ollamaBase = ollamaURL ?? Self.defaultOllamaURL
        ollamaModel = model.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    static let urlSession: Transport = { req in
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// GitHub Copilot, through the `copilot` CLI and its own sign-in.
    public init(copilotPath: @escaping @Sendable () -> String? = { AIHelp.findCopilot() }, model: String? = nil, runner: CopilotRunner? = nil) {
        provider = .copilot
        apiKey = { nil }
        transport = { _ in (0, Data()) }
        self.copilotPath = copilotPath
        copilotModel = model.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        copilotRunner = runner ?? Self.runCopilot
        ollamaBase = Self.defaultOllamaURL
        ollamaModel = nil
    }

    // MARK: Requests

    public struct Context: Sendable {
        public var shell: String
        public var os: String
        public var cwdName: String
        public var gitBranch: String?
        public init(shell: String, os: String, cwdName: String, gitBranch: String?) {
            self.shell = shell; self.os = os; self.cwdName = cwdName; self.gitBranch = gitBranch
        }
        var summary: String {
            "Shell: \(shell). OS: \(os). Current folder: \(cwdName)\(gitBranch.map { " (git branch \($0))" } ?? "")."
        }
    }

    static let system = """
    You help a developer in their terminal. Be brief and practical: lead with the cause or the answer in one or two sentences, then the fix. \
    Put every command they could run in its own ```sh code block, one command per block, ready to paste. \
    Never suggest destructive commands (rm -rf, force pushes, dropping data) without saying clearly what they destroy. \
    If you aren't sure, say what to check rather than guessing.
    """

    /// Why did this command fail, and how to fix it.
    public func explainFailure(command: String, exitCode: Int, output: String, context: Context) async throws -> Answer {
        let out = Self.redact(Self.tail(output, lines: 200))
        let prompt = """
        This command failed with exit code \(exitCode).

        Command:
        ```sh
        \(Self.redact(command))
        ```

        Output (last lines):
        ```
        \(out.isEmpty ? "(no output)" : out)
        ```

        \(context.summary)
        Explain what went wrong and how to fix it.
        """
        return try await send(prompt, effort: "medium")
    }

    /// Turn a plain-English description into shell commands.
    public func generateCommand(_ request: String, context: Context) async throws -> Answer {
        let prompt = """
        Write the shell command(s) for this: \(request)

        \(context.summary)
        Reply with the command(s) in ```sh blocks and one short line on what each does. Prefer a single command when one will do.
        """
        return try await send(prompt, effort: "low")
    }

    /// The JSON body for a request (exposed for tests).
    public static func body(prompt: String, effort: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            // Thinking is adaptive by default on this model; effort sets its depth.
            "output_config": ["effort": effort],
            // If a safety classifier declines, retry on Anthropic's recommended model.
            "fallbacks": "default",
            "messages": [["role": "user", "content": prompt]],
        ]
    }

    private func send(_ prompt: String, effort: String) async throws -> Answer {
        if provider == .copilot { return try await sendCopilot(prompt, effort: effort) }
        if provider == .ollama { return try await sendOllama(prompt) }
        guard let key = apiKey(), !key.isEmpty else { throw AIError.noAPIKey }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.body(prompt: prompt, effort: effort))
        let (status, data): (Int, Data)
        do { (status, data) = try await transport(req) } catch { throw AIError.network(error.localizedDescription) }
        return try Self.parse(status: status, data: data)
    }

    /// Reads a Messages API response. Checks for a refusal before reading content.
    public static func parse(status: Int, data: Data) throws -> Answer {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.badResponse }
        guard (200..<300).contains(status) else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            throw AIError.http(status, msg)
        }
        if json["stop_reason"] as? String == "refusal" {
            throw AIError.refused((json["stop_details"] as? [String: Any])?["category"] as? String)
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { throw AIError.badResponse }
        return Answer(text: text, commands: codeBlocks(text), model: json["model"] as? String)
    }

    // MARK: Ollama (local)

    /// Installed Ollama models, or nil when Ollama isn't reachable.
    public static func ollamaModels(base: URL = defaultOllamaURL, transport: Transport? = nil) async -> [String]? {
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 3
        guard let (status, data) = try? await (transport ?? urlSession)(req), (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// The JSON body for an Ollama chat request (exposed for tests).
    public static func ollamaBody(prompt: String, model: String) -> [String: Any] {
        ["model": model, "stream": false, "options": ["temperature": 0.2],
         "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]]]
    }

    private func sendOllama(_ prompt: String) async throws -> Answer {
        var model = ollamaModel
        if model == nil {
            guard let installed = await Self.ollamaModels(base: ollamaBase, transport: transport) else { throw AIError.ollamaNotRunning }
            guard let first = installed.first else { throw AIError.ollamaNoModel }
            model = first
        }
        var req = URLRequest(url: ollamaBase.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.ollamaBody(prompt: prompt, model: model!))
        let (status, data): (Int, Data)
        do { (status, data) = try await transport(req) } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain, [NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost].contains(ns.code) {
                throw AIError.ollamaNotRunning
            }
            throw AIError.ollama(error.localizedDescription)
        }
        return try Self.parseOllama(status: status, data: data)
    }

    /// Reads an Ollama /api/chat reply.
    public static func parseOllama(status: Int, data: Data) throws -> Answer {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.badResponse }
        if let err = json["error"] as? String {
            if err.lowercased().contains("not found") { throw AIError.ollama("\(err). Pick an installed model in Settings → AI.") }
            throw AIError.ollama(err)
        }
        guard (200..<300).contains(status) else { throw AIError.ollama("HTTP \(status)") }
        var text = ((json["message"] as? [String: Any])?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Reasoning models put their thinking in <think>…</think>; keep only the answer.
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !text.isEmpty else { throw AIError.badResponse }
        return Answer(text: text, commands: codeBlocks(text), model: (json["model"] as? String).map { "Local · \($0)" } ?? "Local AI")
    }

    // MARK: GitHub Copilot

    /// The arguments for one answer-only Copilot run (exposed for tests).
    /// No tools (no shell, no file edits, no MCP servers): it can only reply.
    public static func copilotArguments(path: String, prompt: String, effort: String, model: String?) -> [String] {
        // (No --reasoning-effort: Copilot rejects it when it picks the model itself.)
        var a = [path, "-s", "-p", system + "\n\n" + prompt,
                 "--disable-builtin-mcps", "--disable-client-telemetry", "--stream", "off",
                 // JSON events keep the answer's Markdown (the text mode reformats code blocks).
                 "--output-format", "json"]
        if let model { a += ["--model", model] }
        // Last, because it takes a list: an empty list means no tools at all.
        a.append("--available-tools")
        return a
    }

    private func sendCopilot(_ prompt: String, effort: String) async throws -> Answer {
        guard let path = copilotPath() else { throw AIError.copilotNotInstalled }
        let args = Self.copilotArguments(path: path, prompt: prompt, effort: effort, model: copilotModel)
        let r = await copilotRunner(args, 120)
        return try Self.parseCopilot(status: r.status, output: r.output, timedOut: r.timedOut)
    }

    /// Reads a Copilot CLI run (JSON events, one per line): the assistant's
    /// messages are the answer; anything else on a failed run is the error.
    public static func parseCopilot(status: Int32?, output: String, timedOut: Bool) throws -> Answer {
        if timedOut { throw AIError.copilot("no answer within 2 minutes.") }
        var messages: [String] = [], model: String?, other: [String] = []
        for line in output.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { other.append(t) }
                continue
            }
            let data = obj["data"] as? [String: Any]
            switch obj["type"] as? String {
            case "assistant.message":
                if let c = data?["content"] as? String, !c.isEmpty { messages.append(c) }
                if let m = data?["model"] as? String { model = m }
            case let t? where t.hasSuffix("error"):
                if let m = data?["message"] as? String { other.append(m) }
            default: break
            }
        }
        let text = messages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if status != 0 || text.isEmpty {
            let detail = other.joined(separator: " ")
            let l = detail.lowercased()
            if l.contains("login") || l.contains("log in") || l.contains("sign in") || l.contains("not authenticated") || l.contains("authenticate") {
                throw AIError.copilotNotSignedIn
            }
            if status == 0 { throw AIError.badResponse }
            throw AIError.copilot(detail.isEmpty ? "it stopped with exit code \(status.map(String.init) ?? "?")." : String(detail.suffix(300)))
        }
        return Answer(text: text, commands: codeBlocks(text), model: model.map { "GitHub Copilot · \($0)" } ?? "GitHub Copilot")
    }

    /// Where the `copilot` command is, if installed.
    public static func findCopilot(path: [String] = ShellEnvironment.defaultPath) -> String? {
        let extra = [NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.npm-global/bin"]
        for dir in path + extra {
            let f = dir + "/copilot"
            if FileManager.default.isExecutableFile(atPath: f) { return f }
        }
        return nil
    }

    /// Runs Copilot from an empty folder, so no project's instructions or files are read.
    static let runCopilot: CopilotRunner = { argv, timeout in
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anser-copilot")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var env = ProcessInfo.processInfo.environment
                env["NO_COLOR"] = "1"
                let r = ProcessRunner.run(argv, cwd: dir.path, environment: env, timeout: timeout)
                cont.resume(returning: (r?.exitStatus, String(decoding: r?.output ?? Data(), as: UTF8.self), r?.timedOut ?? false))
            }
        }
    }

    // MARK: Helpers

    /// Contents of ```sh / ```bash / ``` blocks, one command each.
    public static func codeBlocks(_ markdown: String) -> [String] {
        let shellLangs: Set<String> = ["", "sh", "bash", "zsh", "shell", "console", "fish"]
        var out: [String] = []
        var inBlock = false, isShell = false
        var current: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inBlock {
                    let cmd = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if isShell, !cmd.isEmpty { out.append(cmd) }
                    inBlock = false
                } else {
                    inBlock = true
                    isShell = shellLangs.contains(t.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased())
                    current = []
                }
            } else if inBlock {
                current.append(line.hasPrefix("$ ") ? String(line.dropFirst(2)) : line)
            }
        }
        return out
    }

    static func tail(_ s: String, lines: Int) -> String {
        let all = s.components(separatedBy: "\n")
        return all.suffix(lines).joined(separator: "\n")
    }

    /// Blanks out things that look like secrets before anything leaves the Mac.
    public static func redact(_ s: String) -> String {
        let patterns = [
            #"sk-ant-[A-Za-z0-9_\-]{10,}"#, #"sk-[A-Za-z0-9]{20,}"#, #"gh[pousr]_[A-Za-z0-9]{20,}"#, #"github_pat_[A-Za-z0-9_]{20,}"#,
            #"AKIA[0-9A-Z]{16}"#, #"xox[baprs]-[A-Za-z0-9\-]{10,}"#, #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#,
            #"(?i)(password|passwd|secret|token|api[_-]?key)\s*[=:]\s*\S+"#, #"(?i)authorization:\s*bearer\s+\S+"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        ]
        var out = s
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "[redacted]")
        }
        return out
    }
}

// MARK: Step-by-step tasks

/// One step of an AI task: what ran and how it went.
public struct AgentStep: Sendable, Equatable {
    public var command: String
    public var exitCode: Int?
    public var output: String
    /// You skipped it instead of running it.
    public var skipped: Bool
    /// What you said instead (answer to a question, or a note).
    public var note: String?
    public init(command: String, exitCode: Int? = nil, output: String = "", skipped: Bool = false, note: String? = nil) {
        self.command = command; self.exitCode = exitCode; self.output = output; self.skipped = skipped; self.note = note
    }
}

/// What the AI wants to do next.
public enum AgentReply: Sendable, Equatable {
    /// Run this command (with a one-line reason).
    case run(command: String, why: String)
    case done(summary: String)
    /// It needs something from you first.
    case ask(question: String)

    public static func parse(_ text: String) -> AgentReply {
        let blocks = AIHelp.codeBlocks(text)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func after(_ prefix: String) -> String? {
            guard let i = lines.firstIndex(where: { $0.uppercased().hasPrefix(prefix) }) else { return nil }
            let rest = ([String(lines[i].dropFirst(prefix.count))] + lines[(i + 1)...]).joined(separator: "\n")
            return rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let cmd = blocks.first {
            // The explanation is the prose outside the code block.
            var why: [String] = []
            var inBlock = false
            for l in lines {
                if l.hasPrefix("```") { inBlock.toggle(); continue }
                if !inBlock, !l.isEmpty, !l.uppercased().hasPrefix("NEXT:") { why.append(l) }
            }
            return .run(command: cmd, why: why.joined(separator: " "))
        }
        if let q = after("QUESTION:") { return .ask(question: q) }
        if let d = after("DONE:") { return .done(summary: d) }
        return .done(summary: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension AIHelp {
    /// The next step toward `goal`, given the steps so far. Stateless: the whole task goes with every request.
    public func nextStep(goal: String, steps: [AgentStep], context: Context, maxSteps: Int = 20) async throws -> AgentReply {
        try await send(Self.agentPrompt(goal: goal, steps: steps, context: context, maxSteps: maxSteps), effort: "medium").reply
    }

    public static func agentPrompt(goal: String, steps: [AgentStep], context: Context, maxSteps: Int = 20) -> String {
        var p = """
        You are doing a task in the user's terminal, one command at a time. They see each command and approve it before it runs.

        Task: \(redact(goal))

        \(context.summary)

        """
        if steps.isEmpty {
            p += "Nothing has run yet.\n"
        } else {
            p += "Steps so far:\n"
            for (i, s) in steps.enumerated() {
                p += "\n\(i + 1). "
                if s.command.isEmpty {
                    p += "(the user said) \(redact(s.note ?? ""))\n"
                    continue
                }
                p += "```sh\n\(redact(s.command))\n```\n"
                if s.skipped { p += "The user skipped this command\(s.note.map { ": \(redact($0))" } ?? "").\n"; continue }
                p += "Exit code: \(s.exitCode.map(String.init) ?? "unknown")\n"
                let out = redact(tail(s.output, lines: 60)).trimmingCharacters(in: .whitespacesAndNewlines)
                p += out.isEmpty ? "(no output)\n" : "Output (last lines):\n```\n\(out)\n```\n"
            }
        }
        p += """

        Reply in exactly one of these forms:
        1. One short sentence on what the next step does and why, then exactly one ```sh block with exactly one command (it may use && or pipes). No other code blocks.
        2. A line starting with DONE: and two or three sentences on what was done and anything the user should check.
        3. A line starting with QUESTION: when you need something only the user knows.

        Prefer read-only commands to look around before changing anything. Never use interactive programs (editors, pagers, prompts); \
        add flags like --yes or --no-pager where needed. Avoid destructive commands unless the task requires them, and say plainly what they destroy. \
        If a step failed, fix the cause rather than repeating it. Stop with DONE: after at most \(maxSteps) steps.
        """
        return p
    }
}

extension AIHelp.Answer {
    var reply: AgentReply { AgentReply.parse(text) }
}
