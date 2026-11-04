import Foundation
import XCTest
@testable import AnserCore

/// Timing checks with a large history. Each budget is per operation, and is
/// what has to fit between two keystrokes without lag.
final class PerformanceTests: XCTestCase {
    static var store: HistoryStore!
    static var path = ""

    override class func setUp() {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).sqlite").path
        let seed = HistoryStore(path: path)
        let verbs = ["git status", "git commit -m", "npm run", "docker compose up", "kubectl get pods -n", "cd ~/dev/project", "ls -la", "make build", "cargo test", "python3 manage.py"]
        for i in 0..<60_000 {
            seed.recordStart(command: "\(verbs[i % verbs.count]) arg\(i)", cwd: "/repo/\(i % 40)", session: "s\(i % 7)",
                             at: Date().addingTimeInterval(-Double(60_000 - i) * 30))
        }
        store = seed
    }

    override class func tearDown() { try? FileManager.default.removeItem(atPath: path) }

    /// Budgets are for release builds (what ships). Debug code is 10–40× slower,
    /// so debug runs get looser limits. Real numbers: swift test -c release --filter PerformanceTests
    #if DEBUG
    static let slack = 15.0
    #else
    static let slack = 1.0
    #endif

    func time(_ label: String, _ budgetMs: Double, runs: Int = 20, _ body: () -> Void) {
        let budgetMs = budgetMs * Self.slack
        body() // warm up
        let start = Date()
        for _ in 0..<runs { body() }
        let ms = Date().timeIntervalSince(start) * 1000 / Double(runs)
        print(String(format: "PERF %@: %.2f ms (budget %.0f ms)", label, ms, budgetMs))
        XCTAssertLessThan(ms, budgetMs, label)
    }

    func testOpenLargeHistory() {
        let start = Date()
        let h = HistoryStore(path: Self.path)
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "PERF open 60k history: %.1f ms", ms))
        XCTAssertEqual(h.commandCount, 60_000)
        XCTAssertLessThan(ms, 1500)
    }

    func testGhostSuggestion() { time("ghost suggestion", 2) { _ = Self.store.suggestion(forPrefix: "git com", cwd: "/repo/3") } }
    func testUpArrowHistory() { time("↑ history prefix list", 5) { _ = Self.store.recentCommands(withPrefix: "npm") } }
    func testFuzzySearch() { time("⌘R fuzzy search", 60, runs: 5) { _ = Self.store.search("dcu", scope: .all, cwd: "/repo/3") } }
    func testNameFrequency() { time("command name frequency", 2) { _ = Self.store.commandNameFrequency() } }

    func testCompletionKeystroke() async {
        let specs = SpecRegistry(); specs.loadBuiltins()
        let engine = CompletionEngine(specs: specs, history: Self.store)
        let env = ShellEnvironment()
        let ctx = CompletionContext(line: "gi", cursor: 2, cwd: "/tmp")
        _ = await engine.complete(ctx, env: env)
        let start = Date()
        for _ in 0..<10 { _ = await engine.complete(ctx, env: env) }
        let ms = Date().timeIntervalSince(start) * 100
        print(String(format: "PERF completion (command position): %.2f ms", ms))
        XCTAssertLessThan(ms, 40 * Self.slack)
    }

    func testHighlightLongCommand() {
        let line = String(repeating: "git commit -m 'msg' && ls -la /tmp | grep foo; ", count: 40)
        time("highlight 2KB command", 15) { _ = Highlighter.highlight(line, cwd: "/tmp", env: ShellEnvironment()) }
    }
}
