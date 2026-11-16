import Foundation

/// Picks the Node version a project needs from the versions installed with
/// nvm or fnm, so Anser can put it first on PATH when you `cd` in — without
/// loading nvm into every shell.
///
/// What a project asks for, in order: `.nvmrc`, `.node-version`, then
/// package.json's `"engines": {"node": …}`. Your default version stays when
/// it already fits.
public enum NodeVersions {
    public struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
        public var major: Int, minor: Int, patch: Int
        public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) { self.major = major; self.minor = minor; self.patch = patch }

        /// "v22.23.3", "22.23", "22".
        public init?(_ s: String) {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            let parts = t.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { return nil }
            var n: [Int] = []
            for p in parts {
                // "3-beta" / "3+build": the numbers before the tag.
                let digits = p.prefix { $0.isNumber }
                guard !digits.isEmpty, let v = Int(digits) else { return nil }
                n.append(v)
            }
            self.init(n[0], n.count > 1 ? n[1] : 0, n.count > 2 ? n[2] : 0)
        }

        public static func < (a: Version, b: Version) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        public var description: String { "\(major).\(minor).\(patch)" }
        /// "22.23" — what the status row shows.
        public var short: String { "\(major).\(minor)" }
    }

    public struct Installed: Equatable, Sendable {
        public var version: Version
        /// The folder to put on PATH (holds node, npm, npx).
        public var bin: String
        public init(version: Version, bin: String) { self.version = version; self.bin = bin }
    }

    /// What a project asks for and where that came from.
    public struct Requirement: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// .nvmrc / .node-version: "22", "22.2", "v22.2.0", "node", "lts/*", "lts/iron".
            case pinned(String)
            /// package.json engines: ">=22", "^20 || ^22", "18.x".
            case range(String)
        }
        public var kind: Kind
        /// ".nvmrc", ".node-version" or "package.json".
        public var source: String
        public var root: String
        public init(kind: Kind, source: String, root: String) { self.kind = kind; self.source = source; self.root = root }

        /// "22" / ">=24" — for the status row.
        public var text: String {
            switch kind { case .pinned(let s), .range(let s): return s }
        }
    }

    public enum Choice: Equatable, Sendable {
        /// Put this one first on PATH.
        case use(Installed)
        /// Nothing installed fits; `install` is what to give `nvm install` ("24").
        case missing(install: String)
    }

    // MARK: Installed versions

    /// Where version managers keep Node: nvm's folder, then fnm's.
    public static func versionFolders(home: String = NSHomeDirectory(), env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var out: [String] = []
        let nvm = env["NVM_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.nvm"
        out.append(nvm + "/versions/node")
        if let fnm = env["FNM_DIR"], !fnm.isEmpty { out.append(fnm + "/node-versions") }
        out.append(home + "/.local/share/fnm/node-versions")
        out.append(home + "/Library/Application Support/fnm/node-versions")
        return out
    }

    /// Every installed version, newest first.
    public static func installed(folders: [String], list: (String) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0) },
                                 isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> [Installed] {
        var found: [Version: Installed] = [:]
        for folder in folders {
            for name in list(folder) ?? [] {
                guard name.hasPrefix("v"), let v = Version(name), found[v] == nil else { continue }
                // nvm: v22.1.0/bin; fnm: v22.1.0/installation/bin.
                for bin in [folder + "/" + name + "/bin", folder + "/" + name + "/installation/bin"] where isExecutable(bin + "/node") {
                    found[v] = Installed(version: v, bin: bin)
                    break
                }
            }
        }
        return found.values.sorted { $0.version > $1.version }
    }

    /// nvm's default (`nvm alias default …`), resolved to an installed version; else the newest.
    public static func defaultVersion(nvmDir: String, installed: [Installed], read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Installed? {
        guard !installed.isEmpty else { return nil }
        if let alias = read(nvmDir + "/alias/default")?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty,
           let hit = resolvePinned(alias, installed: installed, nvmDir: nvmDir, read: read) {
            return hit
        }
        return installed.first
    }

    // MARK: What a project asks for

    /// The nearest .nvmrc / .node-version / package.json with engines, up to the git repo or your home folder.
    public static func requirement(from cwd: String, home: String = NSHomeDirectory(),
                                   exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                                   read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Requirement? {
        var d = cwd
        for _ in 0..<12 {
            if d == home || d == "/" || d.isEmpty { return nil }
            func p(_ n: String) -> String { (d as NSString).appendingPathComponent(n) }
            for n in [".nvmrc", ".node-version"] {
                if let line = read(p(n))?.split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }),
                   !line.isEmpty, !line.hasPrefix("#"), isSafe(line) {
                    return Requirement(kind: .pinned(line), source: n, root: d)
                }
            }
            if let text = read(p("package.json")), let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let engines = json["engines"] as? [String: Any], let node = (engines["node"] as? String)?.trimmingCharacters(in: .whitespaces),
                   !node.isEmpty, node.count < 80 {
                    return Requirement(kind: .range(node), source: "package.json", root: d)
                }
                // A package without engines: the nearest project is this one, and it doesn't care.
                return nil
            }
            if exists(p(".git")) { return nil }
            d = (d as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func isSafe(_ s: String) -> Bool {
        s.count < 40 && s.allSatisfy { $0.isLetter || $0.isNumber || ".-_/*".contains($0) }
    }

    // MARK: Choosing

    /// The version to use for `req`, or what to install. `current` is the default, kept when it fits.
    public static func choose(_ req: Requirement, installed: [Installed], current: Installed?, nvmDir: String,
                              read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> Choice {
        switch req.kind {
        case .pinned(let spec):
            if let current, pinnedMatches(spec, current.version, nvmDir: nvmDir, read: read) { return .use(current) }
            if let hit = resolvePinned(spec, installed: installed, nvmDir: nvmDir, read: read) { return .use(hit) }
            return .missing(install: installSpec(pinned: spec))
        case .range(let range):
            if let current, satisfies(current.version, range) { return .use(current) }
            if let hit = installed.first(where: { satisfies($0.version, range) }) { return .use(hit) }
            return .missing(install: installSpec(range: range))
        }
    }

    /// The newest installed version for "22" / "22.2" / "v22.2.0" / "node" / "lts/*" / "lts/iron".
    static func resolvePinned(_ spec: String, installed: [Installed], nvmDir: String, read: (String) -> String?) -> Installed? {
        installed.first { pinnedMatches(spec, $0.version, nvmDir: nvmDir, read: read) }
            ?? (isNewestAlias(spec) ? installed.first : nil)
    }

    static func isNewestAlias(_ spec: String) -> Bool { ["node", "stable", "latest", "current"].contains(spec.lowercased()) }

    static func pinnedMatches(_ spec: String, _ v: Version, nvmDir: String, read: (String) -> String?) -> Bool {
        let s = spec.lowercased()
        if s.hasPrefix("lts/") {
            // nvm records each LTS line it knows: alias/lts/iron → "v20.19.0"; "*" is the newest line.
            let name = String(s.dropFirst(4))
            if name != "*", let text = read(nvmDir + "/alias/lts/" + name), let lts = Version(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return v.major == lts.major
            }
            if name == "*", let text = read(nvmDir + "/alias/lts/*"), let named = Optional(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               let target = read(nvmDir + "/alias/" + named).flatMap({ Version($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                return v.major == target.major
            }
            // Without nvm's records: an even major (LTS lines are even).
            return v.major % 2 == 0
        }
        if isNewestAlias(s) { return false }
        let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
        let parts = t.split(separator: ".").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return false }
        let want = [v.major, v.minor, v.patch]
        for (i, p) in parts.enumerated() {
            if p == "x" || p == "*" { return true }
            guard let n = Int(p), n == want[i] else { return false }
        }
        return true
    }

    /// What `nvm install` should get when nothing fits: "24" for ">=24", "20" for "^20.1".
    static func installSpec(pinned spec: String) -> String {
        isNewestAlias(spec) ? "node" : (spec.hasPrefix("v") ? String(spec.dropFirst()) : spec)
    }

    static func installSpec(range: String) -> String {
        // The first alternative's lowest version names the major to install.
        let first = range.components(separatedBy: "||").first ?? range
        for token in first.split(separator: " ") {
            let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ">=<^~v"))
            if let m = t.split(separator: ".").first, let major = Int(m) {
                return String(token.hasPrefix(">") && !token.hasPrefix(">=") ? major + 1 : major)
            }
        }
        return "node"
    }

    // MARK: Ranges (the npm semver forms engines use)

    /// Whether `v` fits an npm range: ">=18", "^20.1", "~18.2", "18.x", ">=18 <21", "^20 || ^22", "18 - 20", "*".
    public static func satisfies(_ v: Version, _ range: String) -> Bool {
        let alternatives = range.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }
        return alternatives.contains { alt in
            if alt.isEmpty || alt == "*" || alt.lowercased() == "x" { return true }
            // Hyphen range: "18 - 20.1".
            let hyphen = alt.components(separatedBy: " - ")
            if hyphen.count == 2 {
                return compare(v, ">=", hyphen[0]) && upTo(v, hyphen[1].trimmingCharacters(in: .whitespaces))
            }
            var tokens: [String] = []
            // ">= 18" → ">=18".
            var pendingOp = ""
            for raw in alt.split(separator: " ").map(String.init) {
                if ["<", "<=", ">", ">=", "=", "^", "~"].contains(raw) { pendingOp = raw; continue }
                tokens.append(pendingOp + raw)
                pendingOp = ""
            }
            return !tokens.isEmpty && tokens.allSatisfy { token($0, v) }
        }
    }

    private static func token(_ t: String, _ v: Version) -> Bool {
        for op in [">=", "<=", ">", "<", "="] where t.hasPrefix(op) {
            return compare(v, op, String(t.dropFirst(op.count)))
        }
        if t.hasPrefix("^") {
            guard let (lo, parts) = parse(String(t.dropFirst())) else { return false }
            guard v >= lo else { return false }
            // ^1.2.3 → <2.0.0; ^0.2.3 → <0.3.0; ^0.0.3 → <0.0.4.
            if lo.major > 0 || parts == 1 { return v.major == lo.major }
            if lo.minor > 0 || parts == 2 { return v.major == 0 && v.minor == lo.minor }
            return v == lo
        }
        if t.hasPrefix("~") {
            guard let (lo, parts) = parse(String(t.dropFirst())) else { return false }
            guard v >= lo else { return false }
            return parts == 1 ? v.major == lo.major : (v.major == lo.major && v.minor == lo.minor)
        }
        // "18", "18.x", "18.2.*", "v18.2.0": everything that starts that way.
        return matchesPartial(v, t)
    }

    private static func matchesPartial(_ v: Version, _ t: String) -> Bool {
        let s = t.hasPrefix("v") ? String(t.dropFirst()) : t
        let parts = s.split(separator: ".").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return false }
        let want = [v.major, v.minor, v.patch]
        for (i, p) in parts.enumerated() {
            if p == "x" || p == "X" || p == "*" { return true }
            guard let n = Int(p.prefix { $0.isNumber }), n == want[i] else { return false }
        }
        return true
    }

    /// "18" → (18.0.0, 1 part). Wildcards count as missing parts.
    private static func parse(_ s: String) -> (Version, Int)? {
        let t = s.hasPrefix("v") ? String(s.dropFirst()) : s
        let parts = t.split(separator: ".").map(String.init).prefix { $0 != "x" && $0 != "X" && $0 != "*" }
        guard !parts.isEmpty, let v = Version(parts.joined(separator: ".")) else { return nil }
        return (v, parts.count)
    }

    private static func compare(_ v: Version, _ op: String, _ rhs: String) -> Bool {
        guard let (r, parts) = parse(rhs.trimmingCharacters(in: .whitespaces)) else { return false }
        switch op {
        case ">=": return v >= r
        case ">":
            // ">18" means 19 and up; ">18.2" means 18.3 and up.
            switch parts { case 1: return v.major > r.major; case 2: return (v.major, v.minor) > (r.major, r.minor); default: return v > r }
        case "<": return v < r
        case "<=": return upTo(v, rhs)
        default: return matchesPartial(v, rhs)
        }
    }

    /// "<=20" includes every 20.x.
    private static func upTo(_ v: Version, _ rhs: String) -> Bool {
        guard let (r, parts) = parse(rhs) else { return false }
        switch parts { case 1: return v.major <= r.major; case 2: return (v.major, v.minor) <= (r.major, r.minor); default: return v <= r }
    }

    // MARK: PATH

    /// `path` with Node version folders removed and `bin` first.
    public static func path(_ path: [String], using bin: String, folders: [String]) -> [String] {
        [bin] + path.filter { entry in entry != bin && !folders.contains { entry.hasPrefix($0 + "/") } }
    }

    /// The version folder currently first on PATH, if any.
    public static func activeBin(in path: [String], folders: [String]) -> String? {
        path.first { entry in folders.contains { entry.hasPrefix($0 + "/") } }
    }
}
