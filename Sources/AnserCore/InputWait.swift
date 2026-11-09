import Foundation

/// Spots a running program that is waiting for you to answer: `[y/N]`,
/// password prompts, "Press any key", and AI coding agents (Claude Code,
/// Codex, Copilot…) asking for approval. Anser reads the last lines on screen
/// once the output has gone quiet.
public enum InputWait {
    public enum Kind: String, Sendable, Equatable {
        case confirm      // yes/no question
        case password     // password or passphrase
        case agent        // an AI agent waiting for approval or a choice
        case keypress     // "press any key / Enter to continue"
        case question     // ends in a question or "…:" asking for a value
    }

    public struct Wait: Sendable, Equatable {
        public var kind: Kind
        /// The line that asks (trimmed), for the notification.
        public var line: String
        public var title: String {
            switch kind {
            case .confirm: return "Waiting for a yes or no"
            case .password: return "Waiting for a password"
            case .agent: return "Agent waiting for approval"
            case .keypress: return "Waiting for a key press"
            case .question: return "Waiting for your answer"
            }
        }
    }

    /// `screen`: the visible text. Looks at the last few non-empty lines only.
    public static func detect(screen: String) -> Wait? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let tail = Array(lines.reversed().filter { !$0.isEmpty }.prefix(8))
        guard let last = tail.first else { return nil }
        let lower = last.lowercased()

        // Password prompts: the cursor sits right after them.
        if passwordRE.firstMatch(in: lower, range: NSRange(location: 0, length: (lower as NSString).length)) != nil {
            return Wait(kind: .password, line: last)
        }
        // AI agents draw a box of choices; the question is a few lines up.
        let block = tail.reversed().joined(separator: "\n").lowercased()
        let agentHints = ["do you want to proceed", "do you want to make this edit", "do you want to create", "do you want to run",
                          "allow this", "allow command", "approve", "esc to cancel", "(y)es", "yes, and don't ask again",
                          "yes, allow", "always allow", "run this command?", "apply this change?"]
        if agentHints.contains(where: block.contains), block.contains("1.") || block.contains("yes") || block.contains("❯") || block.contains("›") {
            let q = tail.first(where: { $0.hasSuffix("?") }) ?? last
            return Wait(kind: .agent, line: q)
        }
        if confirmRE.firstMatch(in: lower, range: NSRange(location: 0, length: (lower as NSString).length)) != nil {
            return Wait(kind: .confirm, line: last)
        }
        if keyRE.firstMatch(in: lower, range: NSRange(location: 0, length: (lower as NSString).length)) != nil {
            return Wait(kind: .keypress, line: last)
        }
        // A question or "Enter something:" as the very last thing on screen.
        if last.count <= 160, (last.hasSuffix("?") || last.hasSuffix("? ") || (last.hasSuffix(":") && askRE.firstMatch(in: lower, range: NSRange(location: 0, length: (lower as NSString).length)) != nil)) {
            // Not a log line ("12:01:03 Error?") or a path.
            if !last.hasPrefix("/"), !last.contains("://"), !(last.first?.isNumber ?? false) {
                return Wait(kind: .question, line: last)
            }
        }
        return nil
    }

    static let passwordRE = try! NSRegularExpression(
        pattern: #"(password|passphrase|passcode|pin|verification code|one-time code|otp)( for [^:]+)?( \([^)]*\))?\s*:\s*$|\[sudo\] password"#)
    static let confirmRE = try! NSRegularExpression(
        pattern: #"(\[y/n\]|\(y/n\)|\[yes/no\]|\(yes/no\)|\[y/n/[a-z?/]+\]|\(y/n/[a-z?/]+\)|\byes/no\b|\[y\]|\[n\]|\(y\)|\(n\))[\s:?]*(\[[^\]]*\])?[\s:?]*$|continue\?\s*$|proceed\?\s*$|are you sure.*\?\s*$|overwrite.*\?\s*$"#)
    static let keyRE = try! NSRegularExpression(
        pattern: #"press (any key|enter|return|a key)|hit (enter|return|any key)|press <?(enter|return)>? to"#)
    static let askRE = try! NSRegularExpression(
        pattern: #"^(enter|type|choose|select|pick|name|email|username|user name|login|token|value|which|what|please)\b"#)
}
