import Foundation
import XCTest
@testable import AnserCore

final class NotebookTests: XCTestCase {
    func testGroupsEntriesAndMoves() {
        var nb = Notebook()
        let general = nb.groups[0].id
        let deploy = nb.addGroup(named: "Deploy")
        let a = nb.add(.init(title: "Build", command: "npm run build"), to: general)
        let b = nb.add(.init(title: "", command: "kubectl rollout restart deploy/api\n# then watch"), to: deploy)
        XCTAssertEqual(nb.entryCount, 2)
        XCTAssertEqual(nb.entry(b)?.displayTitle, "kubectl rollout restart deploy/api")

        nb.move(a, to: deploy)
        XCTAssertEqual(nb.groups[1].entries.map(\.id), [b, a])

        // Deleting a group keeps its commands (they move to the first group).
        nb.removeGroup(deploy)
        XCTAssertEqual(nb.groups.map(\.name), ["General"])
        XCTAssertEqual(nb.entryCount, 2)

        XCTAssertEqual(nb.addGroup(named: "General"), nb.groups.last?.id)
        XCTAssertEqual(nb.groups.last?.name, "General 2", "group names stay unique")
    }

    func testSearchAndRoundTrip() throws {
        var nb = Notebook()
        nb.add(.init(title: "Ports", command: "lsof -i :3000", note: "who holds the dev port"))
        nb.add(.init(title: "Disk", command: "du -sh *"))
        XCTAssertEqual(nb.filtered("dev port").flatMap(\.entries).map(\.title), ["Ports"])
        XCTAssertEqual(nb.filtered("").flatMap(\.entries).count, 2)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nb-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try nb.save(to: url)
        XCTAssertEqual(try Notebook.load(from: url), nb)
        XCTAssertEqual(try Notebook.load(from: url.appendingPathExtension("missing")).groups.map(\.name), ["General"])
    }
}

final class SessionExportTests: XCTestCase {
    let entries = [
        SessionExport.Entry(command: "echo <hi>", cwd: "/Users/me/app", exitCode: 0, duration: 0.012,
                            started: Date(timeIntervalSince1970: 1_800_000_000), output: "<hi>\n"),
        SessionExport.Entry(command: "false", cwd: "/tmp", exitCode: 1, duration: 2.5,
                            started: Date(timeIntervalSince1970: 1_800_000_010), output: nil),
    ]

    func testJSON() throws {
        let text = SessionExport.render(.json, title: "Run", entries: entries, home: "/Users/me")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(obj["title"] as? String, "Run")
        let cmds = try XCTUnwrap(obj["commands"] as? [[String: Any]])
        XCTAssertEqual(cmds.count, 2)
        XCTAssertEqual(cmds[0]["output"] as? String, "<hi>")
        XCTAssertEqual(cmds[0]["succeeded"] as? Bool, true)
        XCTAssertEqual(cmds[1]["exitCode"] as? Int, 1)
        XCTAssertTrue(cmds[1]["output"] is NSNull || cmds[1]["output"] == nil, "missing output stays empty, not invented")
    }

    func testHTMLEscapesAndText() {
        let html = SessionExport.render(.html, title: "A & B", entries: entries, home: "/Users/me")
        XCTAssertTrue(html.contains("echo &lt;hi&gt;"))
        XCTAssertTrue(html.contains("<title>A &amp; B</title>"))
        XCTAssertTrue(html.contains("~/app · 12 ms"))
        XCTAssertTrue(html.contains("class=\"cmd fail\""))
        let text = SessionExport.render(.text, title: "", entries: entries, home: "/Users/me")
        XCTAssertTrue(text.hasPrefix("$ echo <hi>\n# ~/app · 12 ms\n<hi>\n"))
        XCTAssertTrue(text.contains("# /tmp · 2.5 s · exit 1"))
    }
}

final class AppearanceModeTests: XCTestCase {
    func testThemeFollowsMode() {
        var a = AnserConfig.Appearance()
        a.theme = "Dracula"
        // No mode: the old single theme, whatever macOS does.
        XCTAssertEqual(a.themeName(systemIsDark: false), "Dracula")

        a.mode = "system"
        XCTAssertEqual(a.themeName(systemIsDark: true), "Dracula", "dark falls back to the old theme")
        XCTAssertEqual(a.themeName(systemIsDark: false), AnserConfig.Appearance.defaultLightTheme)
        a.lightTheme = "GitHub Light Default"
        XCTAssertEqual(a.themeName(systemIsDark: false), "GitHub Light Default")

        a.mode = "dark"
        XCTAssertEqual(a.themeName(systemIsDark: false), "Dracula")
        a.mode = "light"
        XCTAssertEqual(a.themeName(systemIsDark: true), "GitHub Light Default")
        XCTAssertTrue(a.ghosttyLines(systemIsDark: true).contains("theme = GitHub Light Default"))
    }
}

