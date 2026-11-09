import AppKit
import AnserCore

extension Notification.Name {
    static let anserPluginsChanged = Notification.Name("AnserPluginsChanged")
}

/// Runs the plugins you turned on: their chips, palette actions, sidebar
/// sections and after-command hooks. Scripts run in the background with a
/// 5-second limit, only for local shells, and chips with an interval only
/// refresh for the pane in front while Anser is active (to save battery).
final class PluginHost {
    static let shared = PluginHost()
    /// Tests point this at their own folder.
    static var directory = PluginRegistry.defaultDirectory

    private(set) var plugins: [Plugin] = []
    private(set) var errors: [String] = []
    /// Session id → "plugin/chip" → chip.
    private var chips: [String: [String: PluginOutput.Chip]] = [:]
    /// Session id → "plugin/section" → rows.
    private var rows: [String: [String: [PluginOutput.Row]]] = [:]
    private var lastRun: [String: Date] = [:]
    private var pending: Set<String> = []
    private var timer: Timer?
    /// Tests turn plugins on without touching the config file.
    var enabledOverride: [String]?

    var enabledIDs: [String] { enabledOverride ?? Services.shared.config.enabledPlugins }
    var enabled: [Plugin] { plugins.filter { enabledIDs.contains($0.id) } }

    /// Plugins from repos' .anser/plugins, by folder (re-read every few seconds at most).
    private var projectCache: [String: (at: Date, plugins: [Plugin], errors: [String])] = [:]
    /// Repos where you said "not now" to their plugins (until Anser restarts).
    var dismissedProjects: Set<String> = []

    func projectPlugins(cwd: String) -> [Plugin] {
        guard let dir = PluginRegistry.projectDirectory(for: cwd) else { return [] }
        if let c = projectCache[dir], Date().timeIntervalSince(c.at) < 5 { return c.plugins }
        let (p, e) = PluginRegistry.loadProject(cwd: cwd)
        for err in e where projectCache[dir]?.errors.contains(err) != true { Diagnostics.shared.log("project plugin: " + err) }
        projectCache[dir] = (Date(), p, e)
        return p
    }

    /// What runs for this pane: plugins you turned on, plus this repo's plugins you trusted.
    func active(for pane: PaneView) -> [Plugin] {
        guard !pane.session.isRemote else { return [] }
        return enabled + projectPlugins(cwd: pane.session.cwd).filter { FileTrust.plugins.isTrusted($0) }
    }

    /// This repo's plugins waiting for your OK.
    func untrusted(for pane: PaneView) -> [Plugin] {
        guard !pane.session.isRemote, let dir = PluginRegistry.projectDirectory(for: pane.session.cwd), !dismissedProjects.contains(dir) else { return [] }
        return projectPlugins(cwd: pane.session.cwd).filter { !FileTrust.plugins.isTrusted($0) }
    }

    static let timeout: TimeInterval = 5
    static let minInterval: TimeInterval = 10

    func reload() {
        (plugins, errors) = PluginRegistry.load(from: Self.directory)
        projectCache = [:]
        chips = [:]
        rows = [:]
        lastRun = [:]
        for e in errors { Diagnostics.shared.log("plugin: " + e) }
        timer?.invalidate()
        timer = nil
        startTimerIfNeeded(enabled)
        NotificationCenter.default.post(name: .anserPluginsChanged, object: nil)
        AppDelegate.shared.allPanes.forEach { refresh($0) }
    }

    static func hasIntervals(_ p: Plugin) -> Bool {
        (p.manifest.chips ?? []).contains { $0.interval != nil } || (p.manifest.sidebar ?? []).contains { $0.interval != nil }
    }

    private func startTimerIfNeeded(_ list: [Plugin]) {
        guard timer == nil, list.contains(where: Self.hasIntervals) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.minInterval, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 3
    }

    // MARK: Settings

