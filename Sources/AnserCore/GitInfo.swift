import Foundation

/// Pull request status (from the GitHub CLI) and merge-conflict details.
public enum GitInfo {
    public struct PullRequest: Equatable, Sendable {
        public enum Checks: String, Sendable { case passing, failing, pending, none }
        public var number: Int
        public var title: String
        public var state: String          // OPEN, MERGED, CLOSED
        public var url: String
        public var isDraft: Bool
        public var review: String?        // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED
        public var checks: Checks

        /// "#42 ✓", "#42 ✗", "#42 …", "#42 draft", "#42 merged".
        public var chipText: String {
            switch state {
            case "MERGED": return "#\(number) merged"
            case "CLOSED": return "#\(number) closed"
            default: break
            }
            if isDraft { return "#\(number) draft" }
            switch checks {
            case .passing: return "#\(number) ✓"
            case .failing: return "#\(number) ✗"
            case .pending: return "#\(number) …"
            case .none: return "#\(number)"
            }
        }

        public var summary: String {
            var parts = ["#\(number) \(title)"]
            switch checks {
            case .passing: parts.append("Checks passed")
            case .failing: parts.append("Some checks failed")
            case .pending: parts.append("Checks running")
            case .none: break
            }
            switch review {
            case "APPROVED": parts.append("Approved")
            case "CHANGES_REQUESTED": parts.append("Changes requested")
            case "REVIEW_REQUIRED": parts.append("Review required")
            default: break
            }
            if isDraft { parts.append("Draft") }
            return parts.joined(separator: "\n")
        }
    }

    /// The fields to ask `gh pr view --json` for.
    public static let prFields = "number,title,state,url,isDraft,reviewDecision,statusCheckRollup"

    /// Reads `gh pr view --json …` output; nil when there's no PR (or no usable JSON).
    public static func parsePullRequest(_ json: String) -> PullRequest? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let number = obj["number"] as? Int else { return nil }
        let rollup = obj["statusCheckRollup"] as? [[String: Any]] ?? []
        var failing = false, pending = false
        for c in rollup {
            // CheckRun: status + conclusion. StatusContext: state.
            let conclusion = ((c["conclusion"] as? String) ?? (c["state"] as? String) ?? "").uppercased()
            let status = ((c["status"] as? String) ?? "").uppercased()
            if ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) { failing = true }
            else if ["PENDING", "EXPECTED"].contains(conclusion) || (!status.isEmpty && status != "COMPLETED") { pending = true }
        }
        let checks: PullRequest.Checks = rollup.isEmpty ? .none : (failing ? .failing : (pending ? .pending : .passing))
        let review = (obj["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return PullRequest(number: number, title: obj["title"] as? String ?? "", state: (obj["state"] as? String ?? "OPEN").uppercased(),
                           url: obj["url"] as? String ?? "", isDraft: obj["isDraft"] as? Bool ?? false, review: review, checks: checks)
    }

    // MARK: Conflicts

    public struct Conflict: Equatable, Sendable {
        public var path: String
        /// "both modified", "deleted by them", …
        public var kind: String
    }

    /// Unmerged paths from `git status --porcelain` (v1).
    public static func parseConflicts(_ porcelain: String) -> [Conflict] {
        let kinds = ["UU": "both modified", "AA": "both added", "DD": "both deleted", "AU": "added by us",
                     "UA": "added by them", "DU": "deleted by us", "UD": "deleted by them"]
        return porcelain.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            let xy = String(line.prefix(2))
            guard let kind = kinds[xy] else { return nil }
            var path = String(line.dropFirst(3))
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            return Conflict(path: path, kind: kind)
        }
    }

    /// What's in progress in a repository, from files in its .git folder.
    public enum Operation: String, Sendable {
        case merge, rebase, cherryPick = "cherry-pick", revert

        public var title: String {
            switch self {
            case .merge: "Merge"
            case .rebase: "Rebase"
            case .cherryPick: "Cherry-pick"
            case .revert: "Revert"
            }
        }
        /// git subcommand for --continue / --abort.
        public var command: String { rawValue }
    }

    public static func operation(gitDir: String) -> Operation? {
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent(p)) }
        if has("rebase-merge") || has("rebase-apply") { return .rebase }
        if has("MERGE_HEAD") { return .merge }
        if has("CHERRY_PICK_HEAD") { return .cherryPick }
        if has("REVERT_HEAD") { return .revert }
        return nil
    }

    /// The .git folder for a working folder (also for worktrees and submodules).
    public static func gitDir(for cwd: String) -> String? {
        var d = cwd
        while true {
            let g = (d as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: g, isDirectory: &isDir) {
                if isDir.boolValue { return g }
                if let txt = try? String(contentsOfFile: g, encoding: .utf8), txt.hasPrefix("gitdir: ") {
                    var p = txt.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !p.hasPrefix("/") { p = (d as NSString).appendingPathComponent(p) }
                    return p
                }
                return nil
            }
            if d == "/" || d.isEmpty { return nil }
            d = (d as NSString).deletingLastPathComponent
        }
    }
}
