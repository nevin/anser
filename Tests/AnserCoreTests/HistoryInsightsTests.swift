import Foundation
import XCTest
@testable import AnserCore

final class HistoryInsightsTests: XCTestCase {
    func entry(_ cmd: String, _ ago: Double, cwd: String? = "/p", branch: String? = nil, exit: Int? = 0, duration: Double? = 1) -> HistoryEntry {
        HistoryEntry(id: 0, command: cmd, cwd: cwd, session: nil, started: Date().addingTimeInterval(-ago), duration: duration, exitCode: exit, branch: branch)
    }

    func testSummary() {
        let runs = [entry("make", 10, cwd: "/a", branch: "main", exit: 0, duration: 2),
                    entry("make", 20, cwd: "/a", branch: "main", exit: 1, duration: 4),
                    entry("make", 30, cwd: "/b", branch: "dev", exit: 0, duration: 9),
                    entry("make", 40, cwd: "/a", exit: nil, duration: nil)]
        let s = HistoryInsights.summary(of: runs)
        XCTAssertEqual(s.runs, 4)
        XCTAssertEqual(s.finished, 3)
        XCTAssertEqual(s.failed, 1)
        XCTAssertEqual(s.successRate!, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(s.typical, 4)
        XCTAssertEqual(s.folders, [.init("/a", 3), .init("/b", 1)])
        XCTAssertEqual(s.branches, [.init("main", 2), .init("dev", 1)])
        XCTAssertNil(HistoryInsights.summary(of: []).successRate)
    }

    func testTopCommandsAndPerDay() {
        let now = Date()
        let cmds = [HistoryCommand(command: "ls", count: 3, lastUsed: now, lastCwd: nil, lastExit: 0, cwds: []),
                    HistoryCommand(command: "git status", count: 9, lastUsed: now, lastCwd: nil, lastExit: 0, cwds: [])]
        XCTAssertEqual(HistoryInsights.topCommands(cmds, limit: 1), [.init("git status", 9)])
        let days = HistoryInsights.perDay([now, now, now.addingTimeInterval(-86400), now.addingTimeInterval(-86400 * 40)], days: 7, now: now)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.last, 2)
        XCTAssertEqual(days[5], 1)
        XCTAssertEqual(days.reduce(0, +), 3)
    }

    func testRunDates() throws {
        let path = NSTemporaryDirectory() + "insights-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let h = HistoryStore(path: path)
        h.recordStart(command: "a", cwd: nil, session: nil, at: Date())
        h.recordStart(command: "b", cwd: nil, session: nil, at: Date())
        h.recordStart(command: "a", cwd: nil, session: nil, at: Date().addingTimeInterval(-86400 * 60))
        let since = Date().addingTimeInterval(-86400 * 30)
        XCTAssertEqual(h.runDates(since: since).count, 2)
        XCTAssertEqual(h.runDates(command: "a", since: since).count, 1)
    }
}