    static func secretName(_ p: Plugin, _ key: String) -> String { "plugin:\(p.id):\(key)" }

    /// A setting's value: what you entered, else its default.
    func value(_ p: Plugin, _ s: PluginManifest.Setting) -> String? {
        if s.secret == true { return SecretBroker.get(Self.secretName(p, s.key)) ?? s.default }
        return settingsOverride?[p.key]?[s.key] ?? Services.shared.config.pluginSettings[p.key]?[s.key] ?? s.default
    }

    /// Tests set plugin settings here instead of in the config file.
    var settingsOverride: [String: [String: String]]?

    // MARK: Running scripts

    func environment(for pane: PaneView, plugin: Plugin) -> [String: String] {
        let s = pane.session
        var e: [String: String] = ["ANSER_CWD": s.cwd, "ANSER_PLUGIN_DIR": plugin.directory, "ANSER_SESSION": s.id]
        if let b = s.gitBranch { e["ANSER_BRANCH"] = b }
        if let last = s.lastFinished {
            e["ANSER_LAST_COMMAND"] = last.command
            e["ANSER_LAST_EXIT"] = String(last.exitCode ?? 0)
        }
        if let v = s.cloudVars.virtualEnv { e["VIRTUAL_ENV"] = v }
        for setting in plugin.manifest.settings ?? [] {
            if let v = value(plugin, setting) { e[setting.envName] = v }
        }
        return e
    }

    func run(_ script: String, plugin: Plugin, pane: PaneView, extra: [String: String] = [:]) async -> String? {
        let argv = PluginRegistry.argv(for: script, in: plugin.directory)
        let env = environment(for: pane, plugin: plugin).merging(extra) { _, b in b }
        let out = await ScriptRunner.shared.run(argv: argv, cwd: pane.session.cwd, env: pane.session.env, extra: env, timeout: Self.timeout)
        return out.map { String($0.prefix(64 * 1024)) }
    }

    // MARK: Chips and sidebar sections

    func chips(for pane: PaneView) -> [(key: String, chip: PluginOutput.Chip)] {
        let mine = chips[pane.session.id] ?? [:]
        // Keep the order plugins declare them in.
        var out: [(String, PluginOutput.Chip)] = []
        for p in active(for: pane) { for c in p.manifest.chips ?? [] { let k = p.key + "/" + c.id; if let v = mine[k] { out.append((k, v)) } } }
        return out
    }

    func sections(for pane: PaneView) -> [(title: String, rows: [PluginOutput.Row])] {
        let mine = rows[pane.session.id] ?? [:]
        var out: [(String, [PluginOutput.Row])] = []
        for p in active(for: pane) { for s in p.manifest.sidebar ?? [] { if let r = mine[p.key + "/" + s.title], !r.isEmpty { out.append((s.title, r)) } } }
        return out
    }

    /// After a command, on focus, or when plugins change: refresh what applies to this pane.
    func refresh(_ pane: PaneView, onlyDue: Bool = false) {
        let active = self.active(for: pane)
        startTimerIfNeeded(active)
        guard !active.isEmpty, !pane.session.isRemote, pane.session.integrated else {
            if chips[pane.session.id] != nil || rows[pane.session.id] != nil {
                chips[pane.session.id] = nil; rows[pane.session.id] = nil
                pane.refreshBar()
            }
            return
        }
        let sid = pane.session.id
        let cwd = pane.session.cwd
        for p in active {
            for c in p.manifest.chips ?? [] {
                let key = p.key + "/" + c.id
                if onlyDue && !isDue(sid + key, interval: c.interval) { continue }
                guard PluginRegistry.applies(c.when, cwd: cwd) else {
                    if chips[sid]?[key] != nil { chips[sid]?[key] = nil; pane.refreshBar() }
                    continue
                }
                start(sid + key) { [weak self, weak pane] in
                    guard let self, let pane else { return }
                    let out = await self.run(c.script, plugin: p, pane: pane)
                    let chip = out.flatMap(PluginOutput.chip)
                    if self.chips[sid]?[key] != chip {
                        self.chips[sid, default: [:]][key] = chip
                        pane.refreshBar()
                    }
                }
            }
            for sec in p.manifest.sidebar ?? [] {
                let key = p.key + "/" + sec.title
                if onlyDue && !isDue(sid + key, interval: sec.interval) { continue }
                guard PluginRegistry.applies(sec.when, cwd: cwd) else { rows[sid]?[key] = nil; continue }
                start(sid + key) { [weak self, weak pane] in
                    guard let self, let pane else { return }
                    let r = PluginOutput.rows(await self.run(sec.script, plugin: p, pane: pane) ?? "")
                    if self.rows[sid]?[key] != r {
                        self.rows[sid, default: [:]][key] = r
                        if pane.windowController?.focusedPane === pane { pane.windowController?.refreshSidebar() }
                    }
                }
            }
        }
    }

