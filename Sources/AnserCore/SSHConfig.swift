import Foundation

/// Hosts from ~/.ssh/config (for the sidebar), and the host an `ssh` command
/// connects to (so profiles apply as soon as you connect).
public enum SSHConfig {
    public struct Host: Equatable, Sendable {
        public var alias: String
        public var hostName: String?
        public var user: String?
        public var port: Int?

        /// "deploy@10.0.0.4:2222", or nil when there's nothing beyond the alias.
        public var detail: String? {
            var s = (user.map { $0 + "@" } ?? "") + (hostName ?? "")
            if let port, port != 22 { s += ":\(port)" }
            return s.isEmpty || s == alias ? nil : s
        }
    }

    /// Named hosts, in file order. Patterns (*, ?, !) aren't hosts you can pick.
    /// `include` reads files named by Include lines (relative to ~/.ssh).
    public static func hosts(in text: String, include: (String) -> [String] = { _ in [] }, depth: Int = 0) -> [Host] {
        var out: [Host] = []
        var current: [Int] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch key {
            case "host":
                current = []
                for name in value.split(separator: " ").map(String.init) where !name.contains(where: { "*?!".contains($0) }) {
                    if let i = out.firstIndex(where: { $0.alias == name }) { current.append(i) }
                    else { out.append(Host(alias: name)); current.append(out.count - 1) }
                }
            case "match":
                current = []
            case "hostname": for i in current where out[i].hostName == nil { out[i].hostName = value }
            case "user": for i in current where out[i].user == nil { out[i].user = value }
            case "port": for i in current where out[i].port == nil { out[i].port = Int(value) }
            case "include" where depth < 4:
                for file in value.split(separator: " ").map(String.init) {
                    for text in include(file) {
                        for h in hosts(in: text, include: include, depth: depth + 1) where !out.contains(where: { $0.alias == h.alias }) { out.append(h) }
                    }
                }
            default: break
            }
        }
        return out
    }

    /// Hosts from your ~/.ssh/config.
    public static func load(home: String = NSHomeDirectory()) -> [Host] {
        let dir = home + "/.ssh"
        guard let text = try? String(contentsOfFile: dir + "/config", encoding: .utf8) else { return [] }
        return hosts(in: text) { pattern in
            let full = pattern.hasPrefix("/") ? pattern : (pattern.hasPrefix("~") ? home + pattern.dropFirst() : dir + "/" + pattern)
            return expand(full).compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        }
    }

    /// Files matching a path with * in its last part (enough for "config.d/*").
    static func expand(_ path: String) -> [String] {
        guard path.contains("*") || path.contains("?") else { return [path] }
        let dir = (path as NSString).deletingLastPathComponent, pat = (path as NSString).lastPathComponent
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            .filter { AnserConfig.glob(pat, $0) }.map { dir + "/" + $0 }
    }

    /// The destination of an interactive `ssh` command ("ssh -p 22 me@box ls" → nil, it runs a command;
    /// "ssh -A me@box" → "box"). The user part is dropped.
    public static func target(of command: String) -> String? {
        let words = command.split(separator: " ").map(String.init)
        guard let first = words.first, (first as NSString).lastPathComponent == "ssh" else { return nil }
        let takesValue = Set("BbcDEeFIiJLlmOopQRSWw")
        var i = 1
        while i < words.count {
            let w = words[i]
            if w == "--" { i += 1; break }
            if w.hasPrefix("-"), w.count >= 2 {
                if w.count == 2, let c = w.last, takesValue.contains(c) { i += 2 } else { i += 1 }
                continue
            }
            break
        }
        guard i < words.count, i == words.count - 1 else { return nil }
        var host = words[i]
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
        return host.isEmpty ? nil : host
    }
}
