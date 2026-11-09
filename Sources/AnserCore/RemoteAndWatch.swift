import Foundation

/// A command Anser runs in the background every few minutes, telling you
/// when its output changes or it starts failing.
public struct OutputWatch: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var command: String
    public var cwd: String
    public var intervalMinutes: Double
    public var lastOutput: String?
    public var previousOutput: String?
    public var lastExit: Int32?
    public var lastRun: Date?
    public var lastChange: Date?
    public var runs = 0
    public var changes = 0

    public init(command: String, cwd: String, intervalMinutes: Double) {
        self.command = command; self.cwd = cwd; self.intervalMinutes = max(0.5, intervalMinutes)
    }

    public enum Event: Sendable, Equatable { case first, same, changed, failed, recovered }

    /// Records a run and says what happened. Lines that only differ in times and dates don't count as a change.
    public mutating func record(output: String, exit: Int32?, at date: Date = Date()) -> Event {
        runs += 1
        lastRun = date
        let wasFailing = (lastExit ?? 0) != 0
        let failing = (exit ?? 1) != 0
        defer { lastExit = exit }
        guard let before = lastOutput else { lastOutput = output; return failing ? .failed : .first }
        if failing && !wasFailing { previousOutput = before; lastOutput = output; lastChange = date; changes += 1; return .failed }
        if !failing && wasFailing { previousOutput = before; lastOutput = output; lastChange = date; changes += 1; return .recovered }
        if Self.normalized(before) == Self.normalized(output) { lastOutput = output; return .same }
        previousOutput = before
        lastOutput = output
        lastChange = date
        changes += 1
        return .changed
    }

    static let noise = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?Z?|\b\d{1,2}:\d{2}:\d{2}\b|\b\d+(\.\d+)?\s?(ms|s|m|h|d)\b|\b(\d+)(s|m|h|d) ago\b"#)

    /// Output with timestamps and ages blanked ("5s", "3m", "12:04:01"), so a ticking clock isn't a change.
    public static func normalized(_ s: String) -> String {
        noise.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "#")
    }
}

/// Running one command on several ssh hosts at once.
public enum MultiHost {
    public struct Result: Sendable, Equatable {
        public var host: String
        public var exit: Int32?
        public var output: String
        public var seconds: Double
        public var ok: Bool { exit == 0 }
        /// The first meaningful line, for the summary column.
        public var firstLine: String {
            output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        }
        public init(host: String, exit: Int32?, output: String, seconds: Double) {
            self.host = host; self.exit = exit; self.output = output; self.seconds = seconds
        }
    }

    /// The ssh command for one host: no password prompts, a short connect timeout.
    public static func argv(host: String, command: String, ssh: String = "/usr/bin/ssh") -> [String]? {
        guard !host.isEmpty, !host.hasPrefix("-"), !host.contains(where: \.isWhitespace) else { return nil }
        return [ssh, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=10", "-T", "--", host, command]
    }

    /// "4 ok · 1 failed · 1 unreachable"
    public static func summary(_ results: [Result]) -> String {
        let ok = results.filter(\.ok).count
        let unreachable = results.filter { $0.exit == 255 }.count
        let failed = results.count - ok - unreachable
        var p = ["\(ok) ok"]
        if failed > 0 { p.append("\(failed) failed") }
        if unreachable > 0 { p.append("\(unreachable) unreachable") }
        return p.joined(separator: " · ")
    }
}

/// Grey inline completions from a local model (Ollama). Nothing leaves the Mac.
public enum AICompletion {
    public static func prompt(typed: String, shell: String, cwdName: String, recent: [String]) -> String {
        """
        Complete the \(shell) command the user is typing in a terminal (folder: \(cwdName)).
        Recent commands:
        \(recent.suffix(8).map { "  " + AIHelp.redact($0) }.joined(separator: "\n"))

        Typed so far: \(typed)
        Reply with the complete command on one line, starting exactly with what was typed. No explanation, no code fences.
        """
    }

    /// The part to add after what was typed, or nil when the reply doesn't continue it.
    public static func suffix(fromReply reply: String, typed: String) -> String? {
        var line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("```") { line = line.split(separator: "\n").dropFirst().first.map(String.init) ?? "" }
        line = line.split(separator: "\n").first.map(String.init) ?? ""
        if line.hasPrefix("$ ") { line.removeFirst(2) }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        guard line.hasPrefix(typed), line.count > typed.count, line.count < typed.count + 200 else { return nil }
        return String(line.dropFirst(typed.count))
    }

    /// The request body for Ollama's /api/generate.
    public static func body(prompt: String, model: String) -> [String: Any] {
        ["model": model, "prompt": prompt, "stream": false, "options": ["temperature": 0.1, "num_predict": 60, "stop": ["\n"]]]
    }

    /// Asks Ollama for a completion (gives up after `timeout`).
    public static func complete(typed: String, shell: String, cwdName: String, recent: [String], model: String,
                                base: URL = AIHelp.defaultOllamaURL, timeout: TimeInterval = 4,
                                transport: AIHelp.Transport? = nil) async -> String? {
        var req = URLRequest(url: base.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body(prompt: prompt(typed: typed, shell: shell, cwdName: cwdName, recent: recent), model: model))
        let send = transport ?? { r in
            let (d, resp) = try await URLSession.shared.data(for: r)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, d)
        }
        guard let (status, data) = try? await send(req), (200..<300).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = obj["response"] as? String else { return nil }
        return suffix(fromReply: text, typed: typed)
    }
}
