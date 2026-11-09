import Foundation
import XCTest
@testable import AnserCore

final class AliasTests: XCTestCase {
    func testProblems() {
        XCTAssertNil(AliasStore.problem(name: "glog", command: "git log --oneline"))
        XCTAssertNil(AliasStore.problem(name: "k8s-prod", command: "kubectl --context prod"))
        XCTAssertNotNil(AliasStore.problem(name: "", command: "ls"))
        XCTAssertNotNil(AliasStore.problem(name: "1abc", command: "ls"))
        XCTAssertNotNil(AliasStore.problem(name: "a b", command: "ls"))
        XCTAssertNotNil(AliasStore.problem(name: "x;rm", command: "ls"))
        XCTAssertNotNil(AliasStore.problem(name: "alias", command: "ls"))
        XCTAssertNotNil(AliasStore.problem(name: "x", command: " "))
        XCTAssertNotNil(AliasStore.problem(name: "x", command: "a\nb"))
    }

    func testScriptsQuote() {
        let a = [AnserAlias(name: "say", command: "echo 'hi' $HOME")]
        XCTAssertEqual(AliasStore.script(a, shell: .posix), "alias say='echo '\\''hi'\\'' $HOME'\n")
        XCTAssertEqual(AliasStore.script(a, shell: .fish), "alias say 'echo \\'hi\\' $HOME'\n")
        let old = [AnserAlias(name: "a", command: "ls"), AnserAlias(name: "b", command: "pwd")]
        let new = [AnserAlias(name: "b", command: "pwd -P"), AnserAlias(name: "c", command: "date")]
        let ch = AliasStore.changes(from: old, to: new, shell: .posix)
        XCTAssertTrue(ch.contains("unalias a"))
        XCTAssertTrue(ch.contains("alias b='pwd -P'") && ch.contains("alias c='date'"))
        XCTAssertEqual(AliasStore.changes(from: old, to: old, shell: .posix), "")
        XCTAssertTrue(AliasStore.changes(from: old, to: [], shell: .fish).contains("functions -e a"))
    }

    func testBookAndFiles() throws {
        var b = AliasBook()
        b.set(AnserAlias(name: "zz", command: "ls"))
        b.set(AnserAlias(name: "aa", command: "pwd"))
        b.set(AnserAlias(name: "bb", command: "pwd -P"), replacing: "aa")
        XCTAssertEqual(b.aliases.map(\.name), ["bb", "zz"])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anser-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("aliases.json")
        try AliasStore.save(b, to: url)
        XCTAssertEqual(AliasStore.load(from: url), b)
        let sh = try String(contentsOf: dir.appendingPathComponent("aliases.sh"), encoding: .utf8)
        XCTAssertTrue(sh.contains("alias bb='pwd -P'"))
        // The generated file is valid shell.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-n", dir.appendingPathComponent("aliases.sh").path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testSuggestions() {
        func c(_ cmd: String, _ n: Int, exit: Int? = 0) -> HistoryCommand {
            HistoryCommand(command: cmd, count: n, lastUsed: Date(), lastCwd: nil, lastExit: exit, cwds: [])
        }
        let history = [
            c("git log --oneline --graph --all", 12),
            c("docker compose up -d --build", 6),
            c("git status", 40),                          // short
            c("kubectl get pods -n production", 2),       // rare
            c("npm run build -- --prod", 9, exit: 1),     // fails
            c("curl -H 'Authorization: Bearer abc.def.ghi' https://x", 8), // secret
            c("cd ~/dev/some/project", 20),               // ⌘J does this
            c("ls -la --color=always somewhere", 5),
        ]
        let s = HabitSuggestions.suggest(history, aliases: ["ll": "ls -la --color=always somewhere"], dismissed: [], isTaken: { $0 == "glog" })
        XCTAssertEqual(s.map(\.command), ["git log --oneline --graph --all", "docker compose up -d --build"])
        XCTAssertEqual(s[0].name, "glog2", "glog is taken")
        XCTAssertEqual(s[1].name, "dcu")
        XCTAssertTrue(HabitSuggestions.suggest(history, aliases: [:], dismissed: ["git log --oneline --graph --all"], isTaken: { _ in false })
            .allSatisfy { $0.command != "git log --oneline --graph --all" })
        XCTAssertEqual(HabitSuggestions.name(for: "sudo FOO=1 systemctl restart nginx", isTaken: { _ in false }), "srn")
        XCTAssertEqual(HabitSuggestions.name(for: "git log --oneline", isTaken: { _ in false }), "glog")
        XCTAssertEqual(HabitSuggestions.name(for: "ls -la --color", isTaken: { _ in false }), "llc")
    }
}

