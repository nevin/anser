import Foundation
import XCTest
import CoreGraphics
import ImageIO
@testable import AnserCore

final class ProfileTests: XCTestCase {
    let profiles = [
        Profile(host: "prod-*", tabColor: "red", badge: "PROD", confirm: ["*"]),
        Profile(folder: "~/work/payments", badge: "payments", env: ["AWS_PROFILE": "pay"]),
        Profile(folder: "~/work", tabColor: "blue", env: ["AWS_PROFILE": "work", "REGION": "eu"]),
    ]

    func testMatchingHostsAndFolders() {
        let home = "/Users/me"
        XCTAssertEqual(Profile.resolve(profiles, host: "prod-db1", cwd: "/var", home: home)?.badge, "PROD")
        XCTAssertNil(Profile.resolve(profiles, host: "staging-1", cwd: "/var", home: home))
        // A folder profile matches the folder and anything inside it, but not remote shells.
        let p = Profile.resolve(profiles, host: nil, cwd: "/Users/me/work/payments/api", home: home)
        XCTAssertEqual(p?.badge, "payments")
        XCTAssertEqual(p?.tabColor, "blue", "fields not set by the first match come from the next")
        XCTAssertEqual(p?.env, ["AWS_PROFILE": "pay", "REGION": "eu"], "the first match wins per variable")
        XCTAssertNil(Profile.resolve(profiles, host: nil, cwd: "/Users/me/workshop", home: home), "a folder isn't a name prefix")
        XCTAssertNil(Profile.resolve(profiles, host: "box", cwd: "/Users/me/work", home: home))
    }

    func testConfirmation() {
        XCTAssertTrue(Profile(confirm: ["*"]).needsConfirmation("ls"))
        let p = Profile(confirm: ["*rm -rf*", "*drop table*"])
        XCTAssertTrue(p.needsConfirmation("sudo rm -rf /tmp/x"))
        XCTAssertTrue(p.needsConfirmation("psql -c 'DROP TABLE users'"))
        XCTAssertFalse(p.needsConfirmation("ls -la"))
        XCTAssertFalse(p.needsConfirmation("   "))
    }

    func testDecodesFromConfig() throws {
        let json = #"{"profiles":[{"host":"prod-*","tabColor":"red","badge":"PROD","confirm":["*"]}],"quickTerminalHotkey":"ctrl+`","saveOutput":false}"#
        let c = try JSONDecoder().decode(AnserConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.profiles.first?.badge, "PROD")
        XCTAssertEqual(c.quickTerminalHotkey, "ctrl+`")
        XCTAssertFalse(c.saveOutput)
        XCTAssertFalse(c.usageStats, "usage counting is off unless turned on")
        XCTAssertTrue(c.showPullRequests)
    }
}

final class HotKeyTests: XCTestCase {
    func testParse() {
        let k = HotKey.parse("ctrl+`")
        XCTAssertEqual(k?.keyCode, 50)
        XCTAssertEqual(k?.modifiers, 4096)
        XCTAssertEqual(k?.display, "⌃`")
        XCTAssertEqual(HotKey.parse("Option+Space")?.display, "⌥Space")
        XCTAssertEqual(HotKey.parse("cmd+shift+t")?.modifiers, 256 | 512)
        XCTAssertEqual(HotKey.parse("f12")?.keyCode, 111, "function keys may stand alone")
        XCTAssertNil(HotKey.parse("t"), "a plain key would block typing everywhere")
        XCTAssertNil(HotKey.parse("shift+t"))
        XCTAssertNil(HotKey.parse("ctrl+nosuchkey"))
        XCTAssertNil(HotKey.parse("hyper+t"))
    }
}

