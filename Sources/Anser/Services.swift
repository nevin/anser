import AppKit
import AnserCore
import UserNotifications

/// App-wide shared state: history, completion, config, clipboard history.
final class Services {
    static let shared = Services()

    let history = HistoryStore(path: HistoryStore.defaultPath)
    private(set) var specs = SpecRegistry()
    private(set) var engine: CompletionEngine
    private(set) var config = AnserConfig()
    private(set) var configError: String?
    let clipboard = ClipboardHistory()
    /// AI help. The key comes from the Keychain (or ANTHROPIC_API_KEY when launched from a shell).
    var ai = AIHelp(apiKey: { KeychainStore.get() ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] })
    /// Tests can force AI help on without touching the user's settings.
    var aiForcedOn = false
    var aiEnabled: Bool { aiForcedOn || config.aiEnabled }

    private init() {
        engine = CompletionEngine(specs: specs, history: history)
    }

    func start() {
        loadConfig()
        let history = self.history
        DispatchQueue.global(qos: .utility).async { history.importShellHistoryIfNeeded() }
        clipboard.start(limit: config.clipboardHistorySize)
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
        engine.snippets = config.snippets.map { ($0.name, $0.command) }
        clipboard.limit = config.clipboardHistorySize
        HelpParser.shared.allow(config.helpCommands)
        if let e = configError ?? registry.loadErrors.first { NSLog("Anser config: \(e)") }
    }

    // MARK: Notifications

    private var askedForNotifications = false

    func notifyCommandFinished(_ command: String, exitCode: Int, duration: Double) {
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = exitCode == 0 ? "Command finished" : "Command failed (exit \(exitCode))"
            content.body = "\(command)\nTook \(Self.formatDuration(duration))"
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

/// Watches the system clipboard and remembers recent text items.
final class ClipboardHistory {
    private(set) var items: [(text: String, date: Date)] = []
    var limit = 50
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start(limit: Int) {
        self.limit = limit
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // Respect apps that mark items as secret (password managers).
        let types = pb.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return }
        guard let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items.removeAll { $0.text == s }
        items.insert((s, Date()), at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    func remove(_ text: String) { items.removeAll { $0.text == text } }
}
