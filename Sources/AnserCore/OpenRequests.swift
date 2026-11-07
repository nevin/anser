import Foundation

/// Turns links that other apps hand to the default terminal (ssh://, and
/// x-man-page://) into commands. Links can come from any web page, so every
/// part is checked strictly: anything that could be read as an option or
/// shell syntax is refused rather than escaped.
public enum OpenRequests {
    /// `ssh://user@host:2222` → `ssh -p 2222 -- user@host`. nil if anything looks off.
    public static func sshCommand(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "ssh", var host = url.host, !host.isEmpty else { return nil }
        // IPv6 literals arrive without brackets.
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let hostChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
        guard host.unicodeScalars.allSatisfy(hostChars.contains), !host.hasPrefix("-"), host.count <= 253 else { return nil }
        var target = host
        if let user = url.user, !user.isEmpty {
            let userChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            guard user.unicodeScalars.allSatisfy(userChars.contains), !user.hasPrefix("-"), user.count <= 64 else { return nil }
            target = user + "@" + host
        }
        // Paths, queries and passwords in the link are ignored, never passed on.
        var cmd = "ssh"
        if let port = url.port {
            guard (1...65535).contains(port) else { return nil }
            cmd += " -p \(port)"
        }
        return cmd + " -- " + target
    }

    /// `x-man-page://ls` or `x-man-page://3/printf` → `man ls` / `man 3 printf`.
    public static func manCommand(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "x-man-page" else { return nil }
        let parts = ([url.host] + url.pathComponents.filter { $0 != "/" }).compactMap { $0 }.filter { !$0.isEmpty }
        let nameChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-:")
        func ok(_ s: String) -> Bool { !s.hasPrefix("-") && s.count <= 100 && s.unicodeScalars.allSatisfy(nameChars.contains) }
        switch parts.count {
        case 1 where ok(parts[0]): return "man " + parts[0]
        case 2 where ok(parts[0]) && ok(parts[1]) && parts[0].first?.isNumber == true: return "man \(parts[0]) \(parts[1])"
        default: return nil
        }
    }

    /// The shell command that runs a script file double-clicked in Finder.
    /// The tab stays open afterwards so you can read what it printed.
    public static func scriptCommand(path: String) -> String {
        ShellLexer.escape(path)
    }
}