final class TipTests: XCTestCase {
    func testTipsShowOnceAndAreSpaced() {
        var t = TipEngine()
        let now = Date()
        for _ in 0..<5 { XCTAssertNil(t.historyArrow(now: now)) }
        let tip = t.historyArrow(now: now)
        XCTAssertEqual(tip?.id, "arrow")
        XCTAssertNil(t.historyArrow(now: now.addingTimeInterval(9999)), "never twice")
        XCTAssertNil(t.commandStarted("clear", aiEnabled: false, now: now.addingTimeInterval(60)), "spaced out")
        XCTAssertEqual(t.commandStarted("clear", aiEnabled: false, now: now.addingTimeInterval(700))?.id, "clear")
    }

    func testCommandPatterns() {
        var t = TipEngine()
        t.spacing = 0
        XCTAssertEqual(t.commandStarted("history | grep docker", aiEnabled: false)?.id, "history-grep")
        for _ in 0..<2 { XCTAssertNil(t.commandStarted("git checkout main", aiEnabled: false)) }
        XCTAssertEqual(t.commandStarted("git switch dev", aiEnabled: false)?.id, "git-switch")
        let long = "docker compose -f dev.yml up --build"
        for _ in 0..<3 { _ = t.commandStarted(long, aiEnabled: false) }
        XCTAssertEqual(t.commandStarted(long, aiEnabled: false)?.id, "save-notebook")
        XCTAssertFalse(t.state.counts.keys.contains { $0.hasPrefix("repeat:") }, "repeat counters are dropped once used")
        XCTAssertNil(t.commandFinished(exitCode: 130, aiEnabled: true), "Ctrl-C isn't a failure")
        _ = t.commandFinished(exitCode: 1, aiEnabled: true); _ = t.commandFinished(exitCode: 2, aiEnabled: true)
        XCTAssertEqual(t.commandFinished(exitCode: 1, aiEnabled: true)?.id, "explain")
    }

    func testStateRoundTrips() throws {
        var t = TipEngine()
        _ = t.mouseCopy()
        let d = try JSONEncoder().encode(t.state)
        XCTAssertEqual(try JSONDecoder().decode(TipEngine.State.self, from: d), t.state)
    }
}

final class UsageStatsTests: XCTestCase {
    func testCountsAndSummary() {
        var u = UsageStats()
        let now = Date()
        u.record("history.search", at: now)
        u.record("history.search", at: now)
        u.record("history.search", at: now.addingTimeInterval(-86_400 * 2))
        u.record("ai.explain", at: now)
        u.record("old", at: now.addingTimeInterval(-86_400 * 120))
        let s = u.summary(days: 30, now: now)
        XCTAssertEqual(s.first, .init(feature: "history.search", count: 3, daysUsed: 2))
        XCTAssertFalse(s.contains { $0.feature == "old" })
        u.prune(keep: 90, now: now)
        XCTAssertEqual(u.days.count, 2)
        XCTAssertTrue(u.report(now: now).contains("ai.explain: 1"))
        XCTAssertTrue(UsageStats().report().contains("No usage"))
    }
}

final class OutputHistoryTests: XCTestCase {
    func testSaveSearchAndForget() {
        let path = NSTemporaryDirectory() + "out-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let h = HistoryStore(path: path)
        let a = h.recordStart(command: "make build", cwd: "/p", session: "s")
        h.recordFinish(id: a, exitCode: 2, duration: 1)
        h.saveOutput("compiling…\nerror: undefined symbol _foo\n", forHistoryID: a)
        let b = h.recordStart(command: "ls", cwd: "/p", session: "s")
        h.saveOutput("README.md\n", forHistoryID: b)

        let hits = h.searchOutput("UNDEFINED SYMBOL")
        XCTAssertEqual(hits.map(\.entry.command), ["make build"])
        XCTAssertEqual(hits.first?.line, "error: undefined symbol _foo")
        XCTAssertEqual(h.searchOutput("").map(\.entry.command), ["ls", "make build"], "empty search lists newest first")
        XCTAssertEqual(h.output(forHistoryID: b), "README.md")

        // Long output keeps its end.
        let c = h.recordStart(command: "yes", cwd: "/p", session: "s")
        h.saveOutput(String(repeating: "y\n", count: 40_000) + "THE END", forHistoryID: c)
        XCTAssertTrue(h.output(forHistoryID: c)?.hasSuffix("THE END") == true)
        XCTAssertLessThanOrEqual(h.output(forHistoryID: c)?.count ?? 0, HistoryStore.maxOutputCharacters)

        // Forgetting a command forgets its output.
        h.delete(command: "make build")
        XCTAssertTrue(h.searchOutput("undefined").isEmpty)
        XCTAssertTrue(h.search("make", scope: .output).isEmpty, "the Output scope is searched with searchOutput")
    }
}

