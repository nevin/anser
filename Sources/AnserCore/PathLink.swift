import Foundation

/// A file reference found in terminal output: `src/app.swift:42:10`,
/// `./main.go:7`, `Foo.kt(12,3)`, `"/abs/path.py", line 3`.
public struct PathLink: Equatable, Sendable {
    public var path: String
    public var line: Int?
    public var column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path; self.line = line; self.column = column
    }

    /// Parses one word (as found under the mouse).
    public static func parse(_ raw: String) -> PathLink? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>[]{},;"))
        while let last = s.last, ".:)".contains(last), !s.hasSuffix("..") { s.removeLast() }
        guard !s.isEmpty, !s.contains("://") else { return nil }
        // file(12,3) / file(12)
        if let open = s.lastIndex(of: "("), s.hasSuffix(")") || s[open...].allSatisfy({ $0.isNumber || $0 == "," || $0 == "(" }) {
            let nums = s[s.index(after: open)...].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if !nums.isEmpty { return PathLink(path: String(s[..<open]), line: nums.first, column: nums.count > 1 ? nums[1] : nil) }
        }
        // file:12:3 / file:12
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var nums: [Int] = []
        var end = parts.count
        while end > 1, let n = Int(parts[end - 1]) { nums.insert(n, at: 0); end -= 1 }
        let path = parts[0..<end].joined(separator: ":")
        guard !path.isEmpty else { return nil }
        return PathLink(path: path, line: nums.first, column: nums.count > 1 ? nums[1] : nil)
    }

    /// The word under the mouse may stop before ":42". Look it up in the
    /// visible text to pick up a line/column that follows it.
    public static func find(word: String, in text: String) -> PathLink? {
        guard var link = parse(word) else { return nil }
        if link.line != nil { return link }
        let escaped = NSRegularExpression.escapedPattern(for: link.path)
        let patterns = [escaped + #":(\d+)(?::(\d+))?"#, escaped + #"\((\d+)(?:,(\d+))?\)"#, escaped + #"\"?, line (\d+)()"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { continue }
            let ns = text as NSString
            func group(_ i: Int) -> Int? {
                let r = m.range(at: i)
                return r.location == NSNotFound || r.length == 0 ? nil : Int(ns.substring(with: r))
            }
            link.line = group(1)
            link.column = group(2)
            return link
        }
        return link
    }

    /// Absolute path, resolving `~` and paths relative to `cwd`.
    public func resolved(cwd: String, home: String = NSHomeDirectory()) -> String {
        var p = path
        if p.hasPrefix("~") { p = home + p.dropFirst() }
        if !p.hasPrefix("/") { p = (cwd as NSString).appendingPathComponent(p) }
        return (p as NSString).standardizingPath
    }

    /// Shell-free argv to open this in an editor at the right line.
    public func editorCommand(_ editor: String, absolutePath: String) -> [String] {
        let l = line ?? 1, c = column ?? 1
        switch (editor as NSString).lastPathComponent {
        case "code", "cursor", "codium", "windsurf": return [editor, "-g", "\(absolutePath):\(l):\(c)"]
        case "zed", "subl", "mate": return [editor, "\(absolutePath):\(l):\(c)"]
        case "idea", "pycharm", "webstorm", "goland", "clion", "rubymine", "studio": return [editor, "--line", "\(l)", absolutePath]
        case "vim", "nvim", "vi", "nano", "micro", "emacs", "hx", "helix", "kak": return [editor, "+\(l)", absolutePath]
        default: return [editor, absolutePath]
        }
    }

    public static let terminalEditors: Set<String> = ["vim", "nvim", "vi", "nano", "micro", "emacs", "hx", "helix", "kak"]
    public static let guiEditors = ["cursor", "code", "zed", "subl", "windsurf", "codium", "idea"]
}
