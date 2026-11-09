import Foundation

/// Messages the shell integration scripts send to the app through a FIFO.
/// Wire format: one line per event, fields separated by TAB, with `\\`, `\t`
/// and `\n` escaped as `\\\\`, `\\t` and `\\n`.
public enum ShellEvent: Equatable, Sendable {
    /// Shell started. Carries the shell name and its PATH.
    case hello(shell: String, pid: Int32, path: String)
    /// A prompt is about to be shown (precmd). Carries last exit status and cwd.
    case prompt(exitCode: Int, cwd: String)
    /// A command is about to run (preexec).
    case preexec(command: String, cwd: String)
    /// Aliases changed: the file holding `alias` output, and function names.
    case aliases(file: String)
    case functions(names: [String])
    /// The shell's own line editor has text in it (user typed in raw mode).
    case buffer(String)
    /// Cloud context variables: AWS_PROFILE, KUBECONFIG, DOCKER_CONTEXT, CLOUDSDK_CORE_PROJECT.
    case context(CloudContext.Vars)
    /// Features this shell's hooks support ("load": ESC [9990~ loads a file Anser wrote).
    case capabilities([String])

    public static func parse(_ line: String) -> ShellEvent? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { unescape(String($0)) }
        guard let kind = fields.first else { return nil }
        func f(_ i: Int) -> String { i < fields.count ? fields[i] : "" }
        switch kind {
        case "hello": return .hello(shell: f(1), pid: Int32(f(2)) ?? 0, path: f(3))
        case "prompt": return .prompt(exitCode: Int(f(1)) ?? 0, cwd: f(2))
        case "preexec": return .preexec(command: f(1), cwd: f(2))
        case "aliases": return .aliases(file: f(1))
        case "functions": return .functions(names: f(1).split(separator: " ").map(String.init))
        case "buffer": return .buffer(f(1))
        case "ctx":
            func v(_ i: Int) -> String? { f(i).isEmpty ? nil : f(i) }
            return .context(CloudContext.Vars(awsProfile: v(1), kubeconfig: v(2), dockerContext: v(3), gcloudProject: v(4), virtualEnv: v(5)))
        case "caps": return .capabilities(fields.dropFirst().filter { !$0.isEmpty })
        default: return nil
        }
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\\", let n = it.next() {
                switch n {
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "\\": out.append("\\")
                default: out.append("\\"); out.append(n)
                }
            } else {
                out.append(c)
            }
        }
        return out
    }
}

/// Splits a byte stream into complete lines, keeping any partial tail.
public struct LineBuffer: Sendable {
    private var pending = Data()
    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<nl]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }
}
