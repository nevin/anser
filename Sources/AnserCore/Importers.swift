import Foundation
import CoreText

/// Brings settings over from iTerm2 and Warp: color themes (as Ghostty theme
/// files), font, and Warp workflows (as Command Notebook entries).
public enum Importers {
    public struct Theme: Equatable, Sendable {
        public var name: String
        /// A Ghostty theme file.
        public var text: String
        public init(name: String, text: String) { self.name = name; self.text = text }
    }

    public struct Found: Equatable, Sendable {
        public var source: String
        public var themes: [Theme] = []
        /// The theme the app was using, if known (one of `themes`, or a built-in name).
        public var currentTheme: String?
        public var fontFamily: String?
        public var fontSize: Double?
        public var entries: [Notebook.Entry] = []
        public init(source: String) { self.source = source }
        public var isEmpty: Bool { themes.isEmpty && fontFamily == nil && fontSize == nil && entries.isEmpty }

        /// "2 themes, font JetBrains Mono 13, 5 workflows".
        public var summary: String {
            var p: [String] = []
            if !themes.isEmpty { p.append("\(themes.count) color theme\(themes.count == 1 ? "" : "s")") }
            if let f = fontFamily { p.append("font \(f)\(fontSize.map { " \(Int($0))pt" } ?? "")") } else if let s = fontSize { p.append("text size \(Int(s))pt") }
            if !entries.isEmpty { p.append("\(entries.count) workflow\(entries.count == 1 ? "" : "s") → Notebook") }
            return p.joined(separator: ", ")
        }
    }

    /// Writes a Ghostty theme file from 16 palette colors plus background/foreground (as #rrggbb).
    public static func ghosttyTheme(palette: [String?], background: String?, foreground: String?, cursor: String? = nil,
                                    selectionBackground: String? = nil, selectionForeground: String? = nil) -> String {
        var l: [String] = []
        for (i, c) in palette.enumerated() { if let c { l.append("palette = \(i)=\(c)") } }
        if let background { l.append("background = \(background)") }
        if let foreground { l.append("foreground = \(foreground)") }
        if let cursor { l.append("cursor-color = \(cursor)") }
        if let selectionBackground { l.append("selection-background = \(selectionBackground)") }
        if let selectionForeground { l.append("selection-foreground = \(selectionForeground)") }
        return l.joined(separator: "\n") + "\n"
    }