final class OllamaTests: XCTestCase {
    let ctx = AIHelp.Context(shell: "zsh", os: "macOS", cwdName: "repo", gitBranch: nil)

    func testAsksTheLocalServer() async throws {
        let seen = ArgsBox()
        let ai = AIHelp(ollamaURL: URL(string: "http://localhost:9999")!, ollamaModel: nil, transport: { req in
            seen.set((seen.get()) + [req.url!.path])
            if req.url!.path == "/api/tags" {
                return (200, Data(#"{"models":[{"name":"qwen2.5-coder:7b"},{"name":"llama3.2"}]}"#.utf8))
            }
            let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "qwen2.5-coder:7b", "no model set: the first installed one")
            XCTAssertEqual(body["stream"] as? Bool, false)
            let reply = #"{"model":"qwen2.5-coder:7b","message":{"role":"assistant","content":"<think>hmm</think>Use:\n```sh\npwd\n```"}}"#
            return (200, Data(reply.utf8))
        })
        let a = try await ai.generateCommand("show the folder", context: ctx)
        XCTAssertEqual(a.commands, ["pwd"])
        XCTAssertFalse(a.text.contains("think"), "reasoning is dropped")
        XCTAssertEqual(a.model, "Local · qwen2.5-coder:7b")
        XCTAssertEqual(seen.get(), ["/api/tags", "/api/chat"])
        XCTAssertEqual(ai.provider, .ollama)
        XCTAssertTrue(AIHelp.Provider.ollama.destination.contains("nothing leaves"))
    }

    func testErrors() async {
        let down = AIHelp(ollamaModel: nil, transport: { _ in throw URLError(.cannotConnectToHost) })
        do { _ = try await down.generateCommand("x", context: ctx); XCTFail() } catch { XCTAssertEqual(error as? AIHelp.AIError, .ollamaNotRunning) }
        let empty = AIHelp(ollamaModel: nil, transport: { _ in (200, Data(#"{"models":[]}"#.utf8)) })
        do { _ = try await empty.generateCommand("x", context: ctx); XCTFail() } catch { XCTAssertEqual(error as? AIHelp.AIError, .ollamaNoModel) }
        XCTAssertThrowsError(try AIHelp.parseOllama(status: 404, data: Data(#"{"error":"model 'x' not found"}"#.utf8)))
    }
}

final class NotebookMergeTests: XCTestCase {
    func testSnippetsImportOnce() {
        var nb = Notebook()
        let snippets = [AnserConfig.Snippet(name: "Ports", command: "lsof -i :{{port}}", description: "who holds it")]
        XCTAssertTrue(nb.importSnippets(snippets))
        XCTAssertEqual(nb.groups.map(\.name), ["General", "Snippets"])
        XCTAssertEqual(nb.entry(titled: "ports")?.note, "who holds it")
        nb.removeGroup(nb.groups[1].id)
        XCTAssertFalse(nb.importSnippets(snippets), "only once, so deleted ones don't come back")
        XCTAssertEqual(Notebook.starter.importedSnippets, true)
        XCTAssertEqual(Notebook.starter.entryCount, 4)
    }

    func testMergeKeepsBoth() {
        var a = Notebook()
        let shared = Notebook.Entry(title: "same", command: "echo same")
        a.add(shared)
        var b = a
        a.add(.init(title: "only a", command: "a"))
        let g = b.addGroup(named: "Deploy")
        b.add(.init(title: "only b", command: "b"), to: g)
        let m = a.merged(with: b)
        XCTAssertEqual(m.entryCount, 3)
        XCTAssertEqual(m.groups.map(\.name), ["General", "Deploy"])
    }
}

final class GitInfoTests: XCTestCase {
    func testPullRequest() {
        let json = #"{"number":42,"title":"Add thing","state":"OPEN","url":"https://github.com/o/r/pull/42","isDraft":false,"reviewDecision":"APPROVED","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","state":"SUCCESS"}]}"#
        let pr = GitInfo.parsePullRequest(json)
        XCTAssertEqual(pr?.chipText, "#42 ✓")
        XCTAssertTrue(pr?.summary.contains("Approved") == true)
        let failing = json.replacingOccurrences(of: #""conclusion":"SUCCESS""#, with: #""conclusion":"FAILURE""#)
        XCTAssertEqual(GitInfo.parsePullRequest(failing)?.checks, .failing)
        let running = json.replacingOccurrences(of: #""status":"COMPLETED","conclusion":"SUCCESS""#, with: #""status":"IN_PROGRESS","conclusion":"""#)
        XCTAssertEqual(GitInfo.parsePullRequest(running)?.chipText, "#42 …")
        XCTAssertEqual(GitInfo.parsePullRequest(json.replacingOccurrences(of: "OPEN", with: "MERGED"))?.chipText, "#42 merged")
        XCTAssertNil(GitInfo.parsePullRequest("no pull requests found for branch \"x\""))
    }

    func testConflictsAndOperation() throws {
        let porcelain = "UU src/a.swift\n M other.txt\nAA \"new file.txt\"\nUD gone.txt\n?? x\n"
        XCTAssertEqual(GitInfo.parseConflicts(porcelain), [
            .init(path: "src/a.swift", kind: "both modified"), .init(path: "new file.txt", kind: "both added"),
            .init(path: "gone.txt", kind: "deleted by them"),
        ])
        let dir = NSTemporaryDirectory() + "gitop-\(UUID())"
        try FileManager.default.createDirectory(atPath: dir + "/.git/rebase-merge", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        XCTAssertEqual(GitInfo.gitDir(for: dir + "/sub"), dir + "/.git")
        XCTAssertEqual(GitInfo.operation(gitDir: dir + "/.git"), .rebase)
    }
}

final class ImporterTests: XCTestCase {
    func testMiniYAML() {
        let y = """
        ---
        # a comment
        name: "Uninstall: a package"
        command: |-
            brew tap x/y
            brew rmtree {{package_name}}
        tags:
          - homebrew
          - cleanup
        arguments:
          - name: package_name
            description: The package
            default_value: wget
          - name: other
            default_value: ~
        author: 'Ian O''Neil'
        """
        let d = MiniYAML.parse(y) as? [String: Any]
        XCTAssertEqual(d?["name"] as? String, "Uninstall: a package")
        XCTAssertEqual(d?["command"] as? String, "brew tap x/y\nbrew rmtree {{package_name}}")
        XCTAssertEqual(d?["tags"] as? [String], ["homebrew", "cleanup"])
        let args = d?["arguments"] as? [[String: Any]]
        XCTAssertEqual(args?.first?["default_value"] as? String, "wget")
        XCTAssertTrue(args?.last?["default_value"] is NSNull)
        XCTAssertEqual(d?["author"] as? String, "Ian O'Neil")
    }

    func testWarpWorkflowAndTheme() {
        let wf = """
        name: Remove a package
        command: brew rmtree {{package_name}}
        description: Removes it and its dependencies
        arguments:
          - name: package_name
            default_value: wget
        """
        let e = Importers.warpWorkflows(yaml: wf)
        XCTAssertEqual(e.first?.command, "brew rmtree {{package_name:wget}}")
        XCTAssertEqual(e.first?.note, "Removes it and its dependencies")

        let theme = """
        accent: '#268bd2'
        background: '#002b36'
        foreground: '#839496'
        details: darker
        terminal_colors:
          normal:
            black: '#073642'
            red: '#dc322f'
          bright:
            black: '#002b36'
        """
        let t = Importers.warpTheme(yaml: theme, name: "solarized")
        XCTAssertEqual(t?.name, "Warp - solarized")
        XCTAssertTrue(t?.text.contains("palette = 0=#073642") == true)
        XCTAssertTrue(t?.text.contains("palette = 8=#002b36") == true)
        XCTAssertTrue(t?.text.contains("background = #002b36") == true)
    }

    func testWarpFolder() throws {
        let home = NSTemporaryDirectory() + "warp-\(UUID())"
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.warp/workflows", withIntermediateDirectories: true)
        try "name: Hi\ncommand: echo hi\n".write(toFile: home + "/.warp/workflows/hi.yaml", atomically: true, encoding: .utf8)
        let f = Importers.warp(home: home, prefs: URL(fileURLWithPath: home + "/none.plist"))
        XCTAssertEqual(f?.entries.map(\.command), ["echo hi"])
        XCTAssertEqual(f?.summary, "1 workflow → Notebook")
        XCTAssertNil(Importers.warp(home: home + "/missing"))
    }

    func testITerm2Profiles() throws {
        func color(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] { ["Red Component": r, "Green Component": g, "Blue Component": b] }
        var profile: [String: Any] = ["Name": "Work", "Guid": "g1", "Normal Font": "Menlo-Regular 14",
                                      "Background Color": color(0, 0, 0), "Foreground Color": color(1, 1, 1)]
        for i in 0..<16 { profile["Ansi \(i) Color"] = color(Double(i) / 15, 0, 0) }
        let plist: [String: Any] = ["New Bookmarks": [profile], "Default Bookmark Guid": "g1"]
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "iterm-\(UUID()).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
        let f = try XCTUnwrap(Importers.iTerm2(prefs: url))
        XCTAssertEqual(f.themes.first?.name, "iTerm2 - Work")
        XCTAssertEqual(f.currentTheme, "iTerm2 - Work")
        XCTAssertTrue(f.themes.first?.text.contains("palette = 15=#ff0000") == true)
        XCTAssertTrue(f.themes.first?.text.contains("background = #000000") == true)
        XCTAssertEqual(f.fontFamily, "Menlo")
        XCTAssertEqual(f.fontSize, 14)
    }
}

final class OpenRequestTests: XCTestCase {
    func testSSHLinks() {
        XCTAssertEqual(OpenRequests.sshCommand(URL(string: "ssh://deploy@prod-1.example.com:2222")!), "ssh -p 2222 -- deploy@prod-1.example.com")
        XCTAssertEqual(OpenRequests.sshCommand(URL(string: "ssh://box")!), "ssh -- box")
        XCTAssertEqual(OpenRequests.sshCommand(URL(string: "ssh://me@[::1]")!), "ssh -- me@::1")
        // Anything that could become an option or shell syntax is refused.
        for bad in ["ssh://-oProxyCommand=evil", "ssh://-x@host", "ssh://host;rm%20-rf", "ssh://a%60id%60@host", "http://host", "ssh://"] {
            XCTAssertNil(URL(string: bad).flatMap(OpenRequests.sshCommand), bad)
        }
        XCTAssertEqual(OpenRequests.sshCommand(URL(string: "ssh://me:secret@host/some/path?x=1")!), "ssh -- me@host", "passwords and paths are dropped")
    }

    func testManLinks() {
        XCTAssertEqual(OpenRequests.manCommand(URL(string: "x-man-page://ls")!), "man ls")
        XCTAssertEqual(OpenRequests.manCommand(URL(string: "x-man-page://3/printf")!), "man 3 printf")
        XCTAssertNil(OpenRequests.manCommand(URL(string: "x-man-page://-P%20evil")!))
        XCTAssertNil(OpenRequests.manCommand(URL(string: "x-man-page://a/b/c")!))
    }

    func testScriptCommandQuotes() {
        XCTAssertEqual(OpenRequests.scriptCommand(path: "/Users/me/My Scripts/go.command"), "/Users/me/My\\ Scripts/go.command")
    }
}

final class SessionProtocolTests: XCTestCase {
    func testFramesSurviveSplitting() {
        let a = SessionProtocol.frame(.output, Data("hello".utf8))
        let b = SessionProtocol.frame(.resize, SessionProtocol.resizePayload(cols: 120, rows: 40))
        let c = SessionProtocol.frame(.exit, SessionProtocol.exitPayload(-3))
        let all = a + b + c
        var d = SessionProtocol.Decoder()
        var got: [(SessionProtocol.Kind, Data)] = []
        for byte in all { got += d.append(Data([byte])) }   // one byte at a time
        XCTAssertEqual(got.map(\.0), [.output, .resize, .exit])
        XCTAssertEqual(String(decoding: got[0].1, as: UTF8.self), "hello")
        XCTAssertEqual(SessionProtocol.parseResize(got[1].1)?.cols, 120)
        XCTAssertEqual(SessionProtocol.parseResize(got[1].1)?.rows, 40)
        XCTAssertEqual(SessionProtocol.parseExit(got[2].1), -3)
        var bad = SessionProtocol.Decoder()
        _ = bad.append(Data([0x99, 0, 0, 0, 1, 0]))
        XCTAssertTrue(bad.broken, "unknown frame types stop decoding")
        XCTAssertTrue(SessionProtocol.isValidID("A1B2-c3"))
        XCTAssertFalse(SessionProtocol.isValidID("../etc"))
    }

    func testReplayBufferTrimsAtLinesAndTracksFullScreen() {
        var r = ReplayBuffer(limit: 50)
        r.append(Data((String(repeating: "x", count: 30) + "\n").utf8))
        r.append(Data("line two is here\nline three\n".utf8))
        XCTAssertLessThanOrEqual(r.data.count, 50)
        XCTAssertTrue(String(decoding: r.data, as: UTF8.self).hasPrefix("line two"), "starts at a line break, never mid-sequence")
        r.append(Data("\u{1b}[?10".utf8)); r.append(Data("49h vim".utf8))
        XCTAssertTrue(r.alternateScreen, "found even when split across reads")
        r.append(Data("\u{1b}[?1049l".utf8))
        XCTAssertFalse(r.alternateScreen)
    }
}

final class SSHConfigTests: XCTestCase {
    func testHostsAndIncludes() {
        let text = """
        # comment
        Host web1 web2
          HostName 10.0.0.1
          User deploy
          Port 2222
        Host *.example.com !skip
          User x
        Include extra
        Host web1
          User someone-else
        """
        let h = SSHConfig.hosts(in: text) { name in name == "extra" ? ["Host db\n  HostName db.internal\n"] : [] }
        XCTAssertEqual(h.map(\.alias), ["web1", "web2", "db"])
        XCTAssertEqual(h[0].detail, "deploy@10.0.0.1:2222", "the first value wins, like ssh")
        XCTAssertEqual(h[2].hostName, "db.internal")
    }

    func testTargetOfCommand() {
        XCTAssertEqual(SSHConfig.target(of: "ssh prod-web"), "prod-web")
        XCTAssertEqual(SSHConfig.target(of: "ssh -A -p 2222 deploy@prod-web"), "prod-web")
        XCTAssertEqual(SSHConfig.target(of: "/usr/bin/ssh -i ~/.ssh/k box"), "box")
        XCTAssertNil(SSHConfig.target(of: "ssh box uptime"), "running a command isn't an interactive session")
        XCTAssertNil(SSHConfig.target(of: "sshfs box:/ mnt"))
    }
}

final class CommandLintTests: XCTestCase {
    let known: Set<String> = ["git", "ls", "echo", "rm", "curl", "sh", "dd", "kubectl", "psql", "tree", "date"]
    func lint(_ s: String) -> [CommandLint.Issue] {
        CommandLint.check(s, isKnown: { self.known.contains($0) }, suggest: { $0 == "tre" ? "tree" : nil })
    }

    func testMistakes() {
        XCTAssertEqual(lint("tre -L 2").first?.message, "“tre” isn't a command here. Did you mean “tree”?")
        XCTAssertTrue(lint("FOO=1 ls").isEmpty, "assignments aren't commands")
        XCTAssertTrue(lint("echo 'it''s fine' \"and $(date)\"").isEmpty)
        XCTAssertEqual(lint("echo 'oops").first?.message, "This ' quote isn't closed.")
        XCTAssertEqual(lint("echo $(date").first?.range.location, 6)
        XCTAssertEqual(lint("echo done)").first?.message, "This ) has no matching opening bracket.")
        XCTAssertTrue(lint("echo '(' # )").isEmpty, "brackets in quotes and comments don't count")
    }

    func testRisky() {
        func severity(_ s: String) -> CommandLint.Severity? { lint(s).filter { $0.severity != .error }.max { $0.severity < $1.severity }?.severity }
        XCTAssertEqual(severity("rm -rf /"), .danger)
        XCTAssertEqual(severity("sudo rm -rf ~"), .danger)
        XCTAssertEqual(severity("rm -fr \"$HOME\""), .danger)
        XCTAssertNil(severity("rm -rf build/"), "ordinary cleanups are fine")
        XCTAssertNil(severity("rm -rf ./node_modules"))
        XCTAssertEqual(severity("dd if=x.img of=/dev/disk4 bs=1m"), .danger)
        XCTAssertEqual(severity(":(){ :|:& };:"), .danger)
        XCTAssertEqual(severity("git push --force origin main"), .warning)
        XCTAssertEqual(severity("git push -f"), .warning)
        XCTAssertNil(severity("git push --force-with-lease"))
        XCTAssertEqual(severity("git reset --hard HEAD~1"), .warning)
        XCTAssertEqual(severity("curl -fsSL https://x.sh | sh"), .warning)
        XCTAssertEqual(severity("psql -c 'DROP TABLE users'"), .warning)
        XCTAssertNil(severity("echo hi # rm -rf /"), "comments are ignored")
    }

    func testMatchingBracket() {
        let line = "echo $(date) [x]"
        XCTAssertEqual(CommandLint.matchingBracket(in: line, at: 12).map { [$0.0, $0.1] }, [6, 11])
        XCTAssertEqual(CommandLint.matchingBracket(in: line, at: 13).map { [$0.0, $0.1] }, [13, 15])
        XCTAssertNil(CommandLint.matchingBracket(in: "echo '('", at: 7))
    }
}

final class TimingBlameImageTests: XCTestCase {
    func testTypicalDuration() {
        let path = NSTemporaryDirectory() + "t-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let h = HistoryStore(path: path)
        XCTAssertNil(h.timing(for: "make"))
        for (d, e) in [(30.0, 0), (50.0, 0), (40.0, 0), (5.0, 2)] {
            let id = h.recordStart(command: "make", cwd: "/p", session: "s")
            h.recordFinish(id: id, exitCode: e, duration: d)
        }
        let t = h.timing(for: "make")
        XCTAssertEqual(t?.typical, 40, "median of successful runs; failures don't count")
        XCTAssertEqual(t?.runs, 3)
        XCTAssertEqual(t?.fastest, 30)
    }

    func testBlamePorcelain() {
        let sha = String(repeating: "a", count: 40), zero = String(repeating: "0", count: 40)
        let text = """
        \(sha) 1 1 2
        author Ada
        author-time 1800000000
        summary Add the parser
        filename x.swift
        \tlet a = 1
        \(sha) 2 2
        \tlet b = 2
        \(zero) 3 3 1
        author Not Committed Yet
        author-time 1800000500
        summary Version of x.swift from x.swift
        \tlet c = 3
        """
        let lines = GitBlame.parse(text)
        XCTAssertEqual(lines.map(\.number), [1, 2, 3])
        XCTAssertEqual(lines[1].author, "Ada", "details are given once per commit")
        XCTAssertEqual(lines[1].summary, "Add the parser")
        XCTAssertEqual(lines[0].text, "let a = 1")
        XCTAssertTrue(lines[2].isUncommitted)
        XCTAssertEqual(lines[0].shortCommit, "aaaaaaaa")
    }

    /// A 2×2 PNG made here, so the test needs no files.
    func tinyPNG() -> Data {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testITermImagesBecomeKitty() {
        let png = tinyPNG()
        let seq = Data("before\u{1b}]1337;File=name=eA==;width=10;inline=1:\(png.base64EncodedString())\u{07}after".utf8)
        // Fed in tiny pieces, as output really arrives.
        var f = InlineImageFilter()
        var out = Data()
        var i = 0
        while i < seq.count { out += f.feed(seq.subdata(in: i..<min(i + 7, seq.count))); i += 7 }
        let s = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("before\u{1b}_Ga=T,f=100,q=2,c=10,m=0;"), String(s.prefix(60)))
        XCTAssertTrue(s.hasSuffix("\u{1b}\\after"))
        XCTAssertFalse(s.contains("1337"))
        var plain = InlineImageFilter()
        XCTAssertEqual(plain.feed(Data("ls \u{1b}[31mred\u{1b}[0m done".utf8)), Data("ls \u{1b}[31mred\u{1b}[0m done".utf8), "other escapes pass through")
        var download = InlineImageFilter()
        let file = "\u{1b}]1337;File=name=eA==:aGVsbG8=\u{07}"
        XCTAssertEqual(String(decoding: download.feed(Data(file.utf8)), as: UTF8.self), file, "downloads (no inline=1) are left alone")
    }

    func testLargeImagesAreChunked() {
        let seq = InlineImageFilter.kittySequence(png: Data(repeating: 7, count: 9000))
        let s = String(decoding: seq, as: UTF8.self)
        XCTAssertEqual(s.components(separatedBy: "\u{1b}_G").count - 1, 3, "12 000 base64 characters in 4 KB pieces")
        XCTAssertTrue(s.contains("m=1;") && s.contains("_Gm=0;"))
    }
}

final class HistoryDeleteTests: XCTestCase {
    func testDeleteRunsKeepsOtherRuns() {
        let path = NSTemporaryDirectory() + "d-\(UUID()).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let h = HistoryStore(path: path)
        let a = h.recordStart(command: "make", cwd: "/p", session: "tab1")
        let b = h.recordStart(command: "make", cwd: "/p", session: "tab2")
        let c = h.recordStart(command: "secret-ish", cwd: "/p", session: "tab1")
        h.saveOutput("built", forHistoryID: a)
        h.delete(ids: [a, c])
        XCTAssertEqual(h.search("make", scope: .all).count, 1, "another tab's run keeps it")
        XCTAssertTrue(h.search("secret-ish", scope: .all).isEmpty, "no runs left: gone from suggestions too")
        XCTAssertNil(h.output(forHistoryID: a))
        XCTAssertEqual(h.entries(session: "tab2").map(\.id), [b])
    }
}

final class MemoryBudgetTests: XCTestCase {
    func testNewestKeepsMostOlderShrinkThenDrop() {
        let b = OutputBudget(newest: 100, older: 10, total: 125)
        // oldest … newest
        // newest 100; then 10, 5, 10 (older ones cap at 10) reaching the total of 125; the oldest gets nothing.
        XCTAssertEqual(b.plan([50, 50, 5, 50, 500]), [nil, 10, 5, 10, 100])
        XCTAssertEqual(b.plan([nil, 3, nil]), [nil, 3, nil])
        XCTAssertEqual(b.plan([]), [])
    }

    func testTailCutsAtLinesAndCharacters() {
        let text = (0..<100).map { "line \($0) é" }.joined(separator: "\n")
        let t = OutputBudget.tail(text, bytes: 40)
        XCTAssertTrue(text.hasSuffix(t))
        XCTAssertTrue(t.hasPrefix("line "), "starts at a line: \(t)")
        XCTAssertLessThanOrEqual(t.utf8.count, 40)
        XCTAssertEqual(OutputBudget.tail("short", bytes: 40), "short")
        XCTAssertGreaterThan(MemoryUse.footprint().current, 0)
    }
}
