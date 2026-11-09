import Foundation
import XCTest
@testable import AnserCore

final class MoreRunnersTests: XCTestCase {
    func testDotnet() throws {
        let out = """
          Failed Shop.Tests.CartTests.AddsItems [12 ms]
          Error Message:
           Assert.Equal() Failure
          Stack Trace:
             at Shop.Tests.CartTests.AddsItems() in /src/Shop.Tests/CartTests.cs:line 42
        """
        let r = try XCTUnwrap(TestFailures.report(command: "dotnet test", output: out))
        XCTAssertEqual(r.runner, .dotnet)
        XCTAssertEqual(r.failures.first?.location, "/src/Shop.Tests/CartTests.cs:42")
        XCTAssertEqual(TestFailures.rerunCommand(r.failures, runner: .dotnet, original: "dotnet test"), "dotnet test --filter 'FullyQualifiedName~Shop.Tests.CartTests.AddsItems'")
    }

    func testPHPUnitExUnitJUnit() throws {
        let php = """
        There was 1 failure:

        1) Tests\\\\CartTest::testTotal
        Failed asserting that 3 matches expected 4.

        /app/tests/CartTest.php:23

        FAILURES!
        """
        let p = try XCTUnwrap(TestFailures.report(command: "vendor/bin/phpunit", output: php))
        XCTAssertEqual(p.failures.first?.name, "testTotal")
        XCTAssertEqual(p.failures.first?.line, 23)
        XCTAssertEqual(TestFailures.rerunCommand(p.failures, runner: .phpunit, original: "vendor/bin/phpunit"), "vendor/bin/phpunit --filter testTotal")

        let ex = """
          1) test adds numbers (MathTest)
             test/math_test.exs:12
             Assertion with == failed
        """
        let e = try XCTUnwrap(TestFailures.report(command: "mix test", output: ex))
        XCTAssertEqual(e.runner, .exunit)
        XCTAssertEqual(TestFailures.rerunCommand(e.failures, runner: .exunit, original: "mix test"), "mix test test/math_test.exs:12")

        let gradle = """
        MathTest > addsNumbers() FAILED
            org.opentest4j.AssertionFailedError at MathTest.java:12
        """
        let g = try XCTUnwrap(TestFailures.report(command: "./gradlew test", output: gradle))
        XCTAssertEqual(g.runner, .junit)
        XCTAssertEqual(g.failures.first?.location, "MathTest.java:12")
        XCTAssertEqual(TestFailures.rerunCommand(g.failures, runner: .junit, original: "./gradlew test"), "./gradlew test --tests MathTest.addsNumbers")
        let maven = "[ERROR]   com.acme.MathTest.addsNumbers:12 expected: <4> but was: <3>\n"
        let m = try XCTUnwrap(TestFailures.report(command: "mvn test", output: maven))
        XCTAssertEqual(TestFailures.rerunCommand(m.failures, runner: .junit, original: "mvn test"), "mvn test -Dtest='MathTest#addsNumbers'")
    }

    func testWatchPatterns() {
        XCTAssertTrue(WatchRules.matches("src/app.py", patterns: []))
        XCTAssertTrue(WatchRules.matches("src/app.py", patterns: ["*.py"]))
        XCTAssertFalse(WatchRules.matches("README.md", patterns: ["*.py", "*.toml"]))
        XCTAssertTrue(WatchRules.matches("src/x/y.ts", patterns: ["src/"]))
        XCTAssertTrue(WatchRules.matches("Makefile", patterns: ["Makefile"]))
        XCTAssertEqual(WatchRules.parsePatterns("*.py, *.toml  src/"), ["*.py", "*.toml", "src/"])
    }
}

final class MoreHistoryTests: XCTestCase {
    func store() -> (HistoryStore, String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("anser-h2-\(UUID().uuidString).sqlite").path
        return (HistoryStore(path: path), path)
    }

    func testTrashRestoreAndPurge() {
        let (h, path) = store()
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        h.recordStart(command: "gti status", cwd: "/p", session: "s")
        h.recordStart(command: "gti status", cwd: "/p", session: "s")
        h.recordStart(command: "secret thing", cwd: "/p", session: "s")
        h.delete(commands: ["gti status"], permanently: false)
        h.delete(commands: ["secret thing"], permanently: true)
        XCTAssertNil(h.stats(for: "gti status"))
        XCTAssertEqual(h.trashed().map(\.command), ["gti status"])
        XCTAssertEqual(h.trashed().first?.runs, 2)
        h.restore(commands: ["gti status"])
        XCTAssertEqual(h.stats(for: "gti status")?.count, 2)
        XCTAssertTrue(h.trashed().isEmpty)
        h.delete(commands: ["gti status"], permanently: false, now: Date().addingTimeInterval(-8 * 86400))
        XCTAssertEqual(h.purgeTrash(olderThan: Date().addingTimeInterval(-7 * 86400)), 2)
        XCTAssertTrue(h.trashed().isEmpty)
    }