final class CopilotProviderTests: XCTestCase {
    let ctx = AIHelp.Context(shell: "zsh", os: "macOS", cwdName: "repo", gitBranch: "main")

    func testArgumentsTurnEveryToolOff() {
        let a = AIHelp.copilotArguments(path: "/opt/homebrew/bin/copilot", prompt: "hi", effort: "low", model: "gpt-5")
        XCTAssertEqual(a.first, "/opt/homebrew/bin/copilot")
        XCTAssertEqual(a.last, "--available-tools", "an empty tool list must come last")
        XCTAssertTrue(a.contains("--disable-builtin-mcps"))
        XCTAssertEqual(a[a.firstIndex(of: "--output-format")! + 1], "json")
        XCTAssertEqual(a[a.firstIndex(of: "--model")! + 1], "gpt-5")
        XCTAssertFalse(a.contains { $0.hasPrefix("--allow") || $0 == "--yolo" })
        XCTAssertFalse(AIHelp.copilotArguments(path: "c", prompt: "", effort: "", model: nil).contains("--model"))
    }

    func testReadsAnswerFromJSONEvents() async throws {
        let events = """
        {"type":"session.auto_mode_resolved","data":{"chosenModel":"gpt-6-luna"}}
        {"type":"assistant.message","data":{"model":"gpt-6-luna","content":"Count them:\\n```sh\\nwc -l < a.txt\\n```"}}
        {"type":"result","exitCode":0}
        """
        let seen = ArgsBox()
        let ai = AIHelp(copilotPath: { "/bin/copilot" }, runner: { argv, _ in seen.set(argv); return (0, events, false) })
        let a = try await ai.generateCommand("count lines in a.txt", context: ctx)
        XCTAssertEqual(a.commands, ["wc -l < a.txt"])
        XCTAssertEqual(a.model, "GitHub Copilot · gpt-6-luna")
        XCTAssertTrue(seen.get().contains { $0.contains("count lines in a.txt") }, "the request goes in the prompt")
    }

    func testErrors() async {
        let notInstalled = AIHelp(copilotPath: { nil })
        do { _ = try await notInstalled.generateCommand("x", context: ctx); XCTFail() } catch { XCTAssertEqual(error as? AIHelp.AIError, .copilotNotInstalled) }
        XCTAssertThrowsError(try AIHelp.parseCopilot(status: 1, output: "Error: Not authenticated. Run copilot login.", timedOut: false)) {
            XCTAssertEqual($0 as? AIHelp.AIError, .copilotNotSignedIn)
        }
        XCTAssertThrowsError(try AIHelp.parseCopilot(status: 1, output: "Error: Model \"x\" not available", timedOut: false)) {
            XCTAssertEqual($0 as? AIHelp.AIError, .copilot("Error: Model \"x\" not available"))
        }
        XCTAssertThrowsError(try AIHelp.parseCopilot(status: nil, output: "", timedOut: true))
        XCTAssertThrowsError(try AIHelp.parseCopilot(status: 0, output: "{\"type\":\"result\"}", timedOut: false)) {
            XCTAssertEqual($0 as? AIHelp.AIError, .badResponse)
        }
    }

    /// Talks to the real Copilot CLI. Run with ANSER_LIVE_COPILOT=1 (uses one premium request).
    func testLiveCopilot() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANSER_LIVE_COPILOT"] == "1")
        let ai = AIHelp()
        let a = try await ai.generateCommand("show the current folder's path", context: ctx)
        XCTAssertFalse(a.commands.isEmpty, a.text)
        print("live copilot:", a.model ?? "", a.commands)
    }
}

final class ArgsBox: @unchecked Sendable {
    private var v: [String] = []
    private let l = NSLock()
    func set(_ a: [String]) { l.withLock { v = a } }
    func get() -> [String] { l.withLock { v } }
}