    private func isDue(_ key: String, interval: Double?) -> Bool {
        guard let i = interval else { return false }
        return Date().timeIntervalSince(lastRun[key] ?? .distantPast) >= max(Self.minInterval, i) - 1
    }

    /// One run at a time per chip or section.
    private func start(_ key: String, _ work: @escaping () async -> Void) {
        guard !pending.contains(key) else { return }
        pending.insert(key)
        lastRun[key] = Date()
        Task { @MainActor [weak self] in
            await work()
            self?.pending.remove(key)
        }
    }

    /// Interval refreshes: only the focused pane of the front window, only while Anser is active.
    private func tick() {
        guard NSApp.isActive, let wc = NSApp.keyWindow?.windowController as? TerminalWindowController, let pane = wc.focusedPane else { return }
        refresh(pane, onlyDue: true)
    }

    func forget(_ pane: PaneView) {
        chips[pane.session.id] = nil
        rows[pane.session.id] = nil
    }

    // MARK: Actions and hooks

    struct ActionItem { let plugin: Plugin; let action: PluginManifest.Action }

    var actions: [ActionItem] { enabled.flatMap { p in (p.manifest.actions ?? []).map { ActionItem(plugin: p, action: $0) } } }

    func actions(for pane: PaneView?) -> [ActionItem] {
        guard let pane else { return actions }
        return active(for: pane).flatMap { p in (p.manifest.actions ?? []).map { ActionItem(plugin: p, action: $0) } }
    }

