import Foundation

/// `git blame --porcelain` read into lines with their commit, author and time.
public enum GitBlame {
    public struct Line: Equatable, Sendable {
        public var number: Int
        public var commit: String
        public var author: String
        public var time: Date
        public var summary: String
        public var text: String
        /// Lines not committed yet have an all-zero commit.
        public var isUncommitted: Bool { commit.allSatisfy { $0 == "0" } }
        public var shortCommit: String { String(commit.prefix(8)) }
    }

    public static func parse(_ porcelain: String) -> [Line] {
        struct Info { var author = "", time = Date(timeIntervalSince1970: 0), summary = "" }
        var infos: [String: Info] = [:]
        var out: [Line] = []
        var current: (commit: String, line: Int)?
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("\t") {
                guard let c = current else { continue }
                let info = infos[c.commit] ?? Info()
                out.append(Line(number: c.line, commit: c.commit, author: info.author, time: info.time, summary: info.summary, text: String(line.dropFirst())))
                current = nil
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let key = parts.first else { continue }
            if key.count == 40, key.allSatisfy(\.isHexDigit) {
                // "<sha> <orig line> <final line> [<lines in group>]"
                let nums = (parts.count > 1 ? parts[1] : "").split(separator: " ")
                current = (key, nums.count >= 2 ? Int(nums[1]) ?? 0 : 0)
                if infos[key] == nil { infos[key] = Info() }
                continue
            }
            guard let c = current, parts.count == 2 else { continue }
            switch key {
            case "author": infos[c.commit]?.author = parts[1]
            case "author-time": infos[c.commit]?.time = Date(timeIntervalSince1970: Double(parts[1]) ?? 0)
            case "summary": infos[c.commit]?.summary = parts[1]
            default: break
            }
        }
        return out
    }
}
