import AppKit
import AnserCore

/// The project's Node version and Python virtualenv, switched by themselves
/// when you `cd` in and back when you leave (Settings → Suggestions & Helpers).
/// `.env` files stay an offer you click (ProjectEnvironment.swift): they can hold secrets.
struct RuntimeNode: Equatable {
    var requirement: NodeVersions.Requirement
    var choice: NodeVersions.Choice
}

extension PaneView {
    var runtimesOn: Bool { Services.shared.config.projectRuntimes }
    /// Where Node versions live (the self-test points this at its own fake ones).
    static var nodeFoldersForTest: [String]?
    var nodeFolders: [String] { Self.nodeFoldersForTest ?? NodeVersions.versionFolders() }

    /// At each prompt: put the project's Node first on PATH and activate its virtualenv.
    func checkProjectRuntimes() {
        guard runtimesOn, !session.isRemote, session.integrated, session.atPrompt, session.capabilities.contains("load") else {
            if runtimeNode != nil { runtimeNode = nil; refreshBar() }
            return
        }
        let shell = ProjectEnv.Shell(session.env.shell)
        var lines: [String] = []
        let before = runtimeNode
        if let line = nodeSwitch(shell: shell) { lines.append(line) }
        lines += venvSwitch(shell: shell)
        if !lines.isEmpty {
            Diagnostics.shared.log("project runtimes: " + lines.map { $0.hasPrefix("export PATH") || $0.hasPrefix("set -gx PATH") ? "node → \(runtimeNodeLabel)" : "venv" }.joined(separator: ", "))
            _ = sendToShell(lines.joined(separator: "\n") + "\n")
        }
        if before != runtimeNode { refreshBar() }
    }

    private var runtimeNodeLabel: String {
        if case .use(let v)? = runtimeNode?.choice { return v.version.description }
        return "default"
    }

    /// Shell code that makes the right Node version first on PATH, or nil when it already is.
    private func nodeSwitch(shell: ProjectEnv.Shell) -> String? {
        let folders = nodeFolders
        let installed = NodeVersions.installed(folders: folders)
        guard !installed.isEmpty else { runtimeNode = nil; return nil }
        let nvmDir = String(folders[0].dropLast("/versions/node".count))
        let fallback = NodeVersions.defaultVersion(nvmDir: nvmDir, installed: installed)
        let req = NodeVersions.requirement(from: session.cwd)
        var target: NodeVersions.Installed?
        if let req {
            let choice = NodeVersions.choose(req, installed: installed, current: fallback, nvmDir: nvmDir)
            runtimeNode = RuntimeNode(requirement: req, choice: choice)
            if case .use(let v) = choice { target = v } else { target = fallback }
        } else {
            runtimeNode = nil
            target = fallback
        }
        let path = session.env.path
        let active = NodeVersions.activeBin(in: path, folders: folders)
        // No version-managed Node on PATH and no project asking: leave the shell as you set it up.
        guard let target, active != nil || req != nil, active != target.bin else { return nil }
        let newPath = NodeVersions.path(path, using: target.bin, folders: folders)
        switch shell {
        case .posix:
            return "export PATH=" + ProjectEnv.q(newPath.joined(separator: ":"), shell) + "; hash -r 2>/dev/null"
        case .fish:
            return "set -gx PATH " + newPath.map { ProjectEnv.q($0, shell) }.joined(separator: " ")
        }
    }

    /// Activates the project's .venv/venv, and deactivates one Anser activated once you leave.
    /// A virtualenv you activated yourself is left alone.
    private func venvSwitch(shell: ProjectEnv.Shell) -> [String] {
        let active = session.cloudVars.virtualEnv.flatMap { $0.isEmpty ? nil : $0 }
        let project = ProjectEnv.findVenv(from: session.cwd)
        if let project, project != active, active == nil || active == runtimeVenv {
            runtimeVenv = project
            let activate = project + (shell == .fish ? "/bin/activate.fish" : "/bin/activate")
            return ["source \(ProjectEnv.q(activate, shell)) >/dev/null 2>&1"]
        }
        if project == nil, let ours = runtimeVenv, active == ours {
            runtimeVenv = nil
            return [shell == .fish ? "functions -q deactivate; and deactivate" : "type deactivate >/dev/null 2>&1 && deactivate"]
        }
        if active != runtimeVenv, active != project { runtimeVenv = nil }
        return []
    }