    func perform(_ item: ActionItem, in pane: PaneView) {
        Services.shared.record("plugin.action")
        if let cmd = item.action.run {
            if pane.session.atPrompt { pane.submitFromEditor(cmd) } else { AppDelegate.shared.openTab(cwd: pane.session.cwd, run: cmd) }
            return
        }
        guard let script = item.action.script else { return }
        pane.flash("Running “\(item.action.title)”…")
        Task { @MainActor [weak pane] in
            guard let pane else { return }
            let out = (await self.run(script, plugin: item.plugin, pane: pane) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { pane.flash("“\(item.action.title)” finished") }
            else if !out.contains("\n"), out.count <= 120 { pane.flash(out) }
            else { OutputViewer(command: item.action.title, output: out, exitCode: nil, onExport: {}).show(over: pane.window) }
        }
    }

    /// The after-command hook: fire and forget.
    func commandFinished(in pane: PaneView) {
        guard !pane.session.isRemote, let b = pane.session.lastFinished, !b.command.isEmpty else { return }
        for p in active(for: pane) {
            guard let h = p.manifest.hooks, let script = h.commandFinished else { continue }
            if let min = h.minSeconds, (b.duration ?? 0) < min { continue }
            if h.onlyFailures == true, (b.exitCode ?? 0) == 0 { continue }
            let extra = ["ANSER_COMMAND": b.command, "ANSER_EXIT": String(b.exitCode ?? 0),
                         "ANSER_DURATION": String(format: "%.1f", b.duration ?? 0), "ANSER_CWD": b.cwd]
            Task { [weak pane] in
                guard let pane else { return }
                _ = await self.run(script, plugin: p, pane: pane, extra: extra)
            }
        }
    }

    // MARK: Project plugins

    /// Shows what this repo's plugins run, and turns them on if you trust them.
    func review(_ list: [Plugin], for pane: PaneView) {
        guard let p0 = list.first, let w = pane.window else { return }
        let a = NSAlert()
        let root = ((p0.directory as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        a.messageText = list.count == 1 ? "Turn on the project plugin “\(p0.manifest.name)”?" : "Turn on \(list.count) project plugins?"
        let details = list.map { p in "• \(p.manifest.name)\(p.manifest.description.map { ": " + $0 } ?? "")\n" + p.scriptsSummary.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") }
        a.informativeText = "They come with the repo in \(PathDisplay.short((root as NSString).deletingLastPathComponent)) and run scripts on your Mac with your permissions. Turn them on only if you trust the people who can change this repo. Any change to their files asks again.\n\n" + String(details.joined(separator: "\n").prefix(1800))
        a.addButton(withTitle: "Trust & Turn On")
        a.addButton(withTitle: "Not Now")
        a.beginSheetModal(for: w) { [weak self, weak pane] r in
            guard let self, let pane else { return }
            if r == .alertFirstButtonReturn {
                list.forEach { FileTrust.plugins.trust($0) }
                Services.shared.record("plugin.project.trust")
            } else if let dir = PluginRegistry.projectDirectory(for: pane.session.cwd) {
                self.dismissedProjects.insert(dir)
            }
            self.refresh(pane)
            pane.refreshBar()
        }
    }

    /// Settings → Plugins → Add Starter Plugin: installs one from the gallery and turns it on.
    @discardableResult
    func installStarter(_ item: PluginGallery.Item) -> Bool {
        do {
            try PluginGallery.install(item, into: Self.directory)
            var list = enabledIDs.filter { $0 != item.id }
            list.append(item.id)
            if enabledOverride != nil { enabledOverride = list } else { SettingsWindowController.setValue(["enabledPlugins"], list) }
            Services.shared.record("plugin.starter." + item.id)
            reload()
            return true
        } catch {
            Diagnostics.shared.log("starter plugin failed: \(error.localizedDescription)")
            return false
        }
    }

    /// A form for a plugin's settings.
    func editSettings(_ p: Plugin, over window: NSWindow?) {
        let settings = p.manifest.settings ?? []
        guard !settings.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "\(p.manifest.name) settings"
        a.informativeText = "Scripts read these as ANSER_SETTING_… variables. Secret ones are kept in your Keychain."
        var fields: [(PluginManifest.Setting, NSTextField)] = []
        var rows: [[NSView]] = []
        for s in settings {
            let f: NSTextField = s.secret == true ? NSSecureTextField() : NSTextField()
            f.placeholderString = s.placeholder ?? s.default
            f.stringValue = s.secret == true ? "" : (Services.shared.config.pluginSettings[p.key]?[s.key] ?? "")
            if s.secret == true, SecretBroker.get(Self.secretName(p, s.key)) != nil { f.placeholderString = "•••••• (saved; type to replace)" }
            f.widthAnchor.constraint(equalToConstant: 240).isActive = true
            fields.append((s, f))
            rows.append([NSTextField(labelWithString: s.title + ":"), f])
        }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        grid.frame = NSRect(x: 0, y: 0, width: 380, height: CGFloat(rows.count) * 30)
        a.accessoryView = grid
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let save = { [weak self] (r: NSApplication.ModalResponse) in
            guard let self, r == .alertFirstButtonReturn else { return }
            var values = Services.shared.config.pluginSettings[p.key] ?? [:]
            for (s, f) in fields {
                let v = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.secret == true {
                    if !v.isEmpty { SecretStore.set(Self.secretName(p, s.key), v) }
                } else {
                    values[s.key] = v.isEmpty ? nil : v
                }
            }
            var all = Services.shared.config.pluginSettings
            all[p.key] = values.isEmpty ? nil : values
            SettingsWindowController.setValue(["pluginSettings"], all.isEmpty ? nil : all)
            Services.shared.record("plugin.settings")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { AppDelegate.shared.allPanes.forEach { self.refresh($0) } }
        }
        if let window { a.beginSheetModal(for: window, completionHandler: save) } else { save(a.runModal()) }
    }

    // MARK: Files

    /// Settings → Plugins → New Plugin: an example to start from.
    @discardableResult
    static func createExample() -> String? {
        let fm = FileManager.default
        var name = "example", n = 2
        while fm.fileExists(atPath: (directory as NSString).appendingPathComponent(name)) { name = "example-\(n)"; n += 1 }
        let dir = (directory as NSString).appendingPathComponent(name)
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try PluginTemplate.manifest.write(toFile: dir + "/plugin.json", atomically: true, encoding: .utf8)
            for (file, text) in [("last-commit.sh", PluginTemplate.lastCommit), ("finished.sh", PluginTemplate.finished)] {
                try text.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
                chmod(dir + "/" + file, 0o755)
            }
            return dir
        } catch { return nil }
    }

    /// Opens a plugin's link or file. Apps, scripts and other runnable files are shown in Finder instead of opened.
    static func open(_ url: URL) {
        if url.isFileURL {
            let p = url.path
            let runnable = FileManager.default.isExecutableFile(atPath: p) && !FileManager.default.fileExists(atPath: p + "/.")
            if runnable || ["app", "command", "tool", "pkg", "dmg", "sh", "terminal"].contains(url.pathExtension.lowercased()) {
                NSWorkspace.shared.activateFileViewerSelecting([url]); return
            }
        }
        NSWorkspace.shared.open(url)
    }

    static func openFolder() {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: directory))
    }
}

// MARK: Pane chips

extension PaneView {
    /// Plugin chips in the status row (after Anser's own).
    func refreshPluginChips() {
        var items = PluginHost.shared.chips(for: self)
        let waiting = PluginHost.shared.untrusted(for: self)
        if !waiting.isEmpty {
            items.insert(("__review", PluginOutput.Chip(text: "\(waiting.count) project plugin\(waiting.count == 1 ? "" : "s")", color: "orange",
                                                        tooltip: "This repo comes with plugins (.anser/plugins). They run only after you review and trust them.")), at: 0)
        }
        let t = theme
        while pluginChipViews.count < items.count {
            let c = ChipView()
            bar.addSubview(c)
            pluginChipViews.append(c)
        }
        for (i, view) in pluginChipViews.enumerated() {
            guard i < items.count else { view.set(symbol: nil, text: "", color: t.dim); view.onClick = nil; continue }
            let chip = items[i].chip
            let color = TabBarView.color(chip.color) ?? t.foreground.withAlphaComponent(0.7)
            view.set(symbol: "puzzlepiece.extension", text: chip.text, color: color,
                     tooltip: (chip.tooltip ?? chip.text) + (chip.run.map { "\nClick to run: \($0)" } ?? "") + "\nFrom plugin \(items[i].key.split(separator: "/").first ?? "")")
            let key = items[i].key
            view.onClick = { [weak self] in
                guard let self else { return }
                if key == "__review" { PluginHost.shared.review(PluginHost.shared.untrusted(for: self), for: self); return }
                if let cmd = chip.run {
                    if self.session.atPrompt { self.submitFromEditor(cmd) } else { self.flash("Wait for the running command to finish") }
                } else if let o = chip.open, let url = PluginOutput.safeToOpen(o) {
                    PluginHost.open(url)
                }
            }
        }
    }
}
