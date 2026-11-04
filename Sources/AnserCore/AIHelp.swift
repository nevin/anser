import Foundation

/// Optional AI help through the Claude API (Messages API over HTTPS; Swift has
/// no official Anthropic SDK). Nothing is sent unless the user asks:
/// "Explain this error" or "Generate a command".
public final class AIHelp: @unchecked Sendable {
    public enum AIError: Error, LocalizedError, Equatable {
        case noAPIKey
        case refused(String?)
        case http(Int, String)
        case badResponse
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .noAPIKey: "Add your Anthropic API key in Settings → AI help."
            case .refused(let cat): "Claude declined this request\(cat.map { " (\($0))" } ?? "")."
            case .http(let code, let msg): "The Claude API returned an error (\(code)): \(msg)"
            case .badResponse: "Couldn't read the response from the Claude API."
            case .network(let m): "Couldn't reach the Claude API: \(m)"
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

    private let apiKey: @Sendable () -> String?
    private let transport: Transport

    public init(apiKey: @escaping @Sendable () -> String?, transport: Transport? = nil) {
        self.apiKey = apiKey
        self.transport = transport ?? { req in
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
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
