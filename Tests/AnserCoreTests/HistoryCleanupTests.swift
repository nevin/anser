import Foundation
import XCTest
@testable import AnserCore

final class HistoryCleanupTests: XCTestCase {
    func c(_ cmd: String, _ n: Int = 1, exit: Int? = 0) -> HistoryCommand {
        HistoryCommand(command: cmd, count: n, lastUsed: Date(), lastCwd: nil, lastExit: exit, cwds: [])
    }
    let known: Set<String> = ["git", "ls", "docker", "npm", "kubectl", "pwd", "clear", "cd", "make"]
    func issue(_ h: HistoryCommand) -> HistoryCleanup.Issue? {
        HistoryCleanup.issue(for: h, isKnown: { self.known.contains($0) }, closest: { HistoryCleanup.closest(to: $0, in: Array(self.known)) })
    }

    func testFindsMistakes() {
        XCTAssertEqual(issue(c("gti status", exit: 127)), .typo(of: "git"))
        XCTAssertEqual(issue(c("zzqx run", exit: 127)), .notFound, "nothing close to suggest")
        XCTAssertNil(issue(c("git status -sb", 3, exit: 127)), "a fixed typo keeps its old exit code")
        XCTAssertNil(issue(c("git status -sb", 1, exit: 127)))
        XCTAssertEqual(issue(c("gti status", exit: nil)), .typo(of: "git"), "imported history has no exit codes")
        XCTAssertEqual(issue(c("dokcer ps", 2, exit: 127)), .typo(of: "docker"))
        XCTAssertEqual(issue(c("nm run biuld", 1, exit: 1)), .failedOnce(exit: 1), "the program ran, so its name isn't a typo")
        XCTAssertEqual(issue(c("npm run biuld", exit: 1)), .failedOnce(exit: 1))
        XCTAssertEqual(issue(c("ls")), .trivial)
        XCTAssertEqual(issue(c("cd ..", 30)), .trivial)
        XCTAssertNil(issue(c("git status --short", 5)))
        XCTAssertNil(issue(c("make build", 1, exit: 130)), "stopped with ⌃C isn't a mistake")
        XCTAssertNil(issue(c("./run.sh --fast", 1, exit: 0)), "paths aren't checked")
        XCTAssertNil(issue(c("terraform plan", 10, exit: 0)), "a tool you use that isn't installed here")
        XCTAssertFalse(HistoryCleanup.Issue.trivial.isMistake)
    }

    func testDistance() {
        XCTAssertEqual(HistoryCleanup.distance("gti", "git"), 1)
        XCTAssertEqual(HistoryCleanup.distance("dokcer", "docker"), 1)
        XCTAssertEqual(HistoryCleanup.distance("kubeclt", "kubectl"), 1)
        XCTAssertEqual(HistoryCleanup.distance("abc", "xyz"), 3)
        XCTAssertEqual(HistoryCleanup.closest(to: "sl", in: ["ls", "sh"], frequency: ["ls": 50]), "ls")
        XCTAssertNil(HistoryCleanup.closest(to: "foo", in: ["git", "ls"]))
    }

    func testCompactAndDelete() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("anser-hist-\(UUID().uuidString).sqlite").path
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let h = HistoryStore(path: path)
        let now = Date()
        for i in 0..<30 { h.recordStart(command: "git status", cwd: "/p", session: "s", at: now.addingTimeInterval(Double(-i * 60))) }
        let old = h.recordStart(command: "ancient-tool --x", cwd: "/p", session: "s", at: now.addingTimeInterval(-400 * 86400))
        h.saveOutput("old output", forHistoryID: old)
        let recent = h.recordStart(command: "make", cwd: "/p", session: "s", at: now.addingTimeInterval(-3 * 86400))
        h.saveOutput("recent output", forHistoryID: recent)
        h.recordStart(command: "gti status", cwd: "/p", session: "s", at: now)
        XCTAssertEqual(h.runCount, 33)

        let r = h.compact(.init(keepRunsPerCommand: 5, unusedForDays: 365, outputOlderThanDays: 1, removeCommands: ["gti status"]), now: now)
        XCTAssertEqual(h.stats(for: "git status")?.count, 5)
        XCTAssertNil(h.stats(for: "ancient-tool --x"))
        XCTAssertNil(h.stats(for: "gti status"))
        XCTAssertEqual(h.runCount, 6)
        XCTAssertEqual(r.runsRemoved, 27)
        XCTAssertEqual(r.commandsRemoved, 2)
        XCTAssertNil(h.output(forHistoryID: recent), "output older than a day is dropped")
        XCTAssertGreaterThan(r.bytesBefore, 0)

        h.delete(commands: ["git status", "make"])
        XCTAssertEqual(h.runCount, 0)
        XCTAssertTrue(h.allCommands().isEmpty)
        XCTAssertNil(h.suggestion(forPrefix: "git", cwd: nil))
    }
}

final class HistoryToNotebookTests: XCTestCase {
    func testNotebookFromHistory() {
        var nb = Notebook()
        XCTAssertEqual(nb.addFromHistory([("git log --oneline", "Short log"), ("make test", "")], toGroupNamed: "From history"), 2)
        XCTAssertEqual(nb.addFromHistory([("make test", "again"), ("  git log --oneline ", "")], toGroupNamed: "General"), 0, "already saved")
        XCTAssertTrue(nb.contains(command: "make test"))
        let g = nb.groups.first { $0.name == "From history" }
        XCTAssertEqual(g?.entries.map(\.displayTitle), ["Short log", "make test"])
    }

    func testRunsAndRename() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("anser-h3-\(UUID().uuidString).sqlite").path
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        let h = HistoryStore(path: path)
        let a = h.recordStart(command: "gti push", cwd: "/a", session: "s", at: Date().addingTimeInterval(-60))
        h.recordFinish(id: a, exitCode: 1, duration: 0.2)
        h.recordStart(command: "gti push", cwd: "/b", session: "s")
        h.recordStart(command: "git push", cwd: "/c", session: "s")
        XCTAssertEqual(h.runs(of: "gti push").map(\.cwd), ["/b", "/a"])
        h.rename(command: "gti push", to: "git push")
        XCTAssertNil(h.stats(for: "gti push"))
        XCTAssertEqual(h.stats(for: "git push")?.count, 3, "merged into the existing command")
        XCTAssertEqual(h.suggestion(forPrefix: "gi", cwd: nil), "git push")
    }
}