    // MARK: The Node chip

    func refreshNodeChip() {
        let t = theme
        guard runtimesOn, let n = runtimeNode, !session.isRemote else {
            nodeChip.filled = nil
            nodeChip.set(symbol: nil, text: "", color: t.foreground.withAlphaComponent(0.55))
            return
        }
        let from = "\(n.requirement.source) asks for \(n.requirement.text)"
        switch n.choice {
        case .use(let v):
            nodeChip.filled = nil
            nodeChip.set(symbol: "hexagon", text: "node " + v.version.short, color: t.foreground.withAlphaComponent(0.7),
                         tooltip: "Node \(v.version) for this project (\(from)).\nAnser switches back when you leave the folder.")
        case .missing(let install):
            nodeChip.set(role: .suggestion, symbol: "hexagon", text: "Needs Node \(install) · Install",
                         tooltip: "\(from), and no installed Node fits.\nClick to run `\(installCommand(install) ?? "nvm install \(install)")` in this tab.",
                         filled: true, theme: t)
        }
    }

    /// `nvm install 24` or `fnm install 24`; nil when neither is set up.
    func installCommand(_ spec: String) -> String? {
        let nvm = session.env.functions.contains("nvm")
            || FileManager.default.fileExists(atPath: nodeFolders[0].replacingOccurrences(of: "/versions/node", with: "/nvm.sh"))
        if nvm { return "nvm install " + ShellLexer.escape(spec) }
        if CommandIndex.shared.contains("fnm", env: session.env) { return "fnm install " + ShellLexer.escape(spec) }
        return nil
    }

    func nodeChipClicked() {
        guard let n = runtimeNode else { return }
        switch n.choice {
        case .missing(let spec):
            guard let cmd = installCommand(spec) else {
                flash("Install nvm (github.com/nvm-sh/nvm) or fnm to add Node \(spec)")
                return
            }
            guard session.atPrompt else { flash("Wait for the running command to finish"); return }
            Services.shared.record("node.install")
            run(cmd)
        case .use(let v):
            flash("Node \(v.version) · \(n.requirement.source): \(n.requirement.text)")
        }
    }

    // MARK: pip outside a virtualenv

    /// After `pip install …` fails with no virtualenv active, offer to make one and install there.
    func pipFix(for command: String, exitCode: Int) -> String? {
        guard runtimesOn, exitCode != 0, session.cloudVars.virtualEnv?.isEmpty ?? true, !session.isRemote else { return nil }
        let words = command.split(separator: " ").map(String.init)
        let isPipInstall: Bool = {
            if let first = words.first, ["pip", "pip3"].contains((first as NSString).lastPathComponent) { return words.dropFirst().first == "install" }
            if words.count >= 4, ["python", "python3"].contains((words[0] as NSString).lastPathComponent), words[1] == "-m", words[2] == "pip" { return words[3] == "install" }
            return false
        }()
        // Installing for your user only is a choice, not a mistake.
        guard isPipInstall, !words.contains("--user"), !words.contains("--break-system-packages") else { return nil }
        let pipArgs = words.drop { $0 != "install" }.joined(separator: " ")
        let activate = ProjectEnv.Shell(session.env.shell) == .fish ? "source .venv/bin/activate.fish" : "source .venv/bin/activate"
        let existing = FileManager.default.fileExists(atPath: (session.cwd as NSString).appendingPathComponent(".venv/bin/activate"))
        return (existing ? "" : "python3 -m venv .venv && ") + activate + " && pip " + pipArgs
    }
}