final class LogLinesTests: XCTestCase {
    func testJSON() {
        let l = LogLines.parse(#"{"time":"2026-11-08T10:00:00Z","level":"error","msg":"db down","err":{"code":5},"attempt":3}"#)
        XCTAssertEqual(l.level, .error)
        XCTAssertEqual(l.time, "2026-11-08T10:00:00Z")
        XCTAssertEqual(l.message, "db down")
        XCTAssertTrue(l.isJSON)
        XCTAssertEqual(l.fields.map(\.key), ["attempt", "err.code"])
        XCTAssertEqual(LogLines.parse(#"{"level":50,"msg":"pino"}"#).level, .error)
        XCTAssertNotNil(LogLines.prettyJSON(#"{"b":1,"a":[1,2]}"#))
        XCTAssertNil(LogLines.prettyJSON("not json"))
    }

    func testLogfmtAndPlain() {
        let l = LogLines.parse(#"ts=2026-11-08T10:00:00Z level=warn msg="slow query" duration=2.3s"#)
        XCTAssertEqual(l.level, .warn)
        XCTAssertEqual(l.message, "slow query")
        XCTAssertEqual(l.fields.first?.key, "duration")
        let p = LogLines.parse("2026-11-08 10:00:01,123 ERROR [main] Something broke")
        XCTAssertEqual(p.level, .error)
        XCTAssertEqual(p.time, "2026-11-08 10:00:01,123")
        XCTAssertEqual(LogLines.parse("[INFO] server listening on :8080").level, .info)
        XCTAssertEqual(LogLines.parse("E1108 10:00:00.123456   1 controller.go:12] sync failed").level, .error)
        XCTAssertEqual(LogLines.parse("    at Object.<anonymous> (x.js:1:1)").level, .unknown)
        XCTAssertEqual(LogLines.parse("Processed 10 items with 0 errors in a long message that goes on and on and on, ERROR later").level, .unknown)
        let c = LogLines.parse("web-1  | 2026-11-08T10:00:00Z WARN low disk")
        XCTAssertEqual(c.source, "web-1")
        XCTAssertEqual(c.level, .warn)
        XCTAssertEqual(LogLines.parse("[pod/api-7f/app] ERROR boom").source, "api-7f/app")
    }

    func testFollowCommands() {
        XCTAssertTrue(LogLines.isFollowCommand("tail -f /var/log/system.log"))
        XCTAssertTrue(LogLines.isFollowCommand("tail -n 100 -F app.log"))
        XCTAssertTrue(LogLines.isFollowCommand("docker compose logs -f web"))
        XCTAssertTrue(LogLines.isFollowCommand("kubectl logs -f deploy/api"))
        XCTAssertTrue(LogLines.isFollowCommand("journalctl -fu nginx"))
        XCTAssertTrue(LogLines.isFollowCommand("stern api"))
        XCTAssertFalse(LogLines.isFollowCommand("tail -n 20 app.log"))
        XCTAssertFalse(LogLines.isFollowCommand("kubectl apply -f x.yaml"))
        XCTAssertFalse(LogLines.isFollowCommand("ls -f"))
    }

    func testAppended() {
        XCTAssertEqual(LogLines.appended(to: [], from: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(LogLines.appended(to: ["a", "b", "c", "d"], from: ["b", "c", "d", "e", "f"]), ["e", "f"])
        XCTAssertEqual(LogLines.appended(to: ["a", "b", "c", "d"], from: ["c", "d"]), [])
        // The start scrolled away and new lines came in.
        XCTAssertEqual(LogLines.appended(to: ["1", "2", "3", "4", "5"], from: ["3", "4", "5", "6"]), ["6"])
    }
}

final class RecordingTests: XCTestCase {
    func testFramesAndReplay() throws {
        var r = TabRecording(title: "demo", started: Date(timeIntervalSince1970: 1_700_000_000), columns: 20, rows: 3)
        XCTAssertTrue(r.add("$ ", at: 0))
        XCTAssertFalse(r.add("$ ", at: 0.2), "unchanged screens aren't kept")
        r.add("$ ls", at: 1)
        r.add("$ ls\na b", at: 10)
        r.marks.append(.init(t: 1, label: "ls"))
        XCTAssertEqual(r.frames.count, 3)
        XCTAssertEqual(r.frameIndex(at: 0.5), 0)
        XCTAssertEqual(r.frameIndex(at: 5), 1)
        XCTAssertEqual(r.frameIndex(at: 99), 2)
        let fast = r.compressingIdle(maxGap: 1.5)
        XCTAssertEqual(fast.duration, 2.5, accuracy: 0.001)
        XCTAssertEqual(fast.marks.first?.t ?? -1, 1, accuracy: 0.001)
        let back = try TabRecording.decode(r.encoded())
        XCTAssertEqual(back, r)
        let cast = r.asciicast().split(separator: "\n")
        XCTAssertEqual(cast.count, 4)
        let header = try JSONSerialization.jsonObject(with: Data(cast[0].utf8)) as? [String: Any]
        XCTAssertEqual(header?["version"] as? Int, 2)
        XCTAssertEqual(header?["width"] as? Int, 20)
        let ev = try JSONSerialization.jsonObject(with: Data(cast[3].utf8)) as? [Any]
        XCTAssertEqual(ev?[1] as? String, "o")
        XCTAssertTrue((ev?[2] as? String)?.contains("a b") == true)
        let html = r.html()
        XCTAssertTrue(html.contains("<title>demo</title>") && html.contains("\"frames\""))
        var s = TabRecording(title: "</script><b>", columns: 1, rows: 1)
        s.add("token=ghp_abcdefghijklmnopqrstuvwxyz0123", at: 0)
        XCTAssertFalse(s.redacted().frames[0].text.contains("ghp_"))
        XCTAssertFalse(s.html().contains("</script><b>"), "titles can't break out of the page")
    }
}