    /// A name safe to use as a theme file name.
    public static func safeName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Imported" : String(cleaned.prefix(80))
    }

    // MARK: iTerm2

    public static var iTerm2Prefs: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.googlecode.iterm2.plist")
    }

    /// The default iTerm2 profile's colors and font, plus every other profile's colors.
    public static func iTerm2(prefs: URL = iTerm2Prefs) -> Found? {
        guard let data = try? Data(contentsOf: prefs),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let profiles = plist["New Bookmarks"] as? [[String: Any]], !profiles.isEmpty else { return nil }
        let defaultGuid = plist["Default Bookmark Guid"] as? String
        let main = profiles.first { $0["Guid"] as? String == defaultGuid } ?? profiles[0]
        var found = Found(source: "iTerm2")
        for p in profiles {
            let name = "iTerm2 - " + safeName(p["Name"] as? String ?? "Default")
            func color(_ key: String) -> String? { hex(p[key] as? [String: Any]) ?? hex(p[key + " (Dark)"] as? [String: Any]) }
            let palette = (0..<16).map { color("Ansi \($0) Color") }
            guard palette.contains(where: { $0 != nil }) || color("Background Color") != nil else { continue }
            let text = ghosttyTheme(palette: palette, background: color("Background Color"), foreground: color("Foreground Color"),
                                    cursor: color("Cursor Color"), selectionBackground: color("Selection Color"),
                                    selectionForeground: color("Selected Text Color"))
            if !found.themes.contains(where: { $0.text == text }) { found.themes.append(Theme(name: name, text: text)) }
            if p["Guid"] as? String == main["Guid"] as? String { found.currentTheme = found.themes.first { $0.text == text }?.name }
        }
        if let font = main["Normal Font"] as? String {
            let parts = font.split(separator: " ")
            if let last = parts.last, let size = Double(last) { found.fontSize = size }
            let ps = parts.dropLast().joined(separator: " ")
            if !ps.isEmpty { found.fontFamily = familyName(postScript: ps) }
        }
        return found.isEmpty ? nil : found
    }

    /// "#rrggbb" from an iTerm2 color dictionary (components 0–1).
    static func hex(_ d: [String: Any]?) -> String? {
        guard let d, let r = d["Red Component"] as? Double, let g = d["Green Component"] as? Double, let b = d["Blue Component"] as? Double else { return nil }
        func c(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", c(r), c(g), c(b))
    }

    /// "JetBrainsMono-Regular" → "JetBrains Mono" (falls back to the name given).
    public static func familyName(postScript: String) -> String {
        let font = CTFontCreateWithName(postScript as CFString, 12, nil)
        let family = CTFontCopyFamilyName(font) as String
        // CoreText substitutes a default font for unknown names; keep the original then.
        let ps = CTFontCopyPostScriptName(font) as String
        return ps.caseInsensitiveCompare(postScript) == .orderedSame ? family : postScript
    }

    // MARK: Warp

    public static func warp(home: String = NSHomeDirectory(), prefs: URL? = nil) -> Found? {
        var found = Found(source: "Warp")
        let fm = FileManager.default
        let warpDir = (home as NSString).appendingPathComponent(".warp")
        let themesDir = (warpDir as NSString).appendingPathComponent("themes")
        for f in ((try? fm.contentsOfDirectory(atPath: themesDir)) ?? []).sorted() where f.hasSuffix(".yaml") || f.hasSuffix(".yml") {
            guard let text = try? String(contentsOfFile: (themesDir as NSString).appendingPathComponent(f), encoding: .utf8),
                  let theme = warpTheme(yaml: text, name: (f as NSString).deletingPathExtension) else { continue }
            found.themes.append(theme)
        }
        let flowsDir = (warpDir as NSString).appendingPathComponent("workflows")
        for f in ((try? fm.contentsOfDirectory(atPath: flowsDir)) ?? []).sorted() where f.hasSuffix(".yaml") || f.hasSuffix(".yml") {
            guard let text = try? String(contentsOfFile: (flowsDir as NSString).appendingPathComponent(f), encoding: .utf8) else { continue }
            found.entries += warpWorkflows(yaml: text)
        }
        let prefsURL = prefs ?? URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences/dev.warp.Warp-Stable.plist")
        if let data = try? Data(contentsOf: prefsURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if let name = unquote(plist["FontName"]), !name.isEmpty { found.fontFamily = name }
            if let s = unquote(plist["FontSize"]).flatMap(Double.init) ?? (plist["FontSize"] as? Double) { found.fontSize = s }
            if let t = unquote(plist["Theme"]) {
                // Either a built-in name or JSON like {"Custom":{"name":"Mine","path":"…/mine.yaml"}}.
                if let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
                   let custom = obj["Custom"] as? [String: Any], let path = custom["path"] as? String {
                    let base = "Warp - " + safeName(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
                    found.currentTheme = found.themes.first { $0.name == base }?.name
                } else if !t.hasPrefix("{") {
                    found.currentTheme = t
                }
            }
        }
        return found.isEmpty ? nil : found
    }

    /// Warp stores some preferences as JSON strings ("\"Hack\"").
    static func unquote(_ v: Any?) -> String? {
        if let n = v as? NSNumber { return n.stringValue }
        guard var s = v as? String else { return nil }
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2,
           let decoded = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed) as? String { s = decoded }
        return s
    }

    public static func warpTheme(yaml: String, name: String) -> Theme? {
        guard let root = MiniYAML.parse(yaml) as? [String: Any] else { return nil }
        let colors = root["terminal_colors"] as? [String: Any]
        let order = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        var palette: [String?] = []
        for group in ["normal", "bright"] {
            let g = colors?[group] as? [String: Any]
            palette += order.map { normalizeHex(g?[$0] as? String) }
        }
        let bg = normalizeHex(root["background"] as? String), fg = normalizeHex(root["foreground"] as? String)
        guard bg != nil || palette.contains(where: { $0 != nil }) else { return nil }
        return Theme(name: "Warp - " + safeName(name),
                     text: ghosttyTheme(palette: palette, background: bg, foreground: fg, cursor: normalizeHex(root["accent"] as? String)))
    }

    static func normalizeHex(_ s: String?) -> String? {
        guard var h = s?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if !h.hasPrefix("#") { h = "#" + h }
        guard h.count == 7 || h.count == 4, h.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return h.lowercased()
    }

    /// Warp workflow YAML (one workflow, or a list) → notebook entries. Arguments
    /// with defaults become {{name:default}}.
    public static func warpWorkflows(yaml: String) -> [Notebook.Entry] {
        let root = MiniYAML.parse(yaml)
        let items: [[String: Any]] = (root as? [[String: Any]]) ?? ((root as? [String: Any]).map { [$0] } ?? [])
        return items.compactMap { w in
            guard var command = w["command"] as? String, !command.isEmpty else { return nil }
            for a in w["arguments"] as? [[String: Any]] ?? [] {
                guard let n = a["name"] as? String, let d = a["default_value"] as? String, !d.isEmpty else { continue }
                command = command.replacingOccurrences(of: "{{\(n)}}", with: "{{\(n):\(d)}}")
            }
            return Notebook.Entry(title: w["name"] as? String ?? "", command: command, note: w["description"] as? String ?? "")
        }
    }
}

