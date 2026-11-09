import AppKit
import AnserCore

/// Your choice per project: load its environment by itself ("always") or never offer ("never").
enum ProjectEnvPrefs {
    /// Tests point this at their own file.
    static var file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Anser")
        return dir.appendingPathComponent("project-env.json")
    }()

    private static func all() -> [String: String] {
        guard let d = try? Data(contentsOf: file), let o = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return o
    }

    static func get(_ root: String) -> String? { all()[root] }

    static func set(_ root: String, _ value: String?) {
        var a = all()
        a[root] = value
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(a).write(to: file, options: .atomic)
    }
}

extension PaneView {
    var envTools: ProjectEnv.Tools {
        ProjectEnv.Tools(nvm: session.env.functions.contains("nvm"),
                         fnm: CommandIndex.shared.contains("fnm", env: session.env),
                         direnv: CommandIndex.shared.contains("direnv", env: session.env))
    }

    /// At each prompt: unload when you leave a project, offer (or load) when you enter one.
    func checkProjectEnvironment() {
        guard Services.shared.config.offerProjectEnvironment, !session.isRemote, session.integrated, session.atPrompt else { return }
        let cwd = session.cwd
        guard cwd != envCheckedCwd else { return }
        envCheckedCwd = cwd
        if let l = envLoaded, !(cwd == l.root || cwd.hasPrefix(l.root + "/")) { unloadProjectEnv(quiet: false) }
        envOffer = nil
        defer { refreshBar() }
        guard let f = ProjectEnv.find(from: cwd), envLoaded?.root != f.root, hasSomethingToLoad(f) else { return }
        switch ProjectEnvPrefs.get(f.root) {
        case "always": loadProjectEnv(f, automatic: true)
        case "never": break
        default: envOffer = f
        }
    }

    private func hasSomethingToLoad(_ f: ProjectEnv.Found) -> Bool {
        let tools = envTools
        if !f.dotenvFiles.isEmpty { return true }
        if let v = f.venv, session.cloudVars.virtualEnv != (f.root as NSString).appendingPathComponent(v) { return true }
        if f.nodeVersion != nil, tools.nvm || tools.fnm { return true }
        if f.envrc, tools.direnv { return true }
        return false
    }

    /// Loads silently through the shell's hook (ESC [9990~), so nothing is typed or saved to history.
    func loadProjectEnv(_ f: ProjectEnv.Found, automatic: Bool = false) {
        guard session.capabilities.contains("load") else {
            flash("Open a new tab to load project environments (this shell started before Anser could)")
            return
        }
        guard session.atPrompt else { flash("Wait for the running command to finish"); return }
        var values: [(key: String, value: String)] = []
        for name in f.dotenvFiles {
            if let text = try? String(contentsOfFile: (f.root as NSString).appendingPathComponent(name), encoding: .utf8) {
                values += ProjectEnv.parseDotenv(text)
            }
        }
        let shell = ProjectEnv.Shell(session.env.shell)
        let (script, loaded) = ProjectEnv.loadScript(f, values: values, shell: shell, tools: envTools, activeVenv: session.cloudVars.virtualEnv)
        guard sendToShell(script) else { flash("Couldn't load the project environment"); return }
        envLoaded = loaded
        envOffer = nil
        Services.shared.record(automatic ? "env.autoload" : "env.load")
        Diagnostics.shared.log("project env loaded: \(loaded.keys.count) vars venv=\(loaded.venv) node=\(loaded.node)")
        flash("Loaded " + (loaded.summary.isEmpty ? "the project environment" : loaded.summary))
        refreshBar()
    }

    func unloadProjectEnv(quiet: Bool = false) {
        guard let l = envLoaded else { return }
        envLoaded = nil
        if session.capabilities.contains("load"), session.atPrompt {
            _ = sendToShell(ProjectEnv.unloadScript(l, shell: ProjectEnv.Shell(session.env.shell)))
            if !quiet { flash("Unloaded \(l.summary.isEmpty ? "the project environment" : l.summary)") }
        }
        refreshBar()
    }

