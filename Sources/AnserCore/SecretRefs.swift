import Foundation

/// Secrets in saved commands: `{{secret:github-token}}` comes from the
/// Keychain and `{{op://vault/item/field}}` from 1Password's `op` tool. The
/// value is filled in only as the command runs, so it never appears in the
/// command, in history or on screen.
public enum SecretRefs {
    public enum Ref: Sendable, Equatable, Hashable {
        case keychain(String)
        case onePassword(String)
    }

    nonisolated(unsafe) static let re = try! NSRegularExpression(
        pattern: #"\{\{\s*(?:secret:([A-Za-z0-9_.\-]{1,64})|(op://[^}\s'"]{3,300}))\s*\}\}"#)

    public static func find(_ s: String) -> [(range: NSRange, ref: Ref)] {
        guard s.contains("{{") else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            if m.range(at: 1).location != NSNotFound { return (m.range, .keychain(ns.substring(with: m.range(at: 1)))) }
            return (m.range, .onePassword(ns.substring(with: m.range(at: 2))))
        }
    }

    public static func contains(_ s: String) -> Bool { !find(s).isEmpty }

    /// Replaces each reference with shell code that produces its value.
    /// `keychainCode` returns the code for a Keychain secret (nil = not available,
    /// and the whole rewrite fails). 1Password references become `$(op read '…')`.
    public static func rewrite(_ s: String, keychainCode: (String) -> String?) -> String? {
        var out = s
        for (range, ref) in find(s).reversed() {
            let code: String
            switch ref {
            case .keychain(let name):
                guard let c = keychainCode(name) else { return nil }
                code = c
            case .onePassword(let path):
                code = "\"$(op read \(ShellLexer.escape(path)))\""
            }
            out = (out as NSString).replacingCharacters(in: range, with: code)
        }
        return out
    }

    /// Keychain secret names used in a command.
    public static func keychainNames(_ s: String) -> [String] {
        find(s).compactMap { if case .keychain(let n) = $0.ref { return n } else { return nil } }
    }
}
