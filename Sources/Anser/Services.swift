import AppKit
import AnserCore
import UserNotifications

/// App-wide shared state: history, completion, config, clipboard history.
final class Services {
    static let shared = Services()

    /// The self-test gets its own throwaway history, so test commands never reach yours.
    let history = HistoryStore(path: Services.isSelfTest
        ? NSTemporaryDirectory() + "anser-selftest-history-\(ProcessInfo.processInfo.processIdentifier).sqlite"
        : HistoryStore.defaultPath)
    private(set) var specs = SpecRegistry()
    private(set) var engine: CompletionEngine
    private(set) var config = AnserConfig()
    private(set) var configError: String?
    let clipboard = ClipboardHistory()
    /// AI help from the provider chosen in Settings → AI. Claude's key comes from the Keychain
    /// (or ANTHROPIC_API_KEY when launched from a shell); Copilot uses its own sign-in.
    var ai: AIHelp {
        get {
            if let aiOverride { return aiOverride }
            if config.aiProvider == AIHelp.Provider.copilot.rawValue { return AIHelp(model: config.copilotModel) }
            if config.aiProvider == AIHelp.Provider.ollama.rawValue {
                return AIHelp(ollamaURL: config.ollamaURL.flatMap(URL.init(string:)), ollamaModel: config.ollamaModel)
            }
            return AIHelp(apiKey: { KeychainStore.get() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] })
        }
        set { aiOverride = newValue }
    }
    /// Set by tests to fake the AI.
    var aiOverride: AIHelp?
    var aiName: String { ai.provider.displayName }
    /// Tests can force AI help on without touching the user's settings.
    var aiForcedOn = false
    var aiEnabled: Bool { aiForcedOn || config.aiEnabled }

    private init() {
        engine = CompletionEngine(specs: specs, history: history)
    }

    static var isSelfTest: Bool { ProcessInfo.processInfo.environment["ANSER_SELFTEST"] != nil }

    func start() {
        loadConfig()
        if !Self.isSelfTest { prepareNotebook(); watchNotebook() }
        let history = self.history
        if !Self.isSelfTest { DispatchQueue.global(qos: .utility).async { history.importShellHistoryIfNeeded() } }
        clipboard.start(limit: config.clipboardHistorySize)
        MemoryManager.shared.start()
    }

    func loadConfig() {
        (config, configError) = AnserConfig.load()
        let registry = SpecRegistry()
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("Specs"), FileManager.default.fileExists(atPath: dir.path) {
            registry.load(directory: dir)
        } else {
            registry.loadBuiltins()
        }
        registry.load(directory: AnserConfig.completionsDirectory)
        specs = registry
        engine = CompletionEngine(specs: registry, history: history)
        if !Self.isSelfTest {
            let url = Self.notebookURL(for: config.notebookLocation)
            if url != NotebookWindow.fileURL { NotebookWindow.fileURL = url; watchNotebook() }
        }
        refreshSnippets()
        clipboard.limit = config.clipboardHistorySize
        HelpParser.shared.allow(config.helpCommands)
        if let e = configError ?? registry.loadErrors.first { NSLog("Anser config: \(e)") }
    }

    // MARK: Command Notebook

    /// The notebook file for a `notebookLocation` setting: nil = ~/.config/anser,
    /// "icloud" = iCloud Drive/Anser, otherwise a folder (or a .json file path).
    static func notebookURL(for location: String?) -> URL {
        guard let loc = location?.trimmingCharacters(in: .whitespaces), !loc.isEmpty else { return Notebook.defaultURL }
        if loc.lowercased() == "icloud" { return iCloudFolder.appendingPathComponent("notebook.json") }
        let path = (loc as NSString).expandingTildeInPath
        return path.hasSuffix(".json") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path).appendingPathComponent("notebook.json")
    }

    static var iCloudFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Anser")
    }
    static var iCloudAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudFolder.deletingLastPathComponent().path)
    }

    /// First run: start with a few examples. After that, copy config.json snippets in once.
    func prepareNotebook() {
        let url = NotebookWindow.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            var nb = Notebook.starter
            nb.importedSnippets = false
            nb.importSnippets(config.snippets)
            try? nb.save(to: url)
        } else if var nb = try? Notebook.load(from: url), nb.importSnippets(config.snippets) {
            try? nb.save(to: url)
        }
        refreshSnippets()
    }

    /// Saved commands, for completion and the palette.
    private(set) var notebookEntries: [Notebook.Entry] = []

    /// Completion offers the notebook's named commands (and any config.json snippets).
    func refreshSnippets() {
        notebookEntries = ((try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook()).allEntries
        var seen = Set<String>()
        var list: [CompletionEngine.Snippet] = []
        for e in notebookEntries where !e.title.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert(e.command).inserted {
            list.append(CompletionEngine.Snippet(name: e.title, command: e.command))
        }
        for s in config.snippets where seen.insert(s.command).inserted { list.append(CompletionEngine.Snippet(name: s.name, command: s.command)) }
        engine.snippets = list
    }

    private var notebookWatcher: DispatchSourceFileSystemObject?
    private var notebookStamp: Date?

    /// Notices when the notebook file changes outside Anser (iCloud, git pull,
    /// another Mac) and reloads it everywhere.
    func watchNotebook() {
        notebookWatcher?.cancel()
        notebookWatcher = nil
        guard !Self.isSelfTest else { return }
        let dir = NotebookWindow.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        notebookStamp = Self.modified(NotebookWindow.fileURL)
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let stamp = Self.modified(NotebookWindow.fileURL)
            guard stamp != self.notebookStamp else { return }
            self.notebookStamp = stamp
            self.refreshSnippets()
            MainActor.assumeIsolated { NotebookWindow.shared.reloadIfIdle() }
            NotificationCenter.default.post(name: .anserNotebookChanged, object: nil)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        notebookWatcher = src
    }

    /// Call after Anser itself saves the notebook, so the watcher doesn't treat it as outside.
    func notebookSaved() {
        notebookStamp = Self.modified(NotebookWindow.fileURL)
        refreshSnippets()
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Tips and usage

    private(set) var tips: TipEngine = {
        guard let d = UserDefaults.standard.data(forKey: "AnserTips"),
              let s = try? JSONDecoder().decode(TipEngine.State.self, from: d) else { return TipEngine() }
        return TipEngine(state: s)
    }()

    /// Runs a tip rule and shows the tip (if any) in `pane`. Tips follow the "Keyboard tips" setting.
    func tip(in pane: PaneView?, _ rule: (inout TipEngine) -> TipEngine.Tip?) {
        guard config.keyTips != "never", !Self.isSelfTest || tipsForcedOn else { return }
        let before = tips.state
        let t = rule(&tips)
        if tips.state != before, !Self.isSelfTest, let d = try? JSONEncoder().encode(tips.state) { UserDefaults.standard.set(d, forKey: "AnserTips") }
        if let t, let pane { pane.showTip(t.text) ; record("tip.\(t.id)") }
    }
    /// Tests turn tips on and reset them.
    var tipsForcedOn = false
    func resetTipsForTest() { tips = TipEngine(); tips.spacing = 0 }

    private(set) var usage = UsageStats.load()
    private var usageSaveScheduled = false

    /// Counts a feature use, only on this Mac, only when usage stats are on.
    func record(_ feature: String) {
        guard config.usageStats, !Self.isSelfTest else { return }
        usage.record(feature)
        guard !usageSaveScheduled else { return }
        usageSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.usageSaveScheduled = false
            self.usage.prune()
            self.usage.save()
        }
    }

    func clearUsage() { usage = UsageStats(); usage.save() }

    /// Tests turn vim keys on without touching the user's config file.
    func setVimForTest(_ on: Bool) { config.editor.vimMode = on }

    /// Exercise optional editor following without changing the config file.
    func setEditorFollowsOutputForTest(_ on: Bool) { config.editorFollowsOutput = on }

    /// Tests set profiles without touching the user's config file.
    func setProfilesForTest(_ p: [Profile]) { config.profiles = p }

    // MARK: Notifications

    private var askedForNotifications = false

    func notifyCommandFinished(_ command: String, exitCode: Int, duration: Double, sessionID: String? = nil) {
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = exitCode == 0 ? "Command finished" : "Command failed (exit \(exitCode))"
            content.body = "\(command)\nTook \(Self.formatDuration(duration))"
            if let sessionID { content.userInfo = ["session": sessionID] }
            content.sound = exitCode == 0 ? nil : .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if askedForNotifications { post(); return }
        askedForNotifications = true
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in if ok { post() } }
    }

    static func formatDuration(_ d: Double) -> String {
        if d < 1 { return String(format: "%.0fms", d * 1000) }
        if d < 60 { return String(format: "%.1fs", d) }
        let m = Int(d) / 60, s = Int(d) % 60
        if m < 60 { return "\(m)m \(s)s" }
        return "\(m / 60)h \(m % 60)m"
    }
}

