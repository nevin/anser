import Foundation

/// When an ssh connection drops (sleep, Wi-Fi change, server restart), Anser
/// offers to reconnect, or does it by itself with growing waits.
public enum SSHReconnect {
    public static let maxAttempts = 6

    /// ssh exits with 255 when the connection failed or dropped. Only sessions
    /// that were up for a while count, so a typo'd host isn't retried forever.
    public static func shouldOffer(command: String, exitCode: Int?, duration: Double?) -> Bool {
        guard exitCode == 255, (duration ?? 0) >= 8 else { return false }
        return isInteractiveSSH(command)
    }

    /// `ssh host` or `ssh -p 22 user@host` with no remote command; also mosh and `et`.
    public static func isInteractiveSSH(_ command: String) -> Bool {
        let tokens = ShellLexer.tokenize(command).filter { $0.kind != .comment }
        let words = tokens.filter { $0.kind == .word }.map(\.value)
        guard let first = words.first.map({ ($0 as NSString).lastPathComponent }) else { return false }
        if first == "mosh" || first == "et" { return words.count >= 2 }
        guard first == "ssh", words.count == tokens.count else { return false }   // no pipes or `&&`
        return SSHConfig.target(of: words.joined(separator: " ")) != nil
    }

    /// Seconds to wait before attempt `n` (1-based): 2, 4, 8, 16, 30, 30.
    public static func delay(attempt n: Int) -> TimeInterval {
        min(30, pow(2, Double(max(1, n))))
    }

    /// The command to reconnect with: adds keep-alives so a dead connection is
    /// noticed in about 45 seconds instead of hanging.
    public static func reconnectCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("ssh "), !trimmed.contains("ServerAliveInterval") else { return trimmed }
        return "ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 " + trimmed.dropFirst(4)
    }
}