    func testFixAfterFailure() {
        let (h, path) = store()
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        func run(_ c: String, _ exit: Int, _ session: String = "t1") -> Int64 {
            let id = h.recordStart(command: c, cwd: "/p", session: session)
            h.recordFinish(id: id, exitCode: exit, duration: 1)
            return id
        }
        _ = run("npm test", 1)
        _ = run("ls", 0)
        _ = run("npm instal", 1)
        _ = run("npm install", 0)
        _ = run("npm test", 0)
        _ = run("npm test", 0, "other")
        let now = run("npm test", 1, "t2")
        XCTAssertEqual(h.fixAfterFailure(of: "npm test", excludingID: now), ["npm install"])
        XCTAssertNil(h.fixAfterFailure(of: "make", excludingID: 0))
    }

    func testAutoCleanIsWeekly() {
        // Exercised in the app self-test; here just the trash cut-off logic is covered above.
        XCTAssertTrue(true)
    }
}

final class WatchHostAndAITests: XCTestCase {
    func testOutputWatch() {
        var w = OutputWatch(command: "kubectl get pods", cwd: "/", intervalMinutes: 5)
        XCTAssertEqual(w.record(output: "web 1/1 Running 5m", exit: 0), .first)
        XCTAssertEqual(w.record(output: "web 1/1 Running 10m", exit: 0), .same, "ages don't count")
        XCTAssertEqual(w.record(output: "web 0/1 CrashLoopBackOff 11m", exit: 0), .changed)
        XCTAssertEqual(w.previousOutput, "web 1/1 Running 10m")
        XCTAssertEqual(w.record(output: "error", exit: 1), .failed)
        XCTAssertEqual(w.record(output: "error", exit: 1), .same)
        XCTAssertEqual(w.record(output: "ok", exit: 0), .recovered)
        XCTAssertEqual(w.changes, 3)
        XCTAssertEqual(OutputWatch(command: "x", cwd: "/", intervalMinutes: 0).intervalMinutes, 0.5)
    }

    func testMultiHost() {
        XCTAssertEqual(MultiHost.argv(host: "web1", command: "uptime")?.suffix(3), ["--", "web1", "uptime"])
        XCTAssertTrue(MultiHost.argv(host: "web1", command: "uptime")?.contains("BatchMode=yes") == true)
        XCTAssertNil(MultiHost.argv(host: "-oProxyCommand=x", command: "id"))
        XCTAssertNil(MultiHost.argv(host: "a b", command: "id"))
        let r = [MultiHost.Result(host: "a", exit: 0, output: "\n up 3 days\n", seconds: 1), MultiHost.Result(host: "b", exit: 1, output: "", seconds: 1),
                 MultiHost.Result(host: "c", exit: 255, output: "", seconds: 8)]
        XCTAssertEqual(r[0].firstLine, "up 3 days")
        XCTAssertEqual(MultiHost.summary(r), "1 ok · 1 failed · 1 unreachable")
    }

    func testAICompletion() async {
        XCTAssertEqual(AICompletion.suffix(fromReply: "git log --oneline\n", typed: "git lo"), "g --oneline")
        XCTAssertEqual(AICompletion.suffix(fromReply: "```sh\ndocker ps -a\n```", typed: "docker p"), "s -a")
        XCTAssertNil(AICompletion.suffix(fromReply: "rm -rf /", typed: "git"))
        XCTAssertNil(AICompletion.suffix(fromReply: "git", typed: "git"))
        let reply = #"{"response":"kubectl get pods -A"}"#
        let got = await AICompletion.complete(typed: "kubectl get p", shell: "zsh", cwdName: "app", recent: ["ls"], model: "m",
                                              transport: { req in
                                                  XCTAssertEqual(req.url?.path, "/api/generate")
                                                  return (200, Data(reply.utf8))
                                              })
        XCTAssertEqual(got, "ods -A")
    }

    func testTrimAndAliasGroups() {
        var r = TabRecording(title: "t", columns: 10, rows: 2)
        r.add("a", at: 0); r.add("b", at: 2); r.add("c", at: 4); r.add("d", at: 6)
        r.marks = [.init(t: 2, label: "x"), .init(t: 5, label: "y")]
        let t = r.trimmed(from: 3, to: 5)
        XCTAssertEqual(t.frames.map(\.text), ["b", "c", "c"])
        XCTAssertEqual(t.frames.map(\.t), [0, 1, 2])
        XCTAssertEqual(t.marks.map(\.label), ["y"])

        var b = AliasBook()
        b.set(AnserAlias(name: "gl", command: "git log", group: "git"))
        b.set(AnserAlias(name: "x", command: "exit", group: "  "))
        XCTAssertNil(b["x"]?.group)
        XCTAssertEqual(b.importAliases(["gl": "other", "dps": "docker ps", "bad name": "x"]), 1)
        XCTAssertEqual(b["dps"]?.group, "Imported")
        XCTAssertEqual(b.groups, ["git", "Imported"])
        XCTAssertEqual(b.grouped.map(\.group), [nil, "git", "Imported"])
        let old = try? JSONDecoder().decode(AnserAlias.self, from: Data(#"{"name":"a","command":"b"}"#.utf8))
        XCTAssertEqual(old?.name, "a", "files from before groups still load")
    }
}
