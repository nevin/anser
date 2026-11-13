import Foundation
import os

/// Guards for things Anser runs or opens on its own (not commands you type).
public enum GitSafety {
    /// Config that makes git run arbitrary programs. A repository folder that
    /// came from a download or archive (not a fresh clone) can carry these.
    /// core.hooksPath isn't here: husky and similar tools set it in most Node
    /// repos, and `environment` points it at /dev/null for Anser's own git runs.
    static let riskyKeyPatterns = [
        #"^\s*fsmonitor\s*="#, #"^\s*(clean|smudge|process|textconv)\s*="#,
        #"^\s*external\s*="#, #"^\s*sshcommand\s*="#, #"^\s*gitproxy\s*="#, #"^\s*askpass\s*="#,
        #"^\s*pager\s*="#, #"^\s*editor\s*="#, #"^\s*path\s*="#,   // include.path / includeIf
    ]

    /// Settings forced on every git command Anser runs itself (highest
    /// precedence, via GIT_CONFIG_COUNT): no fsmonitor program, no hooks.
    public static let environment: [String: String] = [
        "GIT_CONFIG_COUNT": "3",
        "GIT_CONFIG_KEY_0": "core.fsmonitor", "GIT_CONFIG_VALUE_0": "false",
        "GIT_CONFIG_KEY_1": "core.hooksPath", "GIT_CONFIG_VALUE_1": "/dev/null",
        "GIT_CONFIG_KEY_2": "core.untrackedCache", "GIT_CONFIG_VALUE_2": "false",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
    ]

    /// config path → (modified, risky). The lock owns the dictionary, so it can't be touched unlocked.
    private static let cache = OSAllocatedUnfairLock(initialState: [String: (Date, Bool)]())

    /// The repository's own .git/config (or a worktree's) for the folder.
    static func configPath(for cwd: String) -> String? {
        var d = cwd
        while !d.isEmpty, d != "/" {
            let g = (d as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: g, isDirectory: &isDir) {
                if isDir.boolValue { return g + "/config" }
                if let txt = try? String(contentsOfFile: g, encoding: .utf8), txt.hasPrefix("gitdir: ") {
                    var p = txt.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !p.hasPrefix("/") { p = (d as NSString).appendingPathComponent(p) }
                    return p + "/config"
                }
                return nil
            }
            d = (d as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// True if the repository's config could make git run a program, filter
    /// files through one, or pull in other config. Anser then skips its own
    /// automatic git commands there (typing `git` yourself is unaffected).
    public static func isRisky(cwd: String) -> Bool {
        guard let path = configPath(for: cwd) else { return false }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        if let hit = cache.withLock({ $0[path] }), hit.0 == mtime { return hit.1 }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let risky = text.split(separator: "\n").contains { line in
            let l = line.lowercased()
            return riskyKeyPatterns.contains { l.range(of: $0, options: .regularExpression) != nil }
        }
        cache.withLock { $0[path] = (mtime, risky) }
        return risky
    }
}

/// What may be opened directly when you ⌘-click it or follow a link.
public enum OpenSafety {
    /// Things macOS would *run* rather than show: scripts, apps, installers,
    /// and shortcut files that open other places.
    static let runnable: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "fish", "pkg", "mpkg", "dmg", "jar",
        "scpt", "scptd", "applescript", "workflow", "action", "shortcut", "webloc", "inetloc", "fileloc", "url",
        "prefpane", "kext", "plugin", "bundle", "framework", "xpc", "service", "saver", "osax", "mobileconfig", "dylib",
    ]

    /// True if the file is safe to hand to the default app (it will be
    /// *shown*, not run). Otherwise reveal it in Finder instead.
    public static func canOpenDirectly(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if runnable.contains(ext) { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { return !ext.isEmpty ? false : true }   // packages have extensions; plain folders are fine
        // Executable files with no document extension would launch in Terminal.
        if FileManager.default.isExecutableFile(atPath: path), ext.isEmpty || ["py", "rb", "pl", "js"].contains(ext) { return false }
        return true
    }

    /// URL schemes that open without asking.
    public static let quietSchemes: Set<String> = ["http", "https", "mailto"]
}
