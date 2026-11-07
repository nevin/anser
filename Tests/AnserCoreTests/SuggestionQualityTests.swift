import Foundation
import XCTest
@testable import AnserCore

final class SuggestionQualityTests: XCTestCase {
    var dir: URL!
    var history: HistoryStore!
    var engine: CompletionEngine!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("anser-sq-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        history = HistoryStore(path: dir.appendingPathComponent("h.sqlite").path)
        let specs = SpecRegistry()
        specs.loadBuiltins()
        engine = CompletionEngine(specs: specs, history: history)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func ran(_ cmd: String, exit: Int, times: Int = 1) {
        for _ in 0..<times {
            let id = history.recordStart(command: cmd, cwd: dir.path, session: "s")
            history.recordFinish(id: id, exitCode: exit, duration: 0.1)
        }
    }

    private func complete(_ line: String) async -> [Completion] {
        await engine.complete(CompletionContext(line: line, cursor: line.utf16.count, cwd: dir.path), env: ShellEnvironment())
    }

    func testTyposAreNotSuggested() async {
        ran("git commit -m 'works'", exit: 0)
        ran("git commmit -m 'typo'", exit: 1)      // unknown git subcommand
        ran("gti status", exit: 127)                 // command not found
        let lines = await complete("git com").filter { $0.kind == .history }.map(\.insert)
        XCTAssertEqual(lines, ["git commit -m 'works'"])
        XCTAssertNil(history.suggestion(forPrefix: "gti", cwd: nil), "ghost text skips 'not found'")
        XCTAssertNil(history.suggestion(forPrefix: "git commm", cwd: nil), "ghost text skips one-off failures")
    }

    /// Imported history has no exit codes: an unknown subcommand might be an alias, so it's kept but ranked last.
    func testImportedUnknownSubcommandGoesLast() async {
        _ = history.recordStart(command: "git co main", cwd: dir.path, session: "s")       // no exit recorded
        _ = history.recordStart(command: "git commmit -m x", cwd: dir.path, session: "s")
        ran("git checkout main", exit: 0)
        let lines = await complete("git c").filter { $0.kind == .history }.map(\.insert)
        XCTAssertEqual(lines.first, "git checkout main")
        XCTAssertTrue(lines.contains("git co main"))
    }

    func testRepeatedFailuresRankBelowSuccesses() async {
        ran("make test-unit", exit: 2, times: 3)     // a real command that's failing lately
        ran("make test-all", exit: 0)
        let hist = await complete("make te").filter { $0.kind == .history }
        XCTAssertEqual(hist.map(\.insert), ["make test-all", "make test-unit"])
        XCTAssertEqual(hist.last?.detail, "history · failed")
    }

    func testTypedSubcommandComesBeforeHistory() async {
        ran("git commit -m 'one'", exit: 0)
        ran("git commit -m 'two'", exit: 0)
        let all = await complete("git com")
        XCTAssertEqual(all.first?.kind, .subcommand)
        XCTAssertEqual(all.first?.insert, "commit")
    }

    func testRelativeTimes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ s: Double) -> String { RelativeTime.format(now.addingTimeInterval(-s), now: now) }
        XCTAssertEqual(ago(0), "just now")
        XCTAssertEqual(ago(59), "just now")
        XCTAssertEqual(ago(5 * 60), "5 min ago")
        XCTAssertEqual(ago(3 * 3600), "3 hr ago")
        XCTAssertEqual(ago(4 * 86400), "4 days ago")
        XCTAssertEqual(ago(15 * 86400), "2 wk ago")
        XCTAssertEqual(RelativeTime.format(unix: "\(Int(now.timeIntervalSince1970) - 120)", now: now), "2 min ago")
        XCTAssertNil(RelativeTime.format(unix: "soon"))
    }
}