/// Just enough YAML for Warp's theme and workflow files: maps, lists, quoted
/// and plain scalars, `|` / `>` block text, comments. Values are String,
/// [String: Any], [Any] or NSNull.
public enum MiniYAML {
    public static func parse(_ text: String) -> Any? {
        var p = Parser(lines: text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "  ").components(separatedBy: "\n"))
        return p.node(minIndent: 0)
    }

    struct Parser {
        var lines: [String]
        var i = 0

        static func indent(_ s: String) -> Int { s.prefix { $0 == " " }.count }
        static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        static func blank(_ s: String) -> Bool {
            let t = trimmed(s)
            return t.isEmpty || t.hasPrefix("#") || t == "---" || t == "..."
        }

        mutating func skipBlank() { while i < lines.count, Self.blank(lines[i]) { i += 1 } }

        mutating func node(minIndent: Int) -> Any? {
            skipBlank()
            guard i < lines.count else { return nil }
            let ind = Self.indent(lines[i])
            guard ind >= minIndent else { return nil }
            let t = Self.trimmed(lines[i])
            if t == "-" || t.hasPrefix("- ") { return list(indent: ind) }
            if Self.splitKey(t) == nil { i += 1; return Self.scalar(t) }
            return map(indent: ind)
        }

        mutating func list(indent: Int) -> [Any] {
            var out: [Any] = []
            while true {
                skipBlank()
                guard i < lines.count, Self.indent(lines[i]) == indent else { break }
                let t = Self.trimmed(lines[i])
                guard t == "-" || t.hasPrefix("- ") else { break }
                let rest = String(t.dropFirst()).drop { $0 == " " }
                if rest.isEmpty { i += 1; out.append(node(minIndent: indent + 1) ?? NSNull()); continue }
                if Self.splitKey(String(rest)) != nil {
                    let col = indent + (t.count - rest.count)
                    lines[i] = String(repeating: " ", count: col) + rest
                    out.append(map(indent: col))
                } else {
                    out.append(Self.scalar(String(rest)))
                    i += 1
                }
            }
            return out
        }

        mutating func map(indent: Int) -> [String: Any] {
            var out: [String: Any] = [:]
            while true {
                skipBlank()
                guard i < lines.count, Self.indent(lines[i]) == indent else { break }
                let t = Self.trimmed(lines[i])
                if t.hasPrefix("- ") || t == "-" { break }
                guard let (k, v) = Self.splitKey(t) else { i += 1; continue }
                i += 1
                if v.isEmpty {
                    skipBlank()
                    if i < lines.count {
                        let ni = Self.indent(lines[i]), nt = Self.trimmed(lines[i])
                        if ni > indent || (ni == indent && (nt.hasPrefix("- ") || nt == "-")) {
                            out[k] = node(minIndent: ni) ?? NSNull()
                            continue
                        }
                    }
                    out[k] = NSNull()
                } else if v.hasPrefix("|") || v.hasPrefix(">") {
                    out[k] = block(style: v, parentIndent: indent)
                } else {
                    out[k] = Self.scalar(v)
                }
            }
            return out
        }

        mutating func block(style: String, parentIndent: Int) -> String {
            var collected: [String] = []
            var blockIndent: Int?
            while i < lines.count {
                let l = lines[i]
                if Self.trimmed(l).isEmpty { collected.append(""); i += 1; continue }
                let ind = Self.indent(l)
                guard ind > parentIndent else { break }
                if blockIndent == nil { blockIndent = ind }
                collected.append(String(l.dropFirst(min(ind, blockIndent!))))
                i += 1
            }
            while collected.last == "" { collected.removeLast() }
            return style.hasPrefix(">") ? collected.joined(separator: " ") : collected.joined(separator: "\n")
        }

        /// "key: value" → (key, value); "key:" → (key, ""). nil for a plain scalar.
        static func splitKey(_ t: String) -> (String, String)? {
            var quote: Character?
            let chars = Array(t)
            for (n, c) in chars.enumerated() {
                if let q = quote { if c == q { quote = nil }; continue }
                if (c == "\"" || c == "'") && n == 0 { quote = c; continue }
                if c == ":" && (n == chars.count - 1 || chars[n + 1] == " ") {
                    var key = String(chars[..<n]).trimmingCharacters(in: .whitespaces)
                    if key.count >= 2, let f = key.first, f == "\"" || f == "'", key.last == f { key = String(key.dropFirst().dropLast()) }
                    guard !key.isEmpty, !key.contains(" #") else { return nil }
                    return (key, String(chars[(n + 1)...]).trimmingCharacters(in: .whitespaces))
                }
            }
            return nil
        }

        static func scalar(_ raw: String) -> Any {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("'"), let end = s.dropFirst().lastIndex(of: "'") {
                return String(s[s.index(after: s.startIndex)..<end]).replacingOccurrences(of: "''", with: "'")
            }
            if s.hasPrefix("\""), let end = s.dropFirst().lastIndex(of: "\"") {
                let inner = String(s[s.index(after: s.startIndex)..<end])
                return inner.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            if let r = s.range(of: " #") { s = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
            if s == "~" || s == "null" || s.isEmpty { return NSNull() }
            return s
        }
    }
}
