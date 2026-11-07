import Foundation

/// Settings that apply in some places only, chosen by ssh host or folder:
///
///   { "host": "prod-*", "tabColor": "red", "badge": "PROD", "confirm": ["*"] }
///   { "folder": "~/work/payments", "badge": "payments", "env": { "AWS_PROFILE": "payments" } }
///
/// `host` and `folder` use * and ? wildcards. A folder matches itself and
/// everything inside it. When several profiles match, the first one that
/// sets a field wins.
public struct Profile: Codable, Sendable, Equatable {
    public var name: String?
    public var host: String?
    public var folder: String?
    /// One of the tab colors: red, orange, yellow, green, blue, purple, teal.
    public var tabColor: String?
    /// Short label shown in the status row, e.g. "PROD".
    public var badge: String?
    /// Extra environment for new tabs opened in the folder (local folders only).
    public var env: [String: String]?
    /// Ask before running commands matching these patterns here ("*" = every command).
    public var confirm: [String]?

    public init(name: String? = nil, host: String? = nil, folder: String? = nil, tabColor: String? = nil,
                badge: String? = nil, env: [String: String]? = nil, confirm: [String]? = nil) {
        self.name = name; self.host = host; self.folder = folder; self.tabColor = tabColor
        self.badge = badge; self.env = env; self.confirm = confirm
    }

    /// Whether this profile applies to a place. A remote place has a host; a local one doesn't.
    public func matches(host h: String?, cwd: String, home: String = NSHomeDirectory()) -> Bool {
        guard host != nil || folder != nil else { return false }
        if let host {
            guard let h, AnserConfig.glob(host.lowercased(), h.lowercased()) else { return false }
        }
        if let folder {
            guard h == nil else { return false }
            var f = folder.hasPrefix("~") ? home + folder.dropFirst() : folder
            while f.count > 1, f.hasSuffix("/") { f.removeLast() }
            guard AnserConfig.glob(f, cwd) || AnserConfig.glob(f + "/*", cwd) else { return false }
        }
        return true
    }

    /// The combined settings of every matching profile (first match wins per field).
    public static func resolve(_ profiles: [Profile], host: String?, cwd: String, home: String = NSHomeDirectory()) -> Profile? {
        let hits = profiles.filter { $0.matches(host: host, cwd: cwd, home: home) }
        guard !hits.isEmpty else { return nil }
        var out = Profile()
        for p in hits {
            out.name = out.name ?? p.name
            out.tabColor = out.tabColor ?? p.tabColor
            out.badge = out.badge ?? p.badge
            if let e = p.env { out.env = e.merging(out.env ?? [:]) { _, mine in mine } }
            if let c = p.confirm { out.confirm = (out.confirm ?? []) + c }
        }
        return out
    }

    /// Whether running `command` here needs a confirmation first.
    public func needsConfirmation(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !c.isEmpty else { return false }
        return (confirm ?? []).contains { AnserConfig.glob($0.lowercased(), c) }
    }
}