    /// Writes shell code for the hook to source, then presses its private key.
    /// (Adds to a file the shell hasn't picked up yet, so nothing is lost.)
    func sendToShell(_ script: String) -> Bool {
        guard session.shellPID > 0 else { return false }
        let path = (ShellSession.loadDirectory as NSString).appendingPathComponent("load-\(session.shellPID).sh")
        var text = script
        if let pending = try? String(contentsOfFile: path, encoding: .utf8) { text = pending + "\n" + script }
        unlink(path)
        guard FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return false }
        lastEnvScript = script
        surfaceView.binding("text:\\x1b[9990~")
        return true
    }

    func refreshProjectEnvChip() {
        let t = theme
        if let l = envLoaded {
            envChip.filled = nil
            envChip.set(symbol: "leaf", text: "env · " + String(l.summary.prefix(30)), color: ChipRole.info.color(t),
                        tooltip: "Loaded from \(PathDisplay.short(l.root)): \(l.summary)" + (l.keys.isEmpty ? "" : "\nVariables: " + l.keys.prefix(12).joined(separator: ", "))
                            + "\nUnloads when you leave the folder. Click for options.")
        } else if let f = envOffer {
            envChip.filled = ChipRole.suggestion.color(t)
            envChip.set(symbol: "leaf", text: "Load " + String(f.summary.prefix(30)), color: ChipRole.suggestion.color(t),
                        tooltip: "This project has \(f.summary).\nClick to load it into this shell (values from .env are set with export, never run).")
        } else {
            envChip.filled = nil
            envChip.set(symbol: nil, text: "", color: t.foreground.withAlphaComponent(0.55))
        }
    }

    func showProjectEnvMenu() {
        let m = NSMenu()
        if let f = envOffer {
            m.addItem(ClosureMenuItem(title: "Load Now") { [weak self] in self?.loadProjectEnv(f) })
            m.addItem(ClosureMenuItem(title: "Always Load in This Project") { [weak self] in
                ProjectEnvPrefs.set(f.root, "always")
                self?.loadProjectEnv(f, automatic: true)
            })
            m.addItem(ClosureMenuItem(title: "Don't Offer in This Project") { [weak self] in
                ProjectEnvPrefs.set(f.root, "never")
                self?.envOffer = nil
                self?.refreshBar()
            })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(title: "What Would Load…") { [weak self] in self?.describeProjectEnv(f) })
        } else if let l = envLoaded {
            m.addItem(ClosureMenuItem(title: "Unload") { [weak self] in self?.unloadProjectEnv() })
            m.addItem(ClosureMenuItem(title: "Reload") { [weak self] in
                guard let self, let f = ProjectEnv.find(from: self.session.cwd) else { return }
                self.unloadProjectEnv(quiet: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.loadProjectEnv(f) }
            })
            let always = ProjectEnvPrefs.get(l.root) == "always"
            let item = ClosureMenuItem(title: "Always Load in This Project") {
                ProjectEnvPrefs.set(l.root, always ? nil : "always")
            }
            item.state = always ? .on : .off
            m.addItem(item)
        } else {
            return
        }
        m.popUp(positioning: nil, at: NSPoint(x: envChip.frame.minX, y: envChip.frame.maxY + 2), in: bar)
    }

    /// Shell → Project Environment.
    func projectEnvironmentAction() {
        if let f = envOffer { loadProjectEnv(f); return }
        if envLoaded != nil, !envChip.isHidden { showProjectEnvMenu(); return }
        if envLoaded != nil { unloadProjectEnv(); return }
        if let f = ProjectEnv.find(from: session.cwd), !session.isRemote { loadProjectEnv(f); return }
        flash("No .env, virtualenv, .nvmrc or .envrc in this project")
    }

    private func describeProjectEnv(_ f: ProjectEnv.Found) {
        guard let w = window else { return }
        var lines: [String] = []
        for name in f.dotenvFiles {
            let text = (try? String(contentsOfFile: (f.root as NSString).appendingPathComponent(name), encoding: .utf8)) ?? ""
            let keys = ProjectEnv.parseDotenv(text).map(\.key)
            lines.append("\(name): " + (keys.isEmpty ? "no variables" : keys.joined(separator: ", ")))
        }
        if let v = f.venv { lines.append("Python virtualenv: \(v)") }
        if let n = f.nodeVersion { lines.append("Node \(n) (from \(f.nodeFile ?? ".nvmrc"))" + (envTools.nvm || envTools.fnm ? "" : " — needs nvm or fnm")) }
        if f.envrc { lines.append(".envrc" + (envTools.direnv ? " (through direnv, which runs it)" : " — needs direnv")) }
        let a = NSAlert()
        a.messageText = "Project environment for \((f.root as NSString).lastPathComponent)"
        a.informativeText = lines.joined(separator: "\n") + "\n\nValues from .env files are set with export; Anser never runs them. PATH and other variables that would change which programs run are skipped."
        a.addButton(withTitle: "Load")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in if r == .alertFirstButtonReturn { self?.loadProjectEnv(f) } }
    }
}
