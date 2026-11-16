import AppKit
import AnserCore

/// Commit (and push, and open a pull request) from the Changes view. The
/// command runs in the tab, so you see git's output and it lands in history.
extension TerminalWindowController {
    /// The Changes view's Commit buttons.
    func commitActions(pane: PaneView) -> [PickerPanel.Action] {
        var actions = [PickerPanel.Action(title: "Commit…", symbol: "checkmark.circle", button: true) { [weak self, weak pane] _ in
            guard let pane else { return }
            self?.showCommit(for: pane, suggestMessage: false)
        }]
        if Services.shared.aiEnabled {
            actions.append(PickerPanel.Action(title: "Commit with \(Services.shared.aiName) Message…", symbol: "sparkles", button: true) { [weak self, weak pane] _ in
                guard let pane else { return }
                self?.showCommit(for: pane, suggestMessage: true)
            })
        }
        return actions
    }

    /// `suggestMessage`: send the diff to the AI you set up and fill in its message.
    func showCommit(for pane: PaneView, suggestMessage: Bool) {
        guard pane.session.gitBranch != nil else { pane.flash("This folder isn't in a git repository"); return }
        if pane.session.gitRisky { pane.flash("Git checks are off in this repo (its config can run programs)"); return }
        guard pane.session.atPrompt else { pane.flash("Wait for the running command to finish, then commit"); return }
        let cwd = pane.session.cwd, env = pane.session.env
        Task { @MainActor [weak self, weak pane] in
            guard let pane else { return }
            let changes = await Generators.gitChanges(cwd: cwd, env: env, timeout: 10)
            guard !changes.isEmpty else { pane.flash("Nothing to commit: everything is committed"); return }
            let staged = changes.filter(\.staged).count
            let upstream = await ScriptRunner.shared.run("git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null", cwd: cwd, env: env, timeout: 3)
            let hasUpstream = !(upstream ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let remote = await ScriptRunner.shared.run("git remote get-url origin 2>/dev/null", cwd: cwd, env: env, timeout: 3) ?? ""
            let onGitHub = remote.contains("github.com") && CommandIndex.shared.contains("gh", env: env)
            var message = ""
            if suggestMessage {
                pane.flash("Asking \(Services.shared.aiName) for a commit message…")
                let diff = await ScriptRunner.shared.run(staged > 0 ? "git diff --cached --stat --patch" : "git diff --stat --patch",
                                                         cwd: cwd, env: env, timeout: 10) ?? ""
                let untracked = changes.filter(\.untracked).map { "new file: " + $0.path }.joined(separator: "\n")
                let ctx = AIHelp.Context(shell: env.shell, os: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                                         cwdName: (cwd as NSString).lastPathComponent, gitBranch: pane.session.gitBranch)
                do {
                    message = try await Services.shared.ai.commitMessage(diff: diff + (untracked.isEmpty ? "" : "\n" + untracked), context: ctx)
                    Services.shared.record("git.commit.ai")
                } catch {
                    pane.flash("Couldn't get a message: \(error.localizedDescription)")
                }
            }
            self?.presentCommitForm(pane: pane, message: message, changes: changes, staged: staged, hasUpstream: hasUpstream, onGitHub: onGitHub)
        }
    }

    private func presentCommitForm(pane: PaneView, message: String, changes: [GitChange], staged: Int, hasUpstream: Bool, onGitHub: Bool) {
        let branch = pane.session.gitBranch ?? ""
        let mainBranch = ["main", "master", "trunk", "develop"].contains(branch)
        var fields: [FormSheet.Field] = [
            .init("message", "Message", .text(placeholder: "What this change does, e.g. “Fix the login redirect”", mono: false), value: message),
            .init("stageAll", "", .check(title: "Stage all \(changes.count) changed file\(changes.count == 1 ? "" : "s") first"), value: staged == 0 ? "1" : "",
                  help: "git add -A: new, changed and deleted files"),
            .init("push", "", .check(title: hasUpstream ? "Push to \(branch)'s remote branch" : "Push, creating \(branch) on origin"), value: "",
                  help: hasUpstream ? "git push" : "git push -u origin HEAD"),
        ]
        if onGitHub, !mainBranch {
            fields.append(.init("pr", "", .check(title: "Open a pull request on GitHub"), value: "",
                                help: "Pushes, then gh pr create --fill --web: GitHub opens with the title and description filled in, for you to check"))
        }
        let summary = staged > 0 ? "\(staged) of \(changes.count) changed file\(changes.count == 1 ? "" : "s") staged on \(branch)."
                                 : "\(changes.count) changed file\(changes.count == 1 ? "" : "s") on \(branch), none staged yet."
        let f = FormSheet(title: "Commit", message: summary, fields: fields, ok: "Commit", width: 520)
        func options(_ v: [String: String]) -> GitCommit.Options {
            GitCommit.Options(message: v["message"] ?? "", stageAll: v["stageAll"] == "1", push: v["push"] == "1",
                              hasUpstream: hasUpstream, openPullRequest: v["pr"] == "1")
        }
        f.validate = { v in
            if (v["message"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a message" }
            if staged == 0, v["stageAll"] != "1" { return "Nothing is staged: stage all, or stage files with ⌘⏎ in Changed Files" }
            return nil
        }
        f.warn = { v in
            let m = (v["message"] ?? "").trimmingCharacters(in: .whitespaces)
            return m.count > 72 ? "Long first line (\(m.count) characters): many tools cut it at 72" : nil
        }
        f.preview = { v in "Runs: " + GitCommit.command(options(v)) }
        f.present(over: pane.window, focus: "message") { [weak pane] v in
            guard let v, let pane else { return }
            guard pane.session.atPrompt else { pane.flash("Wait for the running command to finish, then commit"); return }
            let o = options(v)
            Services.shared.record(o.openPullRequest ? "git.commit.pr" : o.push ? "git.commit.push" : "git.commit")
            pane.run(GitCommit.command(o))
        }
    }
}