/// Keeps Anser's memory in check: hands freed memory back to macOS after big
/// output, closed tabs and while idle in the background, and trims what Anser
/// keeps when macOS reports memory pressure.
final class MemoryManager {
    static let shared = MemoryManager()
    private var pressureSource: DispatchSourceMemoryPressure?
    private var releaseScheduled = false
    private(set) var pressureEvents = 0

    func start() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in self?.trim(critical: src.data.contains(.critical)) }
        src.resume()
        pressureSource = src
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.releaseSoon(after: 10)
        }
    }

    /// Hands freed memory back to macOS shortly (calls close together are merged).
    func releaseSoon(after delay: TimeInterval = 2) {
        guard !releaseScheduled else { return }
        releaseScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.releaseScheduled = false
            DispatchQueue.global(qos: .utility).async { MemoryUse.releaseFreed() }
        }
    }

    /// macOS is short of memory: keep much less, drop caches, give memory back.
    func trim(critical: Bool) {
        pressureEvents += 1
        let before = MemoryUse.footprint().current
        for p in AppDelegate.shared.allPanes {
            p.session.outputBudget = .tight
            p.session.applyOutputBudget()
        }
        ScriptRunner.shared.forgetAll()
        Services.shared.clipboard.trim(to: critical ? 5 : 15)
        URLCache.shared.removeAllCachedResponses()
        MemoryUse.releaseFreed()
        let after = MemoryUse.footprint().current
        Diagnostics.shared.log("memory pressure (\(critical ? "critical" : "warning")): \(MemoryUse.megabytes(before)) → \(MemoryUse.megabytes(after))")
        // Back to normal limits for new output once things calm down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            for p in AppDelegate.shared.allPanes { p.session.outputBudget = .standard }
        }
    }
}

/// Watches the system clipboard and remembers recent text items.
final class ClipboardHistory {
    private(set) var items: [(text: String, date: Date)] = []
    var limit = 50
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start(limit: Int) {
        self.limit = limit
        schedule(every: Self.foregroundInterval)
        // Check less often while Anser is in the background (fewer wake-ups, less battery);
        // check right away when you come back.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.schedule(every: Self.backgroundInterval)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.poll()
            self?.schedule(every: Self.foregroundInterval)
        }
    }

    private(set) var interval: TimeInterval = 0
    private func schedule(every seconds: TimeInterval) {
        guard seconds != interval else { return }
        interval = seconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = seconds * 0.4
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // Respect apps that mark items as secret (password managers).
        let types = pb.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return }
        guard let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Huge copies (a whole log) aren't kept: pasting a cut-down version would be wrong.
        guard s.utf8.count <= Self.maxItemBytes else { return }
        items.removeAll { $0.text == s }
        items.insert((s, Date()), at: 0)
        trim(to: limit)
    }

    /// How often the clipboard is checked: copies made in other apps are caught
    /// within a few seconds, and one made in Anser is seen when you come back anyway.
    static let foregroundInterval: TimeInterval = 1
    static let backgroundInterval: TimeInterval = 3
    static let maxItemBytes = 1 << 20
    static let maxTotalBytes = 16 << 20

    /// Keeps at most `count` items and 16 MB in all.
    func trim(to count: Int) {
        if items.count > count { items.removeLast(items.count - count) }
        var total = items.reduce(0) { $0 + $1.text.utf8.count }
        while total > Self.maxTotalBytes, let last = items.last {
            total -= last.text.utf8.count
            items.removeLast()
        }
    }

    func remove(_ text: String) { items.removeAll { $0.text == text } }
}
